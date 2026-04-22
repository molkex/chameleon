package mobile

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
)

const hour = time.Hour

// GoogleSignInRequest is the body for POST /api/mobile/auth/google.
type GoogleSignInRequest struct {
	IDToken  string `json:"id_token"`
	DeviceID string `json:"device_id"`
}

// GoogleSignIn handles POST /api/mobile/auth/google.
//
// Mirrors AppleSignIn: verifies the Google ID token, finds or creates the user
// by google_id, links device_id, returns JWT pair. On sign-up we also capture
// the Google email into users.email and fire-and-forget a magic link so the
// user has a password-less secondary entry point.
func (h *Handler) GoogleSignIn(c echo.Context) error {
	if h.Google == nil || !h.Google.IsEnabled() {
		return c.JSON(http.StatusServiceUnavailable, ErrorResponse{
			Error: "google sign-in is not configured",
		})
	}

	var req GoogleSignInRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}
	req.IDToken = strings.TrimSpace(req.IDToken)
	req.DeviceID = strings.TrimSpace(req.DeviceID)

	if req.IDToken == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "id_token is required"})
	}
	if req.DeviceID == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "device_id is required"})
	}

	ctx := c.Request().Context()

	claims, err := h.Google.VerifyIDToken(ctx, req.IDToken)
	if err != nil {
		h.Logger.Warn("google: verify id token", zap.Error(err))
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "invalid google id_token"})
	}

	// Find existing user by google_id first.
	user, err := h.findUserByGoogleID(ctx, claims.Sub)
	if err != nil {
		h.Logger.Error("db: find by google_id", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	// If no google_id match but email is known and verified, link the existing
	// email-based user to this Google identity. Prevents duplicate accounts
	// when a user first signed up via email and later taps Google.
	if user == nil && claims.Email != "" && claims.EmailVerified {
		existing, err := h.DB.FindUserByEmail(ctx, claims.Email)
		if err != nil {
			h.Logger.Error("db: find by email", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		user = existing
	}

	// Also check by device_id — the user may have first tapped
	// "Continue without account" or Apple Sign-In on this device,
	// generating a vpn_username deterministically from device_id. A fresh
	// INSERT would then collide on unique(vpn_username). Re-use that row.
	if user == nil {
		existingByDevice, err := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
		if err != nil {
			h.Logger.Error("db: find by device_id", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		user = existingByDevice
	}

	isNew := false
	if user == nil {
		isNew = true
		user, err = h.createUser(ctx, req.DeviceID, "", "google")
		if err != nil {
			h.Logger.Error("google: create user", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
	}

	// Persist Google identity + email on the user row.
	dirty := false
	if user.GoogleID == nil || *user.GoogleID != claims.Sub {
		g := claims.Sub
		user.GoogleID = &g
		dirty = true
	}
	if user.DeviceID == nil || *user.DeviceID != req.DeviceID {
		did := req.DeviceID
		user.DeviceID = &did
		dirty = true
	}
	if !user.IsActive {
		user.IsActive = true
		dirty = true
	}
	if dirty {
		if err := h.DB.UpdateUser(ctx, user); err != nil {
			h.Logger.Error("google: update user", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
	}

	if claims.Email != "" && claims.EmailVerified {
		if user.Email == nil || *user.Email != claims.Email {
			if err := h.DB.SetUserEmail(ctx, user.ID, claims.Email); err != nil {
				h.Logger.Warn("google: set email (non-fatal)", zap.Error(err))
			} else {
				e := claims.Email
				user.Email = &e
			}
		}
		// Email from Google is already verified by Google — flip the flag
		// without requiring a magic-link round-trip.
		if err := h.DB.MarkEmailVerified(ctx, user.ID); err != nil {
			h.Logger.Warn("google: mark verified (non-fatal)", zap.Error(err))
		}
	}

	if err := h.addUserToVPN(ctx, user); err != nil {
		h.Logger.Warn("vpn: add google user (non-fatal)", zap.Error(err))
	}

	if isNew {
		h.captureInitialContext(c, user.ID)
	}

	// Fire-and-forget: send a backup magic link so the user can sign in from
	// another device via email if they lose access to their Google account.
	if isNew && claims.Email != "" && claims.EmailVerified {
		lang := langFromAcceptLanguage(c.Request().Header.Get("Accept-Language"))
		go h.issueBackupMagicLink(user.ID, claims.Email, "google_backup", lang)
	}

	vpnUsername := ""
	if user.VPNUsername != nil {
		vpnUsername = *user.VPNUsername
	}
	tokens, err := h.JWT.CreateTokenPair(user.ID, vpnUsername, "user")
	if err != nil {
		h.Logger.Error("jwt: create token pair", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	return c.JSON(http.StatusOK, AuthResponse{
		AccessToken:  tokens.AccessToken,
		RefreshToken: tokens.RefreshToken,
		ExpiresAt:    tokens.ExpiresAt,
		UserID:       user.ID,
		Username:     vpnUsername,
		IsNew:        isNew,
	})
}

// findUserByGoogleID is a thin wrapper; the column already exists in the
// users table but there is no dedicated DB method yet. Inline query avoids
// having to extend the DB layer just for Google.
func (h *Handler) findUserByGoogleID(ctx context.Context, googleID string) (*db.User, error) {
	return h.DB.FindUserByGoogleID(ctx, googleID)
}

// issueBackupMagicLink is run in a goroutine after a successful social
// sign-in. It creates a token with purpose "apple_backup" or "google_backup"
// and mails the link. `lang` comes from the caller's Accept-Language so the
// email matches the UI language the user just signed in with. Errors are
// non-fatal and logged.
func (h *Handler) issueBackupMagicLink(userID int64, emailAddr, purpose, lang string) {
	ctx := context.Background()
	raw, hashHex, err := db.GenerateRawToken()
	if err != nil {
		h.Logger.Warn("backup link: generate token", zap.Error(err))
		return
	}
	// Backup links live longer (24h) — the user may not check email right away
	// and is not under active attack pressure for this code path.
	if err := h.DB.CreateMagicToken(ctx, hashHex, emailAddr, purpose, &userID, nil, 24*hour); err != nil {
		h.Logger.Warn("backup link: insert token", zap.Error(err))
		return
	}
	h.sendMagicLinkEmail(ctx, emailAddr, raw, purpose, lang)
}

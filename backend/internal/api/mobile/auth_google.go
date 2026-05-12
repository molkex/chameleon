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

	// Check by device_id BEFORE email. The user may have first tapped
	// "Continue without account" or Apple Sign-In on this device,
	// creating a row with this device_id. We must reuse THAT row, not
	// pick an unrelated user with a matching email — otherwise we'd try
	// to set device_id on the email-user and collide on UNIQUE(device_id)
	// against the guest-user that already owns this device.
	if user == nil {
		existingByDevice, err := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
		if err != nil {
			h.Logger.Error("db: find by device_id", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		user = existingByDevice
	}

	// If no google_id and no device_id match but email is known and verified,
	// link the existing email-based user (cross-device merge: same person
	// who signed up via email on a different device, now using Google here).
	if user == nil && claims.Email != "" && claims.EmailVerified {
		existing, err := h.DB.FindUserByEmail(ctx, claims.Email)
		if err != nil {
			h.Logger.Error("db: find by email", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		user = existing
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
		// Before claiming this device_id, check whether another user
		// (typically a transient guest from the current install) already
		// owns it. If so, free the device_id on that user — otherwise
		// the UPDATE below explodes on UNIQUE(device_id).
		other, ferr := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
		if ferr != nil {
			h.Logger.Error("google: find conflicting device_id", zap.Error(ferr))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		if other != nil && other.ID != user.ID {
			h.Logger.Info("google: freeing device_id from conflicting user",
				zap.Int64("conflicting_user_id", other.ID),
				zap.Int64("claiming_user_id", user.ID))
			if err := h.DB.ClearDeviceID(ctx, other.ID); err != nil {
				h.Logger.Error("google: clear conflicting device_id", zap.Error(err))
				return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
			}
		}
		did := req.DeviceID
		user.DeviceID = &did
		dirty = true
	}
	if !user.IsActive {
		user.IsActive = true
		dirty = true
	}
	// Wiped users (account-deletion option B, or web-flow without VPN creds)
	// come back with NULL VPN creds. Regenerate so the tunnel can actually
	// authenticate with sing-box. Without this, /config returns 409 OR the
	// tunnel "connects" but server-side drops every packet — exactly what
	// the user sees as "VPN is on but Safari hangs".
	if user.VPNUsername == nil || user.VPNUUID == nil {
		vpnUUID, gerr := generateUUID()
		if gerr != nil {
			h.Logger.Error("google: regen vpn uuid", zap.Error(gerr))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		vpnUsername := generateVPNUsernameFromUUID(vpnUUID)
		vpnShortID := ""
		user.VPNUsername = &vpnUsername
		user.VPNUUID = &vpnUUID
		user.VPNShortID = &vpnShortID
		dirty = true
		h.Logger.Info("google: regenerated vpn creds for returning user",
			zap.Int64("user_id", user.ID),
			zap.String("vpn_username", vpnUsername))
	}
	// Returning user with expired trial / no active subscription — extend by
	// 3 days so they re-enter a working state. Otherwise GET /config returns
	// 403 (subscription expired) immediately after the sign-in succeeds, and
	// the iOS app interprets the *flow* as failed even though auth itself
	// worked. Users with an active App Store IAP receipt are validated
	// separately (StoreKit verifies on backend) — this branch only kicks in
	// when both server-side trial AND IAP entitlement are gone.
	if user.SubscriptionExpiry == nil || user.SubscriptionExpiry.Before(time.Now()) {
		trialDays := 3
		if h.Config != nil && h.Config.Payments.Trial.Enabled && h.Config.Payments.Trial.Days > 0 {
			trialDays = h.Config.Payments.Trial.Days
		}
		newExpiry := time.Now().Add(time.Duration(trialDays) * 24 * time.Hour)
		user.SubscriptionExpiry = &newExpiry
		dirty = true
		h.Logger.Info("google: extending expired trial on sign-in",
			zap.Int64("user_id", user.ID),
			zap.Time("new_expiry", newExpiry))
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

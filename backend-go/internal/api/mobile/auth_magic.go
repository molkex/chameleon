package mobile

import (
	"context"
	"fmt"
	"net/http"
	"net/mail"
	"strings"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/email"
)

// MagicLinkRequestBody is POST /auth/magic/request input.
type MagicLinkRequestBody struct {
	Email    string `json:"email"`
	DeviceID string `json:"device_id,omitempty"` // optional — if present, links device on verify
}

// MagicLinkRequest handles POST /api/mobile/auth/magic/request.
//
// Flow:
//  1. Validate email format.
//  2. Rate-limit per email (5 requests / hour).
//  3. Resolve existing user (if any) — sign-up branch sets user_id=nil.
//  4. Create a magic_token row (15 min TTL).
//  5. Send email via Resend.
//
// The response is always 204 No Content, whether or not we found a user —
// this avoids leaking which addresses have accounts.
func (h *Handler) MagicLinkRequest(c echo.Context) error {
	var req MagicLinkRequestBody
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}

	addr, err := mail.ParseAddress(strings.TrimSpace(req.Email))
	if err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid email"})
	}
	emailLower := strings.ToLower(addr.Address)

	ctx := c.Request().Context()

	// Rate limit per email.
	count, err := h.DB.CountRecentMagicRequests(ctx, emailLower, db.MagicRequestRateWindow)
	if err != nil {
		h.Logger.Error("magic: count recent", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	if count >= db.MagicRequestRateLimit {
		return c.JSON(http.StatusTooManyRequests, ErrorResponse{
			Error: "too many requests — try again later",
		})
	}

	// Look up existing user (optional — may be nil for a fresh signup).
	existing, err := h.DB.FindUserByEmail(ctx, emailLower)
	if err != nil {
		h.Logger.Error("magic: find by email", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	var userID *int64
	purpose := "email_signup"
	if existing != nil {
		userID = &existing.ID
		purpose = "email_login"
	}

	raw, hashHex, err := db.GenerateRawToken()
	if err != nil {
		h.Logger.Error("magic: generate token", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	ip := c.RealIP()
	if err := h.DB.CreateMagicToken(ctx, hashHex, emailLower, purpose, userID, &ip, 0); err != nil {
		h.Logger.Error("magic: insert token", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	go h.sendMagicLinkEmail(context.Background(), emailLower, raw, purpose)

	return c.NoContent(http.StatusNoContent)
}

// MagicLinkVerifyBody is POST /auth/magic/verify input.
type MagicLinkVerifyBody struct {
	Token    string `json:"token"`
	DeviceID string `json:"device_id,omitempty"` // links this device on successful verify
}

// MagicLinkVerify handles POST /api/mobile/auth/magic/verify.
//
// Flow:
//  1. Hash the raw token, UPDATE ... RETURNING to atomically consume it.
//  2. If token has user_id → existing user login: mark email verified, issue JWTs.
//  3. If no user_id → fresh signup: create user with this email, issue JWTs.
//  4. Always require device_id on signup so we can associate the trial.
func (h *Handler) MagicLinkVerify(c echo.Context) error {
	var req MagicLinkVerifyBody
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}
	req.Token = strings.TrimSpace(req.Token)
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if req.Token == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "token is required"})
	}

	ctx := c.Request().Context()

	hashHex := db.HashToken(req.Token)
	mt, err := h.DB.ConsumeMagicToken(ctx, hashHex)
	if err != nil {
		h.Logger.Error("magic: consume", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	if mt == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{
			Error: "link is expired or already used",
		})
	}

	var user *db.User
	isNew := false
	if mt.UserID != nil {
		// Existing user login.
		u, err := h.DB.FindUserByID(ctx, *mt.UserID)
		if err != nil || u == nil {
			h.Logger.Error("magic: find user by id", zap.Error(err), zap.Int64p("id", mt.UserID))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		user = u
	} else {
		// Fresh signup — device_id required so VPN creds can be generated.
		if req.DeviceID == "" {
			return c.JSON(http.StatusBadRequest, ErrorResponse{
				Error: "device_id is required for first sign-in",
			})
		}
		user, err = h.createUser(ctx, req.DeviceID, "", "email")
		if err != nil {
			h.Logger.Error("magic: create user", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		// Persist the email on the just-created user.
		if err := h.DB.SetUserEmail(ctx, user.ID, mt.Email); err != nil {
			h.Logger.Error("magic: set email on new user", zap.Error(err))
		}
		user.Email = &mt.Email
		isNew = true
		h.Logger.Info("magic: new email user", zap.Int64("user_id", user.ID), zap.String("email", mt.Email))
	}

	// Mark email as verified (they proved control by following the link).
	if err := h.DB.MarkEmailVerified(ctx, user.ID); err != nil {
		h.Logger.Warn("magic: mark email verified (non-fatal)", zap.Error(err))
	}

	// Link device_id if the caller sent one and it differs.
	if req.DeviceID != "" && (user.DeviceID == nil || *user.DeviceID != req.DeviceID) {
		user.DeviceID = &req.DeviceID
		if err := h.DB.UpdateUser(ctx, user); err != nil {
			h.Logger.Warn("magic: update device_id (non-fatal)", zap.Error(err))
		}
	}

	// Add to VPN engine best-effort.
	if err := h.addUserToVPN(ctx, user); err != nil {
		h.Logger.Warn("vpn: add user (non-fatal)", zap.Error(err), zap.Int64("user_id", user.ID))
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

// sendMagicLinkEmail fires-and-forgets the link email. Called in a goroutine
// so the HTTP response isn't blocked on SMTP. Errors are logged but don't
// affect the user-facing flow.
func (h *Handler) sendMagicLinkEmail(ctx context.Context, toEmail, rawToken, purpose string) {
	if h.Email == nil {
		h.Logger.Warn("magic: no email sender configured, dropping link")
		return
	}

	scheme := "https://madfrog.online"
	if h.Config != nil && h.Config.Email.AppScheme != "" {
		scheme = strings.TrimRight(h.Config.Email.AppScheme, "/")
	}
	link := fmt.Sprintf("%s/app/signin?token=%s", scheme, rawToken)

	subject := "Sign in to MadFrog VPN"
	if purpose == "email_signup" {
		subject = "Welcome to MadFrog VPN"
	}

	html := fmt.Sprintf(`<!doctype html>
<html><body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 32px; background: #0a0e1a; color: #f3faff;">
<div style="max-width: 480px; margin: 0 auto; background: #121827; border-radius: 16px; padding: 32px;">
<h1 style="color: #8CFF4F; font-size: 22px; margin: 0 0 16px;">MadFrog VPN</h1>
<p style="color: #f3faff; font-size: 16px; line-height: 1.5;">Tap the button below to sign in on your device. This link works once and expires in 15 minutes.</p>
<p style="margin: 32px 0;"><a href="%s" style="background: #8CFF4F; color: #0a0e1a; text-decoration: none; padding: 14px 28px; border-radius: 10px; font-weight: 700; display: inline-block;">Sign in</a></p>
<p style="color: #8496b4; font-size: 13px;">If you didn't request this, ignore the email — your account stays safe.</p>
<p style="color: #8496b4; font-size: 11px; margin-top: 24px; word-break: break-all;">Or paste this link in Safari: <br>%s</p>
</div>
</body></html>`, link, link)

	text := fmt.Sprintf("Sign in to MadFrog VPN:\n\n%s\n\nThis link works once and expires in 15 minutes.\nIf you didn't request this, ignore the email.\n", link)

	if err := h.Email.Send(ctx, email.Message{
		To:       toEmail,
		Subject:  subject,
		HTMLBody: html,
		TextBody: text,
	}); err != nil {
		h.Logger.Warn("magic: email send failed", zap.Error(err), zap.String("to", toEmail))
	}
}

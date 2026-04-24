package mobile

import (
	"context"
	"fmt"
	"net/http"
	"net/mail"
	"strings"
	"time"

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

	lang := langFromAcceptLanguage(c.Request().Header.Get("Accept-Language"))
	go func(email, token, purp, lang string) {
		// Bound the SMTP send so a hung mail provider can't leak goroutines.
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		h.sendMagicLinkEmail(ctx, email, token, purp, lang)
	}(emailLower, raw, purpose, lang)

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
		// Re-use an existing device row if the user was previously registered
		// anonymously or via Apple on this device. Avoids unique(vpn_username)
		// collisions and silently merges the device into the email identity.
		existingByDevice, err := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
		if err != nil {
			h.Logger.Error("magic: find by device_id", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		if existingByDevice != nil {
			user = existingByDevice
		} else {
			user, err = h.createUser(ctx, req.DeviceID, "", "email")
			if err != nil {
				h.Logger.Error("magic: create user", zap.Error(err))
				return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
			}
		}
		// Persist the email on the user.
		if err := h.DB.SetUserEmail(ctx, user.ID, mt.Email); err != nil {
			h.Logger.Error("magic: set email on new user", zap.Error(err))
		}
		user.Email = &mt.Email
		isNew = existingByDevice == nil
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
//
// Locale is resolved from the "lang" parameter — handlers pass it in from
// the user's Accept-Language header. Currently we localize to RU when the
// first tag is "ru"; everything else falls back to EN. The two-bucket
// model keeps templates maintainable; add more when we localize the UI.
func (h *Handler) sendMagicLinkEmail(ctx context.Context, toEmail, rawToken, purpose, lang string) {
	if h.Email == nil {
		h.Logger.Warn("magic: no email sender configured, dropping link")
		return
	}

	scheme := "https://madfrog.online"
	if h.Config != nil && h.Config.Email.AppScheme != "" {
		scheme = strings.TrimRight(h.Config.Email.AppScheme, "/")
	}
	link := fmt.Sprintf("%s/app/signin?token=%s", scheme, rawToken)

	tmpl := magicEmailTemplate(lang, purpose)

	// Branded template with the green CTA. The deliverability trade-off
	// was a wash — bare plain-HTML still landed in Junk on fresh-domain
	// iCloud, so we keep the nicer design that users actually recognise.
	// Domain reputation is what eventually moves the needle, not template
	// minimalism. Shape is deliberately light: ONE link, no images, no
	// tracking pixels, tables for client-wide compatibility (Outlook etc).
	html := fmt.Sprintf(`<!doctype html>
<html lang="%s">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Arial,sans-serif;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%%" style="background:#f4f4f5;padding:32px 16px;">
  <tr><td align="center">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="520" style="max-width:520px;background:#ffffff;border-radius:16px;padding:40px 32px;">
      <tr><td style="font-size:22px;font-weight:800;color:#4BAD3B;padding-bottom:20px;">MadFrog VPN</td></tr>
      <tr><td style="font-size:18px;font-weight:600;color:#1c1c1e;padding-bottom:8px;">%s</td></tr>
      <tr><td style="font-size:15px;line-height:1.55;color:#3a3a3c;padding-bottom:28px;">%s</td></tr>
      <tr><td style="padding-bottom:28px;">
        <a href="%s" style="display:inline-block;background:#4BAD3B;color:#ffffff;text-decoration:none;padding:14px 36px;border-radius:10px;font-size:16px;font-weight:700;">%s</a>
      </td></tr>
      <tr><td style="font-size:13px;line-height:1.55;color:#6e6e73;padding-bottom:20px;">%s</td></tr>
      <tr><td style="font-size:12px;line-height:1.55;color:#8e8e93;padding-top:16px;border-top:1px solid #e5e5ea;">
        %s<br>
        <a href="%s" style="color:#6e6e73;word-break:break-all;text-decoration:none;">%s</a>
      </td></tr>
      <tr><td style="font-size:11px;color:#c7c7cc;padding-top:20px;">MadFrog VPN · info@madfrog.online</td></tr>
    </table>
  </td></tr>
</table>
</body>
</html>`,
		tmpl.htmlLang, tmpl.greeting, tmpl.intro, link, tmpl.cta,
		tmpl.footer, tmpl.pasteHint, link, link)

	text := fmt.Sprintf("%s\n\n%s\n\n%s\n\n%s\n\n— MadFrog VPN\n",
		tmpl.greeting, tmpl.intro, link, tmpl.footer)

	if err := h.Email.Send(ctx, email.Message{
		To:       toEmail,
		Subject:  tmpl.subject,
		HTMLBody: html,
		TextBody: text,
	}); err != nil {
		h.Logger.Warn("magic: email send failed", zap.Error(err), zap.String("to", toEmail))
	}
}

// magicEmailStrings are the user-visible strings for one (lang, purpose) combo.
type magicEmailStrings struct {
	htmlLang  string
	subject   string
	greeting  string
	intro     string
	cta       string
	footer    string
	pasteHint string // shown above the raw URL fallback at the bottom
}

// magicEmailTemplate picks the best matching set for the caller's language.
// RU if first lang tag is "ru", otherwise English.
func magicEmailTemplate(lang, purpose string) magicEmailStrings {
	isRu := strings.HasPrefix(strings.ToLower(strings.TrimSpace(lang)), "ru")
	isSignup := purpose == "email_signup"

	switch {
	case isRu && isSignup:
		return magicEmailStrings{
			htmlLang:  "ru",
			subject:   "Подтвердите аккаунт MadFrog VPN",
			greeting:  "Добро пожаловать в MadFrog VPN!",
			intro:     "Нажмите на кнопку ниже, чтобы завершить регистрацию на этом устройстве.",
			cta:       "Войти в MadFrog VPN",
			footer:    "Ссылка действует 15 минут и срабатывает один раз. Если вы не запрашивали вход — просто проигнорируйте это письмо.",
			pasteHint: "Если кнопка не работает, откройте эту ссылку в браузере:",
		}
	case isRu:
		return magicEmailStrings{
			htmlLang:  "ru",
			subject:   "Ссылка для входа в MadFrog VPN",
			greeting:  "Здравствуйте,",
			intro:     "Нажмите на кнопку ниже, чтобы войти на этом устройстве.",
			cta:       "Войти в MadFrog VPN",
			footer:    "Ссылка действует 15 минут и срабатывает один раз. Если вы не запрашивали вход — просто проигнорируйте это письмо.",
			pasteHint: "Если кнопка не работает, откройте эту ссылку в браузере:",
		}
	case isSignup:
		return magicEmailStrings{
			htmlLang:  "en",
			subject:   "Finish creating your MadFrog VPN account",
			greeting:  "Welcome to MadFrog VPN!",
			intro:     "Tap the button below to finish setting up your account on your device.",
			cta:       "Sign in to MadFrog VPN",
			footer:    "This link works once and expires in 15 minutes. If you didn't request it, you can ignore this email.",
			pasteHint: "If the button doesn't work, paste this link in your browser:",
		}
	default:
		return magicEmailStrings{
			htmlLang:  "en",
			subject:   "Your MadFrog VPN sign-in link",
			greeting:  "Hi,",
			intro:     "Tap the button below to sign in on your device.",
			cta:       "Sign in to MadFrog VPN",
			footer:    "This link works once and expires in 15 minutes. If you didn't request it, you can ignore this email.",
			pasteHint: "If the button doesn't work, paste this link in your browser:",
		}
	}
}

// langFromAcceptLanguage extracts the primary language tag. Example:
// "ru-RU,ru;q=0.9,en;q=0.8" → "ru". Returns "" on empty/malformed input,
// which the template function treats as English.
func langFromAcceptLanguage(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}
	// Take the part before the first comma, then before the first ";".
	if comma := strings.IndexByte(header, ','); comma != -1 {
		header = header[:comma]
	}
	if semi := strings.IndexByte(header, ';'); semi != -1 {
		header = header[:semi]
	}
	header = strings.TrimSpace(header)
	if dash := strings.IndexByte(header, '-'); dash != -1 {
		header = header[:dash]
	}
	return strings.ToLower(header)
}

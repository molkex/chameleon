package admin

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

// auditSafeUsername sanitizes a user-supplied username before it lands in
// the admin_audit_log.details column. Audit MED-014 followup:
//   - caps at 64 chars so an accidentally-pasted password (or attacker-
//     crafted huge input) doesn't bloat the row
//   - strips non-printable / control characters so log shippers can't be
//     fooled by embedded newlines, ANSI escapes, or terminal control codes
//
// The result still distinguishes legitimate distinct usernames for
// forensics, but blunts the worst footguns.
func auditSafeUsername(s string) string {
	cleaned := strings.Map(func(r rune) rune {
		if unicode.IsPrint(r) {
			return r
		}
		return -1
	}, s)
	if len(cleaned) > 64 {
		cleaned = cleaned[:64] + "...(truncated)"
	}
	return cleaned
}

// loginRequest is the expected JSON body for POST /api/admin/auth/login.
type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// loginResponse is returned on successful login.
type loginResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresAt    int64  `json:"expires_at"`
}

// refreshRequest is the expected JSON body for POST /api/admin/auth/refresh.
type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// meResponse is returned for GET /api/admin/auth/me.
type meResponse struct {
	ID       *int64 `json:"id"`
	Username string `json:"username"`
	Role     string `json:"role"`
}

// Login handles POST /api/admin/auth/login
//
// Authenticates an admin user via username+password against the admin_users table.
// Legacy password rehash: if stored hash is bcrypt/SHA-256, it is upgraded
// to argon2id on successful login.
//
// To create the first admin user, use the CLI: chameleon admin create --username X --password Y
//
// Sets an httpOnly cookie with the access token for the SPA, and also returns
// token pair in JSON body.
func (h *Handler) Login(c echo.Context) error {
	var req loginRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.Username == "" || req.Password == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "username and password are required")
	}

	ctx := c.Request().Context()

	// Look up admin in database — this is the only auth source.
	adminUser, err := h.DB.FindAdminByUsername(ctx, req.Username)
	if err != nil {
		h.Logger.Error("admin login: db error", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "internal error")
	}

	if adminUser == nil {
		// Audit MED-014: record the attempt with the attempted username
		// so brute-force attempts are visible. Admin ID is nil — the
		// caller is unauthenticated by definition. Sanitize the username
		// so a user who fat-fingered their password into the username
		// field doesn't leak it as cleartext into admin_audit_log.
		h.recordAuditForAdmin(c, nil, "login.failed", "username="+auditSafeUsername(req.Username)+" reason=unknown_user")
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid credentials")
	}

	// Verify password (supports argon2, bcrypt, SHA-256).
	matches, needsRehash := auth.VerifyPassword(req.Password, adminUser.PasswordHash)
	if !matches {
		h.recordAuditForAdmin(c, &adminUser.ID, "login.failed", "username="+auditSafeUsername(req.Username)+" reason=bad_password")
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid credentials")
	}

	// Rehash legacy passwords to argon2id.
	if needsRehash {
		go h.rehashPassword(adminUser.ID, req.Password)
	}

	// Update last_login timestamp.
	_ = h.DB.UpdateAdminLastLogin(ctx, adminUser.ID)

	h.recordAuditForAdmin(c, &adminUser.ID, "login.success", "username="+adminUser.Username)
	return h.issueTokens(c, adminUser.ID, adminUser.Username, adminUser.Role)
}

// Refresh handles POST /api/admin/auth/refresh
//
// Validates a refresh token and issues a new token pair.
// Refresh tokens are single-use: once used, the token is blacklisted in Redis
// using SET NX with TTL matching the token's remaining lifetime.
func (h *Handler) Refresh(c echo.Context) error {
	var req refreshRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.RefreshToken == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "refresh_token is required")
	}

	// Verify the refresh token signature and claims.
	claims, err := h.JWT.VerifyRefreshToken(req.RefreshToken)
	if err != nil {
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid refresh token")
	}

	// One-time use: mark this token as used in Redis.
	// SET NX ensures only the first caller succeeds.
	ctx := c.Request().Context()
	// Audit H-007 (2026-05-26): SHA-256 of full token, not 32-char prefix.
	// HS256 JWT headers share a stable prefix, so token[:32] could collide
	// across unrelated refresh tokens.
	rtHash := sha256.Sum256([]byte(req.RefreshToken))
	key := fmt.Sprintf("rt:used:%s", hex.EncodeToString(rtHash[:]))
	ttl := 30 * 24 * time.Hour                               // Keep blacklist entry for 30 days

	// SetArgs with Mode:"NX" is the non-deprecated replacement for SetNX
	// (as of Redis 2.6.12 / go-redis v9). On condition-failed Redis returns
	// (nil), which surfaces as redis.Nil in go-redis.
	if _, serr := h.Redis.SetArgs(ctx, key, "1", redis.SetArgs{Mode: "NX", TTL: ttl}).Result(); serr != nil {
		if errors.Is(serr, redis.Nil) {
			// Key already existed — token was already used.
			return echo.NewHTTPError(http.StatusUnauthorized, "refresh token already used")
		}
		h.Logger.Error("admin refresh: redis error", zap.Error(serr))
		return echo.NewHTTPError(http.StatusInternalServerError, "internal error")
	}

	return h.issueTokens(c, claims.UserID, claims.Username, claims.Role)
}

// Me handles GET /api/admin/auth/me
//
// Returns the currently authenticated admin's info.
// Used by the React SPA to check auth state on page load.
func (h *Handler) Me(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
	}

	var id *int64
	if claims.UserID != 0 {
		id = &claims.UserID
	}

	return c.JSON(http.StatusOK, meResponse{
		ID:       id,
		Username: claims.Username,
		Role:     claims.Role,
	})
}

// issueTokens creates a token pair and returns it as JSON + sets auth cookie.
func (h *Handler) issueTokens(c echo.Context, userID int64, username, role string) error {
	pair, err := h.JWT.CreateTokenPair(userID, username, role)
	if err != nil {
		h.Logger.Error("admin login: create token pair", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to create tokens")
	}

	// Set httpOnly cookie for the SPA (credentials: "include").
	// Behind nginx the connection to backend is plain HTTP so c.Request().TLS
	// is nil even when the user-facing leg is HTTPS — trust X-Forwarded-Proto
	// (set by our nginx) instead. Strict SameSite is fine because the admin
	// SPA is same-origin with the API.
	c.SetCookie(&http.Cookie{
		Name:     "access_token",
		Value:    pair.AccessToken,
		Path:     "/",
		HttpOnly: true,
		Secure:   isHTTPS(c),
		SameSite: http.SameSiteStrictMode,
		MaxAge:   86400, // 24h
	})

	return c.JSON(http.StatusOK, loginResponse{
		AccessToken:  pair.AccessToken,
		RefreshToken: pair.RefreshToken,
		ExpiresAt:    pair.ExpiresAt,
	})
}

// Logout handles POST /api/admin/auth/logout
//
// Clears the auth cookie.
func (h *Handler) Logout(c echo.Context) error {
	c.SetCookie(&http.Cookie{
		Name:     "access_token",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   isHTTPS(c),
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	})
	// Audit MED-014: logout is unauthenticated route, so claims may be
	// nil — recordAudit handles that and writes admin_user_id=NULL.
	h.recordAudit(c, "logout", "")
	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
}

// isHTTPS reports whether the original client request was over TLS, looking
// past the nginx reverse proxy. We trust X-Forwarded-Proto because nginx is
// the only thing that can talk to the backend port (firewalled to localhost
// + cluster peers), so the header cannot be spoofed by an external client.
func isHTTPS(c echo.Context) bool {
	if c.Request().TLS != nil {
		return true
	}
	return c.Request().Header.Get("X-Forwarded-Proto") == "https"
}

// rehashPassword runs in a background goroutine to upgrade a legacy password hash.
func (h *Handler) rehashPassword(adminID int64, plaintext string) {
	newHash, err := auth.HashPassword(plaintext)
	if err != nil {
		h.Logger.Error("admin: rehash password failed",
			zap.Int64("admin_id", adminID),
			zap.Error(err))
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := h.DB.UpdateAdminPasswordHash(ctx, adminID, newHash); err != nil {
		h.Logger.Error("admin: save rehashed password failed",
			zap.Int64("admin_id", adminID),
			zap.Error(err))
		return
	}

	h.Logger.Info("admin: password rehashed to argon2id",
		zap.Int64("admin_id", adminID))
}

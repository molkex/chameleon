package admin

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

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
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid credentials")
	}

	// Verify password (supports argon2, bcrypt, SHA-256).
	matches, needsRehash := auth.VerifyPassword(req.Password, adminUser.PasswordHash)
	if !matches {
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid credentials")
	}

	// Rehash legacy passwords to argon2id.
	if needsRehash {
		go h.rehashPassword(adminUser.ID, req.Password)
	}

	// Update last_login timestamp.
	_ = h.DB.UpdateAdminLastLogin(ctx, adminUser.ID)

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
	key := fmt.Sprintf("rt:used:%s", req.RefreshToken[:32]) // Use prefix of token as key
	ttl := 30 * 24 * time.Hour                               // Keep blacklist entry for 30 days

	ok, err := h.Redis.SetNX(ctx, key, "1", ttl).Result()
	if err != nil {
		h.Logger.Error("admin refresh: redis error", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "internal error")
	}
	if !ok {
		// Token was already used.
		return echo.NewHTTPError(http.StatusUnauthorized, "refresh token already used")
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
	c.SetCookie(&http.Cookie{
		Name:     "access_token",
		Value:    pair.AccessToken,
		Path:     "/",
		HttpOnly: true,
		Secure:   c.Request().TLS != nil,
		SameSite: http.SameSiteLaxMode,
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
		MaxAge:   -1,
	})
	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
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

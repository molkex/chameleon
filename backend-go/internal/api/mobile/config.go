package mobile

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/useragent"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// GetConfig handles GET /api/mobile/config and GET /api/v1/mobile/config.
//
// Requires JWT authentication. User is identified by JWT claims (user_id).
// Falls back to username query param if JWT user has no vpn_username yet.
//
// Returns raw sing-box client config JSON with X-Expire header.
func (h *Handler) GetConfig(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	ctx := c.Request().Context()

	// Load user from DB by user ID from JWT.
	user, err := h.DB.FindUserByID(ctx, claims.UserID)
	if err != nil {
		h.Logger.Error("db: find user by id", zap.Error(err), zap.Int64("user_id", claims.UserID))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	if user == nil {
		return c.JSON(http.StatusNotFound, ErrorResponse{Error: "user not found"})
	}

	// Check if user is active.
	if !user.IsActive {
		return c.JSON(http.StatusForbidden, ErrorResponse{Error: "account is deactivated"})
	}

	// Check subscription expiry.
	if user.SubscriptionExpiry != nil && user.SubscriptionExpiry.Before(time.Now()) {
		return c.JSON(http.StatusForbidden, ErrorResponse{Error: "subscription expired"})
	}

	// Verify VPN credentials exist.
	if user.VPNUsername == nil || user.VPNUUID == nil {
		return c.JSON(http.StatusConflict, ErrorResponse{Error: "vpn credentials not configured"})
	}

	// Check VPN engine availability.
	if h.VPN == nil {
		return c.JSON(http.StatusServiceUnavailable, ErrorResponse{Error: "vpn engine not available"})
	}

	// Load active servers from DB.
	servers, err := h.DB.ListActiveServers(ctx)
	if err != nil {
		h.Logger.Error("db: list active servers", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	// Convert db.VPNServer to vpn.ServerEntry.
	serverEntries := make([]vpn.ServerEntry, 0, len(servers))
	for _, s := range servers {
		serverEntries = append(serverEntries, vpn.ServerEntry{
			Key:              s.Key,
			Name:             s.Name,
			Host:             s.Host,
			Port:             s.Port,
			Flag:             s.Flag,
			SNI:              s.SNI,
			RealityPublicKey: s.RealityPublicKey,
		})
	}

	shortID := ""
	if user.VPNShortID != nil {
		shortID = *user.VPNShortID
	}

	vpnUser := vpn.VPNUser{
		Username: *user.VPNUsername,
		UUID:     *user.VPNUUID,
		ShortID:  shortID,
	}

	configJSON, err := h.VPN.GenerateClientConfig(vpnUser, serverEntries)
	if err != nil {
		h.Logger.Error("vpn: generate client config", zap.Error(err), zap.Int64("user_id", user.ID))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	h.Logger.Info("config generated",
		zap.Int64("user_id", user.ID),
		zap.Int("servers", len(serverEntries)),
	)

	// Record this fetch as a "last seen" ping. Everything we save here comes
	// from HTTP headers the client already sends (UA, Accept-Language, custom
	// X-* headers) — no sensors, no external geolocation API. Real signup
	// country lives in initial_*, captured once at /auth/register.
	h.touchDevice(user.ID, c)

	// Set X-Expire header (unix timestamp).
	if user.SubscriptionExpiry != nil {
		c.Response().Header().Set("X-Expire", fmt.Sprintf("%d", user.SubscriptionExpiry.Unix()))
	}

	// Return raw sing-box config JSON (not wrapped).
	return c.Blob(http.StatusOK, "application/json", configJSON)
}

// touchDevice updates the user's last_seen + device metadata columns from
// the request's headers. Runs in a background goroutine with a detached
// context so it outlives the request but never blocks the response.
func (h *Handler) touchDevice(userID int64, c echo.Context) {
	req := c.Request()
	ua := req.UserAgent()
	parsed := useragent.Parse(ua)

	info := db.DeviceInfo{
		IP:             c.RealIP(),
		UserAgent:      ua,
		AppVersion:     parsed.AppVersion,
		OSName:         parsed.OSName,
		OSVersion:      parsed.OSVersion,
		Timezone:       firstValue(req.Header.Get("X-Timezone"), 64),
		DeviceModel:    firstValue(req.Header.Get("X-Device-Model"), 64),
		IOSVersion:     firstValue(req.Header.Get("X-iOS-Version"), 32),
		AcceptLanguage: firstValue(req.Header.Get("Accept-Language"), 128),
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := h.DB.TouchUserDevice(ctx, userID, info); err != nil {
			h.Logger.Warn("touch user device", zap.Error(err), zap.Int64("user_id", userID))
		}
	}()
}

// firstValue trims whitespace and truncates to max runes to avoid hostile
// or malformed headers blowing up our VARCHAR columns.
func firstValue(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) > max {
		s = s[:max]
	}
	return s
}

// GetConfigLegacy handles GET /sub/:token/:mode for subscription link compatibility.
func (h *Handler) GetConfigLegacy(c echo.Context) error {
	token := c.Param("token")
	if token == "" {
		return c.String(http.StatusBadRequest, "missing token")
	}

	ctx := c.Request().Context()

	user, err := h.DB.FindUserBySubscriptionToken(ctx, token)
	if err != nil {
		h.Logger.Error("db: find user by subscription token", zap.Error(err))
		return c.String(http.StatusInternalServerError, "internal server error")
	}
	if user == nil {
		return c.String(http.StatusNotFound, "invalid subscription link")
	}

	if !user.IsActive {
		return c.String(http.StatusForbidden, "account deactivated")
	}
	if user.SubscriptionExpiry != nil && user.SubscriptionExpiry.Before(time.Now()) {
		return c.String(http.StatusForbidden, "subscription expired")
	}
	if user.VPNUsername == nil || user.VPNUUID == nil {
		return c.String(http.StatusConflict, "no vpn credentials")
	}
	if h.VPN == nil {
		return c.String(http.StatusServiceUnavailable, "vpn engine not available")
	}

	servers, err := h.DB.ListActiveServers(ctx)
	if err != nil {
		return c.String(http.StatusInternalServerError, "internal server error")
	}

	serverEntries := make([]vpn.ServerEntry, 0, len(servers))
	for _, s := range servers {
		serverEntries = append(serverEntries, vpn.ServerEntry{
			Key: s.Key, Name: s.Name, Host: s.Host,
			Port: s.Port, Flag: s.Flag, SNI: s.SNI,
			RealityPublicKey: s.RealityPublicKey,
		})
	}

	shortID := ""
	if user.VPNShortID != nil {
		shortID = *user.VPNShortID
	}

	configJSON, err := h.VPN.GenerateClientConfig(vpn.VPNUser{
		Username: *user.VPNUsername,
		UUID:     *user.VPNUUID,
		ShortID:  shortID,
	}, serverEntries)
	if err != nil {
		return c.String(http.StatusInternalServerError, "config generation failed")
	}

	if user.SubscriptionExpiry != nil {
		c.Response().Header().Set("X-Expire", fmt.Sprintf("%d", user.SubscriptionExpiry.Unix()))
	}

	return c.Blob(http.StatusOK, "application/json", configJSON)
}

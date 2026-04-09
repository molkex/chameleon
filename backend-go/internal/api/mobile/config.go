package mobile

import (
	"fmt"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// GetConfig handles GET /api/mobile/config and GET /api/v1/mobile/config.
//
// Query params:
//   - username: vpn_username (required)
//   - mode: ignored (kept for compatibility)
//
// Returns raw sing-box client config JSON with X-Expire header.
// No JWT required — user is identified by vpn_username query param.
func (h *Handler) GetConfig(c echo.Context) error {
	username := c.QueryParam("username")
	if username == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "username query parameter is required"})
	}

	ctx := c.Request().Context()

	// Load user from DB by vpn_username.
	user, err := h.DB.FindUserByVPNUsername(ctx, username)
	if err != nil {
		h.Logger.Error("db: find user by vpn_username", zap.Error(err), zap.String("username", username))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	if user == nil {
		return c.JSON(http.StatusNotFound, ErrorResponse{Error: "user not found"})
	}

	// Check if user is active.
	if !user.IsActive {
		return c.JSON(http.StatusForbidden, ErrorResponse{Error: "account is deactivated"})
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

	// Set X-Expire header (unix timestamp).
	if user.SubscriptionExpiry != nil {
		c.Response().Header().Set("X-Expire", fmt.Sprintf("%d", user.SubscriptionExpiry.Unix()))
	}

	// Return raw sing-box config JSON (not wrapped).
	return c.Blob(http.StatusOK, "application/json", configJSON)
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

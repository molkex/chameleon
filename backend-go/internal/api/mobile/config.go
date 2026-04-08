package mobile

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// ConfigResponse wraps the generated sing-box client config.
type ConfigResponse struct {
	Config             json.RawMessage `json:"config"`
	SubscriptionExpiry *int64          `json:"subscription_expiry,omitempty"` // unix timestamp, nil if no subscription
}

// GetConfig handles GET /api/mobile/config.
//
// It requires a valid JWT in the Authorization header, loads the user's data,
// fetches active servers from the DB, and generates a sing-box client config
// via the VPN engine.
func (h *Handler) GetConfig(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	ctx := c.Request().Context()

	// Load user from DB.
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
			Key:  s.Key,
			Name: s.Name,
			Host: s.Host,
			Port: s.Port,
			Flag: s.Flag,
			SNI:  s.SNI,
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

	var subExpiry *int64
	if user.SubscriptionExpiry != nil {
		ts := user.SubscriptionExpiry.Unix()
		subExpiry = &ts
	}

	return c.JSON(http.StatusOK, ConfigResponse{
		Config:             configJSON,
		SubscriptionExpiry: subExpiry,
	})
}

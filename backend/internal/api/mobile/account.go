package mobile

import (
	"net/http"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

// DeleteAccount is the self-service account deletion endpoint required by
// App Store Review 5.1.1(v). It wipes subscription/VPN/device state and
// marks the row inactive, then removes the user from the running VPN
// engine so their credentials stop working immediately.
//
// The row itself is retained (soft delete) so Apple IAP server
// notifications can still replay against original_transaction_id, and so
// analytics/audit history stays intact. If the same Apple ID signs in
// again, auth.AppleSignIn reactivates the row as a blank slate — no
// lingering Pro status, no stale VPN creds.
func (h *Handler) DeleteAccount(c echo.Context) error {
	ctx := c.Request().Context()
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
	}

	// Resolve the VPN username *before* wiping, so we can remove the user
	// from the running sing-box instance on this node.
	var vpnUsername string
	if user, err := h.DB.FindUserByID(ctx, claims.UserID); err == nil && user != nil && user.VPNUsername != nil {
		vpnUsername = *user.VPNUsername
	}

	if err := h.DB.WipeUserOnDelete(ctx, claims.UserID); err != nil {
		h.Logger.Warn("DeleteAccount: db wipe failed", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "db error")
	}

	// Best-effort: remove from the running VPN engine so the credentials
	// stop working immediately. Non-fatal — the DB state is authoritative.
	if h.VPN != nil && vpnUsername != "" {
		if err := h.VPN.RemoveUser(ctx, vpnUsername); err != nil {
			h.Logger.Warn("DeleteAccount: vpn remove failed",
				zap.String("vpn_username", vpnUsername),
				zap.Error(err))
		}
	}

	h.Logger.Info("DeleteAccount: user wiped",
		zap.Int64("user_id", claims.UserID),
		zap.String("vpn_username", vpnUsername),
	)
	return c.NoContent(http.StatusNoContent)
}

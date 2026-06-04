// Package mobile — push.go: device APNs-token registration for SUPPORT-CHAT
// push notifications (ADR 0011 follow-up, P4).
//
// The iOS client registers its APNs device token here after the user grants
// notification permission; admin/support.go later looks the token(s) up by
// user_id and sends a push when a support AGENT replies. Register only writes
// the DB — the mobile handler needs no APNs client (the send happens admin-side).
package mobile

import (
	"net/http"
	"strings"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

// pushTokenMinLen / pushTokenMaxLen bound a hex APNs device token. A real APNs
// token is 64 hex chars (32 bytes), but Apple has widened it before and may
// again, so we accept a generous hex range rather than pin an exact length.
const (
	pushTokenMinLen = 32
	pushTokenMaxLen = 200
)

// isHexToken reports whether s is non-empty and all hex digits. Pure (unit-
// testable) — APNs tokens are lowercase/uppercase hex with no separators.
func isHexToken(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'a' && r <= 'f':
		case r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}

// PushRegister handles POST /push/register — stores the caller's APNs device
// token so an agent reply can push to it. JWT-required (the user id comes from
// the token, never the body). Idempotent via the UNIQUE(token) upsert.
func (h *Handler) PushRegister(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	var req struct {
		Token    string `json:"token"`
		Platform string `json:"platform"`
	}
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request"})
	}

	token := strings.TrimSpace(req.Token)
	if len(token) < pushTokenMinLen || len(token) > pushTokenMaxLen || !isHexToken(token) {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid token"})
	}

	platform := strings.TrimSpace(req.Platform)
	if platform == "" {
		platform = "ios"
	}

	if err := h.DB.UpsertPushToken(c.Request().Context(), claims.UserID, token, platform); err != nil {
		h.Logger.Error("push: register token", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	return c.JSON(http.StatusOK, map[string]any{"ok": true})
}

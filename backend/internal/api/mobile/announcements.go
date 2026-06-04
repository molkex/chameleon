// Package mobile — announcements.go: the client polls this on app open to show
// in-app announcements (INAPP-ANNOUNCEMENTS). Read-only; admin authoring lives
// in internal/api/admin/announcements.go.
package mobile

import (
	"net/http"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// GetActiveAnnouncements handles GET /api/v1/mobile/announcements/active.
// Returns the announcements currently in their show-window, newest first. The
// client shows the first one the user hasn't dismissed (dismissal is tracked
// client-side).
func (h *Handler) GetActiveAnnouncements(c echo.Context) error {
	list, err := h.DB.ActiveAnnouncements(c.Request().Context())
	if err != nil {
		h.Logger.Error("announcements: active", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	out := make([]map[string]any, 0, len(list))
	for _, a := range list {
		m := map[string]any{"id": a.ID, "title": a.Title, "body": a.Body, "kind": a.Kind}
		if a.CTALabel != nil && a.CTAURL != nil {
			m["cta_label"] = *a.CTALabel
			m["cta_url"] = *a.CTAURL
		}
		out = append(out, m)
	}
	return c.JSON(http.StatusOK, map[string]any{"announcements": out})
}

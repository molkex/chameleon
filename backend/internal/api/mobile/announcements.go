// Package mobile — announcements.go: the client polls this on app open to show
// in-app announcements (INAPP-ANNOUNCEMENTS). Read-only; admin authoring lives
// in internal/api/admin/announcements.go. Targeting (audience + platform) is
// resolved here from the authenticated user — no client change needed.
package mobile

import (
	"net/http"
	"strings"
	"time"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// announcementMatches reports whether an announcement targeted at (audience,
// platform) should reach a user in state (userSub, userPlatform). "all" matches
// anyone; an unknown user signal ("") matches only an "all" filter. Pure →
// unit-tested.
func announcementMatches(audience, platform, userSub, userPlatform string) bool {
	if audience != "all" && audience != userSub {
		return false
	}
	if platform != "all" && platform != userPlatform {
		return false
	}
	return true
}

// platformFromOS maps a stored os_name to the targeting bucket.
func platformFromOS(osName string) string {
	if strings.Contains(strings.ToLower(osName), "mac") {
		return "macos"
	}
	if osName == "" {
		return "" // unknown → only "all"-platform announcements reach it
	}
	return "ios" // iOS / iPadOS
}

// GetActiveAnnouncements handles GET /api/v1/mobile/announcements/active.
// Returns the in-window announcements that target this user, newest first. The
// client shows the first one the user hasn't dismissed (dismissal is tracked
// client-side).
func (h *Handler) GetActiveAnnouncements(c echo.Context) error {
	ctx := c.Request().Context()
	list, err := h.DB.ActiveAnnouncements(ctx)
	if err != nil {
		h.Logger.Error("announcements: active", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	// Resolve the user's targeting state only if something actually filters —
	// keeps the common all-"all" case free of extra queries.
	needsUser := false
	for _, a := range list {
		if a.Audience != "all" || a.Platform != "all" {
			needsUser = true
			break
		}
	}
	userSub, userPlatform := "", ""
	if needsUser {
		if claims := auth.GetUserFromContext(c); claims != nil {
			if u, err := h.DB.FindUserByID(ctx, claims.UserID); err == nil && u != nil {
				userPlatform = platformFromOS(u.OSName)
				userSub = "expired"
				if u.SubscriptionExpiry != nil && u.SubscriptionExpiry.After(time.Now()) {
					paid, _ := h.DB.UserHasPaid(ctx, u.ID)
					if paid {
						userSub = "paid"
					} else {
						userSub = "trial"
					}
				}
			}
		}
	}

	out := make([]map[string]any, 0, len(list))
	for _, a := range list {
		if !announcementMatches(a.Audience, a.Platform, userSub, userPlatform) {
			continue
		}
		m := map[string]any{"id": a.ID, "title": a.Title, "body": a.Body, "kind": a.Kind}
		if a.CTALabel != nil && a.CTAURL != nil {
			m["cta_label"] = *a.CTALabel
			m["cta_url"] = *a.CTAURL
		}
		out = append(out, m)
	}
	return c.JSON(http.StatusOK, map[string]any{"announcements": out})
}

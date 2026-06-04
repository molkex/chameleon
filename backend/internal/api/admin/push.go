// Package admin — push.go: admin push broadcast (BROADCAST-PUSH). Sends an APNs
// alert to EVERY registered device token. Reuses the SUPPORT-CHAT P4 push.Client
// (same APNs HTTP/2 sender) and the device_push_tokens table; logs each blast to
// push_broadcasts (migration 023). No iOS build needed — the client already
// displays any push and a non-support_reply tap just opens the app.
package admin

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/push"
	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

const (
	maxBroadcastTitleLen = 50  // soft cap; APNs truncates a long banner anyway
	maxBroadcastBodyLen  = 178 // ~2 lines on the lock screen
	broadcastWorkers     = 24  // concurrent APNs sends (HTTP/2 multiplexed)
	broadcastTimeout     = 90 * time.Second
)

// PushStats handles GET /admin/push/stats — recipient counts for the composer.
func (h *Handler) PushStats(c echo.Context) error {
	total, byPlatform, err := h.DB.PushTokenStats(c.Request().Context())
	if err != nil {
		h.Logger.Error("push stats", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	return c.JSON(http.StatusOK, map[string]any{"total": total, "by_platform": byPlatform})
}

// PushBroadcast handles POST /admin/push/broadcast {title, body}. Sends to every
// registered token through a bounded worker pool, prunes tokens APNs permanently
// rejects (410), logs the tally, and returns it. Synchronous — fine at our scale
// (24-way concurrency clears thousands of tokens in seconds). The send runs on a
// detached, bounded context so an Echo request-timeout can't cancel a blast
// mid-flight (it still completes + logs server-side). Switch to a background job
// + status polling if the token base grows past tens of thousands.
func (h *Handler) PushBroadcast(c echo.Context) error {
	if h.Push == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "push not configured"})
	}
	var req struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	title := strings.TrimSpace(req.Title)
	body := strings.TrimSpace(req.Body)
	if title == "" || body == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "title and body are required"})
	}
	if len([]rune(title)) > maxBroadcastTitleLen || len([]rune(body)) > maxBroadcastBodyLen {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "title or body too long"})
	}

	ctx, cancel := context.WithTimeout(context.Background(), broadcastTimeout)
	defer cancel()

	tokens, err := h.DB.AllPushTokens(ctx)
	if err != nil {
		h.Logger.Error("push broadcast: list tokens", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}

	var sent, failed int64
	custom := map[string]any{"type": "announcement"}
	sem := make(chan struct{}, broadcastWorkers)
	var wg sync.WaitGroup
	for _, tok := range tokens {
		wg.Add(1)
		sem <- struct{}{}
		go func(tok string) {
			defer wg.Done()
			defer func() { <-sem }()
			switch err := h.Push.Send(ctx, tok, title, body, custom); {
			case err == nil:
				atomic.AddInt64(&sent, 1)
			case errors.Is(err, push.ErrBadToken):
				atomic.AddInt64(&failed, 1)
				_ = h.DB.DeletePushToken(ctx, tok)
			default:
				atomic.AddInt64(&failed, 1)
				h.Logger.Warn("push broadcast: send", zap.Error(err))
			}
		}(tok)
	}
	wg.Wait()

	adminUser := ""
	if claims := auth.GetUserFromContext(c); claims != nil {
		adminUser = claims.Username
	}
	id, err := h.DB.InsertBroadcast(ctx, title, body, len(tokens), int(sent), int(failed), adminUser)
	if err != nil {
		h.Logger.Warn("push broadcast: log", zap.Error(err))
	}
	h.Logger.Info("push broadcast sent",
		zap.String("admin", adminUser), zap.Int("total", len(tokens)),
		zap.Int64("sent", sent), zap.Int64("failed", failed))

	return c.JSON(http.StatusOK, map[string]any{
		"id": id, "total": len(tokens), "sent": sent, "failed": failed,
	})
}

// PushBroadcasts handles GET /admin/push/broadcasts — recent broadcast history.
func (h *Handler) PushBroadcasts(c echo.Context) error {
	list, err := h.DB.ListBroadcasts(c.Request().Context(), 20)
	if err != nil {
		h.Logger.Error("push broadcasts list", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	out := make([]map[string]any, 0, len(list))
	for _, b := range list {
		out = append(out, map[string]any{
			"id": b.ID, "title": b.Title, "body": b.Body,
			"total": b.Total, "sent": b.Sent, "failed": b.Failed,
			"admin_user": b.AdminUser, "created_at": b.CreatedAt,
		})
	}
	return c.JSON(http.StatusOK, map[string]any{"broadcasts": out})
}

// Package mobile — support.go: SUPPORT-CHAT P0 REST API (ADR 0011, step 2).
//
// Endpoints (all under /support, JWT-required — anonymous trial users carry a
// device JWT so they're covered, they just get a tighter rate-limit tier):
//
//	POST /support/messages       — send a message (idempotent via mw.Idempotency)
//	GET  /support/messages?since= — list/catch-up (poll fallback for SSE)
//	GET  /support/thread          — current open thread meta
//
// Realtime (SSE + Redis fan-out) and the chat-token are step 3.
package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

const (
	// maxChatBodyLen bounds a single message (chars). Long enough for a
	// detailed problem report, short enough to keep rows + the SSE frame sane.
	maxChatBodyLen = 4000

	// Per-user, per-minute message caps. Anonymous trial accounts
	// (auth_provider IS NULL) get the tighter tier — they're the spam/abuse
	// surface. Tunable; moved to config in a later pass. The one-open-thread
	// cap is enforced structurally by the partial unique index, not here.
	chatRateAuthedPerMin = 20
	chatRateAnonPerMin   = 6
)

// chatCapForTier is the per-minute message cap for a sender. Pure (unit-tested).
func chatCapForTier(anon bool) int {
	if anon {
		return chatRateAnonPerMin
	}
	return chatRateAuthedPerMin
}

// normalizeChatBody trims a message and reports whether it's a valid body
// (non-empty after trim, within maxChatBodyLen). Pure (unit-tested).
func normalizeChatBody(raw string) (string, bool) {
	t := strings.TrimSpace(raw)
	if t == "" || len(t) > maxChatBodyLen {
		return "", false
	}
	return t, true
}

// --- DTOs (json-tagged; db.SupportMessage has no tags) ---

type chatSendRequest struct {
	Text string `json:"text"`
}

type chatMessageDTO struct {
	ID        int64     `json:"id"`
	Sender    string    `json:"sender"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

type chatThreadDTO struct {
	ID            int64     `json:"id"`
	Status        string    `json:"status"`
	LastMessageAt time.Time `json:"last_message_at"`
}

type chatListResponse struct {
	Thread   chatThreadDTO    `json:"thread"`
	Messages []chatMessageDTO `json:"messages"`
}

// SupportSend handles POST /support/messages.
func (h *Handler) SupportSend(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}
	ctx := c.Request().Context()

	var req chatSendRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request"})
	}
	body, ok := normalizeChatBody(req.Text)
	if !ok {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "message empty or too long"})
	}

	// Determine the rate-limit tier from auth_provider. Fail-open: a transient
	// lookup miss must never block a user from reaching support.
	anon := false
	if user, err := h.DB.FindUserByID(ctx, claims.UserID); err == nil && user != nil {
		anon = user.AuthProvider == nil
	} else if err != nil {
		h.Logger.Warn("support: tier lookup failed (fail-open)", zap.Int64("user_id", claims.UserID), zap.Error(err))
	}
	if !h.chatRateAllow(ctx, claims.UserID, anon) {
		c.Response().Header().Set("Retry-After", "60")
		return c.JSON(http.StatusTooManyRequests, ErrorResponse{Error: "too many messages, slow down"})
	}

	thread, err := h.DB.OpenOrGetThread(ctx, claims.UserID)
	if err != nil {
		h.Logger.Error("support: open thread", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	msg, err := h.DB.AppendMessage(ctx, thread.ID, "user", body)
	if err != nil {
		h.Logger.Error("support: append message", zap.Int64("thread_id", thread.ID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	dto := chatMessageDTO{ID: msg.ID, Sender: msg.Sender, Body: msg.Body, CreatedAt: msg.CreatedAt}
	h.publishChatMessage(ctx, thread.ID, dto) // SSE fan-out (best-effort)
	return c.JSON(http.StatusOK, dto)
}

// SupportListMessages handles GET /support/messages?since=<id>.
func (h *Handler) SupportListMessages(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}
	ctx := c.Request().Context()

	sinceID, _ := strconv.ParseInt(c.QueryParam("since"), 10, 64)
	if sinceID < 0 {
		sinceID = 0
	}

	thread, err := h.DB.OpenOrGetThread(ctx, claims.UserID)
	if err != nil {
		h.Logger.Error("support: open thread (list)", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	msgs, err := h.DB.ListMessages(ctx, thread.ID, sinceID, 200)
	if err != nil {
		h.Logger.Error("support: list messages", zap.Int64("thread_id", thread.ID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	out := make([]chatMessageDTO, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, chatMessageDTO{ID: m.ID, Sender: m.Sender, Body: m.Body, CreatedAt: m.CreatedAt})
	}
	return c.JSON(http.StatusOK, chatListResponse{
		Thread:   chatThreadDTO{ID: thread.ID, Status: thread.Status, LastMessageAt: thread.LastMessageAt},
		Messages: out,
	})
}

// SupportThread handles GET /support/thread — current open thread meta.
func (h *Handler) SupportThread(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}
	ctx := c.Request().Context()

	thread, err := h.DB.OpenOrGetThread(ctx, claims.UserID)
	if err != nil {
		h.Logger.Error("support: thread meta", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	return c.JSON(http.StatusOK, chatThreadDTO{
		ID: thread.ID, Status: thread.Status, LastMessageAt: thread.LastMessageAt,
	})
}

// chatRateAllow enforces a per-user, per-minute message cap via Redis INCR.
// Fail-open on any Redis error — a support channel must not be blocked by an
// infra hiccup. nil Redis (tests / Redis-less dev) also fails open.
func (h *Handler) chatRateAllow(ctx context.Context, userID int64, anon bool) bool {
	if h.Redis == nil {
		return true
	}
	key := "chat:rl:" + strconv.FormatInt(userID, 10)
	n, err := h.Redis.Incr(ctx, key).Result()
	if err != nil {
		h.Logger.Warn("support: rate-limit redis error (fail-open)", zap.Error(err))
		return true
	}
	if n == 1 {
		h.Redis.Expire(ctx, key, time.Minute)
	}
	return n <= int64(chatCapForTier(anon))
}

// chatChannel is the Redis pub/sub channel for a thread's live messages.
func chatChannel(threadID int64) string {
	return "support:thread:" + strconv.FormatInt(threadID, 10)
}

// publishChatMessage fans a message out to live SSE subscribers of the thread.
// Best-effort: on a Redis miss the client simply falls back to GET
// /support/messages?since= polling, so we never fail the write on this.
func (h *Handler) publishChatMessage(ctx context.Context, threadID int64, dto chatMessageDTO) {
	if h.Redis == nil {
		return
	}
	payload, err := json.Marshal(dto)
	if err != nil {
		return
	}
	if err := h.Redis.Publish(ctx, chatChannel(threadID), payload).Err(); err != nil {
		h.Logger.Warn("support: redis publish failed", zap.Int64("thread_id", threadID), zap.Error(err))
	}
}

// SupportChatToken handles GET /support/chat-token — a short-lived token the
// hosted chat webview uses to open the SSE stream (EventSource can't send an
// Authorization header). JWT-required (the normal access token).
func (h *Handler) SupportChatToken(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}
	token, err := h.JWT.CreateChatToken(claims.UserID)
	if err != nil {
		h.Logger.Error("support: chat-token", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	return c.JSON(http.StatusOK, map[string]any{
		"token":      token,
		"expires_in": int(auth.ChatTokenTTL.Seconds()),
	})
}

// SupportStream handles GET /support/stream?token=<chat-token> — the SSE live
// feed. Authenticated by the short-lived chat-token (NOT Bearer), so it lives
// outside the requireAuth group, and the global 30s ContextTimeout skips this
// path (server.go) so the stream isn't cut. Idempotency already bypasses GET.
func (h *Handler) SupportStream(c echo.Context) error {
	uid, err := h.JWT.VerifyChatToken(c.QueryParam("token"))
	if err != nil || uid <= 0 {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}
	if h.Redis == nil {
		return c.JSON(http.StatusServiceUnavailable, ErrorResponse{Error: "stream unavailable"})
	}
	ctx := c.Request().Context()
	thread, err := h.DB.OpenOrGetThread(ctx, uid)
	if err != nil {
		h.Logger.Error("support: stream open thread", zap.Int64("user_id", uid), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	resp := c.Response()
	resp.Header().Set("Content-Type", "text/event-stream")
	resp.Header().Set("Cache-Control", "no-cache")
	resp.Header().Set("Connection", "keep-alive")
	resp.Header().Set("X-Accel-Buffering", "no") // belt vs nginx buffering
	resp.WriteHeader(http.StatusOK)

	// Long-lived stream: clear the per-connection write deadline that
	// http.Server.WriteTimeout (30s, main.go:370) would otherwise impose —
	// without weakening it for any other route. echo.Response.Unwrap (v4.15)
	// exposes the underlying conn to the controller.
	_ = http.NewResponseController(resp).SetWriteDeadline(time.Time{})

	// Catch-up replay: everything newer than the client's last id.
	if backlog, err := h.DB.ListMessages(ctx, thread.ID, sseSinceID(c), 200); err == nil {
		for _, m := range backlog {
			writeChatSSE(resp, chatMessageDTO{ID: m.ID, Sender: m.Sender, Body: m.Body, CreatedAt: m.CreatedAt})
		}
		resp.Flush()
	}

	pubsub := h.Redis.Subscribe(ctx, chatChannel(thread.ID))
	defer func() { _ = pubsub.Close() }()
	msgCh := pubsub.Channel()

	keepalive := time.NewTicker(20 * time.Second)
	defer keepalive.Stop()

	for {
		select {
		case <-ctx.Done(): // client disconnected
			return nil
		case <-keepalive.C:
			if _, err := fmt.Fprint(resp, ": ping\n\n"); err != nil {
				return nil
			}
			resp.Flush()
		case rm, ok := <-msgCh:
			if !ok {
				return nil
			}
			if _, err := fmt.Fprintf(resp, "data: %s\n\n", rm.Payload); err != nil {
				return nil
			}
			resp.Flush()
		}
	}
}

// sseSinceID resolves the resume point from Last-Event-ID (SSE reconnect) or
// the ?since= query param. 0 = replay the whole thread.
func sseSinceID(c echo.Context) int64 {
	raw := c.Request().Header.Get("Last-Event-ID")
	if raw == "" {
		raw = c.QueryParam("since")
	}
	id, _ := strconv.ParseInt(raw, 10, 64)
	if id < 0 {
		id = 0
	}
	return id
}

// writeChatSSE writes one message as an SSE event with an id: line so the
// browser can resume via Last-Event-ID after a drop.
func writeChatSSE(resp *echo.Response, dto chatMessageDTO) {
	payload, err := json.Marshal(dto)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(resp, "id: %d\ndata: %s\n\n", dto.ID, payload)
}

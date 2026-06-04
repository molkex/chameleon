// Package admin — support.go: the agent inbox (SUPPORT-CHAT P3, ADR 0011).
//
// The mobile side (internal/api/mobile/support.go) lets a client open a thread
// and send messages; this is the operator side — list threads, read a
// conversation, and reply. An agent reply is appended as sender="agent" and
// published to the SAME Redis channel the client's SSE stream subscribes to
// (support:thread:<id>), so it lands in the client's chat live.
package admin

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

const (
	maxAgentMessageLen = 4000
	chatChannelPrefix  = "support:thread:" // MUST match mobile.chatChannel
)

// agentThreadDTO is one row in the inbox list.
type agentThreadDTO struct {
	ThreadID      int64     `json:"thread_id"`
	UserID        int64     `json:"user_id"`
	Status        string    `json:"status"`
	LastMessageAt time.Time `json:"last_message_at"`
	LastSender    string    `json:"last_sender"`
	LastBody      string    `json:"last_body"`
	Unread        int       `json:"unread"`
	VPNUsername   *string   `json:"vpn_username,omitempty"`
	AuthProvider  *string   `json:"auth_provider,omitempty"`
	DeviceID      *string   `json:"device_id,omitempty"`
}

// agentMessageDTO mirrors mobile.chatMessageDTO byte-for-byte so a reply
// published to Redis renders identically in the client's SSE stream.
type agentMessageDTO struct {
	ID        int64     `json:"id"`
	Sender    string    `json:"sender"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

// SupportThreads handles GET /admin/support/threads — the inbox list.
func (h *Handler) SupportThreads(c echo.Context) error {
	rows, err := h.DB.ListAdminThreads(c.Request().Context(), 100)
	if err != nil {
		h.Logger.Error("admin support: list threads", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	out := make([]agentThreadDTO, 0, len(rows))
	for _, t := range rows {
		out = append(out, agentThreadDTO{
			ThreadID: t.ThreadID, UserID: t.UserID, Status: t.Status,
			LastMessageAt: t.LastMessageAt, LastSender: t.LastSender, LastBody: t.LastBody,
			Unread: t.UnreadFromUser, VPNUsername: t.VPNUsername,
			AuthProvider: t.AuthProvider, DeviceID: t.DeviceID,
		})
	}
	return c.JSON(http.StatusOK, map[string]any{"threads": out})
}

// SupportThreadMessages handles GET /admin/support/threads/:id/messages.
// Opening a thread marks the user's messages read (clears the unread badge).
func (h *Handler) SupportThreadMessages(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad thread id"})
	}
	ctx := c.Request().Context()
	msgs, err := h.DB.ListMessages(ctx, id, 0, 500)
	if err != nil {
		h.Logger.Error("admin support: list messages", zap.Int64("thread", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	if err := h.DB.MarkThreadReadByAgent(ctx, id); err != nil {
		h.Logger.Warn("admin support: mark read", zap.Int64("thread", id), zap.Error(err))
	}
	out := make([]agentMessageDTO, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, agentMessageDTO{ID: m.ID, Sender: m.Sender, Body: m.Body, CreatedAt: m.CreatedAt})
	}
	return c.JSON(http.StatusOK, map[string]any{"messages": out})
}

// SupportReply handles POST /admin/support/threads/:id/reply — the agent's
// reply. Appended as sender="agent" and fanned out to the client's live SSE.
func (h *Handler) SupportReply(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad thread id"})
	}
	var req struct {
		Text string `json:"text"`
	}
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	body := strings.TrimSpace(req.Text)
	if body == "" || len([]rune(body)) > maxAgentMessageLen {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "message empty or too long"})
	}

	ctx := c.Request().Context()
	msg, err := h.DB.AppendMessage(ctx, id, "agent", body)
	if err != nil {
		h.Logger.Error("admin support: reply", zap.Int64("thread", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}

	// Fan out to the client's SSE stream (same channel + DTO shape as the
	// mobile side's publishChatMessage). Best-effort: the client also catches
	// up via GET /support/messages?since= on reconnect, so a Redis miss is
	// non-fatal.
	if h.Redis != nil {
		dto := agentMessageDTO{ID: msg.ID, Sender: msg.Sender, Body: msg.Body, CreatedAt: msg.CreatedAt}
		if payload, e := json.Marshal(dto); e == nil {
			channel := chatChannelPrefix + strconv.FormatInt(id, 10)
			if e := h.Redis.Publish(ctx, channel, payload).Err(); e != nil {
				h.Logger.Warn("admin support: redis publish", zap.Int64("thread", id), zap.Error(e))
			}
		}
	}

	return c.JSON(http.StatusOK, agentMessageDTO{ID: msg.ID, Sender: msg.Sender, Body: msg.Body, CreatedAt: msg.CreatedAt})
}

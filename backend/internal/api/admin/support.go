// Package admin — support.go: the agent inbox (SUPPORT-CHAT P3, ADR 0011).
//
// The mobile side (internal/api/mobile/support.go) lets a client open a thread
// and send messages; this is the operator side — list threads, read a
// conversation, and reply. An agent reply is appended as sender="agent" and
// published to the SAME Redis channel the client's SSE stream subscribes to
// (support:thread:<id>), so it lands in the client's chat live.
package admin

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/push"
	"github.com/chameleonvpn/chameleon/internal/storage"
)

// presignTTL / getTTL mirror the mobile side (internal/api/mobile/support.go).
const (
	presignTTL = 10 * time.Minute
	getTTL     = time.Hour
)

const (
	maxAgentMessageLen = 4000
	chatChannelPrefix  = "support:thread:" // MUST match mobile.chatChannel

	// pushTitle / pushPreviewLen shape the APNs alert for an agent reply.
	pushTitle      = "Поддержка MadFrog"
	pushPreviewLen = 120
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

// attachmentDTO mirrors mobile.attachmentDTO so a reply rendered here matches
// the client's SSE shape byte-for-byte.
type attachmentDTO struct {
	URL  string `json:"url"`
	MIME string `json:"mime"`
	Name string `json:"name"`
	Size int64  `json:"size"`
}

// agentMessageDTO mirrors mobile.chatMessageDTO byte-for-byte so a reply
// published to Redis renders identically in the client's SSE stream.
type agentMessageDTO struct {
	ID         int64          `json:"id"`
	Sender     string         `json:"sender"`
	Body       string         `json:"body"`
	CreatedAt  time.Time      `json:"created_at"`
	Attachment *attachmentDTO `json:"attachment,omitempty"`
}

// presignRequest is the body for POST /admin/support/threads/:id/attachments/presign.
type presignRequest struct {
	Filename string `json:"filename"`
	MIME     string `json:"mime"`
	Size     int64  `json:"size"`
}

// toMessageDTO maps a stored message to its wire shape, presigning a GET URL for
// any attachment. Degrades gracefully (no Attachment) on a nil Storage or a
// presign error — never fails the message.
func (h *Handler) toMessageDTO(ctx context.Context, m db.SupportMessage) agentMessageDTO {
	dto := agentMessageDTO{ID: m.ID, Sender: m.Sender, Body: m.Body, CreatedAt: m.CreatedAt}
	if m.AttachmentKey == nil || h.Storage == nil {
		return dto
	}
	url, err := h.Storage.PresignGet(ctx, *m.AttachmentKey, getTTL)
	if err != nil {
		h.Logger.Warn("admin support: presign get failed (omitting attachment)", zap.Int64("msg_id", m.ID), zap.Error(err))
		return dto
	}
	dto.Attachment = &attachmentDTO{
		URL:  url,
		MIME: derefStr(m.AttachmentMIME),
		Name: derefStr(m.AttachmentName),
		Size: derefInt64(m.AttachmentSize),
	}
	return dto
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefInt64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
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
		out = append(out, h.toMessageDTO(ctx, m))
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
		Text           string `json:"text"`
		AttachmentKey  string `json:"attachment_key"`
		AttachmentMIME string `json:"attachment_mime"`
		AttachmentName string `json:"attachment_name"`
		AttachmentSize int64  `json:"attachment_size"`
	}
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	hasAttachment := req.AttachmentKey != ""
	body := strings.TrimSpace(req.Text)
	// Body may be empty IFF an attachment is present; with text it must be a
	// valid bounded body.
	if hasAttachment {
		if len([]rune(body)) > maxAgentMessageLen {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": "message too long"})
		}
	} else if body == "" || len([]rune(body)) > maxAgentMessageLen {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "message empty or too long"})
	}

	ctx := c.Request().Context()

	// Resolve attachment columns. Authz: the key must live under this thread's
	// prefix; MIME/size re-validated as a belt.
	var aKey, aMIME, aName *string
	var aSize *int64
	if hasAttachment {
		if !storage.KeyBelongsToThread(req.AttachmentKey, id) {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": "attachment does not belong to this thread"})
		}
		if !storage.MIMEAllowed(req.AttachmentMIME) || !storage.SizeAllowed(req.AttachmentSize) {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": "attachment type or size not allowed"})
		}
		aKey = &req.AttachmentKey
		aMIME = &req.AttachmentMIME
		name := storage.SanitizeFilename(req.AttachmentName)
		aName = &name
		size := req.AttachmentSize
		aSize = &size
	}

	msg, err := h.DB.AppendMessageWithAttachment(ctx, id, "agent", body, aKey, aMIME, aName, aSize)
	if err != nil {
		h.Logger.Error("admin support: reply", zap.Int64("thread", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}

	dto := h.toMessageDTO(ctx, *msg)

	// Fan out to the client's SSE stream (same channel + DTO shape as the
	// mobile side's publishChatMessage). Best-effort: the client also catches
	// up via GET /support/messages?since= on reconnect, so a Redis miss is
	// non-fatal.
	if h.Redis != nil {
		if payload, e := json.Marshal(dto); e == nil {
			channel := chatChannelPrefix + strconv.FormatInt(id, 10)
			if e := h.Redis.Publish(ctx, channel, payload).Err(); e != nil {
				h.Logger.Warn("admin support: redis publish", zap.Int64("thread", id), zap.Error(e))
			}
		}
	}

	// APNs push to the thread owner's devices (SUPPORT-CHAT P4). Fire-and-forget
	// in a goroutine with a FRESH context: the request ctx is cancelled the
	// moment we return the JSON below, so reusing it would race the send to
	// completion. nil Push ⇒ push disabled, skip entirely.
	if h.Push != nil {
		h.sendReplyPush(id, body, hasAttachment)
	}

	return c.JSON(http.StatusOK, dto)
}

// pushPreview is the alert body for an agent reply: the message trimmed to
// pushPreviewLen runes, or "Вложение" when the reply is attachment-only. Pure
// (unit-testable). Truncation is rune-safe so a multibyte char is never split.
func pushPreview(body string, hasAttachment bool) string {
	body = strings.TrimSpace(body)
	if body == "" {
		if hasAttachment {
			return "Вложение"
		}
		return ""
	}
	runes := []rune(body)
	if len(runes) > pushPreviewLen {
		return string(runes[:pushPreviewLen]) + "…"
	}
	return body
}

// sendReplyPush resolves the thread owner's device tokens and pushes the reply
// preview to each, in the background. Errors are logged (never surfaced to the
// agent); a token APNs permanently rejects is pruned. Caller must have checked
// h.Push != nil.
func (h *Handler) sendReplyPush(threadID int64, body string, hasAttachment bool) {
	preview := pushPreview(body, hasAttachment)
	go func() {
		// Detached from the request: a fresh, bounded context so the send
		// outlives the HTTP response.
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		userID, err := h.DB.ThreadUserID(ctx, threadID)
		if err != nil {
			h.Logger.Warn("admin support: push resolve user", zap.Int64("thread", threadID), zap.Error(err))
			return
		}
		tokens, err := h.DB.PushTokensForUser(ctx, userID)
		if err != nil {
			h.Logger.Warn("admin support: push list tokens", zap.Int64("user_id", userID), zap.Error(err))
			return
		}
		custom := map[string]any{"type": "support_reply", "thread_id": threadID}
		for _, tok := range tokens {
			err := h.Push.Send(ctx, tok, pushTitle, preview, custom)
			switch {
			case err == nil:
			case errors.Is(err, push.ErrBadToken):
				if delErr := h.DB.DeletePushToken(ctx, tok); delErr != nil {
					h.Logger.Warn("admin support: prune bad push token", zap.Error(delErr))
				}
			default:
				h.Logger.Warn("admin support: push send", zap.Int64("thread", threadID), zap.Error(err))
			}
		}
	}()
}

// SupportAdminPresignUpload handles POST /admin/support/threads/:id/attachments/presign
// — issues a short-lived presigned PUT URL scoped to the given thread so a
// following agent reply referencing the key passes the ownership check.
func (h *Handler) SupportAdminPresignUpload(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad thread id"})
	}
	if h.Storage == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "attachments disabled"})
	}
	var req presignRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	if !storage.MIMEAllowed(req.MIME) {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "file type not allowed"})
	}
	if !storage.SizeAllowed(req.Size) {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "file too large"})
	}

	ctx := c.Request().Context()
	key := storage.BuildKey(id, req.Filename)
	url, err := h.Storage.PresignPut(ctx, key, req.MIME, presignTTL)
	if err != nil {
		h.Logger.Error("admin support: presign put", zap.Int64("thread", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	return c.JSON(http.StatusOK, map[string]any{"upload_url": url, "key": key})
}

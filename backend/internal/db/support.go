// Package db — support.go: queries for SUPPORT-CHAT (ADR 0011, P0 backend).
//
// Model: one OPEN thread per user (a fresh thread after a close), append-only
// messages. Anonymous trial users participate too — there is no auth gate here,
// only the users(id) FK; the mobile API applies the tighter anon rate-limit.
package db

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// SupportThread is one support conversation. closed_at != nil ⇒ status "closed"
// and the 90-day purge clock has started.
type SupportThread struct {
	ID            int64
	UserID        int64
	Status        string // "open" | "closed"
	AssignedAdmin *int64 // P3; nil in P0
	CreatedAt     time.Time
	LastMessageAt time.Time
	ClosedAt      *time.Time
}

// SupportMessage is one append-only message in a thread. The Attachment* fields
// are non-nil only when the message carries a file/photo upload (stored in B2,
// referenced here by object key + declared metadata).
type SupportMessage struct {
	ID             int64
	ThreadID       int64
	Sender         string // "user" | "agent" | "system"
	Body           string
	CreatedAt      time.Time
	ReadAt         *time.Time
	AttachmentKey  *string // B2 object key (under the support/ prefix)
	AttachmentMIME *string // declared content-type
	AttachmentName *string // original (un-sanitized) filename for display
	AttachmentSize *int64  // declared size in bytes
}

const supportThreadCols = `id, user_id, status, assigned_admin, created_at, last_message_at, closed_at`

func scanSupportThread(row pgx.Row) (*SupportThread, error) {
	var t SupportThread
	if err := row.Scan(&t.ID, &t.UserID, &t.Status, &t.AssignedAdmin,
		&t.CreatedAt, &t.LastMessageAt, &t.ClosedAt); err != nil {
		return nil, err
	}
	return &t, nil
}

// OpenOrGetThread returns the user's current open thread, creating one if none
// exists. Atomic via the partial unique index (idx_support_chat_threads_user_open):
// the no-op DO UPDATE makes RETURNING yield the existing row on conflict.
func (db *DB) OpenOrGetThread(ctx context.Context, userID int64) (*SupportThread, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx, `
		INSERT INTO support_chat_threads (user_id) VALUES ($1)
		ON CONFLICT (user_id) WHERE status = 'open'
		DO UPDATE SET last_message_at = support_chat_threads.last_message_at
		RETURNING `+supportThreadCols, userID)
	return scanSupportThread(row)
}

// AppendMessage inserts a text-only message and bumps the thread's
// last_message_at, in a single transaction. Returns the stored row (for Redis
// fan-out at the API layer). Thin wrapper over AppendMessageWithAttachment.
func (db *DB) AppendMessage(ctx context.Context, threadID int64, sender, body string) (*SupportMessage, error) {
	return db.AppendMessageWithAttachment(ctx, threadID, sender, body, nil, nil, nil, nil)
}

// AppendMessageWithAttachment inserts a message — optionally carrying an
// attachment (key/mime/name/size all non-nil together, or all nil for a plain
// text message) — and bumps the thread's last_message_at, in a single
// transaction. Returns the stored row including the attachment columns.
func (db *DB) AppendMessageWithAttachment(ctx context.Context, threadID int64, sender, body string, key, mime, name *string, size *int64) (*SupportMessage, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var m SupportMessage
	err = tx.QueryRow(ctx, `
		INSERT INTO support_chat_messages
			(thread_id, sender, body, attachment_key, attachment_mime, attachment_name, attachment_size)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, thread_id, sender, body, created_at, read_at,
			attachment_key, attachment_mime, attachment_name, attachment_size`,
		threadID, sender, body, key, mime, name, size).Scan(
		&m.ID, &m.ThreadID, &m.Sender, &m.Body, &m.CreatedAt, &m.ReadAt,
		&m.AttachmentKey, &m.AttachmentMIME, &m.AttachmentName, &m.AttachmentSize)
	if err != nil {
		return nil, err
	}

	if _, err = tx.Exec(ctx,
		`UPDATE support_chat_threads SET last_message_at = NOW() WHERE id = $1`, threadID); err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &m, nil
}

// ListMessages returns up to `limit` messages of a thread with id > sinceID
// (sinceID = 0 for the whole thread), ordered oldest-first. Drives both the
// SSE catch-up replay and the poll fallback.
func (db *DB) ListMessages(ctx context.Context, threadID, sinceID int64, limit int) ([]SupportMessage, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if limit <= 0 || limit > 500 {
		limit = 200
	}
	rows, err := db.Pool.Query(ctx, `
		SELECT id, thread_id, sender, body, created_at, read_at,
		       attachment_key, attachment_mime, attachment_name, attachment_size
		FROM support_chat_messages
		WHERE thread_id = $1 AND id > $2
		ORDER BY id ASC
		LIMIT $3`, threadID, sinceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SupportMessage
	for rows.Next() {
		var m SupportMessage
		if err := rows.Scan(&m.ID, &m.ThreadID, &m.Sender, &m.Body, &m.CreatedAt, &m.ReadAt,
			&m.AttachmentKey, &m.AttachmentMIME, &m.AttachmentName, &m.AttachmentSize); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ThreadOwnedBy reports whether threadID belongs to userID — the authz guard on
// every read/write so one user can never touch another's thread.
func (db *DB) ThreadOwnedBy(ctx context.Context, threadID, userID int64) (bool, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var ok bool
	err := db.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM support_chat_threads WHERE id = $1 AND user_id = $2)`,
		threadID, userID).Scan(&ok)
	return ok, err
}

// ThreadUserID returns the owning user's id for a thread — used by the agent
// reply path to resolve which user's push tokens to notify. ErrNotFound when
// the thread doesn't exist.
func (db *DB) ThreadUserID(ctx context.Context, threadID int64) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var userID int64
	err := db.Pool.QueryRow(ctx,
		`SELECT user_id FROM support_chat_threads WHERE id = $1`, threadID).Scan(&userID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, ErrNotFound
		}
		return 0, err
	}
	return userID, nil
}

// CloseThread marks an open thread closed and starts the 90-day purge clock.
// No-op (ErrNotFound) if the thread isn't open. The user's next message creates
// a fresh open thread (the partial unique index allows it).
func (db *DB) CloseThread(ctx context.Context, threadID int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`UPDATE support_chat_threads SET status = 'closed', closed_at = NOW()
		 WHERE id = $1 AND status = 'open'`, threadID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// AdminThreadSummary is one row in the agent inbox list (P3 admin inbox).
type AdminThreadSummary struct {
	ThreadID       int64
	UserID         int64
	Status         string
	LastMessageAt  time.Time
	LastSender     string
	LastBody       string
	UnreadFromUser int
	VPNUsername    *string
	AuthProvider   *string
	DeviceID       *string
}

// ListAdminThreads returns threads for the agent inbox — open first, newest
// activity first — with the last message, the unread (user→agent) count, and
// the client's identity for display.
func (db *DB) ListAdminThreads(ctx context.Context, limit int) ([]AdminThreadSummary, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := db.Pool.Query(ctx, `
		SELECT t.id, t.user_id, t.status, t.last_message_at,
		       COALESCE(lm.sender, ''),
		       CASE
		           WHEN COALESCE(lm.body, '') <> '' THEN lm.body
		           WHEN lm.attachment_key IS NOT NULL THEN '[вложение]'
		           ELSE ''
		       END,
		       COALESCE(uc.cnt, 0),
		       u.vpn_username, u.auth_provider, u.device_id
		FROM support_chat_threads t
		LEFT JOIN users u ON u.id = t.user_id
		LEFT JOIN LATERAL (
			SELECT sender, body, attachment_key FROM support_chat_messages m
			WHERE m.thread_id = t.id ORDER BY m.id DESC LIMIT 1
		) lm ON TRUE
		LEFT JOIN LATERAL (
			SELECT COUNT(*) AS cnt FROM support_chat_messages m
			WHERE m.thread_id = t.id AND m.sender = 'user' AND m.read_at IS NULL
		) uc ON TRUE
		ORDER BY (t.status = 'open') DESC, t.last_message_at DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []AdminThreadSummary
	for rows.Next() {
		var s AdminThreadSummary
		if err := rows.Scan(&s.ThreadID, &s.UserID, &s.Status, &s.LastMessageAt,
			&s.LastSender, &s.LastBody, &s.UnreadFromUser,
			&s.VPNUsername, &s.AuthProvider, &s.DeviceID); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// MarkThreadReadByAgent clears read_at on the user's messages once an agent has
// opened the thread (drives the inbox unread badge back to zero).
func (db *DB) MarkThreadReadByAgent(ctx context.Context, threadID int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx,
		`UPDATE support_chat_messages SET read_at = NOW()
		 WHERE thread_id = $1 AND sender = 'user' AND read_at IS NULL`, threadID)
	return err
}

// CollectPurgeableAttachmentKeys returns the B2 object keys of attachments
// belonging to threads that PurgeClosedThreadsOlderThan(age) is about to delete.
// runSupportRetention calls this BEFORE the purge so it can best-effort delete
// the bytes from B2 (the DB rows cascade away on their own). Returns nil (not an
// error) when there's nothing to clean.
func (db *DB) CollectPurgeableAttachmentKeys(ctx context.Context, age time.Duration) ([]string, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT m.attachment_key
		FROM support_chat_messages m
		JOIN support_chat_threads t ON t.id = m.thread_id
		WHERE t.status = 'closed'
		  AND t.closed_at < NOW() - $1::interval
		  AND m.attachment_key IS NOT NULL`, age.String())
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var keys []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		keys = append(keys, k)
	}
	return keys, rows.Err()
}

// PurgeClosedThreadsOlderThan hard-deletes threads closed more than `age` ago
// (messages cascade). Returns the number of threads removed. Called daily by
// runSupportRetention with age = 90 days.
func (db *DB) PurgeClosedThreadsOlderThan(ctx context.Context, age time.Duration) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`DELETE FROM support_chat_threads
		 WHERE status = 'closed' AND closed_at < NOW() - $1::interval`,
		age.String())
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

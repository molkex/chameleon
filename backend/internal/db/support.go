// Package db — support.go: queries for SUPPORT-CHAT (ADR 0011, P0 backend).
//
// Model: one OPEN thread per user (a fresh thread after a close), append-only
// messages. Anonymous trial users participate too — there is no auth gate here,
// only the users(id) FK; the mobile API applies the tighter anon rate-limit.
package db

import (
	"context"
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

// SupportMessage is one append-only message in a thread.
type SupportMessage struct {
	ID        int64
	ThreadID  int64
	Sender    string // "user" | "agent" | "system"
	Body      string
	CreatedAt time.Time
	ReadAt    *time.Time
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

// AppendMessage inserts a message and bumps the thread's last_message_at, in a
// single transaction. Returns the stored row (for Redis fan-out at the API layer).
func (db *DB) AppendMessage(ctx context.Context, threadID int64, sender, body string) (*SupportMessage, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var m SupportMessage
	err = tx.QueryRow(ctx, `
		INSERT INTO support_chat_messages (thread_id, sender, body)
		VALUES ($1, $2, $3)
		RETURNING id, thread_id, sender, body, created_at, read_at`,
		threadID, sender, body).Scan(&m.ID, &m.ThreadID, &m.Sender, &m.Body, &m.CreatedAt, &m.ReadAt)
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
		SELECT id, thread_id, sender, body, created_at, read_at
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
		if err := rows.Scan(&m.ID, &m.ThreadID, &m.Sender, &m.Body, &m.CreatedAt, &m.ReadAt); err != nil {
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

// Package db — push.go: device APNs-token queries for SUPPORT-CHAT push
// notifications (ADR 0011 follow-up, P4). Schema: migration 022.
//
// One row per device token (token UNIQUE). The mobile /push/register endpoint
// upserts on register; admin/support.go reads every token for the thread's
// owner on an agent reply, and prunes a token APNs has rejected.
package db

import (
	"context"
	"time"
)

// UpsertPushToken records (or refreshes) a device's APNs token for a user. The
// token is the conflict key: a device that re-registers — or moves to another
// account — re-points the same row at the current user_id/platform and bumps
// updated_at, rather than leaving a stale duplicate.
func (db *DB) UpsertPushToken(ctx context.Context, userID int64, token, platform string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		INSERT INTO device_push_tokens (user_id, token, platform)
		VALUES ($1, $2, $3)
		ON CONFLICT (token) DO UPDATE SET
			user_id    = excluded.user_id,
			platform   = excluded.platform,
			updated_at = NOW()`,
		userID, token, platform)
	return err
}

// PushTokensForUser returns every registered APNs token for a user (one per
// device). Empty (not an error) when the user has no registered devices.
func (db *DB) PushTokensForUser(ctx context.Context, userID int64) ([]string, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx,
		`SELECT token FROM device_push_tokens WHERE user_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// DeletePushToken removes a single token — called when APNs reports it as
// permanently invalid (push.ErrBadToken) so we stop sending to a dead device.
func (db *DB) DeletePushToken(ctx context.Context, token string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx,
		`DELETE FROM device_push_tokens WHERE token = $1`, token)
	return err
}

// ── BROADCAST-PUSH ──────────────────────────────────────────────────────────

// AllPushTokens returns every registered APNs token across all users — the
// recipient set for an admin broadcast. Empty (not an error) when none.
func (db *DB) AllPushTokens(ctx context.Context) ([]string, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `SELECT token FROM device_push_tokens`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// PushTokenStats counts registered tokens grouped by platform (drives the
// broadcast recipient preview). Returns the grand total plus a per-platform map.
func (db *DB) PushTokenStats(ctx context.Context) (total int, byPlatform map[string]int, err error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx,
		`SELECT COALESCE(NULLIF(platform,''),'unknown'), count(*) FROM device_push_tokens GROUP BY 1`)
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()

	byPlatform = map[string]int{}
	for rows.Next() {
		var p string
		var n int
		if err := rows.Scan(&p, &n); err != nil {
			return 0, nil, err
		}
		byPlatform[p] = n
		total += n
	}
	return total, byPlatform, rows.Err()
}

// Broadcast is one row of the admin push-broadcast audit log (migration 023).
type Broadcast struct {
	ID        int64
	Title     string
	Body      string
	Total     int
	Sent      int
	Failed    int
	AdminUser string
	CreatedAt time.Time
}

// InsertBroadcast records a completed broadcast and returns its id.
func (db *DB) InsertBroadcast(ctx context.Context, title, body string, total, sent, failed int, adminUser string) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var id int64
	err := db.Pool.QueryRow(ctx,
		`INSERT INTO push_broadcasts (title, body, total, sent, failed, admin_user)
		 VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
		title, body, total, sent, failed, adminUser).Scan(&id)
	return id, err
}

// ListBroadcasts returns recent broadcasts, newest first (capped).
func (db *DB) ListBroadcasts(ctx context.Context, limit int) ([]Broadcast, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	if limit <= 0 || limit > 100 {
		limit = 20
	}

	rows, err := db.Pool.Query(ctx,
		`SELECT id, title, body, total, sent, failed, COALESCE(admin_user,''), created_at
		 FROM push_broadcasts ORDER BY id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Broadcast
	for rows.Next() {
		var b Broadcast
		if err := rows.Scan(&b.ID, &b.Title, &b.Body, &b.Total, &b.Sent, &b.Failed, &b.AdminUser, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// Package db — push.go: device APNs-token queries for SUPPORT-CHAT push
// notifications (ADR 0011 follow-up, P4). Schema: migration 022.
//
// One row per device token (token UNIQUE). The mobile /push/register endpoint
// upserts on register; admin/support.go reads every token for the thread's
// owner on an agent reply, and prunes a token APNs has rejected.
package db

import "context"

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

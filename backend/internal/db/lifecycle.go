package db

import (
	"context"
	"time"
)

// lifecycle.go — A1 lifecycle re-engagement (PRODUCT-MATURITY-LOOP, 2026-06-21).
// Query candidates for a lifecycle reminder window and record what was sent so
// each reminder fires once per subscription cycle (see migration 027).

// LifecycleCandidate is a user eligible for a lifecycle reminder.
type LifecycleCandidate struct {
	UserID  int64
	Email   *string   // nil when the user has no email (anon/device account)
	Expiry  time.Time // the user's current subscription_expiry (= expiry_ref)
	HasPaid bool      // true = paying customer (renew copy); false = trial (convert copy)
}

// LifecycleCandidates returns active users whose subscription_expiry falls in
// [lo, hi) and who have NOT already received the `kind` reminder for this exact
// expiry. Excludes NULL expiry (no coverage, REFUND-NULL-EXPIRY-GATE semantics).
func (db *DB) LifecycleCandidates(ctx context.Context, kind string, lo, hi time.Time) ([]LifecycleCandidate, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT u.id, u.email, u.subscription_expiry,
		       EXISTS(SELECT 1 FROM payments p WHERE p.user_id = u.id AND p.status = 'completed') AS has_paid
		  FROM users u
		 WHERE u.is_active = TRUE
		   AND u.subscription_expiry IS NOT NULL
		   AND u.subscription_expiry >= $1
		   AND u.subscription_expiry <  $2
		   AND NOT EXISTS (
		       SELECT 1 FROM lifecycle_reminders lr
		        WHERE lr.user_id = u.id
		          AND lr.kind = $3
		          AND lr.expiry_ref = u.subscription_expiry
		   )
		 ORDER BY u.subscription_expiry`, lo, hi, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []LifecycleCandidate
	for rows.Next() {
		var c LifecycleCandidate
		if err := rows.Scan(&c.UserID, &c.Email, &c.Expiry, &c.HasPaid); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// RecordLifecycleReminder marks the (user, kind, expiry) reminder as sent.
// ON CONFLICT DO NOTHING makes a concurrent/retried sweep safe.
func (db *DB) RecordLifecycleReminder(ctx context.Context, userID int64, kind string, expiryRef time.Time, channels string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		INSERT INTO lifecycle_reminders (user_id, kind, expiry_ref, channels)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (user_id, kind, expiry_ref) DO NOTHING`,
		userID, kind, expiryRef, channels)
	return err
}

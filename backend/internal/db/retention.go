package db

import "context"

// retention.go — A9 churn/retention visibility (PRODUCT-MATURITY-LOOP, 2026-06-21).
// The owner could see acquisition (total/active/DAU) but NOT retention — no way
// to know renewal/repeat-purchase or trial→paid conversion, which is exactly the
// data needed to decide whether advertising pays back. Computed read-only from
// the existing users + payments tables.

// RetentionStats are the raw churn/retention counts (rates derived in the API).
type RetentionStats struct {
	ActiveSubscribers int64 // subscription_expiry in the future
	Expired7d         int64 // lapsed within the last 7 days
	Expired30d        int64 // lapsed within the last 30 days
	EverTrialed       int64 // users who were ever granted a trial
	PaidUsers         int64 // distinct users with >=1 completed payment
	RepeatPayers      int64 // users with >=2 completed payments (the recurring-revenue core)
	TrialConverted    int64 // trial users who went on to pay at least once
}

// RetentionStats computes churn/retention counts in a single round-trip.
func (db *DB) RetentionStats(ctx context.Context) (*RetentionStats, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var s RetentionStats
	err := db.Pool.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM users WHERE subscription_expiry > now()) AS active_subscribers,
		  (SELECT count(*) FROM users
		     WHERE subscription_expiry <= now()
		       AND subscription_expiry > now() - interval '7 days') AS expired_7d,
		  (SELECT count(*) FROM users
		     WHERE subscription_expiry <= now()
		       AND subscription_expiry > now() - interval '30 days') AS expired_30d,
		  (SELECT count(*) FROM users WHERE trial_granted_at IS NOT NULL) AS ever_trialed,
		  (SELECT count(DISTINCT user_id) FROM payments WHERE status = 'completed') AS paid_users,
		  (SELECT count(*) FROM (
		       SELECT user_id FROM payments WHERE status = 'completed'
		        GROUP BY user_id HAVING count(*) >= 2) rp) AS repeat_payers,
		  (SELECT count(*) FROM users u
		     WHERE u.trial_granted_at IS NOT NULL
		       AND EXISTS(SELECT 1 FROM payments p WHERE p.user_id = u.id AND p.status = 'completed')) AS trial_converted
	`).Scan(
		&s.ActiveSubscribers, &s.Expired7d, &s.Expired30d,
		&s.EverTrialed, &s.PaidUsers, &s.RepeatPayers, &s.TrialConverted,
	)
	if err != nil {
		return nil, err
	}
	return &s, nil
}

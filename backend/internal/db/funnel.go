// Package db — funnel.go contains queries that drive the admin's
// /admin/app/funnel page (USR-09 Phase 1). The whole funnel is derived
// from existing tables (users, payments) so we don't need iOS event
// tracking yet — that's Phase 2, narrowly scoped to events the backend
// genuinely can't infer (paywall.view, purchase.cancel, etc).

package db

import (
	"context"
	"fmt"
	"time"
)

// DailyCount is one bucket in a per-day timeseries. Used for both the
// signups and the DAU series; the API sends both arrays aligned to the
// same calendar dates so the SPA can render them on one chart.
type DailyCount struct {
	Day   time.Time
	Count int64
}

// AuthBreakdown is the count of signups per auth_provider for the window.
type AuthBreakdown struct {
	Provider string
	Count    int64
}

// ConversionStats summarises how many signups in the window ever made
// their first paid charge, and how long it took on average.
type ConversionStats struct {
	Signups           int64
	ConvertedAny      int64   // any non-admin payment
	ConvertedApple    int64
	ConvertedFreekassa int64
	AvgDaysToConvert  float64 // 0 if no conversions
}

// CohortRetentionRow is one signup-week × follow-up-week cell. `Rate` is
// 0..1 — share of the cohort that was last_seen ≥ that week.
type CohortRetentionRow struct {
	CohortWeekStart time.Time // Monday of the signup week
	CohortSize      int64
	WeeksAfter      int    // 0..4
	StillActive     int64
}

// FunnelSummary is the aggregated bundle the admin handler returns. Each
// section is independently queried so a failure on one (e.g. payments
// pool stalled) doesn't take down the whole page.
type FunnelSummary struct {
	WindowDays      int
	Signups         []DailyCount
	DAU             []DailyCount
	// FirstPaymentsPerDay = count of users whose FIRST non-admin paid
	// charge completed on that day. Plotted as the conversion line in
	// the Signups & DAU chart so the operator can eyeball acquisition
	// vs monetization side-by-side without doing window math.
	FirstPaymentsPerDay []DailyCount
	Auth                []AuthBreakdown
	Conversion          ConversionStats
	Cohorts             []CohortRetentionRow
	GeneratedAt         time.Time
}

// FunnelSeries fetches all metrics in one shot, with a single timeout. Each
// sub-query is sequential — the dataset is small (45 users today), parallel
// adds complexity without measurable benefit.
//
// days clamped to [1, 365]. Default 30 if 0.
func (db *DB) FunnelSeries(ctx context.Context, days int) (*FunnelSummary, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if days <= 0 {
		days = 30
	}
	if days > 365 {
		days = 365
	}

	signups, err := db.signupsPerDay(ctx, days)
	if err != nil {
		return nil, fmt.Errorf("signups: %w", err)
	}

	dau, err := db.activeUsersPerDay(ctx, days)
	if err != nil {
		return nil, fmt.Errorf("dau: %w", err)
	}

	auth, err := db.authBreakdown(ctx, days)
	if err != nil {
		return nil, fmt.Errorf("auth: %w", err)
	}

	conv, err := db.conversionStats(ctx, days)
	if err != nil {
		return nil, fmt.Errorf("conversion: %w", err)
	}

	firstPay, err := db.firstPaymentsPerDay(ctx, days)
	if err != nil {
		return nil, fmt.Errorf("first payments per day: %w", err)
	}

	cohorts, err := db.cohortRetention(ctx, days)
	if err != nil {
		return nil, fmt.Errorf("cohorts: %w", err)
	}

	return &FunnelSummary{
		WindowDays:          days,
		Signups:             signups,
		DAU:                 dau,
		FirstPaymentsPerDay: firstPay,
		Auth:                auth,
		Conversion:          conv,
		Cohorts:             cohorts,
		GeneratedAt:         time.Now().UTC(),
	}, nil
}

// firstPaymentsPerDay — count of distinct users whose FIRST non-admin
// completed payment landed on each day in the window. Mirrors the same
// calendar-padded shape as signupsPerDay so the SPA can zip the two
// arrays cell-for-cell.
func (db *DB) firstPaymentsPerDay(ctx context.Context, days int) ([]DailyCount, error) {
	rows, err := db.Pool.Query(ctx, `
		WITH cal AS (
			SELECT generate_series(
				date_trunc('day', NOW() - ($1::int - 1 || ' days')::interval),
				date_trunc('day', NOW()),
				'1 day'::interval
			)::date AS day
		),
		first_pay AS (
			SELECT p.user_id,
			       date_trunc('day', MIN(p.created_at))::date AS first_day
			FROM payments p
			WHERE p.source IN ('apple_iap', 'freekassa')
			  AND p.status = 'completed'
			GROUP BY p.user_id
		)
		SELECT cal.day, COALESCE(COUNT(fp.user_id), 0) AS cnt
		FROM cal
		LEFT JOIN first_pay fp ON fp.first_day = cal.day
		GROUP BY cal.day
		ORDER BY cal.day`, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []DailyCount
	for rows.Next() {
		var d DailyCount
		if err := rows.Scan(&d.Day, &d.Count); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// signupsPerDay — count of users.created_at by day, padded with zeros so
// the array length equals `days` (calendar contiguous, no gaps in the SPA
// chart x-axis).
func (db *DB) signupsPerDay(ctx context.Context, days int) ([]DailyCount, error) {
	rows, err := db.Pool.Query(ctx, `
		WITH cal AS (
			SELECT generate_series(
				date_trunc('day', NOW() - ($1::int - 1 || ' days')::interval),
				date_trunc('day', NOW()),
				'1 day'::interval
			)::date AS day
		)
		SELECT cal.day, COALESCE(COUNT(u.id), 0) AS cnt
		FROM cal
		LEFT JOIN users u
		  ON date_trunc('day', u.created_at)::date = cal.day
		GROUP BY cal.day
		ORDER BY cal.day`, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []DailyCount
	for rows.Next() {
		var d DailyCount
		if err := rows.Scan(&d.Day, &d.Count); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// activeUsersPerDay — DAU: distinct users with last_seen on that day.
// Same calendar padding as signups so the two series align row-for-row.
func (db *DB) activeUsersPerDay(ctx context.Context, days int) ([]DailyCount, error) {
	rows, err := db.Pool.Query(ctx, `
		WITH cal AS (
			SELECT generate_series(
				date_trunc('day', NOW() - ($1::int - 1 || ' days')::interval),
				date_trunc('day', NOW()),
				'1 day'::interval
			)::date AS day
		)
		SELECT cal.day, COALESCE(COUNT(DISTINCT u.id), 0) AS cnt
		FROM cal
		LEFT JOIN users u
		  ON date_trunc('day', u.last_seen)::date = cal.day
		GROUP BY cal.day
		ORDER BY cal.day`, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []DailyCount
	for rows.Next() {
		var d DailyCount
		if err := rows.Scan(&d.Day, &d.Count); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// authBreakdown — how many signups in the window came via each provider.
// COALESCE makes the "no provider set" (legacy / device-only) bucket explicit
// instead of dropping it from the chart.
func (db *DB) authBreakdown(ctx context.Context, days int) ([]AuthBreakdown, error) {
	rows, err := db.Pool.Query(ctx, `
		SELECT COALESCE(NULLIF(auth_provider, ''), 'device') AS provider,
		       COUNT(*) AS cnt
		FROM users
		WHERE created_at > NOW() - ($1::int || ' days')::interval
		GROUP BY 1
		ORDER BY cnt DESC`, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []AuthBreakdown
	for rows.Next() {
		var a AuthBreakdown
		if err := rows.Scan(&a.Provider, &a.Count); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// conversionStats — of the signups in the window, how many ever made a
// paid charge (apple_iap OR freekassa source — explicitly excluding 'admin'
// grants which would inflate the rate). avg_days computed over conversions
// only; zero when there are none, so the SPA can sentinel-check.
func (db *DB) conversionStats(ctx context.Context, days int) (ConversionStats, error) {
	var c ConversionStats
	err := db.Pool.QueryRow(ctx, `
		WITH cohort AS (
			SELECT id, created_at
			FROM users
			WHERE created_at > NOW() - ($1::int || ' days')::interval
		),
		first_pay AS (
			SELECT p.user_id, MIN(p.created_at) AS first_at,
			       BOOL_OR(p.source = 'apple_iap') AS has_apple,
			       BOOL_OR(p.source = 'freekassa') AS has_fk
			FROM payments p
			JOIN cohort c ON c.id = p.user_id
			WHERE p.source IN ('apple_iap', 'freekassa')
			  AND p.status = 'completed'
			GROUP BY p.user_id
		)
		SELECT
			(SELECT COUNT(*) FROM cohort)                                     AS signups,
			(SELECT COUNT(*) FROM first_pay)                                  AS converted_any,
			(SELECT COUNT(*) FROM first_pay WHERE has_apple)                  AS converted_apple,
			(SELECT COUNT(*) FROM first_pay WHERE has_fk)                     AS converted_fk,
			COALESCE(
				(SELECT AVG(EXTRACT(EPOCH FROM (fp.first_at - c.created_at)) / 86400)
				 FROM first_pay fp JOIN cohort c ON c.id = fp.user_id),
				0
			)::float                                                          AS avg_days`,
		days,
	).Scan(&c.Signups, &c.ConvertedAny, &c.ConvertedApple, &c.ConvertedFreekassa, &c.AvgDaysToConvert)
	if err != nil {
		return c, err
	}
	return c, nil
}

// cohortRetention — 4-week retention matrix. For each cohort (week of
// signup) inside the window, compute the share still active in each of
// the following 4 weeks. "Active" = last_seen ≥ start of that week.
//
// Definitional notes:
//   - Cohorts use date_trunc('week', ...) which in Postgres returns Monday
//     of the ISO week. Acceptable for our use case.
//   - WeeksAfter=0 row is always 100% by definition (we exclude it from
//     the output to keep the table dense — the SPA can render the
//     cohort size separately).
//   - last_seen NULL rows count as not-retained — they registered but
//     never came back. Critical to NOT coalesce to NOW(): would lie.
func (db *DB) cohortRetention(ctx context.Context, days int) ([]CohortRetentionRow, error) {
	rows, err := db.Pool.Query(ctx, `
		WITH cohort AS (
			SELECT
				date_trunc('week', created_at)::date AS cohort_week,
				id,
				last_seen
			FROM users
			WHERE created_at > NOW() - ($1::int || ' days')::interval
		),
		sizes AS (
			SELECT cohort_week, COUNT(*) AS size FROM cohort GROUP BY cohort_week
		),
		weeks AS (
			SELECT generate_series(1, 4) AS weeks_after
		),
		retained AS (
			SELECT
				c.cohort_week,
				w.weeks_after,
				COUNT(*) FILTER (
					WHERE c.last_seen IS NOT NULL
					  AND c.last_seen >= c.cohort_week + (w.weeks_after || ' weeks')::interval
				) AS still_active
			FROM cohort c CROSS JOIN weeks w
			GROUP BY c.cohort_week, w.weeks_after
		)
		SELECT
			r.cohort_week,
			s.size,
			r.weeks_after,
			r.still_active
		FROM retained r
		JOIN sizes s ON s.cohort_week = r.cohort_week
		ORDER BY r.cohort_week, r.weeks_after`,
		days,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []CohortRetentionRow
	for rows.Next() {
		var c CohortRetentionRow
		if err := rows.Scan(&c.CohortWeekStart, &c.CohortSize, &c.WeeksAfter, &c.StillActive); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

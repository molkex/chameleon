package db

import (
	"context"
	"time"
)

// Payment period keys returned by PaymentsBlock. Ordered widest-last so the
// SPA can render the toggle in a stable order.
const (
	PaymentPeriodToday = "today"
	PaymentPeriod7d    = "7d"
	PaymentPeriod30d   = "30d"
	PaymentPeriodAll   = "all"
)

// PaymentPeriodStats is the money + count rollup for one time window.
//
// Revenue/Refunds are keyed by ISO-4217 currency in MAJOR units (rubles, not
// kopecks) — only rows that actually carry an amount contribute. Apple IAP
// rows are written with amount_minor=0 / currency='' today (price is not in
// the StoreKit JWS), so they show up in Count but NOT in Revenue. Admin/promo
// grants likewise count toward BySource but carry no money.
type PaymentPeriodStats struct {
	Revenue     map[string]float64  // currency -> major units, completed
	Refunds     map[string]float64  // currency -> major units, refunded
	Count       int                 // completed customer payments (apple_iap + freekassa)
	RefundCount int                 // refunded customer payments
	UniquePayers int                // distinct users with a completed customer payment
	BySource    []PaymentSourceStat // per-source breakdown (all sources incl. admin/promo)
}

// PaymentSourceStat is one source's contribution within a period.
type PaymentSourceStat struct {
	Source  string
	Count   int
	Revenue map[string]float64 // currency -> major units, completed
}

// RecentPayment is one row of the "last payments" table.
type RecentPayment struct {
	UserID      *int64
	AmountMinor *int64 // nil for admin/promo and amount-less Apple rows
	Currency    string // "" when no amount
	Source      string
	Days        int
	Status      string
	CreatedAt   time.Time
}

// customerSources are the sources that represent real end-user payments, as
// opposed to admin/promo grants. Count / UniquePayers only consider these.
var customerSources = []string{"apple_iap", "freekassa"}

func isCustomerSource(s string) bool {
	for _, cs := range customerSources {
		if cs == s {
			return true
		}
	}
	return false
}

// PaymentsBlock aggregates the payments ledger into the four dashboard windows
// (today / 7d / 30d / all-time) in a single pass.
//
// One grouped query returns per (source, currency) conditional sums/counts for
// every window; a second one-row query returns distinct-payer counts (which
// can't be folded into the grouped query). The dataset is tiny, so two round
// trips is fine and keeps the SQL readable.
func (db *DB) PaymentsBlock(ctx context.Context) (map[string]*PaymentPeriodStats, error) {
	periods := map[string]*PaymentPeriodStats{
		PaymentPeriodToday: newPeriodStats(),
		PaymentPeriod7d:    newPeriodStats(),
		PaymentPeriod30d:   newPeriodStats(),
		PaymentPeriodAll:   newPeriodStats(),
	}

	rows, err := db.Pool.Query(ctx, `
		SELECT
			source,
			COALESCE(currency, '') AS currency,
			COUNT(*) FILTER (WHERE status = 'completed' AND created_at >= date_trunc('day', NOW()))                                                AS cnt_today,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'completed' AND amount_minor IS NOT NULL AND created_at >= date_trunc('day', NOW())), 0) AS sum_today,
			COUNT(*) FILTER (WHERE status = 'completed' AND created_at >= NOW() - INTERVAL '7 days')                                                AS cnt_7d,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'completed' AND amount_minor IS NOT NULL AND created_at >= NOW() - INTERVAL '7 days'), 0) AS sum_7d,
			COUNT(*) FILTER (WHERE status = 'completed' AND created_at >= NOW() - INTERVAL '30 days')                                               AS cnt_30d,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'completed' AND amount_minor IS NOT NULL AND created_at >= NOW() - INTERVAL '30 days'), 0) AS sum_30d,
			COUNT(*) FILTER (WHERE status = 'completed')                                                                                           AS cnt_all,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'completed' AND amount_minor IS NOT NULL), 0)                                        AS sum_all,
			COUNT(*) FILTER (WHERE status = 'refunded' AND created_at >= date_trunc('day', NOW()))                                                 AS ref_cnt_today,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'refunded' AND amount_minor IS NOT NULL AND created_at >= date_trunc('day', NOW())), 0) AS ref_sum_today,
			COUNT(*) FILTER (WHERE status = 'refunded' AND created_at >= NOW() - INTERVAL '7 days')                                                AS ref_cnt_7d,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'refunded' AND amount_minor IS NOT NULL AND created_at >= NOW() - INTERVAL '7 days'), 0) AS ref_sum_7d,
			COUNT(*) FILTER (WHERE status = 'refunded' AND created_at >= NOW() - INTERVAL '30 days')                                               AS ref_cnt_30d,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'refunded' AND amount_minor IS NOT NULL AND created_at >= NOW() - INTERVAL '30 days'), 0) AS ref_sum_30d,
			COUNT(*) FILTER (WHERE status = 'refunded')                                                                                           AS ref_cnt_all,
			COALESCE(SUM(amount_minor) FILTER (WHERE status = 'refunded' AND amount_minor IS NOT NULL), 0)                                        AS ref_sum_all
		FROM payments
		GROUP BY source, COALESCE(currency, '')`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var (
			source, currency                            string
			cntToday, cnt7d, cnt30d, cntAll             int
			sumToday, sum7d, sum30d, sumAll             int64
			refCntToday, refCnt7d, refCnt30d, refCntAll int
			refSumToday, refSum7d, refSum30d, refSumAll int64
		)
		if err := rows.Scan(
			&source, &currency,
			&cntToday, &sumToday, &cnt7d, &sum7d, &cnt30d, &sum30d, &cntAll, &sumAll,
			&refCntToday, &refSumToday, &refCnt7d, &refSum7d, &refCnt30d, &refSum30d, &refCntAll, &refSumAll,
		); err != nil {
			return nil, err
		}

		apply := func(p *PaymentPeriodStats, cnt int, sum int64, refCnt int, refSum int64) {
			major := minorToMajor(sum)
			refMajor := minorToMajor(refSum)
			if currency != "" && major != 0 {
				p.Revenue[currency] += major
			}
			if currency != "" && refMajor != 0 {
				p.Refunds[currency] += refMajor
			}
			if isCustomerSource(source) {
				p.Count += cnt
				p.RefundCount += refCnt
			}
			p.addSource(source, cnt, currency, major)
		}

		apply(periods[PaymentPeriodToday], cntToday, sumToday, refCntToday, refSumToday)
		apply(periods[PaymentPeriod7d], cnt7d, sum7d, refCnt7d, refSum7d)
		apply(periods[PaymentPeriod30d], cnt30d, sum30d, refCnt30d, refSum30d)
		apply(periods[PaymentPeriodAll], cntAll, sumAll, refCntAll, refSumAll)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Distinct payer counts per window — separate one-row query because
	// COUNT(DISTINCT) can't share the per-(source,currency) grouping above.
	var uToday, u7d, u30d, uAll int
	err = db.Pool.QueryRow(ctx, `
		SELECT
			COUNT(DISTINCT user_id) FILTER (WHERE created_at >= date_trunc('day', NOW()))     AS u_today,
			COUNT(DISTINCT user_id) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days')     AS u_7d,
			COUNT(DISTINCT user_id) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')    AS u_30d,
			COUNT(DISTINCT user_id)                                                            AS u_all
		FROM payments
		WHERE status = 'completed' AND source IN ('apple_iap', 'freekassa')`).
		Scan(&uToday, &u7d, &u30d, &uAll)
	if err != nil {
		return nil, err
	}
	periods[PaymentPeriodToday].UniquePayers = uToday
	periods[PaymentPeriod7d].UniquePayers = u7d
	periods[PaymentPeriod30d].UniquePayers = u30d
	periods[PaymentPeriodAll].UniquePayers = uAll

	// Drop zero-activity sources so the SPA breakdown stays clean.
	for _, p := range periods {
		p.pruneEmptySources()
	}

	return periods, nil
}

// RecentPayments returns the latest `limit` ledger rows, newest first.
func (db *DB) RecentPayments(ctx context.Context, limit int) ([]RecentPayment, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	rows, err := db.Pool.Query(ctx, `
		SELECT user_id, amount_minor, COALESCE(currency, ''), source, days, status, created_at
		FROM payments
		ORDER BY created_at DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []RecentPayment
	for rows.Next() {
		var p RecentPayment
		var uid *int64
		if err := rows.Scan(&uid, &p.AmountMinor, &p.Currency, &p.Source, &p.Days, &p.Status, &p.CreatedAt); err != nil {
			return nil, err
		}
		p.UserID = uid
		out = append(out, p)
	}
	return out, rows.Err()
}

func newPeriodStats() *PaymentPeriodStats {
	return &PaymentPeriodStats{
		Revenue: map[string]float64{},
		Refunds: map[string]float64{},
	}
}

func (p *PaymentPeriodStats) addSource(source string, cnt int, currency string, major float64) {
	for i := range p.BySource {
		if p.BySource[i].Source == source {
			p.BySource[i].Count += cnt
			if currency != "" && major != 0 {
				p.BySource[i].Revenue[currency] += major
			}
			return
		}
	}
	rev := map[string]float64{}
	if currency != "" && major != 0 {
		rev[currency] = major
	}
	p.BySource = append(p.BySource, PaymentSourceStat{Source: source, Count: cnt, Revenue: rev})
}

func (p *PaymentPeriodStats) pruneEmptySources() {
	kept := p.BySource[:0]
	for _, s := range p.BySource {
		if s.Count > 0 || len(s.Revenue) > 0 {
			kept = append(kept, s)
		}
	}
	p.BySource = kept
}

// minorToMajor converts kopecks/cents to major currency units.
func minorToMajor(minor int64) float64 {
	return float64(minor) / 100.0
}

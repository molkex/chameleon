package admin

import "time"

// mskLocation is Moscow time (UTC+3, no DST since 2014). We use FixedZone — not
// time.LoadLocation("Europe/Moscow") — so admin time display never depends on
// tzdata (zoneinfo) being present in the (possibly distroless/scratch) container
// image, which would otherwise silently fall back to UTC.
var mskLocation = time.FixedZone("MSK", 3*60*60)

// fmtMSK renders a timestamp in Moscow time — the business timezone the admin
// panel displays. DB timestamps are UTC (pgx scans timestamptz as UTC), so
// without this conversion payment/transaction times read 3 hours behind MSK
// (user-reported 2026-06-06). Use this for any human-facing admin time string.
func fmtMSK(t time.Time, layout string) string {
	return t.In(mskLocation).Format(layout)
}

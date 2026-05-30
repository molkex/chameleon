//go:build integration

package db

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// TestPaymentsBlock pins the dashboard payments rollup. It seeds a mix of
// FreeKassa (RUB, with amount), Apple IAP (no amount — price not in the JWS),
// an admin grant (no amount), and a refund, then asserts:
//   - revenue is summed per currency and EXCLUDES refunds + amount-less rows
//   - Count counts only completed customer payments (apple_iap + freekassa)
//   - admin grants never count toward Count / revenue, only BySource
//   - refunds land in Refunds / RefundCount, not revenue
//   - the per-window buckets (today / 7d / 30d / all) filter by created_at
func TestPaymentsBlock(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	now := time.Now().UTC()

	mkUser := func(suffix string) int64 {
		u := &User{
			VPNUsername:  ptr(fmt.Sprintf("device_%s", suffix)),
			VPNUUID:      ptr(fmt.Sprintf("00000000-0000-4000-8000-%012s", suffix)),
			VPNShortID:   ptr(""),
			AuthProvider: ptr("device"),
			IsActive:     true,
			CreatedAt:    now,
			UpdatedAt:    now,
		}
		if err := database.CreateUser(ctx, u); err != nil {
			t.Fatalf("CreateUser(%s): %v", suffix, err)
		}
		return u.ID
	}

	userA := mkUser("p01")
	userB := mkUser("p02")

	seedMoney := func(uid int64, source, charge, currency, status string, amountMinor int64, days int, createdAt time.Time) {
		_, err := database.Pool.Exec(ctx,
			`INSERT INTO payments (user_id, source, charge_id, days, amount_minor, currency, status, created_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
			uid, source, charge, days, amountMinor, currency, status, createdAt)
		if err != nil {
			t.Fatalf("seed payment %s: %v", charge, err)
		}
	}
	seedNoAmount := func(uid int64, source, charge, status string, days int, createdAt time.Time) {
		_, err := database.Pool.Exec(ctx,
			`INSERT INTO payments (user_id, source, charge_id, days, status, created_at)
			 VALUES ($1, $2, $3, $4, $5, $6)`,
			uid, source, charge, days, status, createdAt)
		if err != nil {
			t.Fatalf("seed payment %s: %v", charge, err)
		}
	}

	tenDaysAgo := now.AddDate(0, 0, -10)

	seedMoney(userA, "freekassa", "fk-1", "RUB", "completed", 29900, 30, now)        // today
	seedMoney(userB, "freekassa", "fk-2", "RUB", "completed", 89900, 90, tenDaysAgo) // 30d, not today/7d
	seedNoAmount(userA, "apple_iap", "ap-1", "completed", 30, now)                   // today, no money
	seedNoAmount(userB, "admin", "admin-1", "completed", 30, now)                    // grant, never counts
	seedMoney(userA, "freekassa", "fk-3", "RUB", "refunded", 29900, 30, now)         // refund today
	seedMoney(userA, "freekassa", "fk-void", "RUB", "void", 99900, 30, now)          // operator-excluded test row → must not move ANY total below

	periods, err := database.PaymentsBlock(ctx)
	if err != nil {
		t.Fatalf("PaymentsBlock: %v", err)
	}

	all := periods[PaymentPeriodAll]
	if all == nil {
		t.Fatal("missing 'all' period")
	}
	if got := all.Revenue["RUB"]; got != 1198.00 {
		t.Errorf("all.Revenue[RUB] = %.2f, want 1198.00 (299 + 899, refund excluded)", got)
	}
	if got := all.Refunds["RUB"]; got != 299.00 {
		t.Errorf("all.Refunds[RUB] = %.2f, want 299.00", got)
	}
	if all.Count != 3 {
		t.Errorf("all.Count = %d, want 3 (2 freekassa + 1 apple completed; admin & refund excluded)", all.Count)
	}
	if all.RefundCount != 1 {
		t.Errorf("all.RefundCount = %d, want 1", all.RefundCount)
	}
	if all.UniquePayers != 2 {
		t.Errorf("all.UniquePayers = %d, want 2 (userA + userB)", all.UniquePayers)
	}

	bySource := map[string]PaymentSourceStat{}
	for _, s := range all.BySource {
		bySource[s.Source] = s
	}
	if fk := bySource["freekassa"]; fk.Count != 2 || fk.Revenue["RUB"] != 1198.00 {
		t.Errorf("all freekassa = %+v, want count=2 revenue[RUB]=1198.00", fk)
	}
	if ap := bySource["apple_iap"]; ap.Count != 1 || len(ap.Revenue) != 0 {
		t.Errorf("all apple_iap = %+v, want count=1 revenue empty", ap)
	}
	if adm := bySource["admin"]; adm.Count != 1 || len(adm.Revenue) != 0 {
		t.Errorf("all admin = %+v, want count=1 revenue empty", adm)
	}

	// today window: fk-2 (10d ago) excluded.
	today := periods[PaymentPeriodToday]
	if got := today.Revenue["RUB"]; got != 299.00 {
		t.Errorf("today.Revenue[RUB] = %.2f, want 299.00", got)
	}
	if today.Count != 2 {
		t.Errorf("today.Count = %d, want 2 (fk-1 + ap-1)", today.Count)
	}
	if today.UniquePayers != 1 {
		t.Errorf("today.UniquePayers = %d, want 1 (userA only)", today.UniquePayers)
	}

	// 30d window: includes fk-2.
	d30 := periods[PaymentPeriod30d]
	if got := d30.Revenue["RUB"]; got != 1198.00 {
		t.Errorf("30d.Revenue[RUB] = %.2f, want 1198.00", got)
	}
	if d30.Count != 3 {
		t.Errorf("30d.Count = %d, want 3", d30.Count)
	}
}

// TestRecentPayments checks newest-first ordering and minor→major conversion,
// including the amount-less Apple row (AmountMinor nil → amount 0).
func TestRecentPayments(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	now := time.Now().UTC()

	u := &User{
		VPNUsername:  ptr("device_rp1"),
		VPNUUID:      ptr("00000000-0000-4000-8000-0000000000r1"),
		VPNShortID:   ptr(""),
		AuthProvider: ptr("device"),
		IsActive:     true,
		CreatedAt:    now,
		UpdatedAt:    now,
	}
	if err := database.CreateUser(ctx, u); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	_, err := database.Pool.Exec(ctx,
		`INSERT INTO payments (user_id, source, charge_id, days, amount_minor, currency, status, created_at)
		 VALUES ($1, 'freekassa', 'rp-old', 30, 19900, 'RUB', 'completed', $2)`,
		u.ID, now.AddDate(0, 0, -2))
	if err != nil {
		t.Fatalf("seed old: %v", err)
	}
	_, err = database.Pool.Exec(ctx,
		`INSERT INTO payments (user_id, source, charge_id, days, status, created_at)
		 VALUES ($1, 'apple_iap', 'rp-new', 30, 'completed', $2)`,
		u.ID, now)
	if err != nil {
		t.Fatalf("seed new: %v", err)
	}
	// A void row is the newest of all — it must be excluded from the list so
	// operator-hidden test/sandbox payments don't resurface here.
	_, err = database.Pool.Exec(ctx,
		`INSERT INTO payments (user_id, source, charge_id, days, amount_minor, currency, status, created_at)
		 VALUES ($1, 'freekassa', 'rp-void', 30, 99900, 'RUB', 'void', $2)`,
		u.ID, now.Add(time.Minute))
	if err != nil {
		t.Fatalf("seed void: %v", err)
	}

	rows, err := database.RecentPayments(ctx, 10)
	if err != nil {
		t.Fatalf("RecentPayments: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len(rows) = %d, want 2 (void excluded)", len(rows))
	}
	// Newest first: the Apple row.
	if rows[0].Source != "apple_iap" {
		t.Errorf("rows[0].Source = %q, want apple_iap (newest first)", rows[0].Source)
	}
	if rows[0].AmountMinor != nil {
		t.Errorf("apple row AmountMinor = %v, want nil", *rows[0].AmountMinor)
	}
	if rows[1].Source != "freekassa" || rows[1].AmountMinor == nil || *rows[1].AmountMinor != 19900 {
		t.Errorf("rows[1] = %+v, want freekassa amount_minor=19900", rows[1])
	}
}

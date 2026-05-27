//go:build integration

package db

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// TestFunnelSeriesShape pins the contract of the SQL queries that drive
// the /admin/app/funnel page. Real numeric correctness is hard to assert
// without controlling NOW(), so this test focuses on:
//   - signups timeseries has exactly `days` rows (calendar padded)
//   - DAU timeseries has the same length, aligned by date
//   - auth breakdown returns one row per distinct provider
//   - conversion stats: a paid user counts, an admin grant does NOT
//   - cohort retention emits weeks_after 1..4 for every present cohort
//
// Regression risk: any of these queries can be rewritten to be more
// "efficient" by dropping calendar padding or LEFT JOINs, which silently
// breaks chart alignment in the SPA. This test catches that.
func TestFunnelSeriesShape(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	now := time.Now().UTC()

	// Seed: a few users across the last 14 days with different auth
	// providers and one with a payment.
	mkUser := func(suffix string, daysAgo int, provider string, lastSeenDaysAgo int) int64 {
		u := &User{
			VPNUsername:  ptr(fmt.Sprintf("device_%s", suffix)),
			VPNUUID:      ptr(fmt.Sprintf("00000000-0000-4000-8000-%012s", suffix)),
			VPNShortID:   ptr(""),
			AuthProvider: ptr(provider),
			IsActive:     true,
			CreatedAt:    now.AddDate(0, 0, -daysAgo),
			UpdatedAt:    now,
		}
		if lastSeenDaysAgo >= 0 {
			ls := now.AddDate(0, 0, -lastSeenDaysAgo)
			u.LastSeen = &ls
		}
		if err := database.CreateUser(ctx, u); err != nil {
			t.Fatalf("CreateUser(%s): %v", suffix, err)
		}
		return u.ID
	}

	alpha := mkUser("a01", 10, "apple", 1)        // signed up 10d ago, active yesterday
	mkUser("a02", 5, "google", 0)                  // signed up 5d ago, active today
	mkUser("a03", 3, "device", -1)                 // signed up 3d, never seen
	mkUser("a04", 1, "device", 1)                  // signed up 1d, active yesterday

	// alpha makes a paid Apple purchase 2 days after signup.
	paidAt := now.AddDate(0, 0, -8)
	_, err := database.Pool.Exec(ctx,
		`INSERT INTO payments (user_id, source, charge_id, days, status, created_at)
		 VALUES ($1, 'apple_iap', 'test-charge-001', 30, 'completed', $2)`,
		alpha, paidAt)
	if err != nil {
		t.Fatalf("seed payment: %v", err)
	}
	// And an admin grant — must NOT count as conversion.
	_, err = database.Pool.Exec(ctx,
		`INSERT INTO payments (user_id, source, charge_id, days, status, created_at)
		 VALUES ($1, 'admin', 'admin:0:30:1', 30, 'completed', NOW())`,
		alpha)
	if err != nil {
		t.Fatalf("seed admin grant: %v", err)
	}

	got, err := database.FunnelSeries(ctx, 14)
	if err != nil {
		t.Fatalf("FunnelSeries: %v", err)
	}

	// Calendar padding: signups[] and dau[] must have exactly 14 rows.
	if len(got.Signups) != 14 {
		t.Errorf("signups length: got %d, want 14", len(got.Signups))
	}
	if len(got.DAU) != 14 {
		t.Errorf("dau length: got %d, want 14", len(got.DAU))
	}
	// And the two arrays must be calendar-aligned cell-for-cell, otherwise
	// the SPA's combined line chart misrenders.
	for i := range got.Signups {
		if !got.Signups[i].Day.Equal(got.DAU[i].Day) {
			t.Errorf("series day mismatch at %d: signups=%v dau=%v",
				i, got.Signups[i].Day, got.DAU[i].Day)
		}
	}

	// Auth breakdown: 4 users, providers apple/google/device — device
	// appears twice. Order is desc by count, so device first.
	if len(got.Auth) < 1 {
		t.Fatalf("auth breakdown empty")
	}
	deviceFound := false
	for _, a := range got.Auth {
		if a.Provider == "device" && a.Count == 2 {
			deviceFound = true
		}
	}
	if !deviceFound {
		t.Errorf("auth breakdown missing device=2: %+v", got.Auth)
	}

	// Conversion: 4 signups, 1 paid via Apple, 0 via FreeKassa, admin
	// grant excluded.
	if got.Conversion.Signups != 4 {
		t.Errorf("conversion.signups: got %d, want 4", got.Conversion.Signups)
	}
	if got.Conversion.ConvertedAny != 1 {
		t.Errorf("conversion.converted_any: got %d, want 1 (admin grant must not count)", got.Conversion.ConvertedAny)
	}
	if got.Conversion.ConvertedApple != 1 {
		t.Errorf("conversion.apple: got %d, want 1", got.Conversion.ConvertedApple)
	}
	if got.Conversion.ConvertedFreekassa != 0 {
		t.Errorf("conversion.freekassa: got %d, want 0", got.Conversion.ConvertedFreekassa)
	}
	// alpha signed up 10d ago, paid 8d ago → 2 days to convert.
	if got.Conversion.AvgDaysToConvert < 1.5 || got.Conversion.AvgDaysToConvert > 2.5 {
		t.Errorf("avg_days: got %v, want ~2", got.Conversion.AvgDaysToConvert)
	}

	// Cohort retention: for each cohort week we should see weeks_after
	// 1..4. Just assert the shape (counts depend on the day this test
	// runs which we don't pin).
	if len(got.Cohorts) == 0 {
		t.Errorf("cohort retention empty — expected at least one cohort week")
	}
	weeksByCohort := map[string]map[int]bool{}
	for _, c := range got.Cohorts {
		k := c.CohortWeekStart.Format("2006-01-02")
		if weeksByCohort[k] == nil {
			weeksByCohort[k] = map[int]bool{}
		}
		weeksByCohort[k][c.WeeksAfter] = true
	}
	for cohort, weeks := range weeksByCohort {
		for w := 1; w <= 4; w++ {
			if !weeks[w] {
				t.Errorf("cohort %s missing weeks_after=%d", cohort, w)
			}
		}
	}
}

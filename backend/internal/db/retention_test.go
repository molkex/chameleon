//go:build integration

// retention_test.go covers RetentionStats (A9 churn/retention dashboard).
// Run: go test -tags=integration ./internal/db/...  (needs Docker; SKIPS without).

package db

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestRetentionStats(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	future := time.Now().Add(10 * 24 * time.Hour)
	expired3d := time.Now().Add(-3 * 24 * time.Hour)
	expired20d := time.Now().Add(-20 * 24 * time.Hour)
	trialedAt := time.Now().Add(-30 * 24 * time.Hour)

	mk := func(suffix string, expiry *time.Time, trialed bool) int64 {
		u := &User{
			VPNUsername: ptr(fmt.Sprintf("device_%s", suffix)),
			VPNUUID:     ptr(fmt.Sprintf("00000000-0000-4000-8000-%012s", suffix)),
			VPNShortID:  ptr(""),
			IsActive:    true,
		}
		u.SubscriptionExpiry = expiry
		if trialed {
			u.TrialGrantedAt = &trialedAt
		}
		if err := database.CreateUser(ctx, u); err != nil {
			t.Fatalf("CreateUser(%s): %v", suffix, err)
		}
		return u.ID
	}
	pay := func(uid int64, charge string) {
		_, err := database.Pool.Exec(ctx,
			`INSERT INTO payments (user_id, source, charge_id, days, status, created_at)
			 VALUES ($1, 'apple_iap', $2, 30, 'completed', NOW())`, uid, charge)
		if err != nil {
			t.Fatalf("seed payment %s: %v", charge, err)
		}
	}

	u1 := mk("u01", &future, true)     // active sub, trialed, repeat payer (2 pays) -> converted
	mk("u02", &expired3d, true)        // trialed, expired within 7d, no pay
	u3 := mk("u03", &expired20d, true) // trialed, expired within 30d (not 7d), 1 pay -> converted
	u4 := mk("u04", &future, false)    // active sub, NOT trialed, 1 pay

	pay(u1, "c-u1-a")
	pay(u1, "c-u1-b") // u1 has 2 -> repeat payer
	pay(u3, "c-u3-a")
	pay(u4, "c-u4-a")

	s, err := database.RetentionStats(ctx)
	if err != nil {
		t.Fatalf("RetentionStats: %v", err)
	}

	check := func(name string, got, want int64) {
		if got != want {
			t.Errorf("%s = %d, want %d", name, got, want)
		}
	}
	check("ActiveSubscribers", s.ActiveSubscribers, 2) // u1, u4
	check("Expired7d", s.Expired7d, 1)                 // u2
	check("Expired30d", s.Expired30d, 2)               // u2, u3
	check("EverTrialed", s.EverTrialed, 3)             // u1, u2, u3
	check("PaidUsers", s.PaidUsers, 3)                 // u1, u3, u4
	check("RepeatPayers", s.RepeatPayers, 1)           // u1
	check("TrialConverted", s.TrialConverted, 2)       // u1, u3
}

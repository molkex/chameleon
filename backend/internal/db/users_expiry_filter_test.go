//go:build integration

package db

import (
	"context"
	"testing"
	"time"
)

// Audit P0-E (2026-05-26): ListActiveVPNUsers must NOT return users whose
// subscription_expiry is in the past. Without this guard, expired users
// stay in sing-box's allow-set indefinitely — a cached /v1/config plus a
// valid UUID lets them keep connecting after their subscription ends
// (payment circumvention).
//
// Skipped without `-tags=integration` because it needs a real Postgres
// (testcontainers); fast unit tests don't pay the boot cost.

func TestListActiveVPNUsers_ExcludesExpiredSubscription(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	yesterday := now.Add(-24 * time.Hour)
	tomorrow := now.Add(24 * time.Hour)

	// Seed three users:
	//   - active: vpn creds + future expiry → MUST appear
	//   - expired: vpn creds + past expiry → MUST NOT appear (P0-E)
	//   - nullexp: vpn creds + NULL expiry → MUST NOT appear
	//     (REFUND-NULL-EXPIRY-GATE 2026-06-17: NULL = no coverage, not lifetime)
	seed := []*User{
		{
			VPNUsername:        ptr("device_active"),
			VPNUUID:            ptr("11111111-1111-4111-8111-111111111111"),
			VPNShortID:         ptr(""),
			IsActive:           true,
			SubscriptionExpiry: &tomorrow,
			CreatedAt:          now,
			UpdatedAt:          now,
		},
		{
			VPNUsername:        ptr("device_expired"),
			VPNUUID:            ptr("22222222-2222-4222-8222-222222222222"),
			VPNShortID:         ptr(""),
			IsActive:           true, // is_active=true but expiry is in past
			SubscriptionExpiry: &yesterday,
			CreatedAt:          now,
			UpdatedAt:          now,
		},
		{
			VPNUsername:        ptr("device_nullexp"),
			VPNUUID:            ptr("33333333-3333-4333-8333-333333333333"),
			VPNShortID:         ptr(""),
			IsActive:           true,
			SubscriptionExpiry: nil, // NULL — no coverage (refunded / never subscribed)
			CreatedAt:          now,
			UpdatedAt:          now,
		},
	}
	for _, u := range seed {
		if _, err := database.UpsertUserByVPNUUID(ctx, u); err != nil {
			t.Fatalf("seed UpsertUserByVPNUUID(%s): %v", *u.VPNUsername, err)
		}
	}

	got, err := database.ListActiveVPNUsers(ctx)
	if err != nil {
		t.Fatalf("ListActiveVPNUsers: %v", err)
	}

	usernames := make(map[string]bool)
	for _, u := range got {
		if u.VPNUsername != nil {
			usernames[*u.VPNUsername] = true
		}
	}

	if !usernames["device_active"] {
		t.Error("ListActiveVPNUsers should include device_active (future expiry)")
	}
	if usernames["device_expired"] {
		t.Error("ListActiveVPNUsers MUST exclude device_expired (P0-E regression)")
	}
	if usernames["device_nullexp"] {
		t.Error("ListActiveVPNUsers MUST exclude device_nullexp (REFUND-NULL-EXPIRY-GATE: NULL = no coverage, not lifetime)")
	}
}

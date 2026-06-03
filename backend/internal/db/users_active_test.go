//go:build integration

// users_active_test.go covers the "active = used app OR VPN" engagement
// counts (CountActive24h / CountActive30d) and BumpVPNSeen — the METRICS fix
// (migration 019) that stops the dashboard's "Active (24h)" from reading lower
// than the live "Online" count. Integration-tagged: needs a real Postgres so
// the last_vpn_seen column + OR query run for real.
//
//	go test -tags=integration ./internal/db/...

package db

import (
	"context"
	"testing"
	"time"
)

// makeUser inserts a user with the given vpn_username and (optionally) backdated
// last_seen / last_vpn_seen. Pass nil for a NULL timestamp.
func makeActiveUser(t *testing.T, database *DB, ctx context.Context, username, uuid string, lastSeen, lastVPNSeen *time.Time) {
	t.Helper()
	now := time.Now().UTC()
	u := &User{
		VPNUsername: ptr(username),
		VPNUUID:     ptr(uuid),
		VPNShortID:  ptr(""),
		DeviceID:    ptr("dev-" + username),
		IsActive:    true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	if err := database.CreateUser(ctx, u); err != nil {
		t.Fatalf("CreateUser(%s): %v", username, err)
	}
	if _, err := database.Pool.Exec(ctx,
		`UPDATE users SET last_seen = $2, last_vpn_seen = $3 WHERE vpn_username = $1`,
		username, lastSeen, lastVPNSeen); err != nil {
		t.Fatalf("set timestamps(%s): %v", username, err)
	}
}

// TestCountActiveAppOrVPN pins the OR semantics: a user counts as active if the
// app pinged (last_seen) OR they moved VPN traffic (last_vpn_seen) within the
// window. This is what keeps Active(24h) >= Online.
func TestCountActiveAppOrVPN(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	d2 := now.Add(-2 * 24 * time.Hour)
	d5 := now.Add(-5 * 24 * time.Hour)
	d40 := now.Add(-40 * 24 * time.Hour)

	// A: app-active now.                          24h yes / 30d yes
	makeActiveUser(t, database, ctx, "device_a", "aaaaaaaa-0000-4000-8000-00000000000a", &now, nil)
	// B: app stale (2d), VPN active now.          24h yes / 30d yes
	makeActiveUser(t, database, ctx, "device_b", "aaaaaaaa-0000-4000-8000-00000000000b", &d2, &now)
	// C: both stale (40d).                        24h no  / 30d no
	makeActiveUser(t, database, ctx, "device_c", "aaaaaaaa-0000-4000-8000-00000000000c", &d40, &d40)
	// D: no app ping ever, VPN 5d ago.            24h no  / 30d yes
	makeActiveUser(t, database, ctx, "device_d", "aaaaaaaa-0000-4000-8000-00000000000d", nil, &d5)

	active24h, err := database.CountActive24h(ctx)
	if err != nil {
		t.Fatalf("CountActive24h: %v", err)
	}
	if active24h != 2 {
		t.Errorf("CountActive24h = %d, want 2 (A app + B vpn)", active24h)
	}

	active30d, err := database.CountActive30d(ctx)
	if err != nil {
		t.Fatalf("CountActive30d: %v", err)
	}
	if active30d != 3 {
		t.Errorf("CountActive30d = %d, want 3 (A, B, D; C is 40d out)", active30d)
	}
}

// TestBumpVPNSeen verifies the traffic collector's stamp: a user with no recent
// activity becomes active-24h after a bump, empty input is a no-op, and unknown
// usernames don't error.
func TestBumpVPNSeen(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	old := time.Now().UTC().Add(-10 * 24 * time.Hour)
	makeActiveUser(t, database, ctx, "device_e", "aaaaaaaa-0000-4000-8000-00000000000e", &old, &old)

	// Empty + unknown: both must be harmless.
	if err := database.BumpVPNSeen(ctx, nil); err != nil {
		t.Fatalf("BumpVPNSeen(nil): %v", err)
	}
	if err := database.BumpVPNSeen(ctx, []string{"device_does_not_exist"}); err != nil {
		t.Fatalf("BumpVPNSeen(unknown): %v", err)
	}

	before, err := database.CountActive24h(ctx)
	if err != nil {
		t.Fatalf("CountActive24h before: %v", err)
	}
	if before != 0 {
		t.Fatalf("CountActive24h before bump = %d, want 0", before)
	}

	if err := database.BumpVPNSeen(ctx, []string{"device_e"}); err != nil {
		t.Fatalf("BumpVPNSeen(device_e): %v", err)
	}

	after, err := database.CountActive24h(ctx)
	if err != nil {
		t.Fatalf("CountActive24h after: %v", err)
	}
	if after != 1 {
		t.Errorf("CountActive24h after bump = %d, want 1", after)
	}
}

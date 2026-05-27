//go:build integration

package db

import (
	"context"
	"testing"
	"time"
)

// TestTopTrafficUsers proves the window sum + LEFT JOIN behaviour we depend
// on in the Activity dashboard. The traffic collector writes one row per
// (user, tick) with `used_traffic = upload+download` for THAT tick, so the
// admin's "top users in last N days" is SUM(used_traffic) — not MAX, not
// cumulative_traffic-on-users. Easy thing to get backwards in a rewrite.
func TestTopTrafficUsers(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	// Three users, each with a different total traffic across two snapshots.
	// One user lives only in traffic_snapshots (no users row) — LEFT JOIN
	// must still return them so the admin can spot orphaned VPN accounts.
	now := time.Now().UTC()
	users := []struct {
		u    *User
		snap []int64 // bytes per snapshot
	}{
		{
			u: &User{
				VPNUsername: ptr("device_alpha"),
				VPNUUID:     ptr("aaaaaaaa-0000-4000-8000-000000000001"),
				VPNShortID:  ptr(""),
				IsActive:    true,
				LastCountry: "RU",
				CreatedAt:   now,
				UpdatedAt:   now,
			},
			snap: []int64{2_000_000_000, 3_000_000_000}, // 5 GB
		},
		{
			u: &User{
				VPNUsername: ptr("device_beta"),
				VPNUUID:     ptr("bbbbbbbb-0000-4000-8000-000000000002"),
				VPNShortID:  ptr(""),
				IsActive:    true,
				LastCountry: "DE",
				CreatedAt:   now,
				UpdatedAt:   now,
			},
			snap: []int64{500_000_000, 500_000_000}, // 1 GB
		},
		{
			u: &User{
				VPNUsername: ptr("device_gamma"),
				VPNUUID:     ptr("cccccccc-0000-4000-8000-000000000003"),
				VPNShortID:  ptr(""),
				IsActive:    false,
				LastCountry: "US",
				CreatedAt:   now,
				UpdatedAt:   now,
			},
			snap: []int64{10_000_000_000, 5_000_000_000}, // 15 GB — top
		},
	}
	for _, x := range users {
		if err := database.CreateUser(ctx, x.u); err != nil {
			t.Fatalf("CreateUser: %v", err)
		}
		for _, b := range x.snap {
			// upload = b/2, download = b/2 — InsertTrafficSnapshot stores
			// upload+download as used_traffic, which is what the report sums.
			if err := database.InsertTrafficSnapshot(ctx, *x.u.VPNUsername, b/2, b/2); err != nil {
				t.Fatalf("InsertTrafficSnapshot: %v", err)
			}
		}
	}

	// Orphan row — vpn_username present in traffic but missing from users.
	if err := database.InsertTrafficSnapshot(ctx, "device_orphan", 1_000_000_000, 1_000_000_000); err != nil {
		t.Fatalf("orphan snapshot: %v", err)
	}

	out, err := database.TopTrafficUsers(ctx, 7, 10)
	if err != nil {
		t.Fatalf("TopTrafficUsers: %v", err)
	}

	// Expected order (by bytes desc): gamma (15GB), alpha (5GB), orphan (2GB), beta (1GB).
	wantOrder := []string{"device_gamma", "device_alpha", "device_orphan", "device_beta"}
	if len(out) != len(wantOrder) {
		t.Fatalf("len: got %d, want %d (%+v)", len(out), len(wantOrder), out)
	}
	for i, want := range wantOrder {
		if out[i].VPNUsername != want {
			t.Errorf("rank %d: got %s, want %s", i, out[i].VPNUsername, want)
		}
	}

	// gamma has 15 GB → 15_000_000_000 bytes total in the window
	if out[0].Bytes < 15_000_000_000-100 || out[0].Bytes > 15_000_000_000+100 {
		t.Errorf("gamma bytes: got %d, want ~15e9", out[0].Bytes)
	}

	// orphan must come through the LEFT JOIN with user_id=0 / blank country
	for _, r := range out {
		if r.VPNUsername == "device_orphan" {
			if r.UserID != 0 {
				t.Errorf("orphan UserID: got %d, want 0", r.UserID)
			}
			if r.LastCountry != "" {
				t.Errorf("orphan LastCountry: got %q, want empty", r.LastCountry)
			}
			if r.IsActive {
				t.Errorf("orphan IsActive: got true, want false")
			}
		}
	}

	// Limit clamp — request 1 row, get exactly 1.
	one, _, err := func() ([]TrafficOutlier, int, error) {
		o, e := database.TopTrafficUsers(ctx, 7, 1)
		return o, len(o), e
	}()
	if err != nil {
		t.Fatalf("limit 1: %v", err)
	}
	if len(one) != 1 || one[0].VPNUsername != "device_gamma" {
		t.Errorf("limit 1: got %+v", one)
	}

	// Window clamp — days=0 falls back to default (7), so we still see the
	// recent data we just inserted. days=120 (above max 90) also clamps and
	// returns the same set.
	wide, err := database.TopTrafficUsers(ctx, 120, 10)
	if err != nil {
		t.Fatalf("days=120: %v", err)
	}
	if len(wide) != len(wantOrder) {
		t.Errorf("days=120: got %d rows, want %d", len(wide), len(wantOrder))
	}
}

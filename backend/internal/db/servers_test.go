//go:build integration

package db

import (
	"context"
	"testing"
)

// TestUpdateServerPreservesSecrets locks in MED-015 (2026-05-27 incident).
//
// Background: admin SPA's "edit server" form posts every field of vpn_servers
// every time. Most forms don't surface Reality private key or provider
// password — sensitive material that should only be visible behind re-auth.
// The form was sending empty strings for those fields, and UpdateServer was
// blindly `SET reality_private_key = ''`, wiping the row.
//
// Downstream: chameleon's startup reads the local node's row, the private
// key is "" → fatal: reality private key not found → restart loop → 7-min
// outage on 2026-05-27 from 19:50 to 19:57 UTC.
//
// The fix is COALESCE(NULLIF($N, ''), reality_private_key) — same shape as
// UpsertServerByKey, which already had the guard. This test pins the new
// behaviour for reality_private_key, reality_public_key, and
// provider_password — all three are now empty-string-preserving on PUT.
func TestUpdateServerPreservesSecrets(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	// Seed: a server with real secrets set.
	seed := &VPNServer{
		Key:               "test-node",
		Name:              "Test Node",
		Host:              "1.2.3.4",
		Port:              443,
		SNI:               "www.example.com",
		RealityPublicKey:  "PUB-original-43-chars-padding-aaaaaaaaaaaaa",
		RealityPrivateKey: "PRIV-original-43-chars-padding-aaaaaaaaaaa",
		IsActive:          true,
		SortOrder:         100,
		ProviderName:      "test",
		ProviderLogin:     "user@example.com",
		ProviderPassword:  "super-secret-vps-password",
	}
	created, err := database.CreateServer(ctx, seed)
	if err != nil {
		t.Fatalf("CreateServer: %v", err)
	}

	// Simulate admin SPA edit that omits the sensitive fields (empty strings
	// in their place), changes only a benign field (e.g. cost_monthly).
	update := &VPNServer{
		Key:               created.Key,
		Name:              created.Name,
		Host:              created.Host,
		Port:              created.Port,
		SNI:               created.SNI,
		RealityPublicKey:  "",  // ← form omits, empty string sent
		RealityPrivateKey: "",  // ← form omits
		IsActive:          true,
		SortOrder:         created.SortOrder,
		ProviderName:      created.ProviderName,
		CostMonthly:       9.99, // <- the actual change
		ProviderLogin:     created.ProviderLogin,
		ProviderPassword:  "",  // ← form omits (sensitive, behind re-auth)
		Role:              "",
		Category:          "",
	}

	got, err := database.UpdateServer(ctx, created.ID, update)
	if err != nil {
		t.Fatalf("UpdateServer: %v", err)
	}

	// The benign field change applied.
	if got.CostMonthly != 9.99 {
		t.Errorf("CostMonthly: got %v, want 9.99", got.CostMonthly)
	}
	// Secrets preserved (this is the regression guard).
	if got.RealityPrivateKey != seed.RealityPrivateKey {
		t.Errorf("RealityPrivateKey wiped — guard regressed. got %q, want %q",
			got.RealityPrivateKey, seed.RealityPrivateKey)
	}
	if got.RealityPublicKey != seed.RealityPublicKey {
		t.Errorf("RealityPublicKey wiped. got %q, want %q",
			got.RealityPublicKey, seed.RealityPublicKey)
	}
	if got.ProviderPassword != seed.ProviderPassword {
		t.Errorf("ProviderPassword wiped. got %q, want %q",
			got.ProviderPassword, seed.ProviderPassword)
	}

	// Sanity: a non-empty value DOES replace (so admin can rotate the key
	// intentionally via the same endpoint).
	rotate := *update
	rotate.RealityPrivateKey = "PRIV-rotated-43-chars-bbbbbbbbbbbbbbbbbbbbb"
	rotated, err := database.UpdateServer(ctx, created.ID, &rotate)
	if err != nil {
		t.Fatalf("UpdateServer (rotate): %v", err)
	}
	if rotated.RealityPrivateKey != rotate.RealityPrivateKey {
		t.Errorf("intentional rotate failed: got %q, want %q",
			rotated.RealityPrivateKey, rotate.RealityPrivateKey)
	}
}

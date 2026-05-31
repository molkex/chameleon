//go:build integration

// trial_granted_at_test.go covers SEC-01's DB plumbing (2026-06-01): the
// trial_granted_at column must be written by CreateUser, persisted by
// UpdateUser, and read back by scanUser. Integration-gated (needs Docker) like
// the rest of internal/db — run with:
//
//	go test -tags=integration ./internal/db/...

package db

import (
	"context"
	"testing"
	"time"
)

// TestTrialGrantedAtRoundTrip asserts the full column round-trip: CreateUser
// stamps it, a stamp-less create reads back NULL, and UpdateUser persists a
// new stamp. If any of CreateUser's INSERT, UpdateUser's SET, or scanUser's
// column list drifts out of sync, this fails.
func TestTrialGrantedAtRoundTrip(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	granted := time.Now().UTC().Truncate(time.Second)

	// 1. CreateUser stamps trial_granted_at.
	u := &User{
		DeviceID:       ptr("dev-trial-1"),
		VPNUsername:    ptr("device_trial001"),
		VPNUUID:        ptr("11110000-2222-4333-8444-555566667777"),
		VPNShortID:     ptr(""),
		IsActive:       true,
		TrialGrantedAt: ptr(granted),
	}
	if err := database.CreateUser(ctx, u); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	got, err := database.FindUserByDeviceID(ctx, "dev-trial-1")
	if err != nil || got == nil {
		t.Fatalf("FindUserByDeviceID: err=%v got=%v", err, got)
	}
	if got.TrialGrantedAt == nil {
		t.Fatal("CreateUser did not persist trial_granted_at (read back nil)")
	}
	if !got.TrialGrantedAt.UTC().Equal(granted) {
		t.Errorf("trial_granted_at mismatch: got=%v want=%v", got.TrialGrantedAt.UTC(), granted)
	}

	// 2. A stamp-less create reads back NULL (column is nullable — "still
	//    eligible for a trial").
	u2 := &User{
		DeviceID:    ptr("dev-trial-2"),
		VPNUsername: ptr("device_trial002"),
		VPNUUID:     ptr("22220000-2222-4333-8444-555566667777"),
		VPNShortID:  ptr(""),
		IsActive:    true,
	}
	if err := database.CreateUser(ctx, u2); err != nil {
		t.Fatalf("CreateUser u2: %v", err)
	}
	got2, err := database.FindUserByDeviceID(ctx, "dev-trial-2")
	if err != nil || got2 == nil {
		t.Fatalf("FindUserByDeviceID u2: err=%v got=%v", err, got2)
	}
	if got2.TrialGrantedAt != nil {
		t.Errorf("expected nil trial_granted_at, got %v", got2.TrialGrantedAt)
	}

	// 3. UpdateUser persists a later stamp (the grant-once path stamps an
	//    existing row, not just CreateUser).
	later := granted.Add(48 * time.Hour)
	got2.TrialGrantedAt = ptr(later)
	if err := database.UpdateUser(ctx, got2); err != nil {
		t.Fatalf("UpdateUser: %v", err)
	}
	reread, err := database.FindUserByDeviceID(ctx, "dev-trial-2")
	if err != nil || reread == nil {
		t.Fatalf("FindUserByDeviceID reread: err=%v got=%v", err, reread)
	}
	if reread.TrialGrantedAt == nil || !reread.TrialGrantedAt.UTC().Equal(later) {
		t.Errorf("UpdateUser did not persist trial_granted_at: got=%v want=%v", reread.TrialGrantedAt, later)
	}
}

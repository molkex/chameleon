//go:build integration

// push_test.go covers the device-push-token DB layer (migration 022, P4):
// upsert-on-conflict, list-by-user, delete, the user_id re-point on a token
// that moves accounts, and the account-delete cascade. Integration-tagged
// (testcontainers PG).
//
//	go test -tags=integration ./internal/db/...

package db

import (
	"context"
	"testing"
)

func TestUpsertAndListPushTokens(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "push_a", "aaaaaaaa-0000-4000-8000-00000000a001")

	tokA := "aaaa1111bbbb2222cccc3333dddd4444"
	tokB := "eeee5555ffff6666aaaa7777bbbb8888"

	if err := database.UpsertPushToken(ctx, uid, tokA, "ios"); err != nil {
		t.Fatalf("UpsertPushToken A: %v", err)
	}
	if err := database.UpsertPushToken(ctx, uid, tokB, "ios"); err != nil {
		t.Fatalf("UpsertPushToken B: %v", err)
	}

	tokens, err := database.PushTokensForUser(ctx, uid)
	if err != nil {
		t.Fatalf("PushTokensForUser: %v", err)
	}
	if len(tokens) != 2 {
		t.Fatalf("PushTokensForUser = %d tokens, want 2", len(tokens))
	}

	// Re-registering tokA is idempotent — still two tokens, not three.
	if err := database.UpsertPushToken(ctx, uid, tokA, "ios"); err != nil {
		t.Fatalf("UpsertPushToken A (re-register): %v", err)
	}
	tokens, _ = database.PushTokensForUser(ctx, uid)
	if len(tokens) != 2 {
		t.Errorf("after re-register: %d tokens, want 2", len(tokens))
	}
}

func TestUpsertPushTokenRepointsUser(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid1 := createChatUser(t, database, ctx, "push_owner1", "aaaaaaaa-0000-4000-8000-00000000b001")
	uid2 := createChatUser(t, database, ctx, "push_owner2", "aaaaaaaa-0000-4000-8000-00000000b002")

	tok := "1234abcd5678ef901234abcd5678ef90"

	if err := database.UpsertPushToken(ctx, uid1, tok, "ios"); err != nil {
		t.Fatalf("Upsert uid1: %v", err)
	}
	// Same device token now used by another account (e.g. account switch on the
	// same phone) — it must re-point, not error on the UNIQUE(token).
	if err := database.UpsertPushToken(ctx, uid2, tok, "ios"); err != nil {
		t.Fatalf("Upsert uid2 (re-point): %v", err)
	}

	if t1, _ := database.PushTokensForUser(ctx, uid1); len(t1) != 0 {
		t.Errorf("uid1 still has %d tokens, want 0 after re-point", len(t1))
	}
	if t2, _ := database.PushTokensForUser(ctx, uid2); len(t2) != 1 {
		t.Errorf("uid2 has %d tokens, want 1 after re-point", len(t2))
	}
}

func TestDeletePushToken(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "push_del", "aaaaaaaa-0000-4000-8000-00000000c001")

	tok := "deadbeefdeadbeefdeadbeefdeadbeef"
	if err := database.UpsertPushToken(ctx, uid, tok, "ios"); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	if err := database.DeletePushToken(ctx, tok); err != nil {
		t.Fatalf("DeletePushToken: %v", err)
	}
	if tokens, _ := database.PushTokensForUser(ctx, uid); len(tokens) != 0 {
		t.Errorf("after delete: %d tokens, want 0", len(tokens))
	}
	// Deleting an absent token is a no-op (no error).
	if err := database.DeletePushToken(ctx, "nope"); err != nil {
		t.Errorf("DeletePushToken(absent) = %v, want nil", err)
	}
}

func TestPushTokensCascadeOnUserDelete(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "push_cascade", "aaaaaaaa-0000-4000-8000-00000000d001")

	if err := database.UpsertPushToken(ctx, uid, "cascade0011cascade0011cascade00", "ios"); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	// Hard-delete the user row → the FK ON DELETE CASCADE removes the token.
	if _, err := database.Pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, uid); err != nil {
		t.Fatalf("delete user: %v", err)
	}

	var n int
	if err := database.Pool.QueryRow(ctx,
		`SELECT count(*) FROM device_push_tokens WHERE user_id = $1`, uid).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Errorf("tokens not cascade-deleted: %d remain", n)
	}
}

// TestThreadUserID covers the agent-reply lookup: a thread resolves to its
// owner, and an unknown thread returns ErrNotFound.
func TestThreadUserID(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "push_thread", "aaaaaaaa-0000-4000-8000-00000000e001")
	th, _ := database.OpenOrGetThread(ctx, uid)

	got, err := database.ThreadUserID(ctx, th.ID)
	if err != nil {
		t.Fatalf("ThreadUserID: %v", err)
	}
	if got != uid {
		t.Errorf("ThreadUserID = %d, want %d", got, uid)
	}

	if _, err := database.ThreadUserID(ctx, 999999); err != ErrNotFound {
		t.Errorf("ThreadUserID(unknown) = %v, want ErrNotFound", err)
	}
}

// ── BROADCAST-PUSH ──────────────────────────────────────────────────────────

func TestAllPushTokensAndStats(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	u1 := createChatUser(t, database, ctx, "bcast_a", "aaaaaaaa-0000-4000-8000-00000000f001")
	u2 := createChatUser(t, database, ctx, "bcast_b", "aaaaaaaa-0000-4000-8000-00000000f002")

	// u1: two iOS devices; u2: one macOS device.
	for _, tok := range []string{"bcastA1", "bcastA2"} {
		if err := database.UpsertPushToken(ctx, u1, tok, "ios"); err != nil {
			t.Fatalf("UpsertPushToken: %v", err)
		}
	}
	if err := database.UpsertPushToken(ctx, u2, "bcastB1", "macos"); err != nil {
		t.Fatalf("UpsertPushToken: %v", err)
	}

	all, err := database.AllPushTokens(ctx)
	if err != nil {
		t.Fatalf("AllPushTokens: %v", err)
	}
	if len(all) != 3 {
		t.Errorf("AllPushTokens = %d, want 3", len(all))
	}

	total, byPlat, err := database.PushTokenStats(ctx)
	if err != nil {
		t.Fatalf("PushTokenStats: %v", err)
	}
	if total != 3 {
		t.Errorf("total = %d, want 3", total)
	}
	if byPlat["ios"] != 2 || byPlat["macos"] != 1 {
		t.Errorf("byPlatform = %v, want ios:2 macos:1", byPlat)
	}
}

func TestBroadcastLogRoundTrip(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	id, err := database.InsertBroadcast(ctx, "Привет 🐸", "Новый сервер во Франции", 10, 8, 2, "admin")
	if err != nil {
		t.Fatalf("InsertBroadcast: %v", err)
	}
	if id <= 0 {
		t.Fatalf("InsertBroadcast id = %d, want > 0", id)
	}

	list, err := database.ListBroadcasts(ctx, 10)
	if err != nil {
		t.Fatalf("ListBroadcasts: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("ListBroadcasts len = %d, want 1", len(list))
	}
	b := list[0]
	if b.Title != "Привет 🐸" || b.Total != 10 || b.Sent != 8 || b.Failed != 2 || b.AdminUser != "admin" {
		t.Errorf("broadcast row mismatch: %+v", b)
	}
}

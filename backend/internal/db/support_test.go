//go:build integration

// support_test.go covers SUPPORT-CHAT P0 DB layer (ADR 0011): one-open-thread
// invariant, append + since= pagination, ownership authz, close→fresh-thread,
// 90-day purge, and account-delete wipe. Integration-tagged (testcontainers PG).
//
//	go test -tags=integration ./internal/db/...

package db

import (
	"context"
	"testing"
	"time"
)

// createChatUser inserts a minimal active user and returns its id.
func createChatUser(t *testing.T, database *DB, ctx context.Context, username, uuid string) int64 {
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
	return u.ID
}

func TestOpenOrGetThreadIsSingleOpen(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "chat_a", "aaaaaaaa-0000-4000-8000-0000000000a1")

	t1, err := database.OpenOrGetThread(ctx, uid)
	if err != nil {
		t.Fatalf("OpenOrGetThread #1: %v", err)
	}
	t2, err := database.OpenOrGetThread(ctx, uid)
	if err != nil {
		t.Fatalf("OpenOrGetThread #2: %v", err)
	}
	if t1.ID != t2.ID {
		t.Errorf("expected the same open thread, got %d and %d", t1.ID, t2.ID)
	}
	if t1.Status != "open" {
		t.Errorf("status = %q, want open", t1.Status)
	}
}

func TestAppendAndListSince(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "chat_b", "aaaaaaaa-0000-4000-8000-0000000000b1")
	th, _ := database.OpenOrGetThread(ctx, uid)

	m1, err := database.AppendMessage(ctx, th.ID, "user", "hi")
	if err != nil {
		t.Fatalf("AppendMessage 1: %v", err)
	}
	if _, err := database.AppendMessage(ctx, th.ID, "agent", "hello"); err != nil {
		t.Fatalf("AppendMessage 2: %v", err)
	}
	if _, err := database.AppendMessage(ctx, th.ID, "user", "thanks"); err != nil {
		t.Fatalf("AppendMessage 3: %v", err)
	}

	all, err := database.ListMessages(ctx, th.ID, 0, 100)
	if err != nil {
		t.Fatalf("ListMessages all: %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("ListMessages(since=0) = %d, want 3", len(all))
	}
	if all[0].Sender != "user" || all[1].Sender != "agent" {
		t.Errorf("messages not oldest-first: %q, %q", all[0].Sender, all[1].Sender)
	}

	since, err := database.ListMessages(ctx, th.ID, m1.ID, 100)
	if err != nil {
		t.Fatalf("ListMessages since: %v", err)
	}
	if len(since) != 2 {
		t.Errorf("ListMessages(since=m1) = %d, want 2", len(since))
	}

	// last_message_at must have advanced past the thread's creation.
	reopened, _ := database.OpenOrGetThread(ctx, uid)
	if !reopened.LastMessageAt.After(th.CreatedAt.Add(-time.Second)) {
		t.Errorf("last_message_at not bumped: %v vs created %v", reopened.LastMessageAt, th.CreatedAt)
	}
}

func TestThreadOwnedBy(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	owner := createChatUser(t, database, ctx, "chat_owner", "aaaaaaaa-0000-4000-8000-0000000000c1")
	other := createChatUser(t, database, ctx, "chat_other", "aaaaaaaa-0000-4000-8000-0000000000c2")
	th, _ := database.OpenOrGetThread(ctx, owner)

	if ok, err := database.ThreadOwnedBy(ctx, th.ID, owner); err != nil || !ok {
		t.Errorf("owner should own thread: ok=%v err=%v", ok, err)
	}
	if ok, err := database.ThreadOwnedBy(ctx, th.ID, other); err != nil || ok {
		t.Errorf("other user must NOT own thread: ok=%v err=%v", ok, err)
	}
}

func TestCloseThenNewThread(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "chat_close", "aaaaaaaa-0000-4000-8000-0000000000d1")

	t1, _ := database.OpenOrGetThread(ctx, uid)
	if err := database.CloseThread(ctx, t1.ID); err != nil {
		t.Fatalf("CloseThread: %v", err)
	}
	// Closing again is a no-op (not open).
	if err := database.CloseThread(ctx, t1.ID); err != ErrNotFound {
		t.Errorf("second CloseThread = %v, want ErrNotFound", err)
	}
	// Next OpenOrGetThread must create a FRESH open thread.
	t2, err := database.OpenOrGetThread(ctx, uid)
	if err != nil {
		t.Fatalf("OpenOrGetThread after close: %v", err)
	}
	if t2.ID == t1.ID {
		t.Errorf("expected a new thread after close, reused %d", t1.ID)
	}
	if t2.Status != "open" {
		t.Errorf("new thread status = %q, want open", t2.Status)
	}
}

func TestPurgeClosedThreadsOlderThan(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "chat_purge", "aaaaaaaa-0000-4000-8000-0000000000e1")

	// Old closed thread (101 days ago) with a message — must be purged.
	oldT, _ := database.OpenOrGetThread(ctx, uid)
	_, _ = database.AppendMessage(ctx, oldT.ID, "user", "old")
	if err := database.CloseThread(ctx, oldT.ID); err != nil {
		t.Fatalf("close old: %v", err)
	}
	if _, err := database.Pool.Exec(ctx,
		`UPDATE support_chat_threads SET closed_at = NOW() - INTERVAL '101 days' WHERE id = $1`, oldT.ID); err != nil {
		t.Fatalf("backdate: %v", err)
	}

	// Recently-closed thread — must survive.
	newT, _ := database.OpenOrGetThread(ctx, uid)
	if err := database.CloseThread(ctx, newT.ID); err != nil {
		t.Fatalf("close new: %v", err)
	}

	n, err := database.PurgeClosedThreadsOlderThan(ctx, 90*24*time.Hour)
	if err != nil {
		t.Fatalf("PurgeClosedThreadsOlderThan: %v", err)
	}
	if n != 1 {
		t.Errorf("purged %d threads, want 1", n)
	}

	// The old thread (and its messages, via cascade) is gone; the recent one stays.
	var oldMsgs int
	_ = database.Pool.QueryRow(ctx, `SELECT count(*) FROM support_chat_messages WHERE thread_id = $1`, oldT.ID).Scan(&oldMsgs)
	if oldMsgs != 0 {
		t.Errorf("old thread messages not cascade-deleted: %d", oldMsgs)
	}
	if ok, _ := database.ThreadOwnedBy(ctx, newT.ID, uid); !ok {
		t.Errorf("recently-closed thread was wrongly purged")
	}
}

func TestWipeUserOnDeleteRemovesChat(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "chat_wipe", "aaaaaaaa-0000-4000-8000-0000000000f1")
	th, _ := database.OpenOrGetThread(ctx, uid)
	_, _ = database.AppendMessage(ctx, th.ID, "user", "delete me")

	if err := database.WipeUserOnDelete(ctx, uid); err != nil {
		t.Fatalf("WipeUserOnDelete: %v", err)
	}

	var threads, msgs int
	_ = database.Pool.QueryRow(ctx, `SELECT count(*) FROM support_chat_threads WHERE user_id = $1`, uid).Scan(&threads)
	_ = database.Pool.QueryRow(ctx, `SELECT count(*) FROM support_chat_messages WHERE thread_id = $1`, th.ID).Scan(&msgs)
	if threads != 0 || msgs != 0 {
		t.Errorf("account-delete left chat behind: threads=%d msgs=%d", threads, msgs)
	}
}

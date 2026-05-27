//go:build integration

// app_events_test.go pins the contract of the queries that back the iOS
// event-tracking stream (USR-09 Phase 2). Integration-tagged because all
// of them touch real Postgres — pure-Go assertions on these would either
// re-implement the SQL (mocks lying about what the DB does) or skip the
// JSONB / interval cases that actually matter.

package db

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// TestInsertAndListAppEvents covers the happy paths of the two functions
// that drive the mobile POST handler and the admin list handler:
//
//   - InsertAppEvents writes N rows in one statement, server-enriches the
//     request-time columns (ip, country, received_at), and round-trips
//     JSONB without mangling.
//   - ListAppEvents returns newest-first, honours each filter independently,
//     and reports an accurate total count for pagination.
//
// The shape assertions guard against silent regressions — e.g. dropping
// the JSONB column, swapping ORDER BY direction, or breaking the count
// query when filters are added.
func TestInsertAndListAppEvents(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	// Seed a user so user_id FK is satisfiable.
	user := &User{
		VPNUsername:  ptr("device_e2e_1"),
		VPNUUID:      ptr("00000000-0000-4000-8000-000000000e21"),
		VPNShortID:   ptr(""),
		AuthProvider: ptr("device"),
		IsActive:     true,
		CreatedAt:    time.Now().UTC(),
		UpdatedAt:    time.Now().UTC(),
	}
	if err := database.CreateUser(ctx, user); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	uid := user.ID

	// Batch of three events with distinct names and properties shapes.
	base := time.Now().UTC().Add(-1 * time.Hour)
	batch := []AppEventInsert{
		{
			EventName:  "paywall.view",
			OccurredAt: base,
			Properties: map[string]any{"source": "main"},
		},
		{
			EventName:  "paywall.product.tap",
			OccurredAt: base.Add(30 * time.Second),
			Properties: map[string]any{
				"product_id": "vpn_30_premium",
				"price_usd":  4.99, // float survives JSONB round-trip
			},
		},
		{
			EventName:  "vpn.connect.fail",
			OccurredAt: base.Add(45 * time.Second),
			Properties: map[string]any{
				"error_code": "tls_handshake_timeout",
				"server":     "nl2",
				"attempt":    2,
			},
			DeviceID: "iPhone14,7", // present on one row only
		},
	}

	n, err := database.InsertAppEvents(
		ctx,
		&uid,
		"1.0.27", "ios", "203.0.113.42", "DE",
		batch,
	)
	if err != nil {
		t.Fatalf("InsertAppEvents: %v", err)
	}
	if n != 3 {
		t.Fatalf("InsertAppEvents inserted=%d, want 3", n)
	}

	// List without filter — newest first, all three rows back.
	got, total, err := database.ListAppEvents(ctx, AppEventFilter{Limit: 50})
	if err != nil {
		t.Fatalf("ListAppEvents (all): %v", err)
	}
	if total != 3 || len(got) != 3 {
		t.Fatalf("all events: total=%d len=%d, want 3/3", total, len(got))
	}
	if got[0].EventName != "vpn.connect.fail" {
		t.Fatalf("ORDER BY occurred_at DESC broken: got[0]=%q", got[0].EventName)
	}

	// JSONB round-trip on the second event.
	for _, ev := range got {
		if ev.EventName != "paywall.product.tap" {
			continue
		}
		if ev.Properties["product_id"] != "vpn_30_premium" {
			t.Fatalf("product_id round-trip: got %v", ev.Properties["product_id"])
		}
		// Numbers come back as float64 from JSONB — pin that contract.
		if f, ok := ev.Properties["price_usd"].(float64); !ok || f != 4.99 {
			t.Fatalf("price_usd round-trip: got %T=%v", ev.Properties["price_usd"], ev.Properties["price_usd"])
		}
	}

	// Server-enriched columns survived.
	if got[0].AppVersion != "1.0.27" || got[0].Platform != "ios" {
		t.Fatalf("enrichment: app_version=%q platform=%q", got[0].AppVersion, got[0].Platform)
	}
	if got[0].IP != "203.0.113.42" || got[0].Country != "DE" {
		t.Fatalf("ip/country enrichment: ip=%q country=%q", got[0].IP, got[0].Country)
	}
	if got[0].UserID == nil || *got[0].UserID != uid {
		t.Fatalf("user_id enrichment: got %v want %d", got[0].UserID, uid)
	}

	// Filter by event_name — only the matching event back.
	got, total, err = database.ListAppEvents(ctx, AppEventFilter{
		EventName: "paywall.view",
		Limit:     50,
	})
	if err != nil {
		t.Fatalf("ListAppEvents (name): %v", err)
	}
	if total != 1 || len(got) != 1 || got[0].EventName != "paywall.view" {
		t.Fatalf("name filter broken: total=%d len=%d first=%v", total, len(got), got)
	}

	// Filter by user_id — all three back when matching, none when not.
	got, total, _ = database.ListAppEvents(ctx, AppEventFilter{UserID: &uid, Limit: 50})
	if total != 3 || len(got) != 3 {
		t.Fatalf("user_id filter broken: total=%d len=%d", total, len(got))
	}
	bogus := int64(999999)
	_, total, _ = database.ListAppEvents(ctx, AppEventFilter{UserID: &bogus, Limit: 50})
	if total != 0 {
		t.Fatalf("user_id filter (no match): total=%d, want 0", total)
	}

	// Filter by time window — Since strictly after the second event
	// should drop the first two.
	cutoff := base.Add(40 * time.Second)
	_, total, _ = database.ListAppEvents(ctx, AppEventFilter{Since: cutoff, Limit: 50})
	if total != 1 {
		t.Fatalf("since filter broken: total=%d, want 1", total)
	}
}

// TestListAppEventsPagination verifies Limit + Offset honour their bounds
// and that the total count remains stable across pages.
func TestListAppEventsPagination(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	// 7 events from one anonymous batch (no user).
	now := time.Now().UTC()
	batch := make([]AppEventInsert, 0, 7)
	for i := 0; i < 7; i++ {
		batch = append(batch, AppEventInsert{
			EventName:  "x.test",
			OccurredAt: now.Add(time.Duration(i) * time.Second),
		})
	}
	if _, err := database.InsertAppEvents(ctx, nil, "", "ios", "", "", batch); err != nil {
		t.Fatalf("InsertAppEvents: %v", err)
	}

	// Page 1: limit 3 offset 0 → 3 newest.
	p1, total, _ := database.ListAppEvents(ctx, AppEventFilter{Limit: 3, Offset: 0})
	if total != 7 || len(p1) != 3 {
		t.Fatalf("page1: total=%d len=%d, want 7/3", total, len(p1))
	}
	// Page 2: limit 3 offset 3 → next 3.
	p2, _, _ := database.ListAppEvents(ctx, AppEventFilter{Limit: 3, Offset: 3})
	if len(p2) != 3 {
		t.Fatalf("page2 len=%d, want 3", len(p2))
	}
	// Page 3: limit 3 offset 6 → last 1.
	p3, _, _ := database.ListAppEvents(ctx, AppEventFilter{Limit: 3, Offset: 6})
	if len(p3) != 1 {
		t.Fatalf("page3 len=%d, want 1", len(p3))
	}

	// No overlap between pages.
	seen := map[int64]bool{}
	for _, ev := range append(append(p1, p2...), p3...) {
		if seen[ev.ID] {
			t.Fatalf("pagination overlap on id=%d", ev.ID)
		}
		seen[ev.ID] = true
	}
	if len(seen) != 7 {
		t.Fatalf("total unique ids across pages = %d, want 7", len(seen))
	}

	// Clamp upper bound: Limit=10_000 should land at 500.
	got, _, _ := database.ListAppEvents(ctx, AppEventFilter{Limit: 10_000})
	if len(got) != 7 {
		// Only 7 rows exist, so clamping doesn't manifest here — but
		// at least confirm no error was raised by an absurd limit.
		t.Fatalf("clamp test: got %d", len(got))
	}
}

// TestCountAppEventsByNameDaily checks the per-day aggregation that
// powers the admin chart: rows are grouped by (name, calendar-day-UTC)
// and ordered chronologically.
func TestCountAppEventsByNameDaily(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	// Three events of one name today, two of another yesterday.
	var rows []AppEventInsert
	for i := 0; i < 3; i++ {
		rows = append(rows, AppEventInsert{
			EventName:  "paywall.view",
			OccurredAt: now.Add(-time.Duration(i) * time.Minute),
		})
	}
	for i := 0; i < 2; i++ {
		rows = append(rows, AppEventInsert{
			EventName:  "purchase.start",
			OccurredAt: now.Add(-25 * time.Hour),
		})
	}
	if _, err := database.InsertAppEvents(ctx, nil, "", "ios", "", "", rows); err != nil {
		t.Fatalf("InsertAppEvents: %v", err)
	}

	got, err := database.CountAppEventsByNameDaily(ctx, 30)
	if err != nil {
		t.Fatalf("CountAppEventsByNameDaily: %v", err)
	}
	// Group by (name, day). Expect two buckets.
	if len(got) != 2 {
		t.Fatalf("aggregation: len=%d, want 2; rows=%+v", len(got), got)
	}
	// Counts add up.
	totals := map[string]int64{}
	for _, r := range got {
		totals[r.EventName] += r.Count
	}
	if totals["paywall.view"] != 3 || totals["purchase.start"] != 2 {
		t.Fatalf("counts: %+v", totals)
	}

	// Distinct names emits the union.
	names, err := database.DistinctEventNames(ctx, 30)
	if err != nil {
		t.Fatalf("DistinctEventNames: %v", err)
	}
	if len(names) != 2 {
		t.Fatalf("distinct: got %v", names)
	}
}

// TestInsertAppEventsEmpty pins the no-op early return so a flush of an
// empty queue doesn't issue an INSERT with zero values (which Postgres
// would reject).
func TestInsertAppEventsEmpty(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	n, err := database.InsertAppEvents(ctx, nil, "", "", "", "", nil)
	if err != nil {
		t.Fatalf("empty insert: %v", err)
	}
	if n != 0 {
		t.Fatalf("empty insert inserted=%d, want 0", n)
	}
}

// TestInsertAppEventsCascadeOnUserDelete makes sure the ON DELETE CASCADE
// on the user_id FK actually fires — otherwise a deleted account would
// leave orphaned analytics rows.
func TestInsertAppEventsCascadeOnUserDelete(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	user := &User{
		VPNUsername:  ptr("device_cascade"),
		VPNUUID:      ptr("00000000-0000-4000-8000-000000000c40"),
		VPNShortID:   ptr(""),
		AuthProvider: ptr("device"),
		IsActive:     true,
		CreatedAt:    time.Now().UTC(),
		UpdatedAt:    time.Now().UTC(),
	}
	if err := database.CreateUser(ctx, user); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	uid := user.ID

	// Two events tied to that user.
	_, err := database.InsertAppEvents(ctx, &uid, "", "ios", "", "", []AppEventInsert{
		{EventName: "a.b", OccurredAt: time.Now().UTC()},
		{EventName: "a.c", OccurredAt: time.Now().UTC()},
	})
	if err != nil {
		t.Fatalf("InsertAppEvents: %v", err)
	}

	if _, err := database.Pool.Exec(ctx, "DELETE FROM users WHERE id = $1", uid); err != nil {
		t.Fatalf("delete user: %v", err)
	}

	_, total, err := database.ListAppEvents(ctx, AppEventFilter{UserID: &uid, Limit: 50})
	if err != nil {
		t.Fatalf("ListAppEvents: %v", err)
	}
	if total != 0 {
		t.Fatalf("cascade failed: total=%d, want 0", total)
	}
	// Sanity — the row count is also zero across the table.
	var n int64
	if err := database.Pool.QueryRow(ctx, "SELECT count(*) FROM app_events").Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("cascade left %d orphan rows", n)
	}
	_ = fmt.Sprint() // keeps the import even when assertions don't need fmt
}

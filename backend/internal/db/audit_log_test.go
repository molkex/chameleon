//go:build integration

package db

import (
	"context"
	"testing"
	"time"
)

// TestListAuditEventsFilters covers the four filter axes (admin_id, action,
// since, until) plus pagination + the LEFT JOIN to admin_users for the
// username column. The MED-014 dispatcher writes to this table on every
// admin action; the SPA's "Activity" page reads it back, so a regression
// here means the audit log silently misrenders.
func TestListAuditEventsFilters(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	// Seed an admin user so admin_user_id has a real FK to join against.
	// admin_users id is SERIAL; we don't care about the value as long as
	// LogAuditEvent links to a real row (the column is REFERENCES, so a
	// missing FK would be silently NULL-ed which would mask join bugs).
	_, err := database.Pool.Exec(ctx,
		`INSERT INTO admin_users (username, password_hash, role, is_active) VALUES
		 ('alice', 'x', 'admin', true),
		 ('bob',   'x', 'operator', true)`)
	if err != nil {
		t.Fatalf("seed admins: %v", err)
	}
	var aliceID, bobID int64
	if err := database.Pool.QueryRow(ctx, `SELECT id FROM admin_users WHERE username='alice'`).Scan(&aliceID); err != nil {
		t.Fatalf("get alice id: %v", err)
	}
	if err := database.Pool.QueryRow(ctx, `SELECT id FROM admin_users WHERE username='bob'`).Scan(&bobID); err != nil {
		t.Fatalf("get bob id: %v", err)
	}

	// Mix of (admin, action, age) so each filter axis has a non-trivial
	// match/miss pair.
	events := []AuditEvent{
		{AdminUserID: &aliceID, Action: "login.success", IP: "1.1.1.1", Details: "alice login"},
		{AdminUserID: &aliceID, Action: "user.delete", IP: "1.1.1.1", Details: "alice deleted u#5"},
		{AdminUserID: &bobID, Action: "login.success", IP: "2.2.2.2", Details: "bob login"},
		{AdminUserID: nil, Action: "login.failed", IP: "3.3.3.3", Details: "anon failed login"},
	}
	for _, e := range events {
		if err := database.LogAuditEvent(ctx, e); err != nil {
			t.Fatalf("LogAuditEvent: %v", err)
		}
	}

	// Default — no filter — gets all rows newest-first.
	all, total, err := database.ListAuditEvents(ctx, AuditFilter{}, 1, 50)
	if err != nil {
		t.Fatalf("ListAuditEvents (no filter): %v", err)
	}
	if total != 4 || len(all) != 4 {
		t.Errorf("unfiltered: total=%d len=%d, want 4/4", total, len(all))
	}

	// LEFT JOIN to admin_users must populate username for known admins and
	// leave it nil for the anonymous-login row. This regresses if someone
	// switches the join to INNER.
	var aliceCount, anonCount int
	for _, r := range all {
		if r.AdminUsername != nil && *r.AdminUsername == "alice" {
			aliceCount++
		}
		if r.AdminUserID == nil {
			anonCount++
			if r.AdminUsername != nil {
				t.Errorf("anon row got admin_username=%q, want nil", *r.AdminUsername)
			}
		}
	}
	if aliceCount != 2 || anonCount != 1 {
		t.Errorf("join counts: alice=%d anon=%d, want 2/1", aliceCount, anonCount)
	}

	// Filter by admin → 2 rows for alice.
	aliceOnly, total, err := database.ListAuditEvents(ctx, AuditFilter{AdminUserID: &aliceID}, 1, 50)
	if err != nil {
		t.Fatalf("ListAuditEvents (alice): %v", err)
	}
	if total != 2 || len(aliceOnly) != 2 {
		t.Errorf("alice filter: total=%d len=%d, want 2/2", total, len(aliceOnly))
	}

	// Filter by action → 2 login.success rows (alice + bob).
	logins, total, err := database.ListAuditEvents(ctx, AuditFilter{Action: "login.success"}, 1, 50)
	if err != nil {
		t.Fatalf("ListAuditEvents (login.success): %v", err)
	}
	if total != 2 || len(logins) != 2 {
		t.Errorf("action filter: total=%d len=%d, want 2/2", total, len(logins))
	}

	// Combined filter (AND) → only alice's login.
	until := time.Now().Add(time.Hour)
	aliceLogin, total, err := database.ListAuditEvents(ctx,
		AuditFilter{AdminUserID: &aliceID, Action: "login.success", Until: &until}, 1, 50)
	if err != nil {
		t.Fatalf("ListAuditEvents (combined): %v", err)
	}
	if total != 1 || len(aliceLogin) != 1 {
		t.Errorf("combined: total=%d len=%d, want 1/1", total, len(aliceLogin))
	}

	// Pagination — page=2 with pageSize=2 returns the older 2 rows; total
	// stays 4 regardless of page.
	page2, total, err := database.ListAuditEvents(ctx, AuditFilter{}, 2, 2)
	if err != nil {
		t.Fatalf("ListAuditEvents (page=2): %v", err)
	}
	if total != 4 || len(page2) != 2 {
		t.Errorf("pagination: total=%d len=%d, want 4/2", total, len(page2))
	}

	// Distinct actions for the dropdown — order ASC.
	actions, err := database.ListAuditActions(ctx)
	if err != nil {
		t.Fatalf("ListAuditActions: %v", err)
	}
	wantActions := []string{"login.failed", "login.success", "user.delete"}
	if len(actions) != len(wantActions) {
		t.Fatalf("actions len: got %d, want %d (%v)", len(actions), len(wantActions), actions)
	}
	for i, a := range wantActions {
		if actions[i] != a {
			t.Errorf("actions[%d]: got %q, want %q", i, actions[i], a)
		}
	}
}

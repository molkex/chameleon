package db

import (
	"context"
	"fmt"
)

// AuditEvent describes one row to be inserted into admin_audit_log. All
// fields except Action are optional. Action follows verb-object form, e.g.
// "login.success", "server.delete", "user.extend_subscription".
type AuditEvent struct {
	AdminUserID *int64
	Action      string
	IP          string
	UserAgent   string
	Details     string
}

// LogAuditEvent inserts an admin_audit_log row. Audit MED-014 (2026-05-27).
//
// Callers do not block on this — it is invoked from request handlers and
// must never poison the request. The function returns an error so the
// caller can log it; failed audit writes should never be propagated as
// HTTP errors to the admin (we don't want a broken audit table to take
// the admin panel offline).
//
// Schema lives in migrations/init.sql:
//
//	admin_audit_log(id, admin_user_id, action, ip, user_agent, details, created_at)
func (db *DB) LogAuditEvent(ctx context.Context, event AuditEvent) error {
	if event.Action == "" {
		return fmt.Errorf("audit: action is required")
	}
	const stmt = `
		INSERT INTO admin_audit_log (admin_user_id, action, ip, user_agent, details)
		VALUES ($1, $2, NULLIF($3, ''), NULLIF($4, ''), NULLIF($5, ''))
	`
	_, err := db.Pool.Exec(ctx, stmt, event.AdminUserID, event.Action, event.IP, event.UserAgent, event.Details)
	if err != nil {
		return fmt.Errorf("audit insert: %w", err)
	}
	return nil
}

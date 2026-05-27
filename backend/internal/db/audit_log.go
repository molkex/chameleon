package db

import (
	"context"
	"fmt"
	"strings"
	"time"
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

// AuditRow is one admin_audit_log row as returned by ListAuditEvents.
// admin_username is joined from admin_users so the UI can show
// "admin@example.com" instead of an opaque integer.
type AuditRow struct {
	ID            int64
	AdminUserID   *int64
	AdminUsername *string
	Action        string
	IP            string
	UserAgent     string
	Details       string
	CreatedAt     time.Time
}

// AuditFilter narrows ListAuditEvents. Zero-value fields are ignored, so
// the caller can compose any combination of constraints. Sub-filters are
// AND-combined.
type AuditFilter struct {
	AdminUserID *int64
	Action      string // exact match — UI exposes a dropdown of distinct values
	Since       *time.Time
	Until       *time.Time
}

// ListAuditEvents returns paginated admin_audit_log rows newest-first
// joined with admin_users.username. Page is 1-based, pageSize clamped to
// [1, 200] so a runaway query string can't pull the entire table.
//
// Sorted by id DESC because audit rows are append-only and the SERIAL pk
// matches insertion order; using created_at would force the planner off
// the idx_audit_log_created descending walk into a sort.
func (db *DB) ListAuditEvents(ctx context.Context, f AuditFilter, page, pageSize int) ([]AuditRow, int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 50
	}
	if pageSize > 200 {
		pageSize = 200
	}

	// WHERE-clause is built from filter; placeholders track position so
	// each predicate uses the same $N in both the count and the page query.
	var (
		where []string
		args  []any
	)
	if f.AdminUserID != nil {
		args = append(args, *f.AdminUserID)
		where = append(where, fmt.Sprintf("a.admin_user_id = $%d", len(args)))
	}
	if f.Action != "" {
		args = append(args, f.Action)
		where = append(where, fmt.Sprintf("a.action = $%d", len(args)))
	}
	if f.Since != nil {
		args = append(args, *f.Since)
		where = append(where, fmt.Sprintf("a.created_at >= $%d", len(args)))
	}
	if f.Until != nil {
		args = append(args, *f.Until)
		where = append(where, fmt.Sprintf("a.created_at < $%d", len(args)))
	}
	whereSQL := ""
	if len(where) > 0 {
		whereSQL = "WHERE " + strings.Join(where, " AND ")
	}

	var total int64
	if err := db.Pool.QueryRow(ctx,
		`SELECT count(*) FROM admin_audit_log a `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("audit count: %w", err)
	}

	// Append pagination params last so the WHERE placeholders stay stable
	// across both queries.
	args = append(args, pageSize, (page-1)*pageSize)
	limitClause := fmt.Sprintf("LIMIT $%d OFFSET $%d", len(args)-1, len(args))

	rows, err := db.Pool.Query(ctx, `
		SELECT a.id, a.admin_user_id, u.username, a.action,
		       COALESCE(a.ip, ''), COALESCE(a.user_agent, ''), COALESCE(a.details, ''),
		       a.created_at
		FROM admin_audit_log a
		LEFT JOIN admin_users u ON u.id = a.admin_user_id
		`+whereSQL+`
		ORDER BY a.id DESC
		`+limitClause, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("audit query: %w", err)
	}
	defer rows.Close()

	var out []AuditRow
	for rows.Next() {
		var r AuditRow
		if err := rows.Scan(&r.ID, &r.AdminUserID, &r.AdminUsername, &r.Action,
			&r.IP, &r.UserAgent, &r.Details, &r.CreatedAt); err != nil {
			return nil, 0, fmt.Errorf("audit scan: %w", err)
		}
		out = append(out, r)
	}
	return out, total, rows.Err()
}

// ListAuditActions returns the distinct `action` values present in the
// table (newest 90 days only — older events stay queryable but don't
// pollute the dropdown). Used by the SPA filter dropdown.
func (db *DB) ListAuditActions(ctx context.Context) ([]string, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT DISTINCT action FROM admin_audit_log
		WHERE created_at > NOW() - INTERVAL '90 days'
		ORDER BY action ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var actions []string
	for rows.Next() {
		var a string
		if err := rows.Scan(&a); err != nil {
			return nil, err
		}
		actions = append(actions, a)
	}
	return actions, rows.Err()
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

// Package db — app_events.go contains queries for the iOS-side event
// stream introduced in USR-09 Phase 2 (2026-05-28). The funnel page added
// in Phase 1 derives everything it shows from `users` and `payments`;
// app_events fills the pre-purchase gap (paywall views/taps, purchase
// cancels, vpn-connect failures) that the backend cannot infer.

package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// AppEventInsert is the shape iOS sends to POST /api/v1/events/batch.
// Only event_name and occurred_at are required; the rest are server-
// enriched at request time (user_id from JWT, ip/country from request).
type AppEventInsert struct {
	EventName  string
	OccurredAt time.Time
	Properties map[string]any // serialised to JSONB; nil → '{}'

	// Optional client-supplied context that survives into the row when
	// the client wants to attribute the event to something specific.
	// device_id is intentionally TEXT (not the users.device_id FK) so
	// pre-signup or anonymous events can land too.
	DeviceID string
}

// AppEvent is one stored row. Properties is decoded back to a generic
// map so the admin UI can render arbitrary keys without a schema bump.
type AppEvent struct {
	ID         int64
	UserID     *int64 // null when the event was anonymous (none yet — JWT required)
	DeviceID   string
	EventName  string
	Properties map[string]any
	AppVersion string
	Platform   string
	OccurredAt time.Time
	ReceivedAt time.Time
	IP         string
	Country    string
}

// InsertAppEvents writes the batch in a single INSERT ... VALUES (...),
// (...), ... statement. Returns the number of rows actually inserted.
// Callers should keep batches small (~100) — the mobile endpoint
// enforces this; this function trusts its input.
//
// Per-row failures fall through to the whole batch failing. iOS keeps
// unACK'd events in its queue and retries on the next flush, so an
// occasional rejected batch is harmless.
func (db *DB) InsertAppEvents(
	ctx context.Context,
	userID *int64,
	appVersion, platform, ip, country string,
	events []AppEventInsert,
) (int64, error) {
	if len(events) == 0 {
		return 0, nil
	}

	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	// Build one parameterised INSERT — pgx encodes the array of JSONB
	// values for us. We do not COPY because batches are small and the
	// per-row context (occurred_at, properties) is per-row, not
	// uniform; the SQL form is easier to read and audit.
	var (
		placeholders []string
		args         []any
	)
	for i, ev := range events {
		props := ev.Properties
		if props == nil {
			props = map[string]any{}
		}
		propsJSON, err := json.Marshal(props)
		if err != nil {
			return 0, fmt.Errorf("app_events: marshal properties row %d: %w", i, err)
		}

		base := i * 10
		placeholders = append(placeholders, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d)",
			base+1, base+2, base+3, base+4, base+5,
			base+6, base+7, base+8, base+9, base+10,
		))
		args = append(args,
			userID,
			nullIfEmpty(ev.DeviceID),
			ev.EventName,
			propsJSON,
			nullIfEmpty(appVersion),
			nullIfEmpty(platform),
			ev.OccurredAt,
			time.Now().UTC(),
			nullIfEmpty(ip),
			nullIfEmpty(country),
		)
	}

	stmt := "INSERT INTO app_events " +
		"(user_id, device_id, event_name, properties, app_version, platform, occurred_at, received_at, ip, country) " +
		"VALUES " + strings.Join(placeholders, ",")

	tag, err := db.Pool.Exec(ctx, stmt, args...)
	if err != nil {
		return 0, fmt.Errorf("app_events insert: %w", err)
	}
	return tag.RowsAffected(), nil
}

// AppEventFilter narrows the admin list query. All fields optional; zero
// values mean "do not filter on this column".
type AppEventFilter struct {
	UserID    *int64
	EventName string     // exact match
	Since     time.Time  // occurred_at >= Since (zero = no lower bound)
	Until     time.Time  // occurred_at <  Until (zero = no upper bound)
	Limit     int        // page size, clamped [1, 500]; default 100
	Offset    int        // >= 0
}

// ListAppEvents returns events that match the filter, newest first,
// plus the total count for pagination.
//
// Defence-in-depth on Limit/Offset is here, not in the handler: a
// malformed admin client should not be able to ask for 1M rows.
func (db *DB) ListAppEvents(ctx context.Context, f AppEventFilter) ([]AppEvent, int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if f.Limit <= 0 {
		f.Limit = 100
	}
	if f.Limit > 500 {
		f.Limit = 500
	}
	if f.Offset < 0 {
		f.Offset = 0
	}

	var (
		conds []string
		args  []any
	)
	if f.UserID != nil {
		conds = append(conds, fmt.Sprintf("user_id = $%d", len(args)+1))
		args = append(args, *f.UserID)
	}
	if f.EventName != "" {
		conds = append(conds, fmt.Sprintf("event_name = $%d", len(args)+1))
		args = append(args, f.EventName)
	}
	if !f.Since.IsZero() {
		conds = append(conds, fmt.Sprintf("occurred_at >= $%d", len(args)+1))
		args = append(args, f.Since)
	}
	if !f.Until.IsZero() {
		conds = append(conds, fmt.Sprintf("occurred_at < $%d", len(args)+1))
		args = append(args, f.Until)
	}

	where := ""
	if len(conds) > 0 {
		where = " WHERE " + strings.Join(conds, " AND ")
	}

	// Two queries so total count is honest even when paging. The
	// table is append-only and not huge — a COUNT scan against the
	// filtered window is fine.
	var total int64
	countStmt := "SELECT count(*) FROM app_events" + where
	if err := db.Pool.QueryRow(ctx, countStmt, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("app_events count: %w", err)
	}

	listArgs := append(args, f.Limit, f.Offset)
	listStmt := "SELECT id, user_id, device_id, event_name, properties, " +
		"app_version, platform, occurred_at, received_at, ip, country " +
		"FROM app_events" + where +
		fmt.Sprintf(" ORDER BY occurred_at DESC LIMIT $%d OFFSET $%d", len(args)+1, len(args)+2)

	rows, err := db.Pool.Query(ctx, listStmt, listArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("app_events list: %w", err)
	}
	defer rows.Close()

	out := make([]AppEvent, 0, f.Limit)
	for rows.Next() {
		var (
			ev         AppEvent
			deviceID   *string
			appVer     *string
			platform   *string
			ip         *string
			country    *string
			propsBytes []byte
		)
		if err := rows.Scan(
			&ev.ID,
			&ev.UserID,
			&deviceID,
			&ev.EventName,
			&propsBytes,
			&appVer,
			&platform,
			&ev.OccurredAt,
			&ev.ReceivedAt,
			&ip,
			&country,
		); err != nil {
			return nil, 0, fmt.Errorf("app_events scan: %w", err)
		}
		ev.DeviceID = derefString(deviceID)
		ev.AppVersion = derefString(appVer)
		ev.Platform = derefString(platform)
		ev.IP = derefString(ip)
		ev.Country = derefString(country)
		if len(propsBytes) > 0 {
			_ = json.Unmarshal(propsBytes, &ev.Properties)
		}
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("app_events rows: %w", err)
	}
	return out, total, nil
}

// EventNameDaily is one (event_name, calendar day, count) tuple. Used
// by the admin counts endpoint to chart event frequency over a window.
type EventNameDaily struct {
	EventName string
	Day       time.Time
	Count     int64
}

// CountAppEventsByNameDaily aggregates by event_name × UTC calendar day
// over the trailing `days` window. Empty result when nothing matches.
//
// days clamped to [1, 365]; default 30.
func (db *DB) CountAppEventsByNameDaily(ctx context.Context, days int) ([]EventNameDaily, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if days <= 0 {
		days = 30
	}
	if days > 365 {
		days = 365
	}

	const stmt = `
		SELECT event_name,
		       date_trunc('day', occurred_at) AS day,
		       count(*) AS n
		  FROM app_events
		 WHERE occurred_at >= now() - ($1::int || ' days')::interval
		 GROUP BY event_name, day
		 ORDER BY day ASC, event_name ASC
	`
	rows, err := db.Pool.Query(ctx, stmt, days)
	if err != nil {
		return nil, fmt.Errorf("app_events counts: %w", err)
	}
	defer rows.Close()

	var out []EventNameDaily
	for rows.Next() {
		var row EventNameDaily
		if err := rows.Scan(&row.EventName, &row.Day, &row.Count); err != nil {
			return nil, fmt.Errorf("app_events counts scan: %w", err)
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("app_events counts rows: %w", err)
	}
	return out, nil
}

// DistinctEventNames returns every event_name that has been seen at
// least once in the trailing window. Used to populate the admin
// filter dropdown.
func (db *DB) DistinctEventNames(ctx context.Context, days int) ([]string, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if days <= 0 {
		days = 90
	}
	if days > 365 {
		days = 365
	}

	const stmt = `
		SELECT DISTINCT event_name
		  FROM app_events
		 WHERE occurred_at >= now() - ($1::int || ' days')::interval
		 ORDER BY event_name ASC
	`
	rows, err := db.Pool.Query(ctx, stmt, days)
	if err != nil {
		return nil, fmt.Errorf("app_events names: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("app_events name scan: %w", err)
		}
		out = append(out, name)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("app_events name rows: %w", err)
	}
	return out, nil
}

// nullIfEmpty returns nil for the empty string (so the column lands as
// NULL rather than an empty string), pgx-safe.
func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// derefString turns the pgx Scan-friendly *string into a plain string,
// converting NULL to "". Local helper instead of pulling in null types.
func derefString(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// Re-export pgx so tests that need it don't reach across packages just
// for ErrNoRows. (No call sites yet but kept for symmetry with funnel.go.)
var _ = pgx.ErrNoRows

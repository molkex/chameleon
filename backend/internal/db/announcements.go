// Package db — announcements.go: in-app announcements (INAPP-ANNOUNCEMENTS,
// migration 024). Admin CRUD + the mobile "active in window" read the client
// polls on app open.
package db

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Announcement is one in-app message. Optional starts_at/ends_at bound a
// show-window; optional cta_* render a button.
type Announcement struct {
	ID        int64
	Title     string
	Body      string
	Kind      string // info | promo | update
	Active    bool
	StartsAt  *time.Time
	EndsAt    *time.Time
	CTALabel  *string
	CTAURL    *string
	CreatedBy string
	CreatedAt time.Time
	UpdatedAt time.Time
}

const announcementCols = `id, title, body, kind, active, starts_at, ends_at, cta_label, cta_url, COALESCE(created_by,''), created_at, updated_at`

func scanAnnouncement(s interface {
	Scan(dest ...any) error
}) (*Announcement, error) {
	var a Announcement
	if err := s.Scan(&a.ID, &a.Title, &a.Body, &a.Kind, &a.Active,
		&a.StartsAt, &a.EndsAt, &a.CTALabel, &a.CTAURL, &a.CreatedBy, &a.CreatedAt, &a.UpdatedAt); err != nil {
		return nil, err
	}
	return &a, nil
}

// CreateAnnouncement inserts a new announcement and returns it (with id/timestamps).
func (db *DB) CreateAnnouncement(ctx context.Context, a *Announcement) (*Announcement, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`INSERT INTO announcements (title, body, kind, active, starts_at, ends_at, cta_label, cta_url, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		 RETURNING `+announcementCols,
		a.Title, a.Body, a.Kind, a.Active, a.StartsAt, a.EndsAt, a.CTALabel, a.CTAURL, a.CreatedBy)
	return scanAnnouncement(row)
}

// UpdateAnnouncement overwrites the editable fields of an existing announcement.
func (db *DB) UpdateAnnouncement(ctx context.Context, a *Announcement) (*Announcement, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`UPDATE announcements
		 SET title=$2, body=$3, kind=$4, active=$5, starts_at=$6, ends_at=$7, cta_label=$8, cta_url=$9, updated_at=NOW()
		 WHERE id=$1
		 RETURNING `+announcementCols,
		a.ID, a.Title, a.Body, a.Kind, a.Active, a.StartsAt, a.EndsAt, a.CTALabel, a.CTAURL)
	out, err := scanAnnouncement(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return out, nil
}

// DeleteAnnouncement removes an announcement. ErrNotFound if it doesn't exist.
func (db *DB) DeleteAnnouncement(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `DELETE FROM announcements WHERE id=$1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListAnnouncements returns all announcements (admin view), newest first.
func (db *DB) ListAnnouncements(ctx context.Context, limit int) ([]Announcement, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	if limit <= 0 || limit > 200 {
		limit = 100
	}

	rows, err := db.Pool.Query(ctx,
		`SELECT `+announcementCols+` FROM announcements ORDER BY id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Announcement
	for rows.Next() {
		a, err := scanAnnouncement(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// ActiveAnnouncements returns announcements the client should currently show:
// active AND within the optional [starts_at, ends_at] window. Newest first.
func (db *DB) ActiveAnnouncements(ctx context.Context) ([]Announcement, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx,
		`SELECT `+announcementCols+`
		 FROM announcements
		 WHERE active
		   AND (starts_at IS NULL OR starts_at <= NOW())
		   AND (ends_at   IS NULL OR ends_at   >= NOW())
		 ORDER BY id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Announcement
	for rows.Next() {
		a, err := scanAnnouncement(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

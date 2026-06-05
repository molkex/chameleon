// Package db — promo.go: promo codes, payment intents, redemptions
// (PROMO-CODES, migration 026). Pure redeemability rules live in internal/promo;
// this is the persistence + the idempotent redeem.
package db

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/chameleonvpn/chameleon/internal/promo"
)

// PromoCode is the full row (admin view).
type PromoCode struct {
	ID              int64
	Code            string
	DiscountPct     int
	Active          bool
	PerUserOnce     bool
	MaxUses         *int
	UsedCount       int
	ExpiresAt       *time.Time
	Note            string
	CreatedBy       string
	CreatedAt       time.Time
	UpdatedAt       time.Time
	RedemptionCount int // computed in ListPromoCodes
}

// ToPromo projects the row onto the pure validation type.
func (p *PromoCode) ToPromo() *promo.Code {
	return &promo.Code{
		ID: p.ID, Code: p.Code, DiscountPct: p.DiscountPct, Active: p.Active,
		MaxUses: p.MaxUses, UsedCount: p.UsedCount, PerUserOnce: p.PerUserOnce, ExpiresAt: p.ExpiresAt,
	}
}

const promoCols = `id, code, discount_pct, active, per_user_once, max_uses, used_count, expires_at, COALESCE(note,''), COALESCE(created_by,''), created_at, updated_at`

func scanPromo(row pgx.Row) (*PromoCode, error) {
	var p PromoCode
	if err := row.Scan(&p.ID, &p.Code, &p.DiscountPct, &p.Active, &p.PerUserOnce,
		&p.MaxUses, &p.UsedCount, &p.ExpiresAt, &p.Note, &p.CreatedBy, &p.CreatedAt, &p.UpdatedAt); err != nil {
		return nil, err
	}
	return &p, nil
}

// CreatePromoCode inserts a code. ErrConflict if the code already exists.
func (db *DB) CreatePromoCode(ctx context.Context, p *PromoCode) (*PromoCode, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	row := db.Pool.QueryRow(ctx,
		`INSERT INTO promo_codes (code, discount_pct, active, per_user_once, max_uses, expires_at, note, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING `+promoCols,
		p.Code, p.DiscountPct, p.Active, p.PerUserOnce, p.MaxUses, p.ExpiresAt, p.Note, p.CreatedBy)
	out, err := scanPromo(row)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrConflict
		}
		return nil, err
	}
	return out, nil
}

// UpdatePromoCode overwrites the editable fields (code itself is immutable).
func (db *DB) UpdatePromoCode(ctx context.Context, p *PromoCode) (*PromoCode, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	row := db.Pool.QueryRow(ctx,
		`UPDATE promo_codes SET discount_pct=$2, active=$3, per_user_once=$4, max_uses=$5, expires_at=$6, note=$7, updated_at=NOW()
		 WHERE id=$1 RETURNING `+promoCols,
		p.ID, p.DiscountPct, p.Active, p.PerUserOnce, p.MaxUses, p.ExpiresAt, p.Note)
	out, err := scanPromo(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return out, nil
}

// DeletePromoCode removes a code (cascades redemptions).
func (db *DB) DeletePromoCode(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	tag, err := db.Pool.Exec(ctx, `DELETE FROM promo_codes WHERE id=$1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListPromoCodes returns all codes (newest first) with a redemption count.
func (db *DB) ListPromoCodes(ctx context.Context, limit int) ([]PromoCode, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	rows, err := db.Pool.Query(ctx,
		`SELECT `+promoCols+`,
		   (SELECT count(*) FROM promo_redemptions r WHERE r.promo_code_id = promo_codes.id) AS redemptions
		 FROM promo_codes ORDER BY id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PromoCode
	for rows.Next() {
		var p PromoCode
		if err := rows.Scan(&p.ID, &p.Code, &p.DiscountPct, &p.Active, &p.PerUserOnce,
			&p.MaxUses, &p.UsedCount, &p.ExpiresAt, &p.Note, &p.CreatedBy, &p.CreatedAt, &p.UpdatedAt,
			&p.RedemptionCount); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// GetPromoByCode looks up a code (exact, caller normalizes). Returns (nil, nil)
// when not found — "no such code" is a normal validation outcome, not an error.
func (db *DB) GetPromoByCode(ctx context.Context, code string) (*PromoCode, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	row := db.Pool.QueryRow(ctx, `SELECT `+promoCols+` FROM promo_codes WHERE code=$1`, code)
	p, err := scanPromo(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return p, nil
}

// HasUserRedeemed reports whether the user already redeemed this code.
func (db *DB) HasUserRedeemed(ctx context.Context, codeID, userID int64) (bool, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	var exists bool
	err := db.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM promo_redemptions WHERE promo_code_id=$1 AND user_id=$2)`,
		codeID, userID).Scan(&exists)
	return exists, err
}

// PaymentIntent is the discounted-order record the webhook reconciles against.
type PaymentIntent struct {
	PaymentID   string
	UserID      int64
	PlanID      string
	AmountRub   int
	PromoCodeID *int64
	CreatedAt   time.Time
}

// CreatePaymentIntent persists a pending discounted order.
func (db *DB) CreatePaymentIntent(ctx context.Context, pi *PaymentIntent) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	_, err := db.Pool.Exec(ctx,
		`INSERT INTO payment_intents (payment_id, user_id, plan_id, amount_rub, promo_code_id)
		 VALUES ($1,$2,$3,$4,$5)`,
		pi.PaymentID, pi.UserID, pi.PlanID, pi.AmountRub, pi.PromoCodeID)
	return err
}

// GetPaymentIntent returns the intent for a payment_id, or (nil, nil) if none.
func (db *DB) GetPaymentIntent(ctx context.Context, paymentID string) (*PaymentIntent, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	var pi PaymentIntent
	err := db.Pool.QueryRow(ctx,
		`SELECT payment_id, user_id, plan_id, amount_rub, promo_code_id, created_at FROM payment_intents WHERE payment_id=$1`,
		paymentID).Scan(&pi.PaymentID, &pi.UserID, &pi.PlanID, &pi.AmountRub, &pi.PromoCodeID, &pi.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &pi, nil
}

// RedeemPromo records a redemption and bumps used_count atomically + idempotently:
// the count rises only when a NEW (code,user) redemption is inserted, so a webhook
// retry doesn't double-count.
func (db *DB) RedeemPromo(ctx context.Context, codeID, userID int64, paymentID string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()
	_, err := db.Pool.Exec(ctx, `
		WITH ins AS (
			INSERT INTO promo_redemptions (promo_code_id, user_id, payment_id)
			VALUES ($1,$2,$3)
			ON CONFLICT (promo_code_id, user_id) DO NOTHING
			RETURNING id
		)
		UPDATE promo_codes SET used_count = used_count + 1, updated_at = NOW()
		WHERE id = $1 AND EXISTS (SELECT 1 FROM ins)`,
		codeID, userID, paymentID)
	return err
}

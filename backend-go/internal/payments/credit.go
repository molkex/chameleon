// Package payments is the single entry point for crediting VPN days to users.
// All payment sources — Apple IAP verification, FreeKassa/SBP webhooks, admin
// grants, promo bonuses — MUST call CreditDays. Do not UPDATE users.subscription_expiry
// directly from handlers: payments are idempotent via UNIQUE(source, charge_id)
// and recorded in the payments ledger for reconciliation.
package payments

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Source identifies the system that produced the charge.
type Source string

const (
	SourceAppleIAP  Source = "apple_iap"
	SourceFreeKassa Source = "freekassa"
	SourceAdmin     Source = "admin"
	SourcePromo     Source = "promo"
)

// Credit describes a successful charge that should add Days to the user's subscription.
// ChargeID must be globally unique within Source (Apple: original_transaction_id;
// FreeKassa: intid; admin: synthesized uuid). AmountMinor/Currency are nullable for
// non-monetary sources (admin, promo).
type Credit struct {
	UserID       int64
	Source       Source
	Provider     string // optional: freekassa merchant label (fk / ai_kassa / ...)
	ChargeID     string
	Days         int
	AmountMinor  int64  // in kopecks/cents; 0 if not applicable
	Currency     string // ISO 4217; empty if not applicable
	MetadataJSON []byte // optional raw provider payload
}

// Service persists payments and extends user subscriptions atomically.
type Service struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Service {
	return &Service{pool: pool}
}

// CreditDays records a payment and extends users.subscription_expiry by c.Days.
// Returns alreadyApplied=true when a payment with the same (source, charge_id)
// already exists — the caller should treat this as success without re-delivering.
//
// The insert and the user update run in a single transaction: if the user row is
// missing or the update fails, the payment row is rolled back as well.
func (s *Service) CreditDays(ctx context.Context, c Credit) (alreadyApplied bool, err error) {
	if c.UserID == 0 {
		return false, errors.New("payments: user_id is required")
	}
	if c.Source == "" {
		return false, errors.New("payments: source is required")
	}
	if c.ChargeID == "" {
		return false, errors.New("payments: charge_id is required")
	}
	if c.Days <= 0 {
		return false, fmt.Errorf("payments: days must be > 0, got %d", c.Days)
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return false, fmt.Errorf("payments: begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var amountMinor *int64
	if c.AmountMinor != 0 {
		v := c.AmountMinor
		amountMinor = &v
	}
	var currency *string
	if c.Currency != "" {
		v := c.Currency
		currency = &v
	}
	var provider *string
	if c.Provider != "" {
		v := c.Provider
		provider = &v
	}
	var metadata []byte
	if len(c.MetadataJSON) > 0 {
		metadata = c.MetadataJSON
	}

	var insertedID int64
	err = tx.QueryRow(ctx, `
		INSERT INTO payments (user_id, source, provider, charge_id, days, amount_minor, currency, status, metadata)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'completed', $8)
		ON CONFLICT (source, charge_id) DO NOTHING
		RETURNING id`,
		c.UserID, string(c.Source), provider, c.ChargeID, c.Days, amountMinor, currency, metadata,
	).Scan(&insertedID)

	if errors.Is(err, pgx.ErrNoRows) {
		// Duplicate — another webhook/request already credited this charge.
		return true, nil
	}
	if err != nil {
		return false, fmt.Errorf("payments: insert: %w", err)
	}

	tag, err := tx.Exec(ctx, `
		UPDATE users SET
			subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + ($2 || ' days')::interval,
			is_active = true
		WHERE id = $1`, c.UserID, fmt.Sprintf("%d", c.Days))
	if err != nil {
		return false, fmt.Errorf("payments: extend subscription: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return false, fmt.Errorf("payments: user %d not found", c.UserID)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("payments: commit: %w", err)
	}
	return false, nil
}

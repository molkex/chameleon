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
	"time"

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

// RefundCharge marks a completed payment as refunded and reverses the days it
// added to the user's subscription. Called from the Apple App Store Server
// Notification handler on REFUND / REVOKE.
//
// Idempotent and safe on unknown input:
//   - charge already 'refunded'  → no-op, returns (false, nil)
//   - charge never recorded      → no-op, returns (false, nil)
//     (Apple can send REFUND for a purchase the client never POSTed to /verify)
//
// Reversal model. CreditDays adds days as a source-agnostic running counter:
// `expiry = max(now, expiry) + days`. The exact inverse is `expiry = expiry -
// days`. Days contributed by *other* charges (other Apple renewals, a parallel
// FreeKassa payment) stay intact because they were added to the same counter —
// we only subtract what THIS charge added. No multi-source ledger replay
// needed: the counter is additive and the operation is its inverse.
//
// If the result lands in the past the user's next config fetch sees an expired
// subscription; we also flip is_active to false so any is_active gate revokes
// access immediately. A NULL expiry stays NULL (the user had no active sub —
// refunding a long-consumed period is correctly a no-op on expiry).
func (s *Service) RefundCharge(ctx context.Context, source Source, chargeID string) (refunded bool, err error) {
	if source == "" || chargeID == "" {
		return false, errors.New("payments: refund requires source and charge_id")
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return false, fmt.Errorf("payments: refund begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var userID int64
	var days int
	err = tx.QueryRow(ctx, `
		UPDATE payments SET status = 'refunded'
		WHERE source = $1 AND charge_id = $2 AND status = 'completed'
		RETURNING user_id, days`,
		string(source), chargeID,
	).Scan(&userID, &days)
	if errors.Is(err, pgx.ErrNoRows) {
		// Unknown charge or already refunded — both are no-ops.
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("payments: refund mark: %w", err)
	}

	// Subtract exactly the days this charge added. COALESCE guards the
	// NULL-expiry case (NULL - interval = NULL, NULL > NOW() = NULL → false).
	_, err = tx.Exec(ctx, `
		UPDATE users SET
			subscription_expiry = subscription_expiry - ($2 || ' days')::interval,
			is_active = COALESCE((subscription_expiry - ($2 || ' days')::interval) > NOW(), false)
		WHERE id = $1`, userID, fmt.Sprintf("%d", days))
	if err != nil {
		return false, fmt.Errorf("payments: refund reverse subscription: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("payments: refund commit: %w", err)
	}
	return true, nil
}

// RestoreCharge undoes a RefundCharge: it flips a refunded payment back to
// completed and re-adds its days. Called on the Apple REFUND_REVERSED
// notification (Apple un-did a refund — e.g. a chargeback was reversed).
//
// Idempotent: a charge that is already 'completed' (or unknown) is a no-op,
// returns (false, nil).
//
// The re-credit uses the same `max(now, expiry) + days` formula as CreditDays
// rather than the literal inverse of RefundCharge's subtraction. If time
// passed between the refund and its reversal that's the user-favouring choice
// — they get their full days back starting now — and it keeps the re-credit
// path identical to a normal renewal.
func (s *Service) RestoreCharge(ctx context.Context, source Source, chargeID string) (restored bool, err error) {
	if source == "" || chargeID == "" {
		return false, errors.New("payments: restore requires source and charge_id")
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return false, fmt.Errorf("payments: restore begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var userID int64
	var days int
	err = tx.QueryRow(ctx, `
		UPDATE payments SET status = 'completed'
		WHERE source = $1 AND charge_id = $2 AND status = 'refunded'
		RETURNING user_id, days`,
		string(source), chargeID,
	).Scan(&userID, &days)
	if errors.Is(err, pgx.ErrNoRows) {
		// Not refunded or unknown — no-op.
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("payments: restore mark: %w", err)
	}

	_, err = tx.Exec(ctx, `
		UPDATE users SET
			subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + ($2 || ' days')::interval,
			is_active = true
		WHERE id = $1`, userID, fmt.Sprintf("%d", days))
	if err != nil {
		return false, fmt.Errorf("payments: restore re-credit subscription: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("payments: restore commit: %w", err)
	}
	return true, nil
}

// ReconcileFromLedger recomputes users.subscription_expiry for a single Apple
// subscription from the payments ledger. Used by Restore Purchases when the
// user was previously wiped (account deletion) — the original payment row is
// still in the ledger by original_transaction_id, so we replay it without
// inserting a duplicate.
//
// Expiry formula: created_at + SUM(days) across all ledger rows for this
// (source, charge_id) pair that belong to this user. For a simple 30-day IAP
// with no renewals this is just `created_at + 30 days`. If that's in the past,
// the subscription has already expired and we leave subscription_expiry as NULL.
//
// Returns the new expiry (zero time if expired / not found).
func (s *Service) ReconcileFromLedger(ctx context.Context, userID int64, source Source, chargeID string) (newExpiry time.Time, err error) {
	if userID == 0 || source == "" || chargeID == "" {
		return time.Time{}, errors.New("payments: reconcile requires user_id, source, charge_id")
	}

	var createdAt time.Time
	var totalDays int
	err = s.pool.QueryRow(ctx, `
		SELECT MIN(created_at), COALESCE(SUM(days), 0)
		FROM payments
		WHERE user_id = $1 AND source = $2 AND charge_id = $3 AND status = 'completed'`,
		userID, string(source), chargeID,
	).Scan(&createdAt, &totalDays)
	if err != nil {
		return time.Time{}, fmt.Errorf("payments: reconcile query: %w", err)
	}
	if totalDays == 0 {
		return time.Time{}, nil
	}

	expiry := createdAt.AddDate(0, 0, totalDays)
	if expiry.Before(time.Now()) {
		return time.Time{}, nil
	}

	_, err = s.pool.Exec(ctx, `
		UPDATE users SET
			subscription_expiry = GREATEST(COALESCE(subscription_expiry, $2), $2),
			is_active = true
		WHERE id = $1`, userID, expiry)
	if err != nil {
		return time.Time{}, fmt.Errorf("payments: reconcile update: %w", err)
	}
	return expiry, nil
}

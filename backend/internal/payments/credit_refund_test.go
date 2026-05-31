//go:build integration

// credit_refund_test.go covers SEC-04 (2026-06-01): an Apple REFUND/REVOKE must
// actually revoke access by recomputing subscription_expiry from the remaining
// completed ledger. Integration-gated (needs Docker) like the rest of payments.

package payments

import (
	"context"
	"testing"
	"time"
)

func seedUser(t *testing.T, svc *Service, id int64) {
	t.Helper()
	_, err := svc.pool.Exec(context.Background(), `
		INSERT INTO users (id, device_id, is_active, created_at, updated_at)
		VALUES ($1, $2, true, NOW(), NOW())`, id, "dev_"+time.Now().Format("150405.000000"))
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}
}

func subExpiry(t *testing.T, svc *Service, userID int64) *time.Time {
	t.Helper()
	var exp *time.Time
	if err := svc.pool.QueryRow(context.Background(),
		`SELECT subscription_expiry FROM users WHERE id = $1`, userID).Scan(&exp); err != nil {
		t.Fatalf("read expiry: %v", err)
	}
	return exp
}

func chargeStatus(t *testing.T, svc *Service, source Source, chargeID string) string {
	t.Helper()
	var st string
	if err := svc.pool.QueryRow(context.Background(),
		`SELECT status FROM payments WHERE source = $1 AND charge_id = $2`,
		string(source), chargeID).Scan(&st); err != nil {
		t.Fatalf("read status: %v", err)
	}
	return st
}

// TestRefundRevokesAccessWhenSoleCharge: the common case — a user buys 30 days,
// then refunds. No completed coverage remains → subscription_expiry NULL.
func TestRefundRevokesAccessWhenSoleCharge(t *testing.T) {
	svc := startTestPaymentsDB(t)
	ctx := context.Background()
	seedUser(t, svc, 1)

	if _, err := svc.CreditDays(ctx, Credit{UserID: 1, Source: SourceAppleIAP, ChargeID: "tx-1", Days: 30}); err != nil {
		t.Fatalf("CreditDays: %v", err)
	}
	if subExpiry(t, svc, 1) == nil {
		t.Fatal("precondition: expiry should be set after credit")
	}

	newExp, err := svc.MarkRefundedAndReconcile(ctx, 1, SourceAppleIAP, "tx-1")
	if err != nil {
		t.Fatalf("MarkRefundedAndReconcile: %v", err)
	}
	if newExp != nil {
		t.Errorf("expected nil expiry after refunding the only charge, got %v", newExp)
	}
	if got := subExpiry(t, svc, 1); got != nil {
		t.Errorf("SEC-04: subscription_expiry must be NULL after sole-charge refund, got %v", got)
	}
	if st := chargeStatus(t, svc, SourceAppleIAP, "tx-1"); st != "refunded" {
		t.Errorf("charge status: want refunded, got %q", st)
	}
}

// TestRefundKeepsOtherCoverage: a user with an Apple AND a FreeKassa charge
// refunds only the Apple one — the FreeKassa days must still cover them. This is
// exactly the multi-source case the old log-only handler punted on.
func TestRefundKeepsOtherCoverage(t *testing.T) {
	svc := startTestPaymentsDB(t)
	ctx := context.Background()
	seedUser(t, svc, 2)

	if _, err := svc.CreditDays(ctx, Credit{UserID: 2, Source: SourceAppleIAP, ChargeID: "atx", Days: 30}); err != nil {
		t.Fatalf("credit apple: %v", err)
	}
	if _, err := svc.CreditDays(ctx, Credit{UserID: 2, Source: SourceFreeKassa, ChargeID: "ftx", Days: 30}); err != nil {
		t.Fatalf("credit freekassa: %v", err)
	}

	newExp, err := svc.MarkRefundedAndReconcile(ctx, 2, SourceAppleIAP, "atx")
	if err != nil {
		t.Fatalf("refund: %v", err)
	}
	if newExp == nil {
		t.Fatal("SEC-04: a still-valid FreeKassa charge must keep the user covered after an Apple refund")
	}
	if !newExp.After(time.Now()) {
		t.Errorf("recomputed expiry should be in the future (FreeKassa 30d), got %v", newExp)
	}
	if st := chargeStatus(t, svc, SourceFreeKassa, "ftx"); st != "completed" {
		t.Errorf("FreeKassa charge must stay completed, got %q", st)
	}
}

// TestRefundReversedRestoresAccess: Apple reverses the refund → the charge goes
// back to completed and its days are restored.
func TestRefundReversedRestoresAccess(t *testing.T) {
	svc := startTestPaymentsDB(t)
	ctx := context.Background()
	seedUser(t, svc, 3)

	if _, err := svc.CreditDays(ctx, Credit{UserID: 3, Source: SourceAppleIAP, ChargeID: "rtx", Days: 30}); err != nil {
		t.Fatalf("credit: %v", err)
	}
	if _, err := svc.MarkRefundedAndReconcile(ctx, 3, SourceAppleIAP, "rtx"); err != nil {
		t.Fatalf("refund: %v", err)
	}
	if subExpiry(t, svc, 3) != nil {
		t.Fatal("precondition: expiry NULL after refund")
	}

	restored, err := svc.MarkCompletedAndReconcile(ctx, 3, SourceAppleIAP, "rtx")
	if err != nil {
		t.Fatalf("reverse refund: %v", err)
	}
	if restored == nil || !restored.After(time.Now()) {
		t.Errorf("REFUND_REVERSED must restore a future expiry, got %v", restored)
	}
	if st := chargeStatus(t, svc, SourceAppleIAP, "rtx"); st != "completed" {
		t.Errorf("charge status after reversal: want completed, got %q", st)
	}
}

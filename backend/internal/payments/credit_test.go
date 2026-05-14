//go:build integration

// credit_test.go covers the payment ledger lifecycle: CreditDays adds days,
// RefundCharge (launch-09) reverses them, RestoreCharge re-credits a reversed
// refund. All gated behind `integration` — needs a real Postgres.
//
//	go test -tags=integration ./internal/payments/...
package payments

import (
	"context"
	"testing"
	"time"
)

const dayTolerance = 36 * time.Hour // generous: interval math + test runtime

// approxDaysFromNow asserts t is within tolerance of now+days.
func approxDaysFromNow(t *testing.T, label string, got *time.Time, days int) {
	t.Helper()
	if got == nil {
		t.Fatalf("%s: expiry is nil, want ~%d days from now", label, days)
	}
	want := time.Now().AddDate(0, 0, days)
	diff := got.Sub(want)
	if diff < 0 {
		diff = -diff
	}
	if diff > dayTolerance {
		t.Errorf("%s: expiry = %v, want ~%v (±%v), off by %v", label, got, want, dayTolerance, diff)
	}
}

// TestCreditDays_ExtendsAndIsIdempotent — baseline: CreditDays adds days and a
// replay of the same (source, charge_id) is a no-op.
func TestCreditDays_ExtendsAndIsIdempotent(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	ctx := context.Background()
	uid := makeUser(t, pool, time.Time{}) // no subscription yet

	applied, err := svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "tx-1", Days: 30,
	})
	if err != nil || applied {
		t.Fatalf("first credit: applied=%v err=%v, want false/nil", applied, err)
	}
	expiry, active := userState(t, pool, uid)
	approxDaysFromNow(t, "after credit", expiry, 30)
	if !active {
		t.Error("user should be active after credit")
	}

	// Replay — must be a no-op (alreadyApplied=true, expiry unchanged).
	applied, err = svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "tx-1", Days: 30,
	})
	if err != nil || !applied {
		t.Fatalf("replay credit: applied=%v err=%v, want true/nil", applied, err)
	}
	expiry2, _ := userState(t, pool, uid)
	approxDaysFromNow(t, "after replay", expiry2, 30) // still 30, not 60
}

// TestRefundCharge_ReversesDaysAndMarksRefunded — the core launch-09 path.
func TestRefundCharge_ReversesDaysAndMarksRefunded(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	ctx := context.Background()
	uid := makeUser(t, pool, time.Time{})

	if _, err := svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "tx-refund", Days: 30,
	}); err != nil {
		t.Fatalf("credit: %v", err)
	}

	refunded, err := svc.RefundCharge(ctx, SourceAppleIAP, "tx-refund")
	if err != nil || !refunded {
		t.Fatalf("RefundCharge: refunded=%v err=%v, want true/nil", refunded, err)
	}
	if got := paymentStatus(t, pool, SourceAppleIAP, "tx-refund"); got != "refunded" {
		t.Errorf("payment status = %q, want refunded", got)
	}
	// 30 days credited, 30 reversed → expiry back to ~now (within tolerance).
	expiry, active := userState(t, pool, uid)
	approxDaysFromNow(t, "after refund", expiry, 0)
	if active {
		t.Error("user should be inactive: the only charge covering them was refunded")
	}
}

// TestRefundCharge_KeepsOtherSourceDays — refunding an Apple charge must NOT
// remove days a parallel FreeKassa payment contributed. The running counter
// is source-agnostic; we subtract only what THIS charge added.
func TestRefundCharge_KeepsOtherSourceDays(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	ctx := context.Background()
	uid := makeUser(t, pool, time.Time{})

	// Apple 30 + FreeKassa 30 = ~60 days on the counter.
	if _, err := svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "apple-tx", Days: 30,
	}); err != nil {
		t.Fatalf("apple credit: %v", err)
	}
	if _, err := svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceFreeKassa, ChargeID: "fk-tx", Days: 30,
	}); err != nil {
		t.Fatalf("freekassa credit: %v", err)
	}
	bothExpiry, _ := userState(t, pool, uid)
	approxDaysFromNow(t, "after both credits", bothExpiry, 60)

	// Refund only the Apple charge → ~30 days (the FreeKassa contribution) left.
	if _, err := svc.RefundCharge(ctx, SourceAppleIAP, "apple-tx"); err != nil {
		t.Fatalf("RefundCharge: %v", err)
	}
	expiry, active := userState(t, pool, uid)
	approxDaysFromNow(t, "after apple refund", expiry, 30)
	if !active {
		t.Error("user should stay active: FreeKassa still covers ~30 days")
	}
	// FreeKassa row untouched.
	if got := paymentStatus(t, pool, SourceFreeKassa, "fk-tx"); got != "completed" {
		t.Errorf("freekassa payment status = %q, want completed (untouched)", got)
	}
}

// TestRefundCharge_Idempotent — a second refund of the same charge is a no-op.
func TestRefundCharge_Idempotent(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	ctx := context.Background()
	uid := makeUser(t, pool, time.Time{})

	_, _ = svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "tx-idem", Days: 30,
	})
	if _, err := svc.RefundCharge(ctx, SourceAppleIAP, "tx-idem"); err != nil {
		t.Fatalf("first refund: %v", err)
	}
	expiryAfterFirst, _ := userState(t, pool, uid)

	refunded, err := svc.RefundCharge(ctx, SourceAppleIAP, "tx-idem")
	if err != nil {
		t.Fatalf("second refund: %v", err)
	}
	if refunded {
		t.Error("second refund: refunded=true, want false (already refunded)")
	}
	expiryAfterSecond, _ := userState(t, pool, uid)
	// Expiry must not move on the no-op replay.
	if !timeEq(expiryAfterFirst, expiryAfterSecond) {
		t.Errorf("expiry moved on idempotent replay: %v → %v", expiryAfterFirst, expiryAfterSecond)
	}
}

// TestRefundCharge_UnknownChargeIsNoOp — Apple can send REFUND for a purchase
// that never reached /verify; it must not error.
func TestRefundCharge_UnknownChargeIsNoOp(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	refunded, err := svc.RefundCharge(context.Background(), SourceAppleIAP, "never-seen")
	if err != nil {
		t.Fatalf("RefundCharge unknown: %v, want nil", err)
	}
	if refunded {
		t.Error("RefundCharge unknown: refunded=true, want false")
	}
}

// TestRestoreCharge_ReCreditsAReversedRefund — REFUND_REVERSED path.
func TestRestoreCharge_ReCreditsAReversedRefund(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	ctx := context.Background()
	uid := makeUser(t, pool, time.Time{})

	_, _ = svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "tx-restore", Days: 30,
	})
	if _, err := svc.RefundCharge(ctx, SourceAppleIAP, "tx-restore"); err != nil {
		t.Fatalf("refund: %v", err)
	}

	restored, err := svc.RestoreCharge(ctx, SourceAppleIAP, "tx-restore")
	if err != nil || !restored {
		t.Fatalf("RestoreCharge: restored=%v err=%v, want true/nil", restored, err)
	}
	if got := paymentStatus(t, pool, SourceAppleIAP, "tx-restore"); got != "completed" {
		t.Errorf("payment status = %q, want completed", got)
	}
	expiry, active := userState(t, pool, uid)
	approxDaysFromNow(t, "after restore", expiry, 30)
	if !active {
		t.Error("user should be active again after refund reversal")
	}
}

// TestRestoreCharge_NotRefundedIsNoOp — restoring a charge that was never
// refunded must be a no-op.
func TestRestoreCharge_NotRefundedIsNoOp(t *testing.T) {
	pool := startTestPool(t)
	svc := New(pool)
	ctx := context.Background()
	uid := makeUser(t, pool, time.Time{})

	_, _ = svc.CreditDays(ctx, Credit{
		UserID: uid, Source: SourceAppleIAP, ChargeID: "tx-completed", Days: 30,
	})
	restored, err := svc.RestoreCharge(ctx, SourceAppleIAP, "tx-completed")
	if err != nil {
		t.Fatalf("RestoreCharge: %v", err)
	}
	if restored {
		t.Error("RestoreCharge of a completed charge: restored=true, want false")
	}
}

// --- helpers ---

func timeEq(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Equal(*b)
}

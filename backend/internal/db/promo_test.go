//go:build integration

// promo_test.go — PROMO-CODES DB layer (migration 026): code CRUD + conflict,
// payment intents, and the idempotent redeem (used_count rises once even on a
// webhook retry). Integration-tagged (testcontainers PG).
//
//	go test -tags=integration ./internal/db/...

package db

import (
	"context"
	"testing"
)

func TestPromoCRUDAndConflict(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	created, err := database.CreatePromoCode(ctx, &PromoCode{
		Code: "SAVE50", DiscountPct: 50, Active: true, PerUserOnce: true,
		MaxUses: ptr(100), Note: "summer", CreatedBy: "admin",
	})
	if err != nil {
		t.Fatalf("CreatePromoCode: %v", err)
	}
	if created.Code != "SAVE50" || created.DiscountPct != 50 || created.UsedCount != 0 {
		t.Errorf("unexpected created row: %+v", created)
	}

	// duplicate code → ErrConflict
	if _, err := database.CreatePromoCode(ctx, &PromoCode{Code: "SAVE50", DiscountPct: 10, Active: true}); err != ErrConflict {
		t.Errorf("duplicate code = %v, want ErrConflict", err)
	}

	// get by code
	got, err := database.GetPromoByCode(ctx, "SAVE50")
	if err != nil || got == nil || got.ID != created.ID {
		t.Fatalf("GetPromoByCode: %v / %+v", err, got)
	}
	// missing code → (nil, nil)
	if miss, err := database.GetPromoByCode(ctx, "NOPE"); err != nil || miss != nil {
		t.Errorf("GetPromoByCode(missing) = %+v / %v, want nil/nil", miss, err)
	}

	// update: deactivate
	created.Active = false
	created.DiscountPct = 35
	upd, err := database.UpdatePromoCode(ctx, created)
	if err != nil || upd.Active != false || upd.DiscountPct != 35 {
		t.Fatalf("UpdatePromoCode: %v / %+v", err, upd)
	}
	// update missing → ErrNotFound
	if _, err := database.UpdatePromoCode(ctx, &PromoCode{ID: 999999, Code: "X", DiscountPct: 10}); err != ErrNotFound {
		t.Errorf("update missing = %v, want ErrNotFound", err)
	}

	// list shows it with redemptions=0
	list, err := database.ListPromoCodes(ctx, 50)
	if err != nil || len(list) != 1 || list[0].RedemptionCount != 0 {
		t.Fatalf("ListPromoCodes: %v / %+v", err, list)
	}

	// delete + re-delete
	if err := database.DeletePromoCode(ctx, created.ID); err != nil {
		t.Fatalf("DeletePromoCode: %v", err)
	}
	if err := database.DeletePromoCode(ctx, created.ID); err != ErrNotFound {
		t.Errorf("re-delete = %v, want ErrNotFound", err)
	}
}

func TestPaymentIntentRoundTrip(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "pi_user", "aaaaaaaa-0000-4000-8000-0000000000f1")
	code, _ := database.CreatePromoCode(ctx, &PromoCode{Code: "PI10", DiscountPct: 10, Active: true})

	pcID := code.ID
	if err := database.CreatePaymentIntent(ctx, &PaymentIntent{
		PaymentID: "app_m1_1_999", UserID: uid, PlanID: "m1", AmountRub: 206, PromoCodeID: &pcID,
	}); err != nil {
		t.Fatalf("CreatePaymentIntent: %v", err)
	}
	got, err := database.GetPaymentIntent(ctx, "app_m1_1_999")
	if err != nil || got == nil || got.AmountRub != 206 || got.PromoCodeID == nil || *got.PromoCodeID != pcID {
		t.Fatalf("GetPaymentIntent: %v / %+v", err, got)
	}
	// missing → (nil, nil)
	if miss, err := database.GetPaymentIntent(ctx, "nope"); err != nil || miss != nil {
		t.Errorf("GetPaymentIntent(missing) = %+v / %v", miss, err)
	}
}

func TestRedeemPromoIsIdempotent(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()
	uid := createChatUser(t, database, ctx, "redeem_user", "aaaaaaaa-0000-4000-8000-0000000000f2")
	code, _ := database.CreatePromoCode(ctx, &PromoCode{Code: "ONCE", DiscountPct: 50, Active: true, PerUserOnce: true})

	if has, _ := database.HasUserRedeemed(ctx, code.ID, uid); has {
		t.Fatal("HasUserRedeemed should be false before any redemption")
	}

	// first redeem → used_count 0→1
	if err := database.RedeemPromo(ctx, code.ID, uid, "app_m1_1_1"); err != nil {
		t.Fatalf("RedeemPromo #1: %v", err)
	}
	// webhook retry → must NOT double-count
	if err := database.RedeemPromo(ctx, code.ID, uid, "app_m1_1_1"); err != nil {
		t.Fatalf("RedeemPromo #2 (retry): %v", err)
	}

	if has, _ := database.HasUserRedeemed(ctx, code.ID, uid); !has {
		t.Error("HasUserRedeemed should be true after redemption")
	}
	after, _ := database.GetPromoByCode(ctx, "ONCE")
	if after.UsedCount != 1 {
		t.Errorf("used_count = %d after a redeem + retry, want 1", after.UsedCount)
	}
	if list, _ := database.ListPromoCodes(ctx, 10); len(list) != 1 || list[0].RedemptionCount != 1 {
		t.Errorf("redemption count = %d, want 1", list[0].RedemptionCount)
	}
}

package mobile

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/payments/apple"
)

// productDays maps Apple productIds to the number of VPN days to credit.
// These strings MUST match the product ids created in App Store Connect.
//
// Auto-renewing products (`com.madfrog.vpn.sub.{month,3month,6month,year}`)
// and legacy non-renewing products (`*.{30,90,180,365}days`) coexist during
// the migration window — the non-renewing ids remain here so Restore
// Purchases keeps working for users who already bought them. Cleanup after
// all 365-day legacy purchases expire (≈ 2027-05).
var productDays = map[string]int{
	// Auto-renewing (current — used by build 54+)
	"com.madfrog.vpn.sub.month":   30,
	"com.madfrog.vpn.sub.3month":  90,
	"com.madfrog.vpn.sub.6month":  180,
	"com.madfrog.vpn.sub.year":    365,
	// Legacy non-renewing (kept for Restore Purchases / in-flight buyers)
	"com.madfrog.vpn.sub.30days":  30,
	"com.madfrog.vpn.sub.90days":  90,
	"com.madfrog.vpn.sub.180days": 180,
	"com.madfrog.vpn.sub.365days": 365,
}

// autoRenewingProducts marks the products that share an originalTransactionId
// across every renewal. For those, `payments.charge_id` MUST use the per-event
// transactionId — otherwise renewal #2+ collides on UNIQUE(source, charge_id)
// in CreditDays, the credit silently no-ops, and ReconcileFromLedger caps
// subscription_expiry at the original purchase date instead of extending it.
//
// Non-renewing products always have a fresh originalTransactionId per
// purchase, so for them we keep using originalTransactionId as charge_id
// (the existing idempotency story works as-is).
var autoRenewingProducts = map[string]bool{
	"com.madfrog.vpn.sub.month":  true,
	"com.madfrog.vpn.sub.3month": true,
	"com.madfrog.vpn.sub.6month": true,
	"com.madfrog.vpn.sub.year":   true,
}

// isAutoRenewing reports whether productID is one of our auto-renewing
// subscription products. Used to pick the right charge_id strategy.
func isAutoRenewing(productID string) bool {
	return autoRenewingProducts[productID]
}

// appleChargeID picks the correct payments.charge_id for a verified Apple
// transaction. For auto-renewing products that's the per-event transactionId
// (so each renewal is a distinct row in the ledger). For everything else
// it's the stable originalTransactionId.
func appleChargeID(tx *apple.Transaction) string {
	if isAutoRenewing(tx.ProductID) && tx.TransactionID != "" {
		return tx.TransactionID
	}
	return tx.OriginalTransactionID
}

// ProductDays returns a copy of the Apple productId → days mapping. Exposed
// so the server wiring can pass it to apple.Verifier without reaching into
// unexported package state.
func ProductDays() map[string]int {
	out := make(map[string]int, len(productDays))
	for k, v := range productDays {
		out[k] = v
	}
	return out
}

// VerifySubscriptionRequest is the body for POST /api/mobile/subscription/verify.
//
// StoreKit 2 on iOS returns a JWS-encoded string for each Transaction — the client
// sends that opaque string here. ProductID is echoed back for convenience and
// cross-checked against the verified JWS (they must match).
type VerifySubscriptionRequest struct {
	SignedTransaction string `json:"signed_transaction"`

	// Legacy fields kept temporarily for migration: old clients that still send
	// {transaction_id, product_id} will be rejected but with a clearer error.
	TransactionID string `json:"transaction_id,omitempty"`
	ProductID     string `json:"product_id,omitempty"`
}

// SubscriptionResponse is the response for subscription verification.
type SubscriptionResponse struct {
	Status             string `json:"status"`              // "active" | "expired"
	ProductID          string `json:"product_id"`          // verified product id from Apple
	SubscriptionExpiry int64  `json:"subscription_expiry"` // unix seconds
	AlreadyApplied     bool   `json:"already_applied"`     // true for duplicate deliveries
}

// VerifySubscription handles POST /api/mobile/subscription/verify.
//
// Flow:
//  1. Parse + verify the Apple JWS signature chain against Apple's root CA.
//     No App Store Server API credentials are needed for this step.
//  2. Enforce bundle id, environment, and known product id invariants.
//  3. Credit the user via payments.CreditDays — idempotent on
//     (source=apple_iap, charge_id=originalTransactionId), so duplicate
//     receipts from retried purchases don't double-extend the subscription.
//  4. Reload the user and echo the new expiry back to the client.
func (h *Handler) VerifySubscription(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	var req VerifySubscriptionRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}

	signedJWS := strings.TrimSpace(req.SignedTransaction)
	if signedJWS == "" {
		// Old client format — reject explicitly so UI shows a meaningful error
		// instead of silently failing. The iOS app must be updated to send the
		// StoreKit 2 JWS from Transaction.jsonRepresentation.
		if req.TransactionID != "" || req.ProductID != "" {
			return c.JSON(http.StatusBadRequest, ErrorResponse{
				Error: "outdated client: send signed_transaction (StoreKit 2 JWS), not transaction_id",
			})
		}
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "signed_transaction is required"})
	}

	if h.AppleVerifier == nil {
		h.Logger.Error("subscription verify called but AppleVerifier is nil")
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "payments not configured"})
	}

	tx, err := h.AppleVerifier.Verify(signedJWS)
	if err != nil {
		if errors.Is(err, apple.ErrRevoked) {
			h.Logger.Warn("apple transaction revoked",
				zap.Int64("user_id", claims.UserID),
				zap.String("original_transaction_id", tx.OriginalTransactionID),
			)
			return c.JSON(http.StatusForbidden, ErrorResponse{Error: "transaction revoked"})
		}
		h.Logger.Warn("apple verify failed",
			zap.Int64("user_id", claims.UserID),
			zap.Error(err),
		)
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid receipt"})
	}

	ctx := c.Request().Context()

	// charge_id strategy depends on product type:
	//   - non-renewing: originalTransactionId (stable, one per purchase)
	//   - auto-renewing: transactionId (per-event, so renewals don't collide
	//     on UNIQUE(source, charge_id) and silently no-op).
	// See appleChargeID() and autoRenewingProducts above.
	chargeID := appleChargeID(tx)

	amountMinor := int64(0) // StoreKit JWS does not expose localized price here; fill from ASC if needed later
	currency := ""

	alreadyApplied, err := h.Payments.CreditDays(ctx, payments.Credit{
		UserID:      claims.UserID,
		Source:      payments.SourceAppleIAP,
		ChargeID:    chargeID,
		Days:        tx.Days,
		AmountMinor: amountMinor,
		Currency:    currency,
	})
	if err != nil {
		h.Logger.Error("payments: credit apple iap",
			zap.Error(err),
			zap.Int64("user_id", claims.UserID),
			zap.String("charge_id", chargeID),
		)
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "failed to apply subscription"})
	}

	// Restore Purchases after account wipe: the payment row is already in
	// the ledger, so CreditDays returns alreadyApplied=true and does nothing.
	// Reconcile entitlement from the ledger to restore subscription_expiry.
	if alreadyApplied {
		if newExpiry, rerr := h.Payments.ReconcileFromLedger(ctx, claims.UserID, payments.SourceAppleIAP, chargeID); rerr != nil {
			h.Logger.Warn("payments: reconcile from ledger failed",
				zap.Error(rerr),
				zap.Int64("user_id", claims.UserID),
				zap.String("charge_id", chargeID),
			)
		} else if !newExpiry.IsZero() {
			h.Logger.Info("subscription reconciled from ledger",
				zap.Int64("user_id", claims.UserID),
				zap.String("charge_id", chargeID),
				zap.Time("new_expiry", newExpiry),
			)
		}
	}

	// Persist the Apple-specific fields on the user row so the admin UI and
	// future ASN webhook can look up the user by originalTransactionId.
	user, err := h.DB.FindUserByID(ctx, claims.UserID)
	if err != nil || user == nil {
		h.Logger.Error("db: find user after credit", zap.Error(err), zap.Int64("user_id", claims.UserID))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	user.OriginalTransactionID = &tx.OriginalTransactionID
	user.AppStoreProductID = &tx.ProductID
	if err := h.DB.UpdateUser(ctx, user); err != nil {
		// Non-fatal: the payment already committed. Log and continue.
		h.Logger.Warn("db: persist apple ids",
			zap.Error(err),
			zap.Int64("user_id", claims.UserID),
		)
	}

	h.Logger.Info("subscription verified",
		zap.Int64("user_id", claims.UserID),
		zap.String("product_id", tx.ProductID),
		zap.String("original_transaction_id", tx.OriginalTransactionID),
		zap.Int("days", tx.Days),
		zap.Bool("already_applied", alreadyApplied),
	)

	var expiryUnix int64
	if user.SubscriptionExpiry != nil {
		expiryUnix = user.SubscriptionExpiry.Unix()
	}

	return c.JSON(http.StatusOK, SubscriptionResponse{
		Status:             statusFromExpiry(user.SubscriptionExpiry),
		ProductID:          tx.ProductID,
		SubscriptionExpiry: expiryUnix,
		AlreadyApplied:     alreadyApplied,
	})
}

func statusFromExpiry(t *time.Time) string {
	if t == nil || t.Before(time.Now()) {
		return "expired"
	}
	return "active"
}

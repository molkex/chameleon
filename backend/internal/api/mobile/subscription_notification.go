package mobile

import (
	"context"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/payments/apple"
)

// NotificationRequest is the body Apple POSTs to the ASN v2 webhook.
// The signedPayload is a JWS (ES256, x5c chain) we verify against Apple's
// root CA before trusting any of its contents.
type NotificationRequest struct {
	SignedPayload string `json:"signedPayload"`
}

// AppleNotification handles POST /api/mobile/subscription/notification.
//
// This endpoint is public — Apple does NOT send any auth header. Trust comes
// entirely from verifying the JWS signature chain. Return 200 as soon as the
// notification is safely recorded; Apple retries on non-2xx for up to several
// days, so we must be strictly idempotent.
//
// Routing by notificationType:
//
//	SUBSCRIBED / DID_RENEW / OFFER_REDEEMED → credit via payments.CreditDays
//	REFUND / REVOKE                         → mark payment as refunded, do not change expiry here
//	EXPIRED / DID_FAIL_TO_RENEW / GRACE_*   → log only, expiry handled by client on next config fetch
//	TEST                                    → log and 200
//	anything else                           → log and 200 (forward-compat)
func (h *Handler) AppleNotification(c echo.Context) error {
	if h.AppleVerifier == nil {
		h.Logger.Error("apple notification called but AppleVerifier is nil")
		return c.JSON(http.StatusServiceUnavailable, ErrorResponse{Error: "payments not configured"})
	}

	var req NotificationRequest
	if err := c.Bind(&req); err != nil || req.SignedPayload == "" {
		h.Logger.Warn("apple notification: bad body", zap.Error(err))
		// 400 here is fine — a malformed POST is almost certainly not from Apple.
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "signedPayload required"})
	}

	notif, err := h.AppleVerifier.VerifyNotification(req.SignedPayload)
	if err != nil {
		h.Logger.Warn("apple notification: verify failed", zap.Error(err))
		// Return 400 so Apple doesn't spam retries on garbage. Real Apple
		// payloads will always verify; anything else is noise or attack.
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid signedPayload"})
	}

	logger := h.Logger.With(
		zap.String("notification_type", notif.Type),
		zap.String("notification_subtype", notif.Subtype),
		zap.String("notification_uuid", notif.UUID),
	)

	// TEST pings and summary-only notifications don't carry a transaction —
	// acknowledge with 200 so Apple stops retrying.
	if notif.Tx == nil {
		logger.Info("apple notification: no transaction (test/summary)")
		return c.NoContent(http.StatusOK)
	}

	logger = logger.With(
		zap.String("product_id", notif.Tx.ProductID),
		zap.String("original_transaction_id", notif.Tx.OriginalTransactionID),
		zap.Bool("revoked", notif.Tx.Revoked),
	)

	ctx := c.Request().Context()

	switch notif.Type {
	case "SUBSCRIBED", "DID_RENEW", "OFFER_REDEEMED", "ONE_TIME_CHARGE":
		if notif.Tx.Revoked {
			logger.Warn("apple notification: renewal delivered a revoked transaction, skipping credit")
			return c.NoContent(http.StatusOK)
		}
		if err := h.creditFromNotification(ctx, notif.Tx, logger); err != nil {
			logger.Error("apple notification: credit failed", zap.Error(err))
			// 500 → Apple retries. That's what we want for transient DB errors.
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "credit failed"})
		}
		return c.NoContent(http.StatusOK)

	case "REFUND", "REVOKE":
		// SEC-04: actually revoke. Mark the charge refunded and recompute
		// subscription_expiry from the user's remaining completed ledger (so a
		// still-valid charge from another source keeps them covered). Previously
		// log-only → refunded users kept access until natural expiry.
		if err := h.reconcileRefund(ctx, notif.Tx, "refunded", logger); err != nil {
			logger.Error("apple notification: refund reconcile failed", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "refund reconcile failed"})
		}
		return c.NoContent(http.StatusOK)

	case "REFUND_REVERSED":
		// Apple reversed an earlier refund → restore the charge + its days.
		if err := h.reconcileRefund(ctx, notif.Tx, "completed", logger); err != nil {
			logger.Error("apple notification: refund-reversal reconcile failed", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "reconcile failed"})
		}
		return c.NoContent(http.StatusOK)

	case "EXPIRED", "DID_FAIL_TO_RENEW", "GRACE_PERIOD_EXPIRED":
		logger.Info("apple notification: lifecycle event")
		return c.NoContent(http.StatusOK)

	case "TEST":
		logger.Info("apple notification: test ping")
		return c.NoContent(http.StatusOK)

	default:
		// Forward-compatible: unknown types are 200'd so Apple doesn't retry.
		logger.Info("apple notification: unhandled type")
		return c.NoContent(http.StatusOK)
	}
}

// creditFromNotification looks up the user by originalTransactionId (persisted
// on first purchase via /subscription/verify) and credits days. If we can't
// resolve a user we still return nil — the notification is valid, we just
// haven't seen that original transaction yet.
func (h *Handler) creditFromNotification(ctx context.Context, tx *apple.Transaction, logger *zap.Logger) error {
	user, err := h.DB.FindUserByOriginalTransactionID(ctx, tx.OriginalTransactionID)
	if err != nil {
		return err
	}
	if user == nil {
		// Could be a renewal for a purchase that hasn't hit /verify yet — Apple
		// sometimes delivers webhook before client sync on spotty networks.
		// We return nil so Apple doesn't retry forever; the next client-side
		// Transaction.updates delivery will re-credit via /verify.
		logger.Warn("apple notification: no user for original transaction id")
		return nil
	}

	// Use the per-event transactionId for auto-renewing products so that
	// each renewal is a distinct ledger row. originalTransactionId is the
	// same across renewals and would silently collide on UNIQUE(source,
	// charge_id). See appleChargeID() in subscription.go.
	_, err = h.Payments.CreditDays(ctx, payments.Credit{
		UserID:   user.ID,
		Source:   payments.SourceAppleIAP,
		ChargeID: appleChargeID(tx),
		Days:     tx.Days,
	})
	return err
}

// reconcileRefund (SEC-04) resolves the user by originalTransactionId and flips
// the matching Apple charge to newStatus ("refunded" on REFUND/REVOKE,
// "completed" on REFUND_REVERSED), recomputing subscription_expiry from their
// remaining completed ledger. A missing user is not an error — we ack so Apple
// stops retrying; if we later credit that original transaction, the charge_id
// match still applies.
func (h *Handler) reconcileRefund(ctx context.Context, tx *apple.Transaction, newStatus string, logger *zap.Logger) error {
	user, err := h.DB.FindUserByOriginalTransactionID(ctx, tx.OriginalTransactionID)
	if err != nil {
		return err
	}
	if user == nil {
		logger.Warn("apple notification: refund for unknown original transaction id — nothing to reconcile")
		return nil
	}

	var newExpiry *time.Time
	if newStatus == "completed" {
		newExpiry, err = h.Payments.MarkCompletedAndReconcile(ctx, user.ID, payments.SourceAppleIAP, appleChargeID(tx))
	} else {
		newExpiry, err = h.Payments.MarkRefundedAndReconcile(ctx, user.ID, payments.SourceAppleIAP, appleChargeID(tx))
	}
	if err != nil {
		return err
	}
	logger.Info("apple notification: refund reconciled",
		zap.Int64("user_id", user.ID),
		zap.String("new_status", newStatus),
		zap.Timep("new_expiry", newExpiry))
	return nil
}

package mobile

import (
	"context"
	"net/http"

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

	case "REFUND", "REFUND_REVERSED", "REVOKE":
		// Phase 1b scope: just log. Actually rolling back subscription_expiry
		// requires knowing whether ANY other payment covers the current period,
		// which we'll handle in Phase 2 when we have multi-source ledger queries.
		logger.Warn("apple notification: refund/revoke received — not auto-reversing in Phase 1b")
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

	_, err = h.Payments.CreditDays(ctx, payments.Credit{
		UserID:   user.ID,
		Source:   payments.SourceAppleIAP,
		ChargeID: tx.OriginalTransactionID,
		Days:     tx.Days,
	})
	return err
}

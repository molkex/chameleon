package mobile

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/payments/freekassa"
)

// FreeKassaWebhook handles POST /api/webhooks/freekassa.
//
// FreeKassa sends application/x-www-form-urlencoded with fields:
//
//	MERCHANT_ID, AMOUNT, MERCHANT_ORDER_ID, intid, SIGN, P_EMAIL, ...
//
// We must respond with plain text "YES" on success so FreeKassa stops
// retrying. Any other response (including an empty 200) will be retried
// for hours.
//
// Security layers:
//  1. IP allowlist (configured FK notification IPs).
//  2. MD5 signature verified against secret2.
//  3. Merchant id must match our configured shop id.
//  4. payment_id must belong to the "app_" prefix family — bot payments
//     are routed to the legacy bot by a future proxy handler.
func (h *Handler) FreeKassaWebhook(c echo.Context) error {
	cfg := h.Config.Payments.FreeKassa
	if !cfg.Enabled {
		return c.String(http.StatusServiceUnavailable, "disabled")
	}

	// 1. IP allowlist — empty allowlist means allow everything (dev only).
	if !freekassa.IPAllowed(c.RealIP(), cfg.IPWhitelist) {
		h.Logger.Warn("freekassa webhook: ip not allowed", zap.String("ip", c.RealIP()))
		return c.String(http.StatusForbidden, "forbidden")
	}

	// 2. Parse form payload. Echo's Bind on form data is awkward — pull the
	// fields by name so we keep exact control over signature inputs.
	if err := c.Request().ParseForm(); err != nil {
		h.Logger.Warn("freekassa webhook: parse form", zap.Error(err))
		return c.String(http.StatusBadRequest, "bad form")
	}
	form := c.Request().Form
	payload := freekassa.WebhookPayload{
		MerchantID:      form.Get("MERCHANT_ID"),
		Amount:          form.Get("AMOUNT"),
		MerchantOrderID: form.Get("MERCHANT_ORDER_ID"),
		IntID:           form.Get("intid"),
		Sign:            form.Get("SIGN"),
		Email:           form.Get("P_EMAIL"),
	}

	if payload.MerchantID != cfg.ShopID {
		h.Logger.Warn("freekassa webhook: wrong merchant",
			zap.String("got", payload.MerchantID),
			zap.String("want", cfg.ShopID),
		)
		return c.String(http.StatusForbidden, "wrong merchant")
	}

	// 3. Signature must match. FreeKassa computes against the exact amount
	// string they sent us, so we pass it verbatim.
	if !freekassa.VerifyWebhookSignature(
		payload.MerchantID, payload.Amount, payload.MerchantOrderID, payload.Sign, cfg.Secret2,
	) {
		h.Logger.Warn("freekassa webhook: bad signature",
			zap.String("order_id", payload.MerchantOrderID),
		)
		return c.String(http.StatusForbidden, "bad signature")
	}

	// 3.5. quupbot orders (qb_ prefix): relay to quupbot's own webhook receiver instead
	// of processing here. quupbot shares this project's FreeKassa shopId — see
	// freekassa.QuupbotForwarder's doc comment for why one shopId needs this routing.
	// Feature-gated: h.QuupbotForwarder is nil unless configured, in which case this
	// behaves exactly like the pre-existing "non-app payment id" branch below.
	if freekassa.IsQuupbotPayment(payload.MerchantOrderID) {
		if h.QuupbotForwarder == nil {
			h.Logger.Warn("freekassa webhook: quupbot order but forwarder not configured",
				zap.String("order_id", payload.MerchantOrderID))
			return c.String(http.StatusOK, "YES")
		}
		switch fwdErr := h.QuupbotForwarder.Forward(c.Request().Context(), form); {
		case fwdErr == nil:
			return c.String(http.StatusOK, "YES")
		case errors.Is(fwdErr, freekassa.ErrForwardRejected):
			// Permanent: quupbot examined the payment and rejected it (amount mismatch,
			// unknown order, ...). Don't tell FreeKassa to keep retrying.
			h.Logger.Warn("freekassa webhook: quupbot forward rejected",
				zap.String("order_id", payload.MerchantOrderID), zap.Error(fwdErr))
			return c.String(http.StatusBadRequest, "ERR")
		default:
			// Transient: quupbot unreachable/erroring. Let FreeKassa retry; this is NOT
			// a chameleon payment failure, so it's logged at Warn, not Error/alerted.
			h.Logger.Warn("freekassa webhook: quupbot forward unavailable",
				zap.String("order_id", payload.MerchantOrderID), zap.Error(fwdErr))
			return c.String(http.StatusServiceUnavailable, "ERR")
		}
	}

	// 4. Route by paymentId prefix. Bot payments are handled elsewhere
	// (future proxy). App payments continue below.
	if !freekassa.IsAppPayment(payload.MerchantOrderID) {
		h.Logger.Warn("freekassa webhook: non-app payment id",
			zap.String("order_id", payload.MerchantOrderID),
		)
		// Return YES so FK stops retrying — the payment just isn't ours.
		return c.String(http.StatusOK, "YES")
	}

	parsed, err := freekassa.ParseAppPayment(payload.MerchantOrderID)
	if err != nil {
		h.Logger.Error("freekassa webhook: parse payment id",
			zap.Error(err),
			zap.String("order_id", payload.MerchantOrderID),
		)
		return c.String(http.StatusBadRequest, "bad order id")
	}

	plan, ok := findPlan(h.Config.Payments.Plans, parsed.PlanID)
	if !ok {
		h.Logger.Error("freekassa webhook: unknown plan",
			zap.String("plan", parsed.PlanID),
			zap.String("order_id", payload.MerchantOrderID),
		)
		return c.String(http.StatusBadRequest, "unknown plan")
	}

	// PROMO-CODES: a discounted order persisted a payment_intent at initiate
	// time carrying the expected (discounted) amount + the code to redeem.
	// Full-price orders have no intent → fall back to the plan price.
	wctx := c.Request().Context()
	expectedRub := plan.PriceRub
	intent, ierr := h.DB.GetPaymentIntent(wctx, payload.MerchantOrderID)
	if ierr != nil {
		h.Logger.Warn("freekassa webhook: load payment intent", zap.Error(ierr),
			zap.String("order_id", payload.MerchantOrderID))
	} else if intent != nil {
		expectedRub = intent.AmountRub
	}

	// Amount sanity check — reject if the paid amount is less than EXPECTED
	// (the discounted amount for a promo order, else the plan price). We accept
	// overpayment (unlikely but harmless) rather than rejecting on rounding.
	if paidAmount, ok := parseAmount(payload.Amount); ok {
		if paidAmount+1 < expectedRub {
			h.Logger.Warn("freekassa webhook: amount mismatch",
				zap.Int("paid", paidAmount),
				zap.Int("expected", expectedRub),
			)
			return c.String(http.StatusBadRequest, "amount mismatch")
		}
	}

	// amountMinor = rubles * 100 (kopecks) of what was actually charged.
	amountMinor := int64(expectedRub) * 100

	metadata, _ := json.Marshal(map[string]any{
		"payment_id": payload.MerchantOrderID,
		"intid":      payload.IntID,
		"email":      payload.Email,
		"plan_id":    parsed.PlanID,
	})

	// charge_id is the FK intid — stable across retries. If intid is empty
	// fall back to the order id so duplicate protection still holds.
	chargeID := payload.IntID
	if chargeID == "" {
		chargeID = payload.MerchantOrderID
	}

	alreadyApplied, err := h.Payments.CreditDays(c.Request().Context(), payments.Credit{
		UserID:       parsed.UserID,
		Source:       payments.SourceFreeKassa,
		Provider:     "fk",
		ChargeID:     chargeID,
		Days:         plan.Days,
		AmountMinor:  amountMinor,
		Currency:     "RUB",
		MetadataJSON: metadata,
	})
	if err != nil {
		h.Logger.Error("freekassa webhook: credit days",
			zap.Error(err),
			zap.Int64("user_id", parsed.UserID),
			zap.String("charge_id", chargeID),
		)
		if h.Metrics != nil {
			h.Metrics.CountPayment("freekassa", "failed")
		}
		// Respond with non-YES so FK retries.
		return c.String(http.StatusInternalServerError, "credit failed")
	}
	if h.Metrics != nil && !alreadyApplied {
		h.Metrics.CountPayment("freekassa", "completed")
	}

	// PROMO-CODES: record the redemption (+ bump used_count) once, on the first
	// successful credit. Idempotent at the DB level, and best-effort here — a
	// failure must not fail the webhook (the user already paid + got credited).
	if intent != nil && intent.PromoCodeID != nil && !alreadyApplied {
		if err := h.DB.RedeemPromo(wctx, *intent.PromoCodeID, parsed.UserID, payload.MerchantOrderID); err != nil {
			h.Logger.Warn("promo: redeem", zap.Error(err),
				zap.Int64("user_id", parsed.UserID), zap.Int64("promo_code_id", *intent.PromoCodeID))
		}
	}

	h.Logger.Info("freekassa webhook: credited",
		zap.Int64("user_id", parsed.UserID),
		zap.String("plan", parsed.PlanID),
		zap.Int("days", plan.Days),
		zap.Bool("already_applied", alreadyApplied),
	)

	return c.String(http.StatusOK, "YES")
}

// parseAmount turns "249.00" / "249" into 249.
func parseAmount(s string) (int, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	if dot := strings.IndexByte(s, '.'); dot >= 0 {
		s = s[:dot]
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}

// ensure config import is used even if other symbols are pruned.
var _ = config.PlanConfig{}

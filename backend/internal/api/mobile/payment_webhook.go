package mobile

import (
	"encoding/json"
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

	// Amount sanity check — reject if the paid amount is less than what
	// the plan should cost. We accept overpayment (unlikely but harmless)
	// rather than rejecting borderline cases over rounding.
	if paidAmount, ok := parseAmount(payload.Amount); ok {
		if paidAmount+1 < plan.PriceRub {
			h.Logger.Warn("freekassa webhook: amount mismatch",
				zap.Int("paid", paidAmount),
				zap.Int("expected", plan.PriceRub),
			)
			return c.String(http.StatusBadRequest, "amount mismatch")
		}
	}

	// amountMinor = rubles * 100 (kopecks). Use the plan price since the
	// FK amount is a formatted decimal string — converting it here just
	// to store kopecks isn't worth the rounding risk.
	amountMinor := int64(plan.PriceRub) * 100

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
		// Respond with non-YES so FK retries.
		return c.String(http.StatusInternalServerError, "credit failed")
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

package mobile

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/payments/freekassa"
)

// InitiatePaymentRequest is the body for POST /api/mobile/payment/initiate.
//
// Plan is a stable id from GET /plans (e.g. "m1"). Method is one of "sbp",
// "card", "sberpay". Email is the receipt address — required by 54-FZ and
// persisted on the user row for future charges.
type InitiatePaymentRequest struct {
	Plan   string `json:"plan"`
	Method string `json:"method"`
	Email  string `json:"email"`
}

// InitiatePaymentResponse tells the iOS client where to send the user.
// PaymentURL is the FreeKassa checkout URL — the client opens it in an
// EXTERNAL Safari (not SFSafariViewController) so that Apple treats it as
// "user visited a website", not "in-app purchase".
type InitiatePaymentResponse struct {
	PaymentID  string `json:"payment_id"`
	PaymentURL string `json:"payment_url"`
	Amount     int    `json:"amount"`
	Currency   string `json:"currency"`
	Days       int    `json:"days"`
}

// InitiatePayment handles POST /api/mobile/payment/initiate.
//
// Flow:
//  1. Validate plan/method/email.
//  2. Persist email on the user row (used for future purchases too).
//  3. Build an app_{plan}_{user}_{nonce} payment id.
//  4. Call FreeKassa /orders/create with the client's real IP.
//  5. Return the location URL to the client for Safari redirect.
func (h *Handler) InitiatePayment(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	if h.FreeKassa == nil {
		return c.JSON(http.StatusServiceUnavailable, ErrorResponse{Error: "payments not configured"})
	}

	var req InitiatePaymentRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}
	req.Plan = strings.TrimSpace(req.Plan)
	req.Method = strings.TrimSpace(strings.ToLower(req.Method))
	req.Email = strings.TrimSpace(req.Email)

	if req.Plan == "" || req.Method == "" || req.Email == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "plan, method, email are required"})
	}
	if !strings.Contains(req.Email, "@") {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid email"})
	}

	plan, ok := findPlan(h.Config.Payments.Plans, req.Plan)
	if !ok {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "unknown plan"})
	}

	method, ok := freekassa.ParseMethod(req.Method)
	if !ok {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "unsupported method"})
	}

	ctx := c.Request().Context()

	if err := h.DB.SetUserEmail(ctx, claims.UserID, req.Email); err != nil {
		h.Logger.Warn("payments: save email", zap.Error(err), zap.Int64("user_id", claims.UserID))
		// Non-fatal — continue with the order.
	}

	clientIP := c.RealIP()
	if clientIP == "" || clientIP == "127.0.0.1" || clientIP == "::1" {
		// FreeKassa rejects loopback addresses. Fall back to a non-loopback
		// literal so local testing can still reach the API — production
		// requests always carry a real IP via X-Forwarded-For.
		clientIP = "8.8.8.8"
	}

	paymentID := freekassa.AppPaymentID(plan.ID, claims.UserID, time.Now().UnixNano())

	order, err := h.FreeKassa.CreateOrder(ctx, freekassa.CreateOrderInput{
		PaymentID: paymentID,
		Method:    method,
		Email:     req.Email,
		IP:        clientIP,
		Amount:    plan.PriceRub,
	})
	if err != nil {
		h.Logger.Error("freekassa: create order",
			zap.Error(err),
			zap.Int64("user_id", claims.UserID),
			zap.String("plan", plan.ID),
		)
		return c.JSON(http.StatusBadGateway, ErrorResponse{Error: "payment provider error"})
	}

	h.Logger.Info("payment initiated",
		zap.Int64("user_id", claims.UserID),
		zap.String("plan", plan.ID),
		zap.String("method", req.Method),
		zap.String("payment_id", paymentID),
		zap.Int64("fk_order_id", order.OrderID),
	)

	return c.JSON(http.StatusOK, InitiatePaymentResponse{
		PaymentID:  paymentID,
		PaymentURL: order.Location,
		Amount:     plan.PriceRub,
		Currency:   "RUB",
		Days:       plan.Days,
	})
}

// PaymentStatusResponse is the body for GET /api/mobile/payment/status/:payment_id.
// Status is "pending" until the FreeKassa webhook credits the ledger, then
// flips to "completed". The iOS client polls this while the user is in the
// browser paying.
type PaymentStatusResponse struct {
	Status             string `json:"status"` // "pending" | "completed"
	SubscriptionExpiry int64  `json:"subscription_expiry,omitempty"`
}

// PaymentStatus handles GET /api/mobile/payment/status/:payment_id.
//
// Authorization: the caller's JWT must match the user id encoded in the
// payment_id — we don't want users polling each other's orders.
func (h *Handler) PaymentStatus(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	paymentID := c.Param("payment_id")
	parsed, err := freekassa.ParseAppPayment(paymentID)
	if err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid payment id"})
	}
	if parsed.UserID != claims.UserID {
		return c.JSON(http.StatusForbidden, ErrorResponse{Error: "not your payment"})
	}

	ctx := c.Request().Context()

	// Check the payments ledger for a row tagged with this payment id. We
	// look via metadata->>'payment_id' so one query works regardless of
	// whether the webhook has filled in the real FreeKassa intid yet.
	var found bool
	err = h.DB.Pool.QueryRow(ctx,
		`SELECT 1 FROM payments
		 WHERE source = 'freekassa'
		   AND user_id = $1
		   AND metadata->>'payment_id' = $2
		 LIMIT 1`,
		claims.UserID, paymentID,
	).Scan(new(int))
	switch {
	case err == nil:
		found = true
	case errors.Is(err, pgx.ErrNoRows):
		found = false
	default:
		h.Logger.Error("payments: status query", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	resp := PaymentStatusResponse{Status: "pending"}
	if found {
		resp.Status = "completed"
		user, err := h.DB.FindUserByID(ctx, claims.UserID)
		if err == nil && user != nil && user.SubscriptionExpiry != nil {
			resp.SubscriptionExpiry = user.SubscriptionExpiry.Unix()
		}
	}
	return c.JSON(http.StatusOK, resp)
}

// findPlan returns the plan config with the given id, or ok=false.
func findPlan(plans []config.PlanConfig, id string) (config.PlanConfig, bool) {
	for _, p := range plans {
		if p.ID == id {
			return p, true
		}
	}
	return config.PlanConfig{}, false
}

package mobile

import (
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

// --- Request / Response types ------------------------------------------------

// VerifySubscriptionRequest is the body for POST /api/mobile/subscription/verify.
type VerifySubscriptionRequest struct {
	TransactionID string `json:"transaction_id"`
	ProductID     string `json:"product_id"`
}

// SubscriptionResponse is the response for subscription verification.
type SubscriptionResponse struct {
	Status             string `json:"status"`              // "active", "expired", "unknown"
	ProductID          string `json:"product_id"`          // echoed back
	SubscriptionExpiry int64  `json:"subscription_expiry"` // unix timestamp
}

// productDurations maps exact App Store product IDs to subscription durations.
// Keys must match exactly — no substring matching.
var productDurations = map[string]time.Duration{
	"com.chameleonvpn.monthly":  30 * 24 * time.Hour,
	"com.chameleonvpn.yearly":   365 * 24 * time.Hour,
	"com.chameleonvpn.weekly":   7 * 24 * time.Hour,
	"com.chameleonvpn.lifetime": 100 * 365 * 24 * time.Hour, // ~100 years
}

// --- Handler -----------------------------------------------------------------

// VerifySubscription handles POST /api/mobile/subscription/verify.
//
// TODO: Implement Apple Server API v2 verification.
// Currently this is a placeholder that trusts the client-provided transaction_id
// and updates the subscription expiry based on the product_id.
// In production, the transaction_id MUST be verified against Apple's servers
// before granting access.
func (h *Handler) VerifySubscription(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	var req VerifySubscriptionRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}

	req.TransactionID = strings.TrimSpace(req.TransactionID)
	req.ProductID = strings.TrimSpace(req.ProductID)

	if req.TransactionID == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "transaction_id is required"})
	}
	if req.ProductID == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "product_id is required"})
	}

	// Map product_id to duration (exact match only).
	duration, ok := productDurations[req.ProductID]
	if !ok {
		h.Logger.Warn("unknown product_id",
			zap.String("product_id", req.ProductID),
			zap.Int64("user_id", claims.UserID),
		)
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "unknown product_id"})
	}

	ctx := c.Request().Context()

	// Load user from DB.
	user, err := h.DB.FindUserByID(ctx, claims.UserID)
	if err != nil {
		h.Logger.Error("db: find user by id", zap.Error(err), zap.Int64("user_id", claims.UserID))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	if user == nil {
		return c.JSON(http.StatusNotFound, ErrorResponse{Error: "user not found"})
	}

	// TODO: Verify transaction_id against Apple Server API v2.
	// Steps:
	//   1. Call https://api.storekit.itunes.apple.com/inApps/v1/transactions/{transactionId}
	//   2. Verify the signed transaction (JWS) using Apple's public key
	//   3. Check that the transaction belongs to this user's app
	//   4. Check that the product_id matches
	//   5. Only then update the subscription
	//
	// For now, we trust the client. This MUST be replaced before production.

	// Calculate new expiry: extend from current expiry if still active, or from now.
	var newExpiry time.Time
	if user.SubscriptionExpiry != nil && user.SubscriptionExpiry.After(time.Now()) {
		newExpiry = user.SubscriptionExpiry.Add(duration)
	} else {
		newExpiry = time.Now().Add(duration)
	}

	// Update user in DB.
	user.SubscriptionExpiry = &newExpiry
	user.OriginalTransactionID = &req.TransactionID
	user.AppStoreProductID = &req.ProductID

	if err := h.DB.UpdateUser(ctx, user); err != nil {
		h.Logger.Error("db: update user subscription", zap.Error(err), zap.Int64("user_id", user.ID))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	h.Logger.Info("subscription verified",
		zap.Int64("user_id", user.ID),
		zap.String("product_id", req.ProductID),
		zap.String("transaction_id", req.TransactionID),
		zap.Time("new_expiry", newExpiry),
	)

	return c.JSON(http.StatusOK, SubscriptionResponse{
		Status:             "active",
		ProductID:          req.ProductID,
		SubscriptionExpiry: newExpiry.Unix(),
	})
}

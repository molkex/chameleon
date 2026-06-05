// Package mobile — promo.go: PROMO-CODES client surface. The paywall calls
// ValidatePromo to preview a discount; InitiatePayment (payment.go) reuses
// resolvePromo to charge the discounted amount.
package mobile

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/promo"
)

// resolvePromo validates rawCode for userID against plan. An empty code is the
// no-discount happy path: (nil, plan price, OK). A present-but-invalid code
// returns the failing reason and the UNDISCOUNTED price.
func (h *Handler) resolvePromo(ctx context.Context, rawCode string, userID int64, plan config.PlanConfig) (*db.PromoCode, int, promo.Reason, error) {
	code := promo.Normalize(rawCode)
	if code == "" {
		return nil, plan.PriceRub, promo.OK, nil
	}
	pc, err := h.DB.GetPromoByCode(ctx, code)
	if err != nil {
		return nil, plan.PriceRub, "", err
	}
	redeemed := false
	if pc != nil {
		if redeemed, err = h.DB.HasUserRedeemed(ctx, pc.ID, userID); err != nil {
			return nil, plan.PriceRub, "", err
		}
	}
	var view *promo.Code
	if pc != nil {
		view = pc.ToPromo()
	}
	if reason := promo.Validate(view, time.Now(), redeemed); reason != promo.OK {
		return nil, plan.PriceRub, reason, nil
	}
	return pc, promo.DiscountedPrice(plan.PriceRub, pc.DiscountPct), promo.OK, nil
}

// ValidatePromoRequest — body for POST /api/mobile/payment/promo/validate.
type ValidatePromoRequest struct {
	Code string `json:"code"`
	Plan string `json:"plan"`
}

// ValidatePromoResponse previews the effect of a code on a plan.
type ValidatePromoResponse struct {
	Valid       bool   `json:"valid"`
	Message     string `json:"message"`
	DiscountPct int    `json:"discount_pct,omitempty"`
	OriginalRub int    `json:"original_rub"`
	PriceRub    int    `json:"price_rub"`
}

// ValidatePromo handles POST /api/mobile/payment/promo/validate — preview only,
// no charge. The paywall calls it to show the discounted price before paying.
func (h *Handler) ValidatePromo(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}
	var req ValidatePromoRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}
	plan, ok := findPlan(h.Config.Payments.Plans, strings.TrimSpace(req.Plan))
	if !ok {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "unknown plan"})
	}
	pc, price, reason, err := h.resolvePromo(c.Request().Context(), req.Code, claims.UserID, plan)
	if err != nil {
		h.Logger.Error("promo: validate", zap.Error(err), zap.Int64("user_id", claims.UserID))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}
	if reason != promo.OK {
		return c.JSON(http.StatusOK, ValidatePromoResponse{
			Valid: false, Message: reason.Message(), OriginalRub: plan.PriceRub, PriceRub: plan.PriceRub,
		})
	}
	return c.JSON(http.StatusOK, ValidatePromoResponse{
		Valid: true, Message: promo.OK.Message(), DiscountPct: pc.DiscountPct,
		OriginalRub: plan.PriceRub, PriceRub: price,
	})
}

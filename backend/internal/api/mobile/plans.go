package mobile

import (
	"net/http"

	"github.com/labstack/echo/v4"
)

// Plan is the mobile-facing description of a purchasable plan. Mirrors
// config.PlanConfig but intentionally excludes backend-only knobs.
type Plan struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Days     int    `json:"days"`
	PriceRub int    `json:"price_rub"`
	Badge    string `json:"badge,omitempty"`
}

// PlansResponse is the body for GET /api/mobile/plans.
type PlansResponse struct {
	Plans    []Plan   `json:"plans"`
	Methods  []string `json:"methods"` // "sbp", "card", "sberpay" — whichever are enabled
	Currency string   `json:"currency"`
}

// GetPlans returns the public catalog of paid plans. No auth required — the
// iOS app hits this before sign-in to render the paywall.
func (h *Handler) GetPlans(c echo.Context) error {
	src := h.Config.Payments.Plans
	out := make([]Plan, 0, len(src))
	for _, p := range src {
		out = append(out, Plan{
			ID:       p.ID,
			Title:    p.Title,
			Days:     p.Days,
			PriceRub: p.PriceRub,
			Badge:    p.Badge,
		})
	}

	methods := []string{}
	if h.Config.Payments.FreeKassa.Enabled {
		methods = []string{"sbp", "card", "sberpay"}
	}

	return c.JSON(http.StatusOK, PlansResponse{
		Plans:    out,
		Methods:  methods,
		Currency: "RUB",
	})
}

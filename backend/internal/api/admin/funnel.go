package admin

import (
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// USR-09 Phase 1: SQL-derived funnel from existing tables.
//
// Backend has enough data in `users` + `payments` to compute signups,
// DAU, auth-provider mix, payment conversion, and 4-week retention
// cohorts without any iOS instrumentation. Phase 2 layers paywall.view /
// purchase.cancel / connect.fail on top once iOS ships its end of
// `/mobile/events`.

type dailyCountResp struct {
	Day   string `json:"day"` // YYYY-MM-DD
	Count int64  `json:"count"`
}

type authBreakdownResp struct {
	Provider string `json:"provider"`
	Count    int64  `json:"count"`
}

type conversionResp struct {
	Signups            int64   `json:"signups"`
	ConvertedAny       int64   `json:"converted_any"`
	ConvertedApple     int64   `json:"converted_apple"`
	ConvertedFreeKassa int64   `json:"converted_freekassa"`
	ConversionPct      float64 `json:"conversion_pct"` // 0..100
	AvgDaysToConvert   float64 `json:"avg_days_to_convert"`
}

type cohortCellResp struct {
	WeekStart   string  `json:"week_start"` // YYYY-MM-DD (Monday)
	Size        int64   `json:"size"`
	WeeksAfter  int     `json:"weeks_after"`
	StillActive int64   `json:"still_active"`
	Rate        float64 `json:"rate"` // 0..1, derived for SPA convenience
}

type funnelResponse struct {
	WindowDays  int                 `json:"window_days"`
	Signups     []dailyCountResp    `json:"signups_per_day"`
	DAU         []dailyCountResp    `json:"dau_per_day"`
	Auth        []authBreakdownResp `json:"auth_breakdown"`
	Conversion  conversionResp      `json:"conversion"`
	Cohorts     []cohortCellResp    `json:"cohorts"`
	GeneratedAt string              `json:"generated_at"`
}

// Funnel handles GET /api/v1/admin/stats/funnel?days=N.
//
// Single query against the DB layer; the heavy work lives in
// db.FunnelSeries. Open to admin / operator / viewer like the other
// /stats reads — no PII in the payload, just aggregates.
func (h *Handler) Funnel(c echo.Context) error {
	days, _ := strconv.Atoi(c.QueryParam("days"))

	summary, err := h.DB.FunnelSeries(c.Request().Context(), days)
	if err != nil {
		h.Logger.Error("admin: funnel series", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to compute funnel")
	}

	signups := make([]dailyCountResp, 0, len(summary.Signups))
	for _, d := range summary.Signups {
		signups = append(signups, dailyCountResp{Day: d.Day.Format("2006-01-02"), Count: d.Count})
	}
	dau := make([]dailyCountResp, 0, len(summary.DAU))
	for _, d := range summary.DAU {
		dau = append(dau, dailyCountResp{Day: d.Day.Format("2006-01-02"), Count: d.Count})
	}
	auth := make([]authBreakdownResp, 0, len(summary.Auth))
	for _, a := range summary.Auth {
		auth = append(auth, authBreakdownResp{Provider: a.Provider, Count: a.Count})
	}

	conv := conversionResp{
		Signups:            summary.Conversion.Signups,
		ConvertedAny:       summary.Conversion.ConvertedAny,
		ConvertedApple:     summary.Conversion.ConvertedApple,
		ConvertedFreeKassa: summary.Conversion.ConvertedFreekassa,
		AvgDaysToConvert:   math.Round(summary.Conversion.AvgDaysToConvert*10) / 10,
	}
	if conv.Signups > 0 {
		conv.ConversionPct = math.Round(float64(conv.ConvertedAny)*1000/float64(conv.Signups)) / 10
	}

	cohorts := make([]cohortCellResp, 0, len(summary.Cohorts))
	for _, r := range summary.Cohorts {
		row := cohortCellResp{
			WeekStart:   r.CohortWeekStart.Format("2006-01-02"),
			Size:        r.CohortSize,
			WeeksAfter:  r.WeeksAfter,
			StillActive: r.StillActive,
		}
		if r.CohortSize > 0 {
			row.Rate = math.Round(float64(r.StillActive)/float64(r.CohortSize)*1000) / 1000
		}
		cohorts = append(cohorts, row)
	}

	return c.JSON(http.StatusOK, funnelResponse{
		WindowDays:  summary.WindowDays,
		Signups:     signups,
		DAU:         dau,
		Auth:        auth,
		Conversion:  conv,
		Cohorts:     cohorts,
		GeneratedAt: summary.GeneratedAt.Format(time.RFC3339),
	})
}

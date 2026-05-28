package admin

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// USR-09 Phase 2: admin-side read of the iOS event-tracking stream.
//
// The mobile endpoint writes rows to `app_events`; this file exposes
// three read endpoints for the SPA's /admin/app/events page:
//
//   GET /api/v1/admin/events                    — paginated list + filters
//   GET /api/v1/admin/events/counts?days=N      — name × day aggregation
//   GET /api/v1/admin/events/names?days=N       — distinct names (filter dropdown)
//
// All three are open to admin / operator / viewer like the other
// reporting endpoints. The payload contains no PII beyond what
// `app_events` itself stores (user_id, ip, country, event names).

type appEventResp struct {
	ID         int64          `json:"id"`
	UserID     *int64         `json:"user_id,omitempty"`
	DeviceID   string         `json:"device_id,omitempty"`
	EventName  string         `json:"event_name"`
	Properties map[string]any `json:"properties,omitempty"`
	AppVersion string         `json:"app_version,omitempty"`
	Platform   string         `json:"platform,omitempty"`
	OccurredAt string         `json:"occurred_at"`
	ReceivedAt string         `json:"received_at"`
	IP         string         `json:"ip,omitempty"`
	Country    string         `json:"country,omitempty"`
}

type listEventsResponse struct {
	Total  int64          `json:"total"`
	Page   int            `json:"page"`
	Size   int            `json:"page_size"`
	Events []appEventResp `json:"events"`
}

// ListAppEvents handles GET /api/v1/admin/events with optional filters:
//
//   user_id     — numeric, exact
//   event_name  — exact match
//   since/until — RFC3339, inclusive/exclusive bounds on occurred_at
//   page / page_size — 1-indexed, page_size clamped [1, 500]
func (h *Handler) ListAppEvents(c echo.Context) error {
	filter := db.AppEventFilter{}

	if v := strings.TrimSpace(c.QueryParam("user_id")); v != "" {
		if id, err := strconv.ParseInt(v, 10, 64); err == nil {
			filter.UserID = &id
		}
	}
	if v := strings.TrimSpace(c.QueryParam("event_name")); v != "" {
		filter.EventName = v
	}
	if v := strings.TrimSpace(c.QueryParam("since")); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			filter.Since = t
		}
	}
	if v := strings.TrimSpace(c.QueryParam("until")); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			filter.Until = t
		}
	}

	page, _ := strconv.Atoi(c.QueryParam("page"))
	if page < 1 {
		page = 1
	}
	size, _ := strconv.Atoi(c.QueryParam("page_size"))
	if size <= 0 {
		size = 50
	}
	filter.Limit = size
	filter.Offset = (page - 1) * size

	events, total, err := h.DB.ListAppEvents(c.Request().Context(), filter)
	if err != nil {
		h.Logger.Error("admin: list app events", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list events")
	}

	out := make([]appEventResp, 0, len(events))
	for _, e := range events {
		out = append(out, appEventResp{
			ID:         e.ID,
			UserID:     e.UserID,
			DeviceID:   e.DeviceID,
			EventName:  e.EventName,
			Properties: e.Properties,
			AppVersion: e.AppVersion,
			Platform:   e.Platform,
			OccurredAt: e.OccurredAt.Format(time.RFC3339),
			ReceivedAt: e.ReceivedAt.Format(time.RFC3339),
			IP:         e.IP,
			Country:    e.Country,
		})
	}

	return c.JSON(http.StatusOK, listEventsResponse{
		Total:  total,
		Page:   page,
		Size:   size,
		Events: out,
	})
}

type eventCountResp struct {
	EventName string `json:"event_name"`
	Day       string `json:"day"` // YYYY-MM-DD
	Count     int64  `json:"count"`
}

type listCountsResponse struct {
	Days   int              `json:"days"`
	Counts []eventCountResp `json:"counts"`
}

// AppEventCounts handles GET /api/v1/admin/events/counts?days=N.
//
// Returns one row per (event_name, calendar day UTC) tuple over the
// trailing window. Used by the SPA chart on the events page.
func (h *Handler) AppEventCounts(c echo.Context) error {
	days, _ := strconv.Atoi(c.QueryParam("days"))
	rows, err := h.DB.CountAppEventsByNameDaily(c.Request().Context(), days)
	if err != nil {
		h.Logger.Error("admin: app event counts", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to count events")
	}
	out := make([]eventCountResp, 0, len(rows))
	for _, r := range rows {
		out = append(out, eventCountResp{
			EventName: r.EventName,
			Day:       r.Day.Format("2006-01-02"),
			Count:     r.Count,
		})
	}
	if days <= 0 {
		days = 30
	}
	return c.JSON(http.StatusOK, listCountsResponse{Days: days, Counts: out})
}

type listNamesResponse struct {
	Names []string `json:"names"`
}

// AppEventNames handles GET /api/v1/admin/events/names?days=N.
//
// Returns the union of event_name values seen at least once in the
// trailing window. Used by the SPA filter dropdown.
func (h *Handler) AppEventNames(c echo.Context) error {
	days, _ := strconv.Atoi(c.QueryParam("days"))
	names, err := h.DB.DistinctEventNames(c.Request().Context(), days)
	if err != nil {
		h.Logger.Error("admin: app event names", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list names")
	}
	return c.JSON(http.StatusOK, listNamesResponse{Names: names})
}

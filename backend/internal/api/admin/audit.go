package admin

import (
	"net/http"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
)

// recordAudit is the single entry point for writing admin_audit_log rows
// from inside admin handlers. Audit MED-014 (2026-05-27).
//
// It is fire-and-forget from the request's perspective: any failure to
// persist the audit row is logged but never propagated, because a broken
// audit table must not take down the admin panel. The audit insert reuses
// the request context so it shares the lifetime of the handler call —
// this is OK because the insert is sub-millisecond on a healthy DB and
// the handler will not return before it completes (we want serialised
// ordering of "action happened" then "audit row written").
//
// `details` is free-form: callers should include the targeted resource ID
// or any value relevant for forensics. Do NOT include secrets (passwords,
// tokens) — admin_audit_log is plain TEXT.
func (h *Handler) recordAudit(c echo.Context, action, details string) {
	var adminID *int64
	if claims := auth.GetUserFromContext(c); claims != nil && claims.UserID != 0 {
		uid := claims.UserID
		adminID = &uid
	}

	event := db.AuditEvent{
		AdminUserID: adminID,
		Action:      action,
		IP:          c.RealIP(),
		UserAgent:   c.Request().UserAgent(),
		Details:     details,
	}

	if err := h.DB.LogAuditEvent(c.Request().Context(), event); err != nil {
		// Log but never fail the request. If the audit table is broken
		// we still want the admin action to succeed.
		h.Logger.Error("audit log write failed",
			zap.String("action", action),
			zap.Error(err))
	}
}

// auditRowResponse is the SPA-facing shape for one admin_audit_log row.
// All fields are JSON-safe (no *int64 / *time.Time on the wire) so the
// React side can render without null-juggling.
type auditRowResponse struct {
	ID            int64  `json:"id"`
	AdminUserID   *int64 `json:"admin_user_id"`
	AdminUsername string `json:"admin_username"`
	Action        string `json:"action"`
	IP            string `json:"ip"`
	UserAgent     string `json:"user_agent"`
	Details       string `json:"details"`
	CreatedAt     string `json:"created_at"`
}

type listAuditResponse struct {
	Events   []auditRowResponse `json:"events"`
	Total    int64              `json:"total"`
	Page     int                `json:"page"`
	PageSize int                `json:"page_size"`
}

// ListAuditEvents handles GET /api/v1/admin/audit
//
// Query params: page, page_size (clamped backend-side), admin_id, action,
// since (RFC3339), until (RFC3339). Bad query values fall through to the
// unfiltered default rather than 400 — operators paste timestamps from
// chat all day and we don't want them to learn the parser rules.
func (h *Handler) ListAuditEvents(c echo.Context) error {
	ctx := c.Request().Context()

	page, _ := strconv.Atoi(c.QueryParam("page"))
	pageSize, _ := strconv.Atoi(c.QueryParam("page_size"))

	var filter db.AuditFilter
	if s := c.QueryParam("admin_id"); s != "" {
		if id, err := strconv.ParseInt(s, 10, 64); err == nil {
			filter.AdminUserID = &id
		}
	}
	if s := c.QueryParam("action"); s != "" {
		filter.Action = s
	}
	if s := c.QueryParam("since"); s != "" {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			filter.Since = &t
		}
	}
	if s := c.QueryParam("until"); s != "" {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			filter.Until = &t
		}
	}

	events, total, err := h.DB.ListAuditEvents(ctx, filter, page, pageSize)
	if err != nil {
		h.Logger.Error("admin: list audit events", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list audit events")
	}

	out := make([]auditRowResponse, 0, len(events))
	for _, e := range events {
		row := auditRowResponse{
			ID:          e.ID,
			AdminUserID: e.AdminUserID,
			Action:      e.Action,
			IP:          e.IP,
			UserAgent:   e.UserAgent,
			Details:     e.Details,
			CreatedAt:   e.CreatedAt.UTC().Format(time.RFC3339),
		}
		if e.AdminUsername != nil {
			row.AdminUsername = *e.AdminUsername
		}
		out = append(out, row)
	}

	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 50
	}
	if pageSize > 200 {
		pageSize = 200
	}

	return c.JSON(http.StatusOK, listAuditResponse{
		Events:   out,
		Total:    total,
		Page:     page,
		PageSize: pageSize,
	})
}

// ListAuditActions handles GET /api/v1/admin/audit/actions
//
// Returns the distinct `action` values seen in the last 90 days, used to
// populate the filter dropdown in the SPA without making the operator
// remember the exact verb-object string.
func (h *Handler) ListAuditActions(c echo.Context) error {
	actions, err := h.DB.ListAuditActions(c.Request().Context())
	if err != nil {
		h.Logger.Error("admin: list audit actions", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list audit actions")
	}
	return c.JSON(http.StatusOK, map[string][]string{"actions": actions})
}

// recordAuditForAdmin is the variant used during login flows where the
// admin ID is known but the JWT context isn't populated yet (the auth
// middleware runs after Login itself). Pass adminID=nil to record
// anonymously (e.g. failed-login attempts).
func (h *Handler) recordAuditForAdmin(c echo.Context, adminID *int64, action, details string) {
	event := db.AuditEvent{
		AdminUserID: adminID,
		Action:      action,
		IP:          c.RealIP(),
		UserAgent:   c.Request().UserAgent(),
		Details:     details,
	}

	if err := h.DB.LogAuditEvent(c.Request().Context(), event); err != nil {
		h.Logger.Error("audit log write failed",
			zap.String("action", action),
			zap.Error(err))
	}
}

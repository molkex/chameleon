package admin

import (
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

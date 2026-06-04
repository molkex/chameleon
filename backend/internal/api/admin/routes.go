// Package admin provides HTTP handlers for the Chameleon VPN admin API.
//
// All handlers are methods on the Handler struct, which holds shared
// dependencies (DB, Redis, JWT, VPN engine, config, logger).
package admin

import (
	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/asc"
	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/push"
	"github.com/chameleonvpn/chameleon/internal/storage"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Handler holds all dependencies needed by admin API handlers.
type Handler struct {
	DB             *db.DB
	Redis          *redis.Client
	JWT            *auth.JWTManager
	VPN            vpn.Engine // may be nil if VPN engine is not configured
	Payments       *payments.Service
	Config         *config.Config
	Logger         *zap.Logger
	ClusterSecret  string // shared secret for cluster peer requests

	// PrometheusURL is the base URL of the local Prometheus (MON-04). Used
	// by the /stats/infra endpoint to surface host + backend health in the
	// admin dashboard. Empty → defaults to http://127.0.0.1:9091 (the NL
	// bind from docker-compose). On boxes without Prometheus the endpoint
	// degrades to "unknown" fields rather than failing.
	PrometheusURL string

	// ASC may be nil when ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH env are
	// unset (e.g. dev box without Apple creds). Handlers should
	// degrade gracefully — Status page renders "ASC not configured"
	// rather than 500.
	ASC          *asc.Client
	ASCAppID     string // ASC_APP_ID — the App Store id for queries

	// Storage backs SUPPORT-CHAT attachments (B2 presigned URLs). nil ⇒
	// attachments disabled (presign returns 503, served messages omit them).
	Storage *storage.Client

	// Push sends APNs alerts to a client when an agent replies (SUPPORT-CHAT
	// P4). nil ⇒ push gracefully disabled (no env / creds) — SupportReply skips
	// the send. Built once in main.go via push.NewFromEnv().
	Push *push.Client
}

// RegisterRoutes adds admin API routes to the echo group.
//
// Route layout (all under the provided group prefix):
//
//	POST   /auth/login    — authenticate (no auth required)
//	POST   /auth/refresh  — refresh tokens (no auth required)
//	POST   /auth/logout   — clear auth cookie (no auth required)
//	GET    /auth/me       — current admin info (requires admin auth)
//
//	GET    /users          — list users (requires admin auth)
//	GET    /users/:id      — get single user (requires admin auth)
//	DELETE /users/:id      — soft-delete user (requires admin auth)
//	POST   /users/:id/extend — extend subscription (requires admin auth)
//
//	POST   /nodes/sync     — sync VPN config (requires admin auth)
//	GET    /nodes           — list nodes (requires admin auth)
//
//	GET    /stats           — basic VPN stats (requires admin auth)
//	GET    /stats/dashboard — full dashboard (requires admin auth)
//
//	GET    /servers              — list VPN servers (requires admin auth)
//	POST   /servers              — create VPN server (requires admin auth)
//	PUT    /servers/:id          — update VPN server (requires admin auth)
//	DELETE /servers/:id          — delete VPN server (requires admin auth)
//	POST   /servers/:id/credentials — reveal provider credentials (requires re-auth)
//
//	GET    /admins          — list admin users (requires admin auth)
//	POST   /admins          — create admin user (requires admin auth)
//	DELETE /admins/:id      — delete admin user (requires admin auth)
func RegisterRoutes(g *echo.Group, h *Handler, jwtManager *auth.JWTManager) {
	// Auth routes — no JWT middleware.
	authGroup := g.Group("/auth")
	authGroup.POST("/login", h.Login)
	authGroup.POST("/refresh", h.Refresh)
	authGroup.POST("/logout", h.Logout)

	// Auth check requires admin middleware (supports both header and cookie).
	authGroup.GET("/me", h.Me, CookieOrBearerAuth(jwtManager, h.DB))

	// All remaining routes require admin auth (admin/operator/viewer can read).
	// adminOnly is a stricter middleware applied on top of adminMW to
	// destructive/privileged endpoints — see RequireAdmin below.
	adminMW := CookieOrBearerAuth(jwtManager, h.DB)
	adminOnly := RequireAdmin()

	// Support inbox (SUPPORT-CHAT P3). Read + reply require an authenticated
	// admin (operator can answer clients); a reply fans out to the client's
	// live SSE via Redis. See admin/support.go.
	support := g.Group("/support", adminMW)
	support.GET("/threads", h.SupportThreads)
	support.GET("/threads/:id/messages", h.SupportThreadMessages)
	support.POST("/threads/:id/reply", h.SupportReply)
	support.POST("/threads/:id/attachments/presign", h.SupportAdminPresignUpload)

	// Users. List/get are read; delete/extend are destructive → admin only.
	users := g.Group("/users", adminMW)
	users.GET("", h.ListUsers)
	users.GET("/:id", h.GetUser)
	users.DELETE("/:id", h.DeleteUser, adminOnly)
	users.POST("/:id/extend", h.ExtendSubscription, adminOnly)

	// Nodes. Read endpoints open to viewer/operator; sync/restart admin-only.
	nodes := g.Group("/nodes", adminMW)
	nodes.POST("/sync", h.SyncConfig, adminOnly)
	nodes.POST("/restart-singbox", h.RestartSingbox, adminOnly)
	nodes.POST("/restart-xray", h.RestartSingbox, adminOnly) // backward compat
	g.GET("/nodes", h.ListNodes, adminMW)

	// Protocols / Shield.
	g.GET("/protocols", h.ListProtocols, adminMW)
	g.GET("/shield", h.GetShield, adminMW)

	// Stats.
	g.GET("/stats", h.GetStats, adminMW)
	g.GET("/stats/dashboard", h.GetDashboard, adminMW)
	g.GET("/stats/traffic-outliers", h.TrafficOutliers, adminMW)
	g.GET("/stats/funnel", h.Funnel, adminMW)
	// MON-04: infra/health strip for the dashboard — host CPU/RAM/disk +
	// backend golden signals (p95 latency, req/s, 5xx) + live VPN, all
	// sourced from the local Prometheus. See infra.go.
	g.GET("/stats/infra", h.GetInfra, adminMW)

	// Servers. Read open; CRUD admin-only.
	g.GET("/servers", h.ListServers, adminMW)
	g.POST("/servers", h.CreateServer, adminMW, adminOnly)
	g.PUT("/servers/:id", h.UpdateServer, adminMW, adminOnly)
	g.DELETE("/servers/:id", h.DeleteServer, adminMW, adminOnly)
	g.POST("/servers/:id/credentials", h.GetServerCredentials, adminMW, adminOnly)

	// Admin users management — entirely admin-only (privilege escalation).
	admins := g.Group("/admins", adminMW, adminOnly)
	admins.GET("", h.ListAdmins)
	admins.POST("", h.CreateAdmin)
	admins.DELETE("/:id", h.DeleteAdmin)

	// Audit log viewer. Read endpoints open to admin/operator/viewer —
	// the table holds no secrets (sensitive details are sanitised at write
	// time, see auditSafeUsername in mobile/auth.go and MED-014). Visibility
	// for non-admin operators / viewers is a feature: they review their own
	// actions and catch their teammates' destructive ones.
	audit := g.Group("/audit", adminMW)
	audit.GET("", h.ListAuditEvents)
	audit.GET("/actions", h.ListAuditActions)

	// Service status overview — MON-08. Aggregates live probes of internal
	// services (postgres / redis / singbox port) + outbound integrations
	// (Cloudflare-fronted hosts, SPB relay, Telegram bot) + recent infra
	// audit events. Each probe runs in parallel with its own 3s timeout
	// behind the handler's request context so a single hung dependency
	// doesn't stall the entire page load.
	g.GET("/status", h.GetStatus, adminMW)
	g.GET("/status/apple", h.GetAppleState, adminMW)
	g.GET("/status/handshake-errors", h.GetHandshakeErrors, adminMW)

	// App-event stream — USR-09 Phase 2 (2026-05-28). Reads from the
	// app_events table the mobile /events/batch endpoint populates.
	// Read-only; visible to admin/operator/viewer.
	events := g.Group("/events", adminMW)
	events.GET("", h.ListAppEvents)
	events.GET("/counts", h.AppEventCounts)
	events.GET("/names", h.AppEventNames)
}

// RequireAdmin returns middleware that allows only `admin` role through.
// Layered on top of CookieOrBearerAuth: the latter authenticates and admits
// any of admin/operator/viewer; this one enforces the destructive-action
// gate. Reading the claims is safe because CookieOrBearerAuth ran first.
func RequireAdmin() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			claims, _ := c.Get("auth_claims").(*auth.Claims)
			if claims == nil || claims.Role != "admin" {
				return echo.NewHTTPError(403, "admin role required")
			}
			return next(c)
		}
	}
}

// CookieOrBearerAuth returns Echo middleware that checks for admin auth
// via either the Authorization header (Bearer token) or the access_token cookie.
// This supports both the SPA (cookie-based) and API clients (bearer token).
//
// Audit H-010 (2026-05-26): if `database` is non-nil, every request also
// loads the admin row by claims.UserID and rejects when is_active=false.
// Without that load, a soft-deleted admin (DeleteAdmin sets is_active=false
// but does not invalidate tokens) keeps working until access-token expiry
// and can refresh up to refresh TTL. With it, off-boarding is immediate.
func CookieOrBearerAuth(jwtManager *auth.JWTManager, database *db.DB) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			// Try bearer token from Authorization header first.
			claims := auth.GetUserFromContext(c)
			if claims != nil {
				// Already authenticated by upstream middleware.
				return next(c)
			}

			// Try Authorization header.
			token := auth.ExtractBearerToken(c.Request())

			// If no header token, try cookie.
			if token == "" {
				cookie, err := c.Cookie("access_token")
				if err == nil && cookie.Value != "" {
					token = cookie.Value
				}
			}

			if token == "" {
				return echo.NewHTTPError(401, "unauthorized")
			}

			claimsResult, err := jwtManager.VerifyToken(token)
			if err != nil {
				return echo.NewHTTPError(401, "unauthorized")
			}

			// For admin endpoints, allow admin/operator/viewer roles.
			if claimsResult.Role != "admin" && claimsResult.Role != "operator" && claimsResult.Role != "viewer" {
				return echo.NewHTTPError(403, "forbidden")
			}

			// Audit H-010: reload from DB on every request. The JWT is
			// valid until expiry; DeleteAdmin sets is_active=false but
			// can't revoke already-issued tokens, so without this check
			// off-boarded admins keep working for up to access+refresh
			// TTL. Lookup failure also rejects — fail closed.
			if database != nil {
				ctx := c.Request().Context()
				admin, lookupErr := database.FindAdminByID(ctx, claimsResult.UserID)
				if lookupErr != nil || admin == nil || !admin.IsActive {
					return echo.NewHTTPError(401, "unauthorized")
				}
			}

			c.Set("auth_claims", claimsResult)
			return next(c)
		}
	}
}


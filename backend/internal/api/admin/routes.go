// Package admin provides HTTP handlers for the Chameleon VPN admin API.
//
// All handlers are methods on the Handler struct, which holds shared
// dependencies (DB, Redis, JWT, VPN engine, config, logger).
package admin

import (
	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/payments"
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
	authGroup.GET("/me", h.Me, CookieOrBearerAuth(jwtManager))

	// All remaining routes require admin auth (admin/operator/viewer can read).
	// adminOnly is a stricter middleware applied on top of adminMW to
	// destructive/privileged endpoints — see RequireAdmin below.
	adminMW := CookieOrBearerAuth(jwtManager)
	adminOnly := RequireAdmin()

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
func CookieOrBearerAuth(jwtManager *auth.JWTManager) echo.MiddlewareFunc {
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

			c.Set("auth_claims", claimsResult)
			return next(c)
		}
	}
}


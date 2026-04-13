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

	// All remaining routes require admin auth.
	adminMW := CookieOrBearerAuth(jwtManager)

	// Users.
	users := g.Group("/users", adminMW)
	users.GET("", h.ListUsers)
	users.GET("/:id", h.GetUser)
	users.DELETE("/:id", h.DeleteUser)
	users.POST("/:id/extend", h.ExtendSubscription)

	// Nodes.
	nodes := g.Group("/nodes", adminMW)
	nodes.POST("/sync", h.SyncConfig)
	nodes.POST("/restart-singbox", h.RestartSingbox)
	nodes.POST("/restart-xray", h.RestartSingbox) // backward compat
	g.GET("/nodes", h.ListNodes, adminMW)

	// Protocols / Shield.
	g.GET("/protocols", h.ListProtocols, adminMW)
	g.GET("/shield", h.GetShield, adminMW)

	// Stats.
	g.GET("/stats", h.GetStats, adminMW)
	g.GET("/stats/dashboard", h.GetDashboard, adminMW)

	// Servers.
	g.GET("/servers", h.ListServers, adminMW)
	g.POST("/servers", h.CreateServer, adminMW)
	g.PUT("/servers/:id", h.UpdateServer, adminMW)
	g.DELETE("/servers/:id", h.DeleteServer, adminMW)
	g.POST("/servers/:id/credentials", h.GetServerCredentials, adminMW)

	// Admin users management.
	admins := g.Group("/admins", adminMW)
	admins.GET("", h.ListAdmins)
	admins.POST("", h.CreateAdmin)
	admins.DELETE("/:id", h.DeleteAdmin)
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


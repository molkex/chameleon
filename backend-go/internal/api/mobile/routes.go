// Package mobile provides HTTP handlers for the Chameleon VPN mobile API.
//
// All handlers are methods on the Handler struct, which holds shared
// dependencies (DB, JWT, Apple verifier, VPN engine, config, logger).
package mobile

import (
	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Handler holds all dependencies needed by mobile API handlers.
type Handler struct {
	DB     *db.DB
	JWT    *auth.JWTManager
	Apple  *auth.AppleVerifier
	VPN    vpn.Engine // may be nil if VPN engine is not configured
	Config *config.Config
	Logger *zap.Logger
}

// RegisterRoutes adds mobile API routes to the given echo group.
//
// Route layout:
//
//	POST /auth/register        — device-based registration (no auth required)
//	POST /auth/apple           — Apple Sign-In (no auth required)
//	GET  /config               — VPN client config (auth required)
//	POST /subscription/verify  — App Store subscription verification (auth required)
func RegisterRoutes(g *echo.Group, h *Handler) {
	// Auth endpoints — no JWT required.
	authGroup := g.Group("/auth")
	authGroup.POST("/register", h.Register)
	authGroup.POST("/apple", h.AppleSignIn)

	// Protected endpoints — require valid JWT.
	requireAuth := auth.RequireAuth(h.JWT)

	g.GET("/config", h.GetConfig, requireAuth)

	subGroup := g.Group("/subscription", requireAuth)
	subGroup.POST("/verify", h.VerifySubscription)
}

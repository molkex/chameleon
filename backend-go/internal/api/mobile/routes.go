// Package mobile provides HTTP handlers for the Chameleon VPN mobile API.
//
// All handlers are methods on the Handler struct, which holds shared
// dependencies (DB, JWT, Apple verifier, VPN engine, config, logger).
package mobile

import (
	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/email"
	"github.com/chameleonvpn/chameleon/internal/geoip"
	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/payments/apple"
	"github.com/chameleonvpn/chameleon/internal/payments/freekassa"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Handler holds all dependencies needed by mobile API handlers.
type Handler struct {
	DB            *db.DB
	Redis         *redis.Client
	JWT           *auth.JWTManager
	Apple         *auth.AppleVerifier // Sign In With Apple (identity token)
	Google        *auth.GoogleVerifier // Google Sign-In (id_token)
	AppleVerifier *apple.Verifier     // App Store IAP JWS verification
	Payments      *payments.Service
	FreeKassa     *freekassa.Client // may be nil if FreeKassa is disabled
	VPN           vpn.Engine // may be nil if VPN engine is not configured
	Config        *config.Config
	GeoIP         *geoip.Resolver
	Email         email.Sender // transactional email sender (Resend or noop)
	Logger        *zap.Logger
}

// RegisterRoutes adds mobile API routes to the given echo group.
//
// Route layout:
//
//	POST /auth/register        — device-based registration (no auth required)
//	POST /auth/apple           — Apple Sign-In (no auth required)
//	GET  /config               — VPN client config (by username query param, no JWT)
//	POST /subscription/verify  — App Store subscription verification (auth required)
func RegisterRoutes(g *echo.Group, h *Handler) {
	// Auth endpoints — no JWT required.
	authGroup := g.Group("/auth")
	authGroup.POST("/register", h.Register)
	authGroup.POST("/apple", h.AppleSignIn)
	authGroup.POST("/google", h.GoogleSignIn)
	authGroup.POST("/refresh", h.RefreshToken)
	authGroup.POST("/magic/request", h.MagicLinkRequest)
	authGroup.POST("/magic/verify", h.MagicLinkVerify)

	// Protected endpoints — require valid JWT.
	requireAuth := auth.RequireAuth(h.JWT)

	// Config endpoint — requires JWT, identifies user by token (not query param).
	g.GET("/config", h.GetConfig, requireAuth)

	subGroup := g.Group("/subscription", requireAuth)
	subGroup.POST("/verify", h.VerifySubscription)

	// Paywall catalog — no auth, so the paywall can render before sign-in.
	g.GET("/plans", h.GetPlans)

	// Payment flow — auth required; the user id is pulled from JWT.
	payGroup := g.Group("/payment", requireAuth)
	payGroup.POST("/initiate", h.InitiatePayment)
	payGroup.GET("/status/:payment_id", h.PaymentStatus)

	// User preferences.
	userGroup := g.Group("/user", requireAuth)
	userGroup.PATCH("/theme", h.SetTheme)
	userGroup.DELETE("", h.DeleteAccount)

	// Apple App Store Server Notifications V2 — public endpoint (trust comes
	// from JWS verification, not HTTP auth). Registered at the group root so
	// Apple sees /api/mobile/subscription/notification AND
	// /api/v1/mobile/subscription/notification.
	g.POST("/subscription/notification", h.AppleNotification)
}

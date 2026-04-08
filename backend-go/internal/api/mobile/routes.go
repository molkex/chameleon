package mobile

import (
	"github.com/labstack/echo/v4"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

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

// Package api provides the HTTP server, route registration, and global middleware
// for the Chameleon VPN backend.
package api

import (
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	adminAPI "github.com/chameleonvpn/chameleon/internal/api/admin"
	mw "github.com/chameleonvpn/chameleon/internal/api/middleware"
	"github.com/chameleonvpn/chameleon/internal/api/mobile"
	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/cluster"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/email"
	"github.com/chameleonvpn/chameleon/internal/geoip"
	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/payments/apple"
	"github.com/chameleonvpn/chameleon/internal/payments/freekassa"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Server holds all dependencies needed by HTTP handlers.
// Every handler receives its dependencies through this struct
// rather than globals or closures.
type Server struct {
	Config *config.Config
	DB     *db.DB
	Redis  *redis.Client
	JWT    *auth.JWTManager
	Apple  *auth.AppleVerifier
	Google *auth.GoogleVerifier
	Email  email.Sender
	VPN    vpn.Engine // VPN engine interface (may be nil)
	Syncer *cluster.Syncer
	Logger *zap.Logger
}

// NewServer creates a fully configured Echo instance with all routes
// and middleware attached. The returned Echo is ready to be started.
func NewServer(s *Server) *echo.Echo {
	e := echo.New()

	// Disable Echo's built-in banner and colorful output —
	// we use our own structured logging.
	e.HideBanner = true
	e.HidePort = true

	// Custom HTTP error handler that logs errors and returns JSON.
	e.HTTPErrorHandler = s.httpErrorHandler

	s.setupMiddleware(e)
	s.setupRoutes(e)

	return e
}

// setupMiddleware configures global middleware applied to every request.
// Order matters: outermost middleware runs first.
func (s *Server) setupMiddleware(e *echo.Echo) {
	// 1. Recovery — catch panics, convert to 500, log stack trace.
	e.Use(echomw.RecoverWithConfig(echomw.RecoverConfig{
		DisableStackAll:   true,
		DisablePrintStack: true, // We log it ourselves via the error handler.
		LogErrorFunc: func(_ echo.Context, err error, stack []byte) error {
			s.Logger.Error("panic recovered",
				zap.Error(err),
				zap.ByteString("stack", stack),
			)
			return err
		},
	}))

	// 2. Request ID — generate or propagate X-Request-Id header.
	e.Use(echomw.RequestID())

	// 3. Structured request logging via zap.
	e.Use(s.requestLogger())

	// 4. Security headers on every response.
	e.Use(mw.SecurityHeaders())

	// 5. CORS for admin SPA (origins from config).
	e.Use(echomw.CORSWithConfig(echomw.CORSConfig{
		AllowOrigins: s.Config.Server.CORSOrigins,
		AllowMethods: []string{
			http.MethodGet, http.MethodPost,
			http.MethodPut, http.MethodDelete,
			http.MethodOptions,
		},
		AllowHeaders: []string{
			echo.HeaderOrigin,
			echo.HeaderContentType,
			echo.HeaderAccept,
			echo.HeaderAuthorization,
			echo.HeaderXRequestID,
			"X-Requested-With",
		},
		AllowCredentials: true,
		MaxAge:           86400, // 24h preflight cache
	}))

	// 6. Timeout — abort request processing after 30 seconds.
	e.Use(echomw.TimeoutWithConfig(echomw.TimeoutConfig{
		Timeout: 30 * time.Second,
	}))
}

// setupRoutes registers all API endpoints.
// Mobile and admin handlers are implemented in their respective sub-packages.
func (s *Server) setupRoutes(e *echo.Echo) {
	// Health check (no auth, no rate limit).
	e.GET("/health", s.handleHealth)

	// Single payments service shared across mobile + admin handlers.
	paymentsSvc := payments.New(s.DB.Pool)

	// Apple IAP verifier. A nil *apple.Verifier means the /subscription/verify
	// handler will reject calls with a "payments not configured" error, which
	// is the safe default if someone forgets to set payments.apple.bundle_id.
	appleVerifier, err := apple.New(apple.Config{
		BundleID:     s.Config.Payments.Apple.BundleID,
		AllowSandbox: s.Config.Payments.Apple.AllowSandbox,
		Products:     mobile.ProductDays(),
	})
	if err != nil {
		s.Logger.Warn("apple IAP verifier disabled", zap.Error(err))
		appleVerifier = nil
	}

	// FreeKassa REST client — nil means the /payment/initiate and
	// /webhooks/freekassa handlers will refuse traffic with a clear error.
	var fkClient *freekassa.Client
	if s.Config.Payments.FreeKassa.Enabled {
		c, err := freekassa.New(freekassa.Config{
			ShopID:  s.Config.Payments.FreeKassa.ShopID,
			APIKey:  s.Config.Payments.FreeKassa.APIKey,
			Secret2: s.Config.Payments.FreeKassa.Secret2,
			BaseURL: s.Config.Payments.FreeKassa.BaseURL,
		})
		if err != nil {
			s.Logger.Warn("freekassa disabled", zap.Error(err))
		} else {
			fkClient = c
		}
	}

	mobileHandler := &mobile.Handler{
		DB:            s.DB,
		Redis:         s.Redis,
		JWT:           s.JWT,
		Apple:         s.Apple,
		Google:        s.Google,
		AppleVerifier: appleVerifier,
		Payments:      paymentsSvc,
		FreeKassa:     fkClient,
		VPN:           s.VPN,
		Config:        s.Config,
		GeoIP:         geoip.New(),
		Email:         s.Email,
		Logger:        s.Logger,
	}

	// Mobile API: /api/mobile/* and /api/v1/mobile/* (iOS app uses v1 prefix)
	mobileGroup := e.Group("/api/mobile")
	mobileGroup.Use(mw.RateLimit(s.Config.RateLimit.MobilePerMinute))
	mobile.RegisterRoutes(mobileGroup, mobileHandler)

	mobileV1 := e.Group("/api/v1/mobile")
	mobileV1.Use(mw.RateLimit(s.Config.RateLimit.MobilePerMinute))
	mobile.RegisterRoutes(mobileV1, mobileHandler)

	// FreeKassa server-to-server webhook. Public, unauthenticated — trust
	// comes from IP allowlist + HMAC signature verification inside the
	// handler. Registered at the root, not under /api/mobile, because FK
	// calls it directly and we want a short, stable URL.
	webhooks := e.Group("/api/webhooks")
	webhooks.POST("/freekassa", mobileHandler.FreeKassaWebhook)

	// Subscription link: /sub/:token/:mode (legacy config download)
	subRL := mw.RateLimit(s.Config.RateLimit.MobilePerMinute)
	e.GET("/sub/:token/:mode", mobileHandler.GetConfigLegacy, subRL)
	e.GET("/sub/:token", mobileHandler.GetConfigLegacy, subRL)

	// Admin API served under /api/v1/admin (React SPA) and /api/admin (legacy).
	adminHandler := &adminAPI.Handler{
		DB:            s.DB,
		Redis:         s.Redis,
		JWT:           s.JWT,
		VPN:           s.VPN,
		Payments:      paymentsSvc,
		Config:        s.Config,
		Logger:        s.Logger,
		ClusterSecret: s.Config.Cluster.Secret,
	}

	// Primary admin routes: /api/v1/admin/* (matches React SPA base path)
	adminV1 := e.Group("/api/v1/admin")
	adminV1.Use(mw.RateLimit(s.Config.RateLimit.AdminPerMinute))
	adminV1.Use(mw.CSRFProtect())
	adminAPI.RegisterRoutes(adminV1, adminHandler, s.JWT)

	// Backward-compatible routes: /api/admin/*
	adminLegacy := e.Group("/api/admin")
	adminLegacy.Use(mw.RateLimit(s.Config.RateLimit.AdminPerMinute))
	adminLegacy.Use(mw.CSRFProtect())
	adminAPI.RegisterRoutes(adminLegacy, adminHandler, s.JWT)

	// Cluster sync routes: /api/cluster/* (internal, peer-to-peer, auth required)
	if s.Config.Cluster.Enabled {
		clusterGroup := e.Group("/api/cluster")
		clusterGroup.Use(cluster.ClusterAuth(s.Config.Cluster.Secret))
		cluster.RegisterRoutes(clusterGroup, s.DB, s.Config.Cluster, s.Logger)
		// Node status endpoint — used by peers to aggregate cluster view.
		clusterGroup.GET("/node-status", adminHandler.NodeStatus)
	}
}

// handleHealth returns the health status of the service and its dependencies.
// It checks real connectivity to both PostgreSQL and Redis.
func (s *Server) handleHealth(c echo.Context) error {
	ctx := c.Request().Context()

	dbStatus := "ok"
	if err := s.DB.Health(ctx); err != nil {
		dbStatus = "error: " + err.Error()
	}

	redisStatus := "ok"
	if err := s.Redis.Ping(ctx).Err(); err != nil {
		redisStatus = "error: " + err.Error()
	}

	status := "ok"
	httpCode := http.StatusOK
	if dbStatus != "ok" || redisStatus != "ok" {
		status = "degraded"
		httpCode = http.StatusServiceUnavailable
	}

	return c.JSON(httpCode, map[string]string{
		"status": status,
		"db":     dbStatus,
		"redis":  redisStatus,
	})
}

// requestLogger returns Echo middleware that logs every request with zap.
// It includes the request ID, method, path, status, latency, and client IP.
func (s *Server) requestLogger() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			start := time.Now()

			err := next(c)
			if err != nil {
				c.Error(err)
			}

			req := c.Request()
			res := c.Response()
			latency := time.Since(start)

			fields := []zap.Field{
				zap.String("request_id", res.Header().Get(echo.HeaderXRequestID)),
				zap.String("method", req.Method),
				zap.String("path", req.URL.Path),
				zap.Int("status", res.Status),
				zap.Duration("latency", latency),
				zap.String("ip", c.RealIP()),
				zap.String("user_agent", req.UserAgent()),
			}

			status := res.Status
			switch {
			case status >= 500:
				s.Logger.Error("request", fields...)
			case status >= 400:
				s.Logger.Warn("request", fields...)
			default:
				s.Logger.Info("request", fields...)
			}

			return nil
		}
	}
}

// httpErrorHandler is a custom Echo error handler that returns consistent
// JSON error responses and logs unexpected errors.
func (s *Server) httpErrorHandler(err error, c echo.Context) {
	if c.Response().Committed {
		return
	}

	code := http.StatusInternalServerError
	message := "internal server error"

	if he, ok := err.(*echo.HTTPError); ok {
		code = he.Code
		if msg, ok := he.Message.(string); ok {
			message = msg
		} else {
			message = http.StatusText(code)
		}
	}

	requestID := c.Response().Header().Get(echo.HeaderXRequestID)

	if code >= 500 {
		s.Logger.Error("unhandled error",
			zap.Error(err),
			zap.String("request_id", requestID),
			zap.String("path", c.Request().URL.Path),
		)
	}

	// Don't leak internal details in production responses.
	resp := map[string]interface{}{
		"error":      message,
		"request_id": requestID,
	}

	if c.Request().Method == http.MethodHead {
		_ = c.NoContent(code)
	} else {
		_ = c.JSON(code, resp)
	}
}


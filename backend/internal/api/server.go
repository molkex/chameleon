// Package api provides the HTTP server, route registration, and global middleware
// for the Chameleon VPN backend.
package api

import (
	"context"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	adminAPI "github.com/chameleonvpn/chameleon/internal/api/admin"
	mw "github.com/chameleonvpn/chameleon/internal/api/middleware"
	"github.com/chameleonvpn/chameleon/internal/api/mobile"
	"github.com/chameleonvpn/chameleon/internal/asc"
	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/cluster"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/email"
	"github.com/chameleonvpn/chameleon/internal/geoip"
	"github.com/chameleonvpn/chameleon/internal/metrics"
	"github.com/chameleonvpn/chameleon/internal/payments"
	"github.com/chameleonvpn/chameleon/internal/payments/apple"
	"github.com/chameleonvpn/chameleon/internal/payments/freekassa"
	"github.com/chameleonvpn/chameleon/internal/storage"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Server holds all dependencies needed by HTTP handlers.
// Every handler receives its dependencies through this struct
// rather than globals or closures.
type Server struct {
	// Ctx is the lifetime context — cancellation signals background goroutines
	// (rate-limiter cleanup, cluster sync) to exit cleanly. Set by main.go
	// before calling NewServer.
	Ctx     context.Context
	Config  *config.Config
	DB      *db.DB
	Redis   *redis.Client
	JWT     *auth.JWTManager
	Apple   *auth.AppleVerifier
	Google  *auth.GoogleVerifier
	Email   email.Sender
	VPN     vpn.Engine // VPN engine interface (may be nil)
	Syncer  *cluster.Syncer
	Metrics *metrics.Metrics // Prometheus collectors; may be nil in tests
	// Storage backs SUPPORT-CHAT attachments (B2). nil ⇒ attachments disabled.
	// Built in main.go from B2_* env so the same client is shared with the
	// retention sweep (which runs before NewServer).
	Storage *storage.Client
	Logger  *zap.Logger
}

// NewServer creates a fully configured Echo instance with all routes
// and middleware attached. The returned Echo is ready to be started.
func NewServer(s *Server) *echo.Echo {
	e := echo.New()

	// SEC-02: derive the client IP from X-Forwarded-For only when the request
	// arrives via a trusted hop (loopback / link-local / private). On NL the
	// chameleon process runs net=host and nginx terminates on 127.0.0.1, where
	// it has already resolved the genuine client (set_real_ip_from = Cloudflare
	// ranges + MSK/SPB relays) and rewritten XFF to that single address — so the
	// leftmost untrusted XFF entry is the real client. Without an explicit
	// extractor, Echo's default RealIP() trusts a caller-supplied XFF verbatim,
	// which would let a client reaching :8000 directly forge its IP and defeat
	// the rate-limiter, FreeKassa IP allowlist, and geoIP country lookup. A
	// public peer is untrusted, so its forged XFF is ignored and RemoteAddr wins.
	e.IPExtractor = echo.ExtractIPFromXFFHeader()

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
	// 0. Prometheus HTTP latency histogram. Runs first so the timer brackets
	//    every other middleware (recovery, body limit, CORS, etc.). Skips the
	//    /metrics scrape itself to keep the dashboard clean and avoid a self-
	//    referential noise loop.
	if s.Metrics != nil {
		e.Use(s.metricsMiddleware())
	}

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

	// 2. Audit MED-011: global request-body size cap. Without it, an
	// oversized JSON body can run the parser out of memory. nginx in front
	// usually catches this for public traffic, but the chameleon container
	// also exposes :8000 directly. 1 MiB is generous for any legitimate
	// endpoint (largest is the signed JWS upload for IAP verification,
	// which Apple bounds well under 100 KiB). Tighter per-route caps on
	// auth/payment/webhook are a follow-up.
	e.Use(echomw.BodyLimit("1M"))

	// 3. Request ID — generate or propagate X-Request-Id header.
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
	// ContextTimeoutWithConfig is the non-deprecated replacement for the
	// older TimeoutWithConfig middleware (which had architectural data-race
	// issues; see echo docs). It uses Go's context cancellation so handlers
	// observe the deadline via c.Request().Context().
	e.Use(echomw.ContextTimeoutWithConfig(echomw.ContextTimeoutConfig{
		Timeout: 30 * time.Second,
		// SUPPORT-CHAT: the SSE stream is long-lived — a 30s context deadline
		// would cut it. Skip only that exact path; every other route keeps the
		// 30s guard. (The per-connection write deadline is cleared in the
		// handler via ResponseController; see mobile.SupportStream.)
		Skipper: func(c echo.Context) bool {
			return strings.HasSuffix(c.Path(), "/support/stream")
		},
	}))
}

// setupRoutes registers all API endpoints.
// Mobile and admin handlers are implemented in their respective sub-packages.
func (s *Server) setupRoutes(e *echo.Echo) {
	// Health check (no auth, no rate limit).
	e.GET("/health", s.handleHealth)

	// Prometheus scrape target. Outside any auth/CSRF/rate-limit group on
	// purpose — Prometheus scrapes from localhost (:8000 is 127.0.0.1-bound
	// in docker-compose). MON-04 (2026-05-28).
	if s.Metrics != nil {
		e.GET("/metrics", echo.WrapHandler(s.Metrics.Handler()))
	}

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
		Metrics:       s.Metrics,
		Storage:       s.Storage,
		Logger:        s.Logger,
	}

	// Mobile API: /api/mobile/* and /api/v1/mobile/* (iOS app uses v1 prefix)
	mobileGroup := e.Group("/api/mobile")
	mobileGroup.Use(mw.RateLimit(s.Ctx, s.Config.RateLimit.MobilePerMinute))
	mobileGroup.Use(mw.Idempotency(s.Redis, s.Logger, s.Metrics))
	mobile.RegisterRoutes(mobileGroup, mobileHandler)

	mobileV1 := e.Group("/api/v1/mobile")
	mobileV1.Use(mw.RateLimit(s.Ctx, s.Config.RateLimit.MobilePerMinute))
	mobileV1.Use(mw.Idempotency(s.Redis, s.Logger, s.Metrics))
	mobile.RegisterRoutes(mobileV1, mobileHandler)

	// FreeKassa server-to-server webhook. Public, unauthenticated — trust
	// comes from IP allowlist + HMAC signature verification inside the
	// handler. Registered at the root, not under /api/mobile, because FK
	// calls it directly and we want a short, stable URL.
	webhooks := e.Group("/api/webhooks")
	webhooks.POST("/freekassa", mobileHandler.FreeKassaWebhook)

	// Subscription link: /sub/:token/:mode (legacy config download)
	subRL := mw.RateLimit(s.Ctx, s.Config.RateLimit.MobilePerMinute)
	e.GET("/sub/:token/:mode", mobileHandler.GetConfigLegacy, subRL)
	e.GET("/sub/:token", mobileHandler.GetConfigLegacy, subRL)

	// App Store Connect API client — optional. asc.New() returns nil
	// (nil, nil) when ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH env vars
	// are unset, which is the right shape for the dev-without-creds case.
	// Failure to PARSE configured creds (bad path, malformed PEM) IS
	// fatal at startup — that's a misconfiguration the operator wants
	// loud, not a silent "Apple section is blank in admin".
	ascClient, err := asc.New()
	if err != nil {
		s.Logger.Warn("ASC client init failed — Apple state will be unavailable in admin", zap.Error(err))
	} else if ascClient != nil {
		s.Logger.Info("ASC client initialised — Apple state available in admin")
	}

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
		ASC:           ascClient,
		ASCAppID:      os.Getenv("ASC_APP_ID"),
		Storage:       s.Storage,
		// MON-04: local Prometheus for the dashboard health strip. Env
		// override for non-default binds; empty falls back to the
		// docker-compose bind (127.0.0.1:9091) inside infra.go.
		PrometheusURL: os.Getenv("PROMETHEUS_URL"),
	}

	// Primary admin routes: /api/v1/admin/* (matches React SPA base path)
	adminV1 := e.Group("/api/v1/admin")
	adminV1.Use(mw.RateLimit(s.Ctx, s.Config.RateLimit.AdminPerMinute))
	adminV1.Use(mw.CSRFProtect())
	adminAPI.RegisterRoutes(adminV1, adminHandler, s.JWT)

	// Backward-compatible routes: /api/admin/*
	adminLegacy := e.Group("/api/admin")
	adminLegacy.Use(mw.RateLimit(s.Ctx, s.Config.RateLimit.AdminPerMinute))
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

	// /health is reachable without auth — never leak driver error strings
	// (they expose internal hosts/ports). Real diagnostics live in our own
	// logs, indexed by request_id.
	dbStatus := "ok"
	if err := s.DB.Health(ctx); err != nil {
		s.Logger.Warn("health: db check failed", zap.Error(err))
		dbStatus = "error"
	}

	redisStatus := "ok"
	if err := s.Redis.Ping(ctx).Err(); err != nil {
		s.Logger.Warn("health: redis check failed", zap.Error(err))
		redisStatus = "error"
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

// metricsMiddleware returns Echo middleware that records
// chameleon_http_request_duration_seconds for every request. Route label
// uses c.Path() (route PATTERN like "/api/v1/mobile/auth/register"), NOT
// the raw URL — this is the cardinality fence so a scanner hitting
// /random-urls won't blow up the label set.
//
// /metrics itself is skipped so the scrape doesn't show up in its own
// histogram (would invert the rate() during incidents).
func (s *Server) metricsMiddleware() echo.MiddlewareFunc {
	m := s.Metrics
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			if c.Request().URL.Path == "/metrics" {
				return next(c)
			}
			start := time.Now()
			err := next(c)
			// c.Path() returns the registered route pattern (e.g.
			// "/api/v1/mobile/auth/register") rather than the raw URL.
			// Empty when the request didn't match any route — ObserveHTTP
			// normalises that to "unmatched".
			m.ObserveHTTP(
				c.Request().Method,
				c.Path(),
				c.Response().Status,
				time.Since(start),
			)
			return err
		}
	}
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

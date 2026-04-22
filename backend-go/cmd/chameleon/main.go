// Package main is the entry point for the Chameleon VPN backend server.
//
// Startup order:
//  1. Parse CLI flags / subcommands
//  2. Load and validate configuration from YAML
//  3. Initialize structured logger (zap)
//  4. Connect to PostgreSQL with connection pool
//  5. Connect to Redis
//  6. Initialize auth subsystem (JWT manager, Apple verifier)
//  7. Initialize VPN engine (sing-box in Docker mode)
//  8. Load active users into VPN engine
//  9. Start traffic collector goroutine
//  10. Build Echo HTTP server with routes and middleware
//  11. Start server with graceful shutdown on SIGINT/SIGTERM
//
// Subcommands:
//
//	chameleon admin create --username X --password Y [--role admin|operator] [--config config.yaml]
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"github.com/chameleonvpn/chameleon/internal/api"
	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/cli"
	"github.com/chameleonvpn/chameleon/internal/cluster"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/email"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// version is set at build time via -ldflags.
var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(1)
	}
}

// run encapsulates all startup/shutdown logic so main() never panics.
func run() error {
	// Check for subcommands before parsing flags.
	if len(os.Args) >= 2 && os.Args[1] == "admin" {
		return runAdminCommand()
	}

	configPath := flag.String("config", "config.yaml", "path to configuration file")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	logger, err := newLogger(cfg)
	if err != nil {
		return fmt.Errorf("init logger: %w", err)
	}
	defer func() { _ = logger.Sync() }()

	listenAddr := net.JoinHostPort(cfg.Server.Host, fmt.Sprintf("%d", cfg.Server.Port))
	logger.Info("starting chameleon vpn backend",
		zap.String("version", version),
		zap.String("listen", listenAddr),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	database, err := db.New(
		ctx,
		cfg.Database.URL,
		int32(cfg.Database.MaxConns),
		int32(cfg.Database.MinConns),
		cfg.Database.MaxConnLifetime.Duration,
	)
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}
	defer database.Close()

	logger.Info("database connected",
		zap.Int("max_conns", cfg.Database.MaxConns),
		zap.Int("min_conns", cfg.Database.MinConns),
	)

	redisOpts, err := redis.ParseURL(cfg.Redis.URL)
	if err != nil {
		return fmt.Errorf("parse redis URL: %w", err)
	}

	rdb := redis.NewClient(redisOpts)

	redisCtx, redisCancel := context.WithTimeout(ctx, 5*time.Second)
	defer redisCancel()

	if err := rdb.Ping(redisCtx).Err(); err != nil {
		return fmt.Errorf("connect to redis: %w", err)
	}
	defer func() {
		if err := rdb.Close(); err != nil {
			logger.Error("redis close error", zap.Error(err))
		}
	}()

	logger.Info("redis connected")

	jwtManager := auth.NewJWTManager(
		cfg.Auth.JWTSecret,
		cfg.Auth.AccessTTL.Duration,
		cfg.Auth.RefreshTTL.Duration,
	)

	appleBundleIDs := append([]string{cfg.Auth.AppleBundleID}, cfg.Auth.AppleExtraBundleIDs...)
	appleVerifier := auth.NewAppleVerifier(appleBundleIDs...)

	googleVerifier := auth.NewGoogleVerifier(cfg.Google.IOSClientID)

	// Email sender — Resend if API key is configured, otherwise a noop that
	// only logs. Lets dev/staging run without SMTP creds without blocking
	// the magic-link flow.
	var emailSender email.Sender
	if cfg.Email.Provider == "resend" {
		if s := email.NewResendSender(cfg.Email.APIKey, cfg.Email.FromEmail, cfg.Email.FromName, logger); s != nil {
			emailSender = s
			logger.Info("email provider: resend", zap.String("from", cfg.Email.FromEmail))
		}
	}
	if emailSender == nil {
		emailSender = email.NewNoopSender(logger)
		logger.Warn("email provider: noop (no API key configured)")
	}

	logger.Info("auth initialized",
		zap.Duration("access_ttl", cfg.Auth.AccessTTL.Duration),
		zap.Duration("refresh_ttl", cfg.Auth.RefreshTTL.Duration),
		zap.Bool("google_enabled", googleVerifier.IsEnabled()),
	)

	// Initialize VPN engine (sing-box in Docker mode).
	// Config is written to /etc/singbox/ (shared volume with sing-box container).
	singboxConfigDir := os.Getenv("SINGBOX_CONFIG_DIR")
	if singboxConfigDir == "" {
		singboxConfigDir = "/etc/singbox"
	}

	engine := vpn.NewSingboxEngine(logger, singboxConfigDir, vpn.ModeDocker)

	// Determine SNI for this server.
	sni := cfg.VPN.Reality.SNIs["default"]
	if sni == "" {
		// Pick first available SNI from the map.
		for _, v := range cfg.VPN.Reality.SNIs {
			sni = v
			break
		}
	}
	if sni == "" {
		sni = "www.microsoft.com"
	}

	// Load Reality keys: prefer DB (single source of truth), fall back to config/env.
	realityPrivateKey := cfg.VPN.Reality.PrivateKey
	realityPublicKey := cfg.VPN.Reality.PublicKey

	if cfg.Cluster.NodeID != "" {
		localServer, err := database.FindLocalServer(ctx, cfg.Cluster.NodeID)
		if err != nil {
			logger.Warn("failed to find local server in DB, using config keys",
				zap.String("node_id", cfg.Cluster.NodeID), zap.Error(err))
		} else if localServer != nil {
			if localServer.RealityPrivateKey != "" {
				realityPrivateKey = localServer.RealityPrivateKey
				logger.Info("loaded Reality private key from DB", zap.String("server_key", localServer.Key))
			}
			if localServer.RealityPublicKey != "" {
				realityPublicKey = localServer.RealityPublicKey
				logger.Info("loaded Reality public key from DB", zap.String("server_key", localServer.Key))
			}
			if localServer.SNI != "" && sni == "www.microsoft.com" {
				sni = localServer.SNI
			}
		}
	}

	if realityPrivateKey == "" {
		return fmt.Errorf("reality private key not found — set it in vpn_servers DB table or REALITY_PRIVATE_KEY env var")
	}

	engineCfg := vpn.EngineConfig{
		ListenPort: cfg.VPN.ListenPort,
		Reality: vpn.RealityConfig{
			PrivateKey: realityPrivateKey,
			PublicKey:  realityPublicKey,
			ShortIDs:   cfg.VPN.Reality.ShortIDs,
			SNI:        sni,
		},
		ClashAPIPort:    cfg.VPN.ClashAPIPort,
		ClientMTU:       cfg.VPN.ClientMTU,
		DNSRemote:       cfg.VPN.DNSRemote,
		DNSDirect:       cfg.VPN.DNSDirect,
		UrltestInterval: cfg.VPN.UrltestInterval.Duration.String(),
		UserAPIPort:     cfg.VPN.UserAPIPort,
		UserAPISecret:   cfg.VPN.UserAPISecret,
		V2RayAPIPort:    cfg.VPN.V2RayAPIPort,
	}

	// Load active VPN users from the database.
	dbUsers, err := database.ListActiveVPNUsers(ctx)
	if err != nil {
		return fmt.Errorf("load vpn users: %w", err)
	}

	vpnUsers := make([]vpn.VPNUser, 0, len(dbUsers))
	for _, u := range dbUsers {
		if u.VPNUsername == nil || u.VPNUUID == nil {
			continue
		}
		shortID := ""
		if u.VPNShortID != nil {
			shortID = *u.VPNShortID
		}
		vpnUsers = append(vpnUsers, vpn.VPNUser{
			Username: *u.VPNUsername,
			UUID:     *u.VPNUUID,
			ShortID:  shortID,
		})
	}

	logger.Info("loaded vpn users from database", zap.Int("count", len(vpnUsers)))

	// Start VPN engine — writes config and signals sing-box container.
	if err := engine.Start(ctx, engineCfg, vpnUsers); err != nil {
		logger.Warn("vpn engine start failed (sing-box container may not be ready yet)", zap.Error(err))
		// Don't fail startup — the container might start after us.
	}
	defer func() {
		if err := engine.Stop(); err != nil {
			logger.Error("vpn engine stop error", zap.Error(err))
		}
	}()

	// Start background traffic collector (every 60 seconds).
	go runTrafficCollector(ctx, logger, database, engine, 60*time.Second)

	// Initialize cluster syncer (peer-to-peer user replication).
	syncer := cluster.NewSyncer(database, cfg.Cluster, engine, rdb, logger)
	syncer.Start(ctx)
	defer syncer.Stop()

	srv := &api.Server{
		Config:  cfg,
		DB:      database,
		Redis:   rdb,
		JWT:     jwtManager,
		Apple:   appleVerifier,
		Google:  googleVerifier,
		Email:   emailSender,
		VPN:     engine,
		Syncer:  syncer,
		Logger:  logger,
	}

	e := api.NewServer(srv)

	errCh := make(chan error, 1)
	go func() {
		logger.Info("http server listening", zap.String("addr", listenAddr))
		if err := e.Start(listenAddr); err != nil {
			// echo returns error on Shutdown -- not a real failure.
			errCh <- err
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-quit:
		logger.Info("received shutdown signal", zap.String("signal", sig.String()))
	case err := <-errCh:
		// Only reach here if ListenAndServe fails immediately
		// (port busy, permission denied, etc.)
		return fmt.Errorf("http server: %w", err)
	}

	// Cancel context to stop background goroutines.
	cancel()

	// Drain connections with a 10-second timeout.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	logger.Info("shutting down http server", zap.Duration("timeout", 10*time.Second))

	if err := e.Shutdown(shutdownCtx); err != nil {
		logger.Error("http server shutdown error", zap.Error(err))
		return fmt.Errorf("http server shutdown: %w", err)
	}

	logger.Info("shutdown complete")
	return nil
}

// runTrafficCollector periodically queries the VPN engine for traffic stats
// and records them to the database.
func runTrafficCollector(ctx context.Context, logger *zap.Logger, database *db.DB, engine vpn.Engine, interval time.Duration) {
	logger = logger.Named("traffic-collector")
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Wait a bit for sing-box to start.
	select {
	case <-ctx.Done():
		return
	case <-time.After(30 * time.Second):
	}

	logger.Info("traffic collector started", zap.Duration("interval", interval))

	for {
		select {
		case <-ctx.Done():
			logger.Info("traffic collector stopped")
			return
		case <-ticker.C:
			traffic, err := engine.QueryTraffic(ctx)
			if err != nil {
				logger.Debug("query traffic failed (sing-box may not be ready)", zap.Error(err))
				continue
			}

			for _, t := range traffic {
				if t.Upload == 0 && t.Download == 0 {
					continue
				}

				if err := database.UpdateTraffic(ctx, t.Username, t.Upload, t.Download); err != nil {
					logger.Error("update traffic", zap.Error(err), zap.String("user", t.Username))
				}

				if err := database.InsertTrafficSnapshot(ctx, t.Username, t.Upload, t.Download); err != nil {
					logger.Error("insert traffic snapshot", zap.Error(err), zap.String("user", t.Username))
				}
			}

			if len(traffic) > 0 {
				logger.Info("traffic recorded", zap.Int("users", len(traffic)))
			}
		}
	}
}

// runAdminCommand handles the "admin" subcommand.
//
// Supported sub-subcommands:
//
//	admin create --username X --password Y [--role admin|operator] [--config config.yaml]
func runAdminCommand() error {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "Usage: chameleon admin create --username X --password Y [--role admin|operator] [--config config.yaml]\n")
		os.Exit(1)
	}

	switch os.Args[2] {
	case "create":
		return runAdminCreate()
	default:
		return fmt.Errorf("unknown admin subcommand: %s\nUsage: chameleon admin create --username X --password Y", os.Args[2])
	}
}

// runAdminCreate handles "chameleon admin create".
func runAdminCreate() error {
	fs := flag.NewFlagSet("admin create", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to configuration file")
	username := fs.String("username", "", "admin username (required)")
	password := fs.String("password", "", "admin password (required)")
	role := fs.String("role", "admin", "admin role: admin or operator")

	if err := fs.Parse(os.Args[3:]); err != nil {
		return err
	}

	if *username == "" || *password == "" {
		fs.Usage()
		return fmt.Errorf("--username and --password are required")
	}

	// Load config to get database URL.
	cfg, err := config.Load(*configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	return cli.CreateAdmin(cfg.Database.URL, *username, *password, *role)
}

// newLogger creates a zap.Logger configured for the environment.
// Production (host is 0.0.0.0 or non-localhost) gets JSON encoding;
// development (localhost/127.0.0.1) gets colorized console output.
func newLogger(cfg *config.Config) (*zap.Logger, error) {
	isDev := cfg.Server.Host == "127.0.0.1" || cfg.Server.Host == "localhost"

	var zapCfg zap.Config
	if isDev {
		zapCfg = zap.NewDevelopmentConfig()
		zapCfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	} else {
		zapCfg = zap.NewProductionConfig()
		zapCfg.EncoderConfig.TimeKey = "ts"
		zapCfg.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	}

	zapCfg.EncoderConfig.CallerKey = "caller"
	zapCfg.EncoderConfig.StacktraceKey = "stacktrace"

	return zapCfg.Build()
}

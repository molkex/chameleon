// Package vpn provides VPN engine implementations for Chameleon.
//
// SingboxEngine manages a sing-box process (embedded or Docker) by generating
// JSON configuration files and communicating via signals (SIGHUP for reload,
// SIGTERM for stop) and the clash_api REST endpoint for traffic statistics.
package vpn

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// Mode determines how SingboxEngine manages the sing-box process.
const (
	ModeEmbedded = "embedded" // launch sing-box as a child process
	ModeDocker   = "docker"   // write config to volume, send HUP to container

	// InboundTagVLESS is the tag used for the VLESS Reality inbound in generated configs.
	InboundTagVLESS = "vless-reality-tcp"
)

// Compile-time check: SingboxEngine must implement Engine.
var _ Engine = (*SingboxEngine)(nil)

// SingboxEngine implements Engine by managing a sing-box process/container.
//
// Thread-safety: all exported methods acquire e.mu before mutating state.
// Config files are written atomically (write to temp file, then rename).
type SingboxEngine struct {
	mu         sync.RWMutex
	cfg        EngineConfig
	users      []VPNUser
	configPath string
	configDir  string
	mode       string
	running    bool
	startedAt  time.Time
	logger     *zap.Logger

	// Process management (ModeEmbedded only).
	cmd        *exec.Cmd
	cancelFunc context.CancelFunc

	// Docker container name (ModeDocker only).
	containerName string

	// Stats collector for clash_api.
	stats *StatsCollector

	// User API client for zero-downtime user management (nil if disabled).
	userAPI *UserAPIClient
}

// NewSingboxEngine creates a new sing-box based VPN engine.
//
// Parameters:
//   - logger: structured logger for operational messages
//   - configDir: directory where sing-box config JSON will be written
//   - mode: "embedded" to launch a child process, "docker" to manage a container
func NewSingboxEngine(logger *zap.Logger, configDir string, mode string) *SingboxEngine {
	if mode == "" {
		mode = ModeEmbedded
	}
	return &SingboxEngine{
		configDir:     configDir,
		configPath:    filepath.Join(configDir, "singbox-config.json"),
		mode:          mode,
		containerName: "singbox", // default Docker container name
		logger:        logger.Named("singbox-engine"),
	}
}

// SetContainerName overrides the default Docker container name ("singbox").
// Only relevant when mode is ModeDocker.
func (e *SingboxEngine) SetContainerName(name string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.containerName = name
}

// Start initializes the VPN server with the given configuration and users.
//
// For ModeEmbedded: generates config, writes it to disk, and spawns sing-box.
// For ModeDocker: generates config, writes it to the shared volume, and sends SIGHUP.
func (e *SingboxEngine) Start(ctx context.Context, cfg EngineConfig, users []VPNUser) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.running {
		return fmt.Errorf("singbox engine: already running")
	}

	e.cfg = cfg
	e.users = make([]VPNUser, len(users))
	copy(e.users, users)

	e.logger.Info("starting sing-box engine",
		zap.String("mode", e.mode),
		zap.Int("listen_port", cfg.ListenPort),
		zap.Int("users", len(users)),
	)

	// Ensure config directory exists.
	if err := os.MkdirAll(e.configDir, 0o755); err != nil {
		return fmt.Errorf("singbox engine: create config dir: %w", err)
	}

	// Generate and write config atomically.
	if err := e.writeConfigLocked(); err != nil {
		return fmt.Errorf("singbox engine: write initial config: %w", err)
	}

	switch e.mode {
	case ModeEmbedded:
		if err := e.startProcessLocked(ctx); err != nil {
			return fmt.Errorf("singbox engine: start process: %w", err)
		}
	case ModeDocker:
		if err := e.signalDockerLocked(ctx, "HUP"); err != nil {
			e.logger.Warn("failed to send HUP to container on start (container may not be running yet)",
				zap.Error(err),
			)
		}
	default:
		return fmt.Errorf("singbox engine: unknown mode %q", e.mode)
	}

	// Initialize stats collector.
	clashAPIPort := e.cfg.ClashAPIPort
	if clashAPIPort == 0 {
		clashAPIPort = 9090
	}
	v2rayAPIAddr := ""
	if e.cfg.V2RayAPIPort > 0 {
		v2rayAPIAddr = fmt.Sprintf("127.0.0.1:%d", e.cfg.V2RayAPIPort)
	} else {
		v2rayAPIAddr = "127.0.0.1:8080"
	}
	e.stats = NewStatsCollector(fmt.Sprintf("http://127.0.0.1:%d", clashAPIPort), v2rayAPIAddr, e.logger)

	// Initialize User API client if configured.
	if e.cfg.UserAPIPort > 0 {
		e.userAPI = NewUserAPIClient(e.cfg.UserAPIPort, e.cfg.UserAPISecret, InboundTagVLESS)
		e.logger.Info("user-api client initialized", zap.Int("port", e.cfg.UserAPIPort))
	}

	e.running = true
	e.startedAt = time.Now()

	e.logger.Info("sing-box engine started",
		zap.String("config_path", e.configPath),
	)

	return nil
}

// Stop gracefully shuts down the VPN server.
//
// For ModeEmbedded: sends SIGTERM to the child process and waits up to 10 seconds.
// For ModeDocker: the singbox container is standalone (runs outside docker-compose)
// and must survive chameleon restarts to keep VPN connections alive. We only
// release our in-process references to the engine — the container keeps running.
func (e *SingboxEngine) Stop() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.running {
		return nil
	}

	e.logger.Info("releasing sing-box engine (container keeps running)", zap.String("mode", e.mode))

	var err error
	switch e.mode {
	case ModeEmbedded:
		err = e.stopProcessLocked()
	case ModeDocker:
		// Intentionally no-op. Previous implementation sent SIGTERM to the
		// container, which defeated the standalone-container design: every
		// chameleon restart killed singbox and dropped all VPN connections.
	}

	e.running = false
	e.stats = nil

	if err != nil {
		e.logger.Error("error releasing sing-box engine", zap.Error(err))
		return fmt.Errorf("singbox engine: stop: %w", err)
	}

	e.logger.Info("sing-box engine released")
	return nil
}

// ReloadUsers replaces the full user list.
// Uses User API bulk replace if available, falls back to config rewrite + SIGHUP.
// Returns the number of active users after reload.
func (e *SingboxEngine) ReloadUsers(ctx context.Context, users []VPNUser) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.running {
		return 0, fmt.Errorf("singbox engine: not running")
	}

	e.users = make([]VPNUser, len(users))
	copy(e.users, users)

	e.logger.Info("reloading users", zap.Int("count", len(users)))

	// Try User API bulk replace first.
	if e.userAPI != nil {
		if err := e.userAPI.ReplaceUsers(ctx, users); err != nil {
			e.logger.Warn("user-api replace failed, falling back to SIGHUP",
				zap.Int("count", len(users)), zap.Error(err))
		} else {
			if err := e.writeConfigLocked(); err != nil {
				e.logger.Warn("failed to write config after user-api replace", zap.Error(err))
			}
			e.logger.Info("users reloaded via user-api", zap.Int("count", len(users)))
			return len(users), nil
		}
	}

	// Fallback: config rewrite + SIGHUP.
	if err := e.writeConfigLocked(); err != nil {
		return 0, fmt.Errorf("singbox engine: write config for reload: %w", err)
	}

	if err := e.sendReloadLocked(ctx); err != nil {
		return 0, fmt.Errorf("singbox engine: send reload signal: %w", err)
	}

	e.logger.Info("users reloaded via SIGHUP", zap.Int("count", len(users)))
	return len(users), nil
}

// AddUser appends a user to the running server.
// Uses User API for zero-downtime add if available, falls back to config rewrite + SIGHUP.
func (e *SingboxEngine) AddUser(ctx context.Context, user VPNUser) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.running {
		return fmt.Errorf("singbox engine: not running")
	}

	// Check for duplicate.
	for _, u := range e.users {
		if u.Username == user.Username {
			return fmt.Errorf("singbox engine: user %q already exists", user.Username)
		}
	}

	e.users = append(e.users, user)

	e.logger.Info("adding user", zap.String("username", user.Username))

	// Try User API first (zero-downtime, no config rewrite needed for runtime).
	if e.userAPI != nil {
		if err := e.userAPI.AddUser(ctx, user); err != nil {
			e.logger.Warn("user-api add failed, falling back to SIGHUP",
				zap.String("username", user.Username), zap.Error(err))
		} else {
			// Also update config on disk for persistence across restarts.
			if err := e.writeConfigLocked(); err != nil {
				e.logger.Warn("failed to write config after user-api add", zap.Error(err))
			}
			e.logger.Info("user added via user-api",
				zap.String("username", user.Username), zap.Int("total_users", len(e.users)))
			return nil
		}
	}

	// Fallback: config rewrite + SIGHUP.
	if err := e.writeConfigLocked(); err != nil {
		return fmt.Errorf("singbox engine: write config for add user: %w", err)
	}

	if err := e.sendReloadLocked(ctx); err != nil {
		return fmt.Errorf("singbox engine: send reload signal: %w", err)
	}

	e.logger.Info("user added via SIGHUP", zap.String("username", user.Username), zap.Int("total_users", len(e.users)))
	return nil
}

// RemoveUser removes a user by username from the running server.
// Uses User API for zero-downtime remove if available, falls back to config rewrite + SIGHUP.
func (e *SingboxEngine) RemoveUser(ctx context.Context, username string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.running {
		return fmt.Errorf("singbox engine: not running")
	}

	found := false
	filtered := make([]VPNUser, 0, len(e.users))
	for _, u := range e.users {
		if u.Username == username {
			found = true
			continue
		}
		filtered = append(filtered, u)
	}

	if !found {
		return fmt.Errorf("singbox engine: user %q not found", username)
	}

	e.users = filtered

	e.logger.Info("removing user", zap.String("username", username))

	// Try User API first.
	if e.userAPI != nil {
		if err := e.userAPI.RemoveUser(ctx, username); err != nil {
			e.logger.Warn("user-api remove failed, falling back to SIGHUP",
				zap.String("username", username), zap.Error(err))
		} else {
			if err := e.writeConfigLocked(); err != nil {
				e.logger.Warn("failed to write config after user-api remove", zap.Error(err))
			}
			e.logger.Info("user removed via user-api",
				zap.String("username", username), zap.Int("total_users", len(e.users)))
			return nil
		}
	}

	// Fallback: config rewrite + SIGHUP.
	if err := e.writeConfigLocked(); err != nil {
		return fmt.Errorf("singbox engine: write config for remove user: %w", err)
	}

	if err := e.sendReloadLocked(ctx); err != nil {
		return fmt.Errorf("singbox engine: send reload signal: %w", err)
	}

	e.logger.Info("user removed via SIGHUP", zap.String("username", username), zap.Int("total_users", len(e.users)))
	return nil
}

// QueryTraffic returns per-user traffic since last query via clash_api.
func (e *SingboxEngine) QueryTraffic(ctx context.Context) ([]UserTraffic, error) {
	e.mu.RLock()
	stats := e.stats
	running := e.running
	e.mu.RUnlock()

	if !running || stats == nil {
		return nil, fmt.Errorf("singbox engine: not running")
	}

	return stats.QueryTraffic(ctx)
}

// OnlineUsers returns the count of currently connected users via clash_api.
func (e *SingboxEngine) OnlineUsers(ctx context.Context) (int, error) {
	e.mu.RLock()
	stats := e.stats
	running := e.running
	e.mu.RUnlock()

	if !running || stats == nil {
		return 0, fmt.Errorf("singbox engine: not running")
	}

	return stats.OnlineUsers(ctx)
}

// SessionTraffic returns total upload/download bytes for the current sing-box session.
func (e *SingboxEngine) SessionTraffic(ctx context.Context) (upload, download int64, err error) {
	e.mu.RLock()
	stats := e.stats
	running := e.running
	e.mu.RUnlock()

	if !running || stats == nil {
		return 0, 0, fmt.Errorf("singbox engine: not running")
	}

	return stats.SessionTraffic(ctx)
}

// CurrentSpeed returns real-time speed and active connection count via clash_api.
func (e *SingboxEngine) CurrentSpeed(ctx context.Context) (uploadBPS, downloadBPS int64, connections int, err error) {
	e.mu.RLock()
	stats := e.stats
	running := e.running
	e.mu.RUnlock()

	if !running || stats == nil {
		return 0, 0, 0, fmt.Errorf("singbox engine: not running")
	}

	return stats.CurrentSpeed(ctx)
}

// Health checks if the VPN server is running and responsive.
func (e *SingboxEngine) Health(ctx context.Context) error {
	e.mu.RLock()
	running := e.running
	mode := e.mode
	cmd := e.cmd
	e.mu.RUnlock()

	if !running {
		return fmt.Errorf("singbox engine: not running")
	}

	// For embedded mode, check that the process is still alive.
	if mode == ModeEmbedded && cmd != nil && cmd.Process != nil {
		// Signal 0 checks if process exists without actually sending a signal.
		if err := cmd.Process.Signal(syscall.Signal(0)); err != nil {
			return fmt.Errorf("singbox engine: process not responding: %w", err)
		}
	}

	return nil
}

// UptimeHours returns how many hours the engine has been running.
func (e *SingboxEngine) UptimeHours() float64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if !e.running || e.startedAt.IsZero() {
		return 0
	}
	return time.Since(e.startedAt).Hours()
}

// GenerateClientConfig creates a sing-box client config JSON for iOS/macOS.
func (e *SingboxEngine) GenerateClientConfig(user VPNUser, servers []ServerEntry) ([]byte, error) {
	return generateClientConfig(e.cfg, user, servers)
}

// ---------------------------------------------------------------------------
// Internal helpers (must be called with e.mu held).
// ---------------------------------------------------------------------------

// writeConfigLocked generates the server config and writes it atomically.
func (e *SingboxEngine) writeConfigLocked() error {
	data, err := e.buildServerConfig()
	if err != nil {
		return fmt.Errorf("build config: %w", err)
	}

	return atomicWrite(e.configPath, data)
}

// buildServerConfig generates the sing-box server JSON config from current state.
func (e *SingboxEngine) buildServerConfig() ([]byte, error) {
	// Build user list for the inbound.
	users := make([]singboxUser, 0, len(e.users))
	for _, u := range e.users {
		users = append(users, singboxUser{
			Name: u.Username,
			UUID: u.UUID,
			Flow: "xtls-rprx-vision",
		})
	}

	sni := e.cfg.Reality.SNI
	if sni == "" {
		sni = "ads.adfox.ru"
	}

	shortIDs := e.cfg.Reality.ShortIDs
	if len(shortIDs) == 0 {
		shortIDs = []string{""}
	}

	clashPort := e.cfg.ClashAPIPort
	if clashPort == 0 {
		clashPort = 9090
	}

	// Build services list (user-api if configured).
	var services []singboxService
	userAPIPort := e.cfg.UserAPIPort
	if userAPIPort > 0 {
		services = append(services, singboxService{
			Type:       "user-api",
			Tag:        "user-api",
			Listen:     "127.0.0.1",
			ListenPort: userAPIPort,
			Secret:     e.cfg.UserAPISecret,
		})
	}

	config := singboxServerConfig{
		Log: singboxLog{
			Level: "info",
		},
		DNS: singboxDNS{
			Servers: []singboxDNSServer{
				{Tag: "dns-local", Type: "local"},
			},
		},
		Inbounds: e.buildInboundsLocked(users, sni, shortIDs),
		Outbounds: []singboxOutbound{
			{
				Type: "direct",
				Tag:  "direct",
			},
		},
		Route: singboxRoute{
			DefaultDomainResolver: &singboxDomainResolver{
				Server:   "dns-local",
				Strategy: "ipv4_only",
			},
		},
		Services: services,
		Experimental: &singboxExperimental{
			ClashAPI: &singboxClashAPI{
				ExternalController: fmt.Sprintf("127.0.0.1:%d", clashPort),
			},
		},
	}

	// Enable v2ray_api stats service for per-user traffic accounting.
	// sing-box exposes gRPC StatsService which we query from the traffic collector.
	v2rayPort := e.cfg.V2RayAPIPort
	if v2rayPort == 0 {
		v2rayPort = 8080
	}
	userNames := make([]string, 0, len(e.users))
	for _, u := range e.users {
		userNames = append(userNames, u.Username)
	}
	config.Experimental.V2RayAPI = &singboxV2RayAPI{
		Listen: fmt.Sprintf("127.0.0.1:%d", v2rayPort),
		Stats: singboxV2RayAPIStats{
			Enabled:  true,
			Inbounds: []string{InboundTagVLESS},
			Users:    userNames,
		},
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal config: %w", err)
	}

	return data, nil
}

// buildInboundsLocked builds the inbound list: VLESS Reality + optional Hysteria2 + optional TUIC v5.
func (e *SingboxEngine) buildInboundsLocked(users []singboxUser, sni string, shortIDs []string) []any {
	inbounds := []any{
		singboxInbound{
			Type:       "vless",
			Tag:        InboundTagVLESS,
			Listen:     "::",
			ListenPort: e.cfg.ListenPort,
			Users:      users,
			TLS: &singboxTLS{
				Enabled:    true,
				ServerName: sni,
				Reality: &singboxReality{
					Enabled: true,
					Handshake: singboxHandshake{
						Server:     sni,
						ServerPort: 443,
					},
					PrivateKey: e.cfg.Reality.PrivateKey,
					ShortID:    shortIDs,
				},
			},
		},
	}

	if e.cfg.Hysteria2Port > 0 && e.cfg.UDPCertPath != "" {
		h2users := make([]singboxHysteria2User, 0, len(users))
		for _, u := range users {
			h2users = append(h2users, singboxHysteria2User{Password: u.UUID})
		}
		inbounds = append(inbounds, singboxHysteria2Inbound{
			Type:       "hysteria2",
			Tag:        "hysteria2-in",
			Listen:     "::",
			ListenPort: e.cfg.Hysteria2Port,
			Users:      h2users,
			TLS: &singboxUDPTLS{
				Enabled:         true,
				CertificatePath: e.cfg.UDPCertPath,
				KeyPath:         e.cfg.UDPKeyPath,
			},
		})
	}

	if e.cfg.TUICPort > 0 && e.cfg.UDPCertPath != "" {
		tuicUsers := make([]singboxTUICUser, 0, len(users))
		for _, u := range users {
			tuicUsers = append(tuicUsers, singboxTUICUser{
				Name:     u.Name,
				UUID:     u.UUID,
				Password: u.UUID,
			})
		}
		inbounds = append(inbounds, singboxTUICInbound{
			Type:              "tuic",
			Tag:               "tuic-in",
			Listen:            "::",
			ListenPort:        e.cfg.TUICPort,
			Users:             tuicUsers,
			CongestionControl: "bbr",
			TLS: &singboxUDPTLS{
				Enabled:         true,
				CertificatePath: e.cfg.UDPCertPath,
				KeyPath:         e.cfg.UDPKeyPath,
			},
		})
	}

	return inbounds
}

// startProcessLocked spawns sing-box as a child process.
func (e *SingboxEngine) startProcessLocked(ctx context.Context) error {
	procCtx, cancel := context.WithCancel(ctx)
	e.cancelFunc = cancel

	e.cmd = exec.CommandContext(procCtx, "sing-box", "run", "-c", e.configPath)
	e.cmd.Stdout = &zapWriter{logger: e.logger, level: zap.InfoLevel}
	e.cmd.Stderr = &zapWriter{logger: e.logger, level: zap.WarnLevel}

	if err := e.cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("start sing-box process: %w", err)
	}

	e.logger.Info("sing-box process started",
		zap.Int("pid", e.cmd.Process.Pid),
		zap.String("config", e.configPath),
	)

	// Monitor the process in the background.
	go func() {
		err := e.cmd.Wait()
		e.mu.Lock()
		wasRunning := e.running
		e.mu.Unlock()

		if wasRunning {
			e.logger.Error("sing-box process exited unexpectedly", zap.Error(err))
		} else {
			e.logger.Info("sing-box process exited", zap.Error(err))
		}
	}()

	return nil
}

// stopProcessLocked sends SIGTERM to the child process and waits up to 10 seconds.
func (e *SingboxEngine) stopProcessLocked() error {
	if e.cancelFunc != nil {
		e.cancelFunc()
		e.cancelFunc = nil
	}

	if e.cmd == nil || e.cmd.Process == nil {
		return nil
	}

	// Send SIGTERM for graceful shutdown.
	if err := e.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		e.logger.Warn("failed to send SIGTERM to sing-box", zap.Error(err))
		// Process may have already exited, not an error.
		return nil
	}

	// Wait for the process to exit with a timeout.
	done := make(chan error, 1)
	go func() {
		_, err := e.cmd.Process.Wait()
		done <- err
	}()

	select {
	case <-done:
		e.logger.Info("sing-box process terminated gracefully")
	case <-time.After(10 * time.Second):
		e.logger.Warn("sing-box process did not exit in 10s, sending SIGKILL")
		if err := e.cmd.Process.Kill(); err != nil {
			return fmt.Errorf("kill sing-box process: %w", err)
		}
	}

	e.cmd = nil
	return nil
}

// sendReloadLocked sends a reload signal (SIGHUP) to sing-box.
func (e *SingboxEngine) sendReloadLocked(ctx context.Context) error {
	switch e.mode {
	case ModeEmbedded:
		if e.cmd == nil || e.cmd.Process == nil {
			return fmt.Errorf("no running process to reload")
		}
		if err := e.cmd.Process.Signal(syscall.SIGHUP); err != nil {
			return fmt.Errorf("send SIGHUP: %w", err)
		}
		e.logger.Debug("sent SIGHUP to sing-box process", zap.Int("pid", e.cmd.Process.Pid))
		return nil

	case ModeDocker:
		return e.signalDockerLocked(ctx, "HUP")

	default:
		return fmt.Errorf("unknown mode %q", e.mode)
	}
}

// signalDockerLocked sends a signal to the Docker container.
func (e *SingboxEngine) signalDockerLocked(ctx context.Context, signal string) error {
	cmd := exec.CommandContext(ctx, "docker", "kill", "-s", signal, e.containerName)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker kill -s %s %s: %s: %w", signal, e.containerName, string(output), err)
	}
	e.logger.Debug("sent signal to docker container",
		zap.String("signal", signal),
		zap.String("container", e.containerName),
	)
	return nil
}

// ---------------------------------------------------------------------------
// Atomic file write
// ---------------------------------------------------------------------------

// atomicWrite writes data to path atomically by writing to a temp file first
// and then renaming it. This prevents sing-box from reading a partial config.
func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)

	tmp, err := os.CreateTemp(dir, ".singbox-config-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpPath := tmp.Name()

	// Clean up on failure.
	success := false
	defer func() {
		if !success {
			_ = os.Remove(tmpPath)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}

	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("sync temp file: %w", err)
	}

	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", tmpPath, path, err)
	}

	success = true
	return nil
}

// ---------------------------------------------------------------------------
// zapWriter bridges os.Writer to zap.Logger for process stdout/stderr.
// ---------------------------------------------------------------------------

type zapWriter struct {
	logger *zap.Logger
	level  zapcore.Level
}

func (w *zapWriter) Write(p []byte) (int, error) {
	msg := string(p)
	if w.level == zap.WarnLevel {
		w.logger.Warn(msg)
	} else {
		w.logger.Info(msg)
	}
	return len(p), nil
}

// Ensure zapWriter implements io.Writer.
var _ io.Writer = (*zapWriter)(nil)

// ---------------------------------------------------------------------------
// sing-box JSON config structures
// ---------------------------------------------------------------------------

type singboxServerConfig struct {
	Log          singboxLog           `json:"log"`
	DNS          singboxDNS           `json:"dns"`
	Inbounds     []any                `json:"inbounds"`
	Outbounds    []singboxOutbound    `json:"outbounds"`
	Route        singboxRoute         `json:"route"`
	Services     []singboxService     `json:"services,omitempty"`
	Experimental *singboxExperimental `json:"experimental,omitempty"`
}

type singboxLog struct {
	Level string `json:"level"`
}

type singboxDNS struct {
	Servers []singboxDNSServer `json:"servers"`
}

type singboxDNSServer struct {
	Tag  string `json:"tag"`
	Type string `json:"type"`
}

type singboxInbound struct {
	Type       string        `json:"type"`
	Tag        string        `json:"tag"`
	Listen     string        `json:"listen"`
	ListenPort int           `json:"listen_port"`
	Users      []singboxUser `json:"users"`
	TLS        *singboxTLS   `json:"tls,omitempty"`
}

type singboxHysteria2Inbound struct {
	Type       string                 `json:"type"`
	Tag        string                 `json:"tag"`
	Listen     string                 `json:"listen"`
	ListenPort int                    `json:"listen_port"`
	Users      []singboxHysteria2User `json:"users"`
	TLS        *singboxUDPTLS         `json:"tls"`
}

type singboxHysteria2User struct {
	Password string `json:"password"`
}

type singboxTUICInbound struct {
	Type               string          `json:"type"`
	Tag                string          `json:"tag"`
	Listen             string          `json:"listen"`
	ListenPort         int             `json:"listen_port"`
	Users              []singboxTUICUser `json:"users"`
	CongestionControl  string          `json:"congestion_control"`
	TLS                *singboxUDPTLS  `json:"tls"`
}

type singboxTUICUser struct {
	Name     string `json:"name"`
	UUID     string `json:"uuid"`
	Password string `json:"password"`
}

type singboxUDPTLS struct {
	Enabled         bool   `json:"enabled"`
	CertificatePath string `json:"certificate_path"`
	KeyPath         string `json:"key_path"`
}

type singboxUser struct {
	Name string `json:"name"`
	UUID string `json:"uuid"`
	Flow string `json:"flow,omitempty"`
}

type singboxTLS struct {
	Enabled    bool           `json:"enabled"`
	ServerName string         `json:"server_name"`
	Reality    *singboxReality `json:"reality,omitempty"`
}

type singboxReality struct {
	Enabled   bool             `json:"enabled"`
	Handshake singboxHandshake `json:"handshake"`
	PrivateKey string          `json:"private_key"`
	ShortID   []string         `json:"short_id"`
}

type singboxHandshake struct {
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
}

type singboxOutbound struct {
	Type           string `json:"type"`
	Tag            string `json:"tag"`
	DomainStrategy string `json:"domain_strategy,omitempty"`
}

type singboxRoute struct {
	DefaultDomainResolver *singboxDomainResolver `json:"default_domain_resolver,omitempty"`
}

type singboxDomainResolver struct {
	Server   string `json:"server"`
	Strategy string `json:"strategy"`
}

type singboxService struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Listen     string `json:"listen,omitempty"`
	ListenPort int    `json:"listen_port,omitempty"`
	Secret     string `json:"secret,omitempty"`
}

type singboxExperimental struct {
	ClashAPI *singboxClashAPI `json:"clash_api,omitempty"`
	V2RayAPI *singboxV2RayAPI `json:"v2ray_api,omitempty"`
}

type singboxClashAPI struct {
	ExternalController string `json:"external_controller"`
}

type singboxV2RayAPI struct {
	Listen string              `json:"listen"`
	Stats  singboxV2RayAPIStats `json:"stats"`
}

type singboxV2RayAPIStats struct {
	Enabled  bool     `json:"enabled"`
	Inbounds []string `json:"inbounds,omitempty"`
	Users    []string `json:"users,omitempty"`
}

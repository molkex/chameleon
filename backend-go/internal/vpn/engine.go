package vpn

import (
	"context"
)

// Engine defines the interface for VPN server management.
// This allows swapping implementations (sing-box, xray, mock) and testing.
type Engine interface {
	// Start initializes and starts the VPN server with given users.
	Start(ctx context.Context, cfg EngineConfig, users []VPNUser) error

	// Stop gracefully shuts down the VPN server.
	Stop() error

	// ReloadUsers updates the user list without restarting.
	// Returns the number of active users after reload.
	ReloadUsers(ctx context.Context, users []VPNUser) (int, error)

	// AddUser adds a single user to the running VPN server.
	AddUser(ctx context.Context, user VPNUser) error

	// RemoveUser removes a single user from the running VPN server.
	RemoveUser(ctx context.Context, username string) error

	// QueryTraffic returns per-user traffic since last query (resets counters).
	QueryTraffic(ctx context.Context) ([]UserTraffic, error)

	// OnlineUsers returns the count of currently connected users.
	OnlineUsers(ctx context.Context) (int, error)

	// SessionTraffic returns total upload/download bytes for the current engine session.
	SessionTraffic(ctx context.Context) (upload, download int64, err error)

	// CurrentSpeed returns real-time upload/download speed in bytes per second
	// and the count of active connections.
	CurrentSpeed(ctx context.Context) (uploadBPS, downloadBPS int64, connections int, err error)

	// Health checks if the VPN server is running and healthy.
	Health(ctx context.Context) error

	// UptimeHours returns how many hours the VPN engine has been running.
	UptimeHours() float64

	// GenerateClientConfig creates a sing-box client config JSON for iOS/macOS.
	GenerateClientConfig(user VPNUser, servers []ServerEntry) ([]byte, error)
}

// EngineConfig holds VPN server configuration.
type EngineConfig struct {
	ListenPort      int
	Reality         RealityConfig
	ClashAPIPort    int    // Clash API port for stats collection; default: 9090
	ClientMTU       int    // MTU for client TUN interface; default: 1400
	DNSRemote       string // Remote DNS-over-HTTPS URL; default: "https://1.1.1.1/dns-query"
	DNSDirect       string // Direct DNS-over-HTTPS URL; default: "https://8.8.8.8/dns-query"
	UrltestInterval string // Interval for urltest probing; default: "3m"
	UserAPIPort     int    // User API port for runtime user management; default: 15380; 0 = disabled
	UserAPISecret   string // Bearer token for User API auth
	V2RayAPIPort    int    // v2ray_api gRPC port for per-user traffic stats; default: 8080; 0 = disabled
	// UDP protocols (Hysteria2 and TUIC v5). Both share the same TLS cert.
	Hysteria2Port int    // Hysteria2 UDP listen port; 0 = disabled
	TUICPort      int    // TUIC v5 UDP listen port; 0 = disabled
	UDPCertPath   string // path to TLS certificate PEM for Hysteria2/TUIC (inside container)
	UDPKeyPath    string // path to TLS private key PEM for Hysteria2/TUIC (inside container)
}

// RealityConfig holds VLESS Reality TLS settings.
type RealityConfig struct {
	PrivateKey string
	PublicKey  string   // public key sent to clients for TLS verification
	ShortIDs   []string
	SNI        string // server name for TLS handshake destination
}

// VPNUser represents a user that can connect to the VPN.
type VPNUser struct {
	Username string
	UUID     string
	ShortID  string
}

// ServerEntry represents a VPN server for client config generation.
type ServerEntry struct {
	Key              string
	Name             string
	Host             string
	Port             int
	Flag             string
	SNI              string
	RealityPublicKey string // per-server Reality public key (empty = use engine default)
	Hysteria2Port    int    // 0 = server doesn't support Hysteria2
	TUICPort         int    // 0 = server doesn't support TUIC v5
}

// UserTraffic contains traffic counters for a single user.
type UserTraffic struct {
	Username string
	Upload   int64 // bytes
	Download int64 // bytes
}

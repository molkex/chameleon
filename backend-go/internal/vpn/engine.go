package vpn

import (
	"context"
	"time"
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

	// Health checks if the VPN server is running and healthy.
	Health(ctx context.Context) error

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
}

// RealityConfig holds VLESS Reality TLS settings.
type RealityConfig struct {
	PrivateKey string
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
	Key  string
	Name string
	Host string
	Port int
	Flag string
	SNI  string
}

// UserTraffic contains traffic counters for a single user.
type UserTraffic struct {
	Username string
	Upload   int64 // bytes
	Download int64 // bytes
}

// Stats contains aggregated VPN server statistics.
type Stats struct {
	OnlineUsers    int
	TotalUpload    int64
	TotalDownload  int64
	Uptime         time.Duration
	ServerVersion  string
}

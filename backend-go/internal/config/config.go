// Package config provides typed, validated configuration loading for Chameleon VPN backend.
//
// Configuration is loaded from a YAML file with support for:
//   - Environment variable substitution for secrets (${VAR_NAME} syntax)
//   - Strict validation of all required fields
//   - Sensible defaults for non-critical settings
//   - Duration fields parsed from human-readable strings (e.g. "1h", "30s")
package config

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config is the top-level application configuration.
// All sections are required to be present in the YAML file,
// though individual fields within sections may have defaults.
type Config struct {
	Server    ServerConfig    `yaml:"server"`
	Database  DatabaseConfig  `yaml:"database"`
	Redis     RedisConfig     `yaml:"redis"`
	Auth      AuthConfig      `yaml:"auth"`
	VPN       VPNConfig       `yaml:"vpn"`
	Cluster   ClusterConfig   `yaml:"cluster"`
	RateLimit RateLimitConfig `yaml:"rate_limit"`
}

// ServerConfig controls the HTTP listener.
type ServerConfig struct {
	Host        string   `yaml:"host"`         // default: "0.0.0.0"
	Port        int      `yaml:"port"`         // default: 8000
	CORSOrigins []string `yaml:"cors_origins"` // default: localhost dev + admin.chameleonvpn.com
}

// DatabaseConfig controls the PostgreSQL connection pool.
type DatabaseConfig struct {
	URL             string   `yaml:"url"`               // required; supports ${ENV_VAR}
	MaxConns        int      `yaml:"max_conns"`         // default: 25
	MinConns        int      `yaml:"min_conns"`         // default: 5
	MaxConnLifetime Duration `yaml:"max_conn_lifetime"` // default: 1h
}

// RedisConfig controls the Redis connection.
type RedisConfig struct {
	URL string `yaml:"url"` // required; supports ${ENV_VAR}
}

// AuthConfig controls authentication and authorization.
// Admin credentials are stored in the database (admin_users table), not in config.
// Use the CLI command `chameleon admin create` to create the first admin user.
type AuthConfig struct {
	JWTSecret     string   `yaml:"jwt_secret"`      // required; supports ${ENV_VAR}
	AccessTTL     Duration `yaml:"jwt_access_ttl"`  // default: 24h
	RefreshTTL    Duration `yaml:"jwt_refresh_ttl"` // default: 720h (30 days)
	AppleBundleID string   `yaml:"apple_bundle_id"` // default: "com.chameleonvpn.app"
}

// VPNConfig controls VPN protocol settings and server entries.
type VPNConfig struct {
	ListenPort      int           `yaml:"listen_port"`       // default: 2096
	Reality         RealityConfig `yaml:"reality"`
	Servers         []ServerEntry `yaml:"servers"`
	ClientMTU       int           `yaml:"client_mtu"`        // default: 1400
	DNSRemote       string        `yaml:"dns_remote"`        // default: "https://1.1.1.1/dns-query"
	DNSDirect       string        `yaml:"dns_direct"`        // default: "https://8.8.8.8/dns-query"
	UrltestInterval Duration      `yaml:"urltest_interval"`  // default: 3m
	ClashAPIPort    int           `yaml:"clash_api_port"`    // default: 9090
	UserAPIPort     int           `yaml:"user_api_port"`     // default: 15380; 0 = disabled
	UserAPISecret   string        `yaml:"user_api_secret"`   // supports ${ENV_VAR}
}

// RealityConfig holds VLESS Reality protocol settings.
type RealityConfig struct {
	PrivateKey string            `yaml:"private_key"` // required; supports ${ENV_VAR}
	PublicKey  string            `yaml:"public_key"`  // required; supports ${ENV_VAR}
	ShortIDs   []string          `yaml:"short_ids"`
	SNIs       map[string]string `yaml:"snis"` // key -> SNI hostname
}

// ServerEntry describes a single VPN node.
type ServerEntry struct {
	Key  string `yaml:"key"`  // unique identifier, e.g. "de", "nl"
	Name string `yaml:"name"` // human-readable name, e.g. "Germany"
	Host string `yaml:"host"` // IP address or domain
	Port int    `yaml:"port"` // listen port
	Flag string `yaml:"flag"` // emoji flag for UI
	SNI  string `yaml:"sni"`  // per-server SNI override (optional)
}

// ClusterConfig controls multi-node cluster synchronization.
type ClusterConfig struct {
	Enabled              bool         `yaml:"enabled"`
	NodeID               string       `yaml:"node_id"`
	Secret               string       `yaml:"secret"`                 // shared secret for cluster auth; supports ${ENV_VAR}
	SyncInterval         Duration     `yaml:"sync_interval"`          // default: 30s
	ReconcileInterval    Duration     `yaml:"reconcile_interval"`     // default: 5m (full sync fallback)
	PubSubChannel        string       `yaml:"pubsub_channel"`         // default: "chameleon:sync"
	Peers                []PeerConfig `yaml:"peers"`
}

// RateLimitConfig controls per-endpoint rate limiting.
type RateLimitConfig struct {
	MobilePerMinute int `yaml:"mobile_per_minute"` // default: 60
	AdminPerMinute  int `yaml:"admin_per_minute"`  // default: 120
}

// PeerConfig describes a cluster peer node.
type PeerConfig struct {
	ID  string `yaml:"id"`
	URL string `yaml:"url"`
}

// Duration wraps time.Duration to support YAML unmarshalling from strings like "1h", "30s", "720h".
type Duration struct {
	time.Duration
}

// UnmarshalYAML parses a duration string (e.g. "1h30m", "30s") into a Duration.
func (d *Duration) UnmarshalYAML(value *yaml.Node) error {
	var raw string
	if err := value.Decode(&raw); err != nil {
		return fmt.Errorf("duration value must be a string: %w", err)
	}

	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return fmt.Errorf("invalid duration %q: %w", raw, err)
	}

	d.Duration = parsed
	return nil
}

// MarshalYAML serializes a Duration back to its string representation.
func (d Duration) MarshalYAML() (interface{}, error) {
	return d.Duration.String(), nil
}

// envVarPattern matches ${VAR_NAME} placeholders in configuration values.
var envVarPattern = regexp.MustCompile(`^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$`)

// Load reads configuration from the YAML file at the given path,
// resolves environment variable placeholders, applies defaults,
// and validates all required fields.
//
// Returns a fully initialized Config or a descriptive error.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: failed to read file %q: %w", path, err)
	}

	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("config: failed to parse YAML from %q: %w", path, err)
	}

	cfg.resolveAllEnvVars()
	cfg.applyDefaults()

	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("config: validation failed: %w", err)
	}

	return cfg, nil
}

// resolveEnvVars checks whether a string is an environment variable reference
// (i.e. matches ${VAR_NAME} exactly) and resolves it from the environment.
// If the string is not a reference, it is returned unchanged.
// If the referenced environment variable is empty, an empty string is returned
// (validation will catch missing required values later).
func resolveEnvVars(s string) string {
	matches := envVarPattern.FindStringSubmatch(s)
	if matches == nil {
		return s
	}
	return os.Getenv(matches[1])
}

// resolveAllEnvVars walks all string fields that support environment variable
// substitution and resolves them in place.
func (c *Config) resolveAllEnvVars() {
	// Database
	c.Database.URL = resolveEnvVars(c.Database.URL)

	// Redis
	c.Redis.URL = resolveEnvVars(c.Redis.URL)

	// Auth secrets
	c.Auth.JWTSecret = resolveEnvVars(c.Auth.JWTSecret)

	// VPN Reality
	c.VPN.Reality.PrivateKey = resolveEnvVars(c.VPN.Reality.PrivateKey)
	c.VPN.Reality.PublicKey = resolveEnvVars(c.VPN.Reality.PublicKey)

	// VPN User API
	c.VPN.UserAPISecret = resolveEnvVars(c.VPN.UserAPISecret)

	// Cluster
	c.Cluster.Secret = resolveEnvVars(c.Cluster.Secret)
}

// applyDefaults sets sensible default values for fields that were not
// specified in the configuration file.
func (c *Config) applyDefaults() {
	// Server defaults
	if c.Server.Host == "" {
		c.Server.Host = "0.0.0.0"
	}
	if c.Server.Port == 0 {
		c.Server.Port = 8000
	}
	if len(c.Server.CORSOrigins) == 0 {
		c.Server.CORSOrigins = []string{
			"http://localhost:3000",
			"http://localhost:5173",
			"https://admin.chameleonvpn.com",
		}
	}

	// Database defaults
	if c.Database.MaxConns == 0 {
		c.Database.MaxConns = 25
	}
	if c.Database.MinConns == 0 {
		c.Database.MinConns = 5
	}
	if c.Database.MaxConnLifetime.Duration == 0 {
		c.Database.MaxConnLifetime.Duration = 1 * time.Hour
	}

	// Auth defaults
	if c.Auth.AccessTTL.Duration == 0 {
		c.Auth.AccessTTL.Duration = 24 * time.Hour
	}
	if c.Auth.RefreshTTL.Duration == 0 {
		c.Auth.RefreshTTL.Duration = 720 * time.Hour
	}
	if c.Auth.AppleBundleID == "" {
		c.Auth.AppleBundleID = "com.chameleonvpn.app"
	}

	// VPN defaults
	if c.VPN.ListenPort == 0 {
		c.VPN.ListenPort = 2096
	}
	if c.VPN.ClientMTU == 0 {
		c.VPN.ClientMTU = 1400
	}
	if c.VPN.DNSRemote == "" {
		c.VPN.DNSRemote = "https://1.1.1.1/dns-query"
	}
	if c.VPN.DNSDirect == "" {
		c.VPN.DNSDirect = "https://8.8.8.8/dns-query"
	}
	if c.VPN.UrltestInterval.Duration == 0 {
		c.VPN.UrltestInterval.Duration = 3 * time.Minute
	}
	if c.VPN.ClashAPIPort == 0 {
		c.VPN.ClashAPIPort = 9090
	}
	// UserAPIPort: 0 = disabled (no default — must be explicitly configured)

	// Cluster defaults
	if c.Cluster.SyncInterval.Duration == 0 {
		c.Cluster.SyncInterval.Duration = 30 * time.Second
	}
	if c.Cluster.ReconcileInterval.Duration == 0 {
		c.Cluster.ReconcileInterval.Duration = 5 * time.Minute
	}
	if c.Cluster.PubSubChannel == "" {
		c.Cluster.PubSubChannel = "chameleon:sync"
	}

	// Rate limit defaults
	if c.RateLimit.MobilePerMinute == 0 {
		c.RateLimit.MobilePerMinute = 60
	}
	if c.RateLimit.AdminPerMinute == 0 {
		c.RateLimit.AdminPerMinute = 120
	}
}

// validationError accumulates multiple field-level validation errors
// into a single, readable error message.
type validationError struct {
	fields []string
}

func (ve *validationError) add(field, reason string) {
	ve.fields = append(ve.fields, fmt.Sprintf("  - %s: %s", field, reason))
}

func (ve *validationError) hasErrors() bool {
	return len(ve.fields) > 0
}

func (ve *validationError) Error() string {
	return fmt.Sprintf("missing or invalid configuration fields:\n%s", strings.Join(ve.fields, "\n"))
}

// validate checks that all required configuration fields are present
// and contain valid values. Returns a descriptive error listing all
// problems found, or nil if the configuration is valid.
func (c *Config) validate() error {
	ve := &validationError{}

	// Server
	if c.Server.Port < 1 || c.Server.Port > 65535 {
		ve.add("server.port", fmt.Sprintf("must be between 1 and 65535, got %d", c.Server.Port))
	}

	// Database
	if c.Database.URL == "" {
		ve.add("database.url", "required (set DATABASE_URL env var or provide in config)")
	}
	if c.Database.MaxConns < 1 {
		ve.add("database.max_conns", "must be at least 1")
	}
	if c.Database.MinConns < 0 {
		ve.add("database.min_conns", "must be non-negative")
	}
	if c.Database.MinConns > c.Database.MaxConns {
		ve.add("database.min_conns", fmt.Sprintf("must not exceed max_conns (%d), got %d", c.Database.MaxConns, c.Database.MinConns))
	}

	// Redis
	if c.Redis.URL == "" {
		ve.add("redis.url", "required (set REDIS_URL env var or provide in config)")
	}

	// Auth
	if c.Auth.JWTSecret == "" {
		ve.add("auth.jwt_secret", "required (set JWT_SECRET env var or provide in config)")
	} else if len(c.Auth.JWTSecret) < 32 {
		ve.add("auth.jwt_secret", "must be at least 32 characters for adequate security")
	}
	if c.Auth.AccessTTL.Duration <= 0 {
		ve.add("auth.jwt_access_ttl", "must be a positive duration")
	}
	if c.Auth.RefreshTTL.Duration <= 0 {
		ve.add("auth.jwt_refresh_ttl", "must be a positive duration")
	}
	if c.Auth.RefreshTTL.Duration < c.Auth.AccessTTL.Duration {
		ve.add("auth.jwt_refresh_ttl", "must be greater than or equal to jwt_access_ttl")
	}

	// VPN
	if c.VPN.ListenPort < 1 || c.VPN.ListenPort > 65535 {
		ve.add("vpn.listen_port", fmt.Sprintf("must be between 1 and 65535, got %d", c.VPN.ListenPort))
	}

	// VPN Server entries
	seenKeys := make(map[string]bool, len(c.VPN.Servers))
	for i, srv := range c.VPN.Servers {
		prefix := fmt.Sprintf("vpn.servers[%d]", i)
		if srv.Key == "" {
			ve.add(prefix+".key", "required")
		} else if seenKeys[srv.Key] {
			ve.add(prefix+".key", fmt.Sprintf("duplicate key %q", srv.Key))
		} else {
			seenKeys[srv.Key] = true
		}
		if srv.Name == "" {
			ve.add(prefix+".name", "required")
		}
		if srv.Host == "" {
			ve.add(prefix+".host", "required")
		}
		if srv.Port < 1 || srv.Port > 65535 {
			ve.add(prefix+".port", fmt.Sprintf("must be between 1 and 65535, got %d", srv.Port))
		}
	}

	// Cluster (only validate if enabled)
	if c.Cluster.Enabled {
		if c.Cluster.NodeID == "" {
			ve.add("cluster.node_id", "required when cluster is enabled")
		}
		if c.Cluster.Secret == "" {
			ve.add("cluster.secret", "required when cluster is enabled")
		} else if len(c.Cluster.Secret) < 32 {
			ve.add("cluster.secret", "must be at least 32 characters")
		}
		if c.Cluster.SyncInterval.Duration <= 0 {
			ve.add("cluster.sync_interval", "must be a positive duration")
		}
		for i, peer := range c.Cluster.Peers {
			prefix := fmt.Sprintf("cluster.peers[%d]", i)
			if peer.ID == "" {
				ve.add(prefix+".id", "required")
			}
			if peer.URL == "" {
				ve.add(prefix+".url", "required")
			}
		}
	}

	if ve.hasErrors() {
		return ve
	}
	return nil
}

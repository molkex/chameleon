package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeTestConfig writes a YAML config to a temporary file and returns the path.
func writeTestConfig(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("failed to write test config: %v", err)
	}
	return path
}

func TestLoad_ValidConfig(t *testing.T) {
	yaml := `
server:
  host: "127.0.0.1"
  port: 9000
database:
  url: "postgres://user:pass@localhost:5432/chameleon"
  max_conns: 10
  min_conns: 2
  max_conn_lifetime: "30m"
redis:
  url: "redis://localhost:6379"
auth:
  jwt_secret: "this-is-a-very-long-secret-key-for-testing-purposes-1234"
  jwt_access_ttl: "12h"
  jwt_refresh_ttl: "168h"
  apple_bundle_id: "com.test.app"
vpn:
  listen_port: 3000
  reality:
    private_key: "test-private-key"
    short_ids: ["abc123"]
    snis:
      default: "example.com"
  servers:
    - key: "de"
      name: "Germany"
      host: "1.2.3.4"
      port: 2096
      flag: "DE"
cluster:
  enabled: false
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}

	if cfg.Server.Host != "127.0.0.1" {
		t.Errorf("expected host 127.0.0.1, got %s", cfg.Server.Host)
	}
	if cfg.Server.Port != 9000 {
		t.Errorf("expected port 9000, got %d", cfg.Server.Port)
	}
	if cfg.Database.MaxConns != 10 {
		t.Errorf("expected max_conns 10, got %d", cfg.Database.MaxConns)
	}
	if cfg.Database.MaxConnLifetime.Duration != 30*time.Minute {
		t.Errorf("expected max_conn_lifetime 30m, got %v", cfg.Database.MaxConnLifetime.Duration)
	}
	if cfg.Auth.AccessTTL.Duration != 12*time.Hour {
		t.Errorf("expected access_ttl 12h, got %v", cfg.Auth.AccessTTL.Duration)
	}
	if len(cfg.VPN.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(cfg.VPN.Servers))
	}
	if cfg.VPN.Servers[0].Key != "de" {
		t.Errorf("expected server key 'de', got %q", cfg.VPN.Servers[0].Key)
	}
}

func TestLoad_Defaults(t *testing.T) {
	yaml := `
database:
  url: "postgres://localhost/chameleon"
redis:
  url: "redis://localhost:6379"
auth:
  jwt_secret: "this-is-a-very-long-secret-key-for-testing-purposes-1234"
vpn:
  reality:
    private_key: "key"
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}

	// Check defaults are applied
	if cfg.Server.Host != "0.0.0.0" {
		t.Errorf("expected default host 0.0.0.0, got %s", cfg.Server.Host)
	}
	if cfg.Server.Port != 8000 {
		t.Errorf("expected default port 8000, got %d", cfg.Server.Port)
	}
	if cfg.Database.MaxConns != 25 {
		t.Errorf("expected default max_conns 25, got %d", cfg.Database.MaxConns)
	}
	if cfg.Database.MinConns != 5 {
		t.Errorf("expected default min_conns 5, got %d", cfg.Database.MinConns)
	}
	if cfg.Database.MaxConnLifetime.Duration != 1*time.Hour {
		t.Errorf("expected default max_conn_lifetime 1h, got %v", cfg.Database.MaxConnLifetime.Duration)
	}
	if cfg.Auth.AccessTTL.Duration != 24*time.Hour {
		t.Errorf("expected default access_ttl 24h, got %v", cfg.Auth.AccessTTL.Duration)
	}
	if cfg.Auth.RefreshTTL.Duration != 720*time.Hour {
		t.Errorf("expected default refresh_ttl 720h, got %v", cfg.Auth.RefreshTTL.Duration)
	}
	if cfg.Auth.AppleBundleID != "com.madfrog.vpn" {
		t.Errorf("expected default apple_bundle_id, got %s", cfg.Auth.AppleBundleID)
	}
	if cfg.VPN.ListenPort != 2096 {
		t.Errorf("expected default listen_port 2096, got %d", cfg.VPN.ListenPort)
	}
	if cfg.Cluster.SyncInterval.Duration != 30*time.Second {
		t.Errorf("expected default sync_interval 30s, got %v", cfg.Cluster.SyncInterval.Duration)
	}
}

func TestLoad_EnvVarResolution(t *testing.T) {
	t.Setenv("TEST_DB_URL", "postgres://resolved@localhost/db")
	t.Setenv("TEST_JWT_SECRET", "resolved-secret-that-is-at-least-32-characters-long")

	yaml := `
database:
  url: "${TEST_DB_URL}"
redis:
  url: "redis://localhost:6379"
auth:
  jwt_secret: "${TEST_JWT_SECRET}"
vpn:
  reality:
    private_key: "key"
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}

	if cfg.Database.URL != "postgres://resolved@localhost/db" {
		t.Errorf("expected resolved DB URL, got %q", cfg.Database.URL)
	}
	if cfg.Auth.JWTSecret != "resolved-secret-that-is-at-least-32-characters-long" {
		t.Errorf("expected resolved JWT secret, got %q", cfg.Auth.JWTSecret)
	}
}

func TestLoad_ValidationErrors(t *testing.T) {
	tests := []struct {
		name string
		yaml string
	}{
		{
			name: "missing database url",
			yaml: `
redis:
  url: "redis://localhost"
auth:
  jwt_secret: "this-is-a-very-long-secret-key-for-testing-purposes-1234"
vpn:
  reality:
    private_key: "key"
`,
		},
		{
			name: "missing redis url",
			yaml: `
database:
  url: "postgres://localhost/db"
auth:
  jwt_secret: "this-is-a-very-long-secret-key-for-testing-purposes-1234"
vpn:
  reality:
    private_key: "key"
`,
		},
		{
			name: "jwt secret too short",
			yaml: `
database:
  url: "postgres://localhost/db"
redis:
  url: "redis://localhost"
auth:
  jwt_secret: "short"
vpn:
  reality:
    private_key: "key"
`,
		},
		{
			name: "duplicate server keys",
			yaml: `
database:
  url: "postgres://localhost/db"
redis:
  url: "redis://localhost"
auth:
  jwt_secret: "this-is-a-very-long-secret-key-for-testing-purposes-1234"
vpn:
  reality:
    private_key: "key"
  servers:
    - key: "de"
      name: "Germany"
      host: "1.2.3.4"
      port: 2096
    - key: "de"
      name: "Germany 2"
      host: "5.6.7.8"
      port: 2096
`,
		},
		{
			name: "cluster enabled without node_id",
			yaml: `
database:
  url: "postgres://localhost/db"
redis:
  url: "redis://localhost"
auth:
  jwt_secret: "this-is-a-very-long-secret-key-for-testing-purposes-1234"
vpn:
  reality:
    private_key: "key"
cluster:
  enabled: true
`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeTestConfig(t, tt.yaml)
			_, err := Load(path)
			if err == nil {
				t.Fatal("expected validation error, got nil")
			}
		})
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("/nonexistent/path/config.yaml")
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
}

func TestLoad_InvalidYAML(t *testing.T) {
	path := writeTestConfig(t, "{{invalid yaml}}")
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for invalid YAML, got nil")
	}
}

func TestResolveEnvVars_NoMatch(t *testing.T) {
	result := resolveEnvVars("plain-string")
	if result != "plain-string" {
		t.Errorf("expected 'plain-string', got %q", result)
	}
}

func TestResolveEnvVars_PartialMatch(t *testing.T) {
	// Should NOT resolve if it's not the entire value
	result := resolveEnvVars("prefix-${VAR}-suffix")
	if result != "prefix-${VAR}-suffix" {
		t.Errorf("expected unchanged string, got %q", result)
	}
}

func TestResolveEnvVars_EmptyEnv(t *testing.T) {
	t.Setenv("EMPTY_VAR", "")
	result := resolveEnvVars("${EMPTY_VAR}")
	if result != "" {
		t.Errorf("expected empty string, got %q", result)
	}
}

package config

import (
	"testing"
)

// Audit MED-013 (2026-05-26): Secrets.EncryptionKey must go through
// resolveAllEnvVars. Without it, the literal "${CHAMELEON_PROVIDERS_ENCRYPTION_KEY}"
// from config.production.yaml stays unresolved at runtime, and the
// provider-credential cipher falls back to no-op (plaintext in DB).

func TestEncryptionKey_ResolvedFromEnv(t *testing.T) {
	t.Setenv("CHAMELEON_PROVIDERS_ENCRYPTION_KEY", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
	cfg := &Config{}
	cfg.Secrets.EncryptionKey = "${CHAMELEON_PROVIDERS_ENCRYPTION_KEY}"
	cfg.resolveAllEnvVars()
	if got := cfg.Secrets.EncryptionKey; got != "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" {
		t.Errorf("EncryptionKey should be resolved from env, got %q", got)
	}
}

func TestEncryptionKey_LiteralPreservedWhenNotEnvSyntax(t *testing.T) {
	// A bare-hex value in YAML (no ${}) should pass through unchanged —
	// supports dev configs that hard-code a non-prod KEK.
	cfg := &Config{}
	cfg.Secrets.EncryptionKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	cfg.resolveAllEnvVars()
	if cfg.Secrets.EncryptionKey != "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" {
		t.Errorf("literal hex EncryptionKey should pass through unchanged, got %q", cfg.Secrets.EncryptionKey)
	}
}

func TestEncryptionKey_EmptyWhenEnvMissing(t *testing.T) {
	// If the env var doesn't exist, resolveEnvVars returns the empty
	// string — cipher init will then log "provider passwords plaintext"
	// and we want that loud warning to fire, not a silent crash.
	cfg := &Config{}
	cfg.Secrets.EncryptionKey = "${CHAMELEON_NONEXISTENT_KEY_FOR_TEST}"
	cfg.resolveAllEnvVars()
	if cfg.Secrets.EncryptionKey != "" {
		t.Errorf("missing env should resolve to empty, got %q", cfg.Secrets.EncryptionKey)
	}
}

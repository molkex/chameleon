//go:build e2e

// E2E tests verify that the sing-box client configs we generate for iOS pass
// `sing-box check`. Catches schema drift / deprecated fields before they ship
// to a real device. Requires `sing-box` binary in PATH. Trigger:
//
//	go test -tags=e2e ./tests/e2e/...
package e2e

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestSingboxCheckMinimalConfig asserts that the harness can: write a JSON
// config to a temp file, invoke `sing-box check`, and parse exit status.
// This proves the e2e infrastructure works. Real client-config generation
// (via vpn.GenerateClientConfig) lands in a follow-up once test fixtures
// for User + ServerEntry are available.
func TestSingboxCheckMinimalConfig(t *testing.T) {
	if _, err := exec.LookPath("sing-box"); err != nil {
		t.Skip("sing-box not in PATH — install from https://sing-box.app")
	}

	cfg := map[string]any{
		"log":       map[string]any{"level": "warn"},
		"inbounds":  []any{},
		"outbounds": []any{map[string]any{"type": "direct", "tag": "direct"}},
	}
	body, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	out, err := exec.Command("sing-box", "check", "-c", path).CombinedOutput()
	if err != nil {
		t.Fatalf("sing-box check failed: %v\nout: %s", err, out)
	}
}

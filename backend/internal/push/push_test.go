// push_test.go covers the two parts of the APNs sender that don't need a live
// connection: provider-token signing (a parseable ES256 JWT with the right
// iss/kid) and the payload wire shape (aps dictionary + merged custom keys).
//
// Plain unit tests (no build tag) — run with `go test ./internal/push/`.
package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// newTestClient builds a Client backed by a throwaway P-256 key — enough to
// sign a token without touching any .p8 file or env.
func newTestClient(t *testing.T) *Client {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return &Client{
		key:    key,
		keyID:  "ABC1234567",
		teamID: "TEAM999999",
		topic:  "com.madfrog.vpn",
	}
}

func TestTokenSignsValidES256(t *testing.T) {
	c := newTestClient(t)

	signed, err := c.token()
	if err != nil {
		t.Fatalf("token(): %v", err)
	}

	// Parse back with the public key, asserting ES256 and reading the claims.
	parsed, err := jwt.Parse(signed, func(tok *jwt.Token) (any, error) {
		if _, ok := tok.Method.(*jwt.SigningMethodECDSA); !ok {
			t.Errorf("alg = %v, want ECDSA", tok.Header["alg"])
		}
		return &c.key.PublicKey, nil
	})
	if err != nil {
		t.Fatalf("parse token: %v", err)
	}
	if !parsed.Valid {
		t.Fatal("token not valid")
	}

	if got := parsed.Header["kid"]; got != c.keyID {
		t.Errorf("header kid = %v, want %q", got, c.keyID)
	}
	if got := parsed.Header["alg"]; got != "ES256" {
		t.Errorf("header alg = %v, want ES256", got)
	}

	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		t.Fatalf("claims type = %T", parsed.Claims)
	}
	if got, _ := claims["iss"].(string); got != c.teamID {
		t.Errorf("iss = %q, want %q", got, c.teamID)
	}
	if _, ok := claims["iat"]; !ok {
		t.Error("iat claim missing")
	}
}

func TestTokenIsCachedThenRefreshed(t *testing.T) {
	c := newTestClient(t)

	first, err := c.token()
	if err != nil {
		t.Fatalf("token() #1: %v", err)
	}
	second, err := c.token()
	if err != nil {
		t.Fatalf("token() #2: %v", err)
	}
	if first != second {
		t.Error("expected the cached token to be reused within the refresh window")
	}

	// Backdate the issue time past the refresh window → next call re-mints.
	c.mu.Lock()
	c.tokenIssued = time.Now().Add(-2 * tokenRefresh)
	c.mu.Unlock()

	third, err := c.token()
	if err != nil {
		t.Fatalf("token() #3: %v", err)
	}
	if third == second {
		t.Error("expected a fresh token after the refresh window elapsed")
	}
}

func TestBuildPayloadShape(t *testing.T) {
	p := buildPayload("Поддержка MadFrog", "Привет", map[string]any{
		"type":      "support_reply",
		"thread_id": 42,
	})

	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// Custom keys at the top level.
	if got["type"] != "support_reply" {
		t.Errorf("top-level type = %v, want support_reply", got["type"])
	}
	if tid, _ := got["thread_id"].(float64); tid != 42 {
		t.Errorf("top-level thread_id = %v, want 42", got["thread_id"])
	}

	// aps.alert.{title,body} + sound + badge.
	aps, ok := got["aps"].(map[string]any)
	if !ok {
		t.Fatalf("aps missing or wrong type: %T", got["aps"])
	}
	alert, ok := aps["alert"].(map[string]any)
	if !ok {
		t.Fatalf("aps.alert missing: %T", aps["alert"])
	}
	if alert["title"] != "Поддержка MadFrog" {
		t.Errorf("alert.title = %v", alert["title"])
	}
	if alert["body"] != "Привет" {
		t.Errorf("alert.body = %v", alert["body"])
	}
	if aps["sound"] != "default" {
		t.Errorf("aps.sound = %v, want default", aps["sound"])
	}
	if badge, _ := aps["badge"].(float64); badge != 1 {
		t.Errorf("aps.badge = %v, want 1", aps["badge"])
	}
}

// TestBuildPayloadCustomCannotClobberAps ensures a custom "aps" key can't
// overwrite the real alert dictionary.
func TestBuildPayloadCustomCannotClobberAps(t *testing.T) {
	p := buildPayload("t", "b", map[string]any{"aps": "evil"})
	aps, ok := p["aps"].(map[string]any)
	if !ok {
		t.Fatalf("custom aps clobbered the alert dictionary: %T", p["aps"])
	}
	if _, ok := aps["alert"]; !ok {
		t.Error("aps.alert missing after a custom aps key was supplied")
	}
}

func TestParseECKeyRejectsNonPEM(t *testing.T) {
	if _, err := parseECKey([]byte("not a pem")); err == nil {
		t.Error("expected error on non-PEM input")
	}
}

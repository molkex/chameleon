package apple

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// These tests pin the security-critical REJECTION surface of the Apple IAP
// verifier — the part that stops forged / short-chain / malformed JWS from being
// credited, and guarantees we never panic on hostile input. The happy path
// (a real Apple-root-signed JWS → credited Transaction) is NOT covered here:
// go-iap's ParseSignedTransaction pins Apple's production root CA, so a valid
// signed transaction can only be produced by Apple. That half needs a sandbox /
// integration test with a real signed JWS (tracked as the remainder of
// TEST-APPLE-IAP in state/test-map.yaml).

// makeJWS builds a fake compact JWS "<header>.<payload>.<sig>" whose header
// carries an x5c chain of length n, encoded with enc. assertRealAppleChain only
// inspects the header, so payload/sig are arbitrary placeholders.
func makeJWS(t *testing.T, n int, enc *base64.Encoding) string {
	t.Helper()
	x5c := make([]string, n)
	for i := range x5c {
		x5c[i] = "MIIBfakecert" // arbitrary; not a real DER cert
	}
	hdr, err := json.Marshal(map[string]any{"alg": "ES256", "x5c": x5c})
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	return enc.EncodeToString(hdr) + ".cGF5bG9hZA.c2ln"
}

func TestAssertRealAppleChain(t *testing.T) {
	std := base64.RawStdEncoding
	url := base64.RawURLEncoding

	tests := []struct {
		name    string
		jws     string
		wantErr string // substring to look for; "" = expect success
	}{
		{"two segments", "a.b", "malformed JWS"},
		{"four segments", "a.b.c.d", "malformed JWS"},
		{"undecodable header", "!!!.payload.sig", "decode JWS header"},
		{"header not json", std.EncodeToString([]byte("not json")) + ".p.s", "parse JWS header"},
		{"zero certs", makeJWS(t, 0, std), "x5c chain too short"},
		{"one cert (Xcode local signing)", makeJWS(t, 1, std), "x5c chain too short"},
		{"two certs", makeJWS(t, 2, std), "x5c chain too short"},
		{"three certs accepted (std b64)", makeJWS(t, 3, std), ""},
		{"three certs accepted (url b64)", makeJWS(t, 3, url), ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := assertRealAppleChain(tc.jws)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want nil error, got %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestNew(t *testing.T) {
	if _, err := New(Config{Products: map[string]int{"p": 30}}); err == nil {
		t.Error("want error for empty BundleID, got nil")
	}
	if _, err := New(Config{BundleID: "com.madfrog.vpn"}); err == nil {
		t.Error("want error for empty Products, got nil")
	}
	v, err := New(Config{BundleID: "com.madfrog.vpn", Products: map[string]int{"sub.30days": 30}})
	if err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	if v == nil {
		t.Fatal("New returned nil verifier with nil error")
	}
}

// TestVerifyRejectsBadInput proves Verify returns a clean error (never panics)
// for every shape of hostile/invalid input — including a structurally valid
// 3-cert chain whose certs are bogus (must fail the signature/chain parse,
// not be accepted).
func TestVerifyRejectsBadInput(t *testing.T) {
	v, err := New(Config{BundleID: "com.madfrog.vpn", Products: map[string]int{"sub.30days": 30}})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	cases := []struct {
		name    string
		jws     string
		wantErr string
	}{
		{"empty", "", "empty"},
		{"whitespace only", "   ", "empty"},
		{"malformed (not 3 segments)", "abc", "malformed JWS"},
		{"short chain — forged/local signing", makeJWS(t, 1, base64.RawStdEncoding), "x5c chain too short"},
		{"three bogus certs — fails chain parse", makeJWS(t, 3, base64.RawStdEncoding), "parse signed transaction"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := v.Verify(tc.jws)
			if err == nil {
				t.Fatalf("want error, got tx=%+v", tx)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestVerifyNotificationRejectsEmpty(t *testing.T) {
	v, err := New(Config{BundleID: "com.madfrog.vpn", Products: map[string]int{"sub.30days": 30}})
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	if _, err := v.VerifyNotification("   "); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("want empty-payload error, got %v", err)
	}
}

func TestMsToTime(t *testing.T) {
	if got := msToTime(0); !got.IsZero() {
		t.Errorf("msToTime(0) = %v, want zero time", got)
	}
	const ms = int64(1_700_000_000_000)
	if got := msToTime(ms); got.UnixMilli() != ms {
		t.Errorf("msToTime(%d).UnixMilli() = %d, want %d", ms, got.UnixMilli(), ms)
	}
}

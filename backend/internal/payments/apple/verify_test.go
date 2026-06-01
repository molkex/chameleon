package apple

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	iap "github.com/awa/go-iap/appstore/api"
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

// --- applyInvariants: the credit-decision logic, testable post-refactor ---

func mustVerifier(t *testing.T, opts ...func(*Config)) *Verifier {
	t.Helper()
	cfg := Config{BundleID: "com.madfrog.vpn", Products: map[string]int{"sub.30days": 30}}
	for _, o := range opts {
		o(&cfg)
	}
	v, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return v
}

// baseTx is a valid Production transaction for "sub.30days".
func baseTx() *iap.JWSTransaction {
	return &iap.JWSTransaction{
		BundleID:              "com.madfrog.vpn",
		ProductID:             "sub.30days",
		Environment:           iap.Environment("Production"),
		OriginalTransactionId: "orig-1",
		TransactionID:         "txn-1",
		PurchaseDate:          1_700_000_000_000,
		ExpiresDate:           1_700_500_000_000,
		AppAccountToken:       "  tok-uuid  ",
	}
}

func TestApplyInvariants_Happy(t *testing.T) {
	v := mustVerifier(t)
	tx, err := v.applyInvariants(baseTx())
	if err != nil {
		t.Fatalf("applyInvariants: %v", err)
	}
	if tx.Days != 30 {
		t.Errorf("Days = %d, want 30", tx.Days)
	}
	if tx.Revoked {
		t.Error("Revoked = true, want false")
	}
	if tx.OriginalTransactionID != "orig-1" {
		t.Errorf("OriginalTransactionID = %q", tx.OriginalTransactionID)
	}
	if tx.AppAccountToken != "tok-uuid" {
		t.Errorf("AppAccountToken = %q, want trimmed %q", tx.AppAccountToken, "tok-uuid")
	}
	if tx.PurchaseDate.UnixMilli() != 1_700_000_000_000 {
		t.Errorf("PurchaseDate = %v", tx.PurchaseDate)
	}
	if tx.Environment != EnvProduction {
		t.Errorf("Environment = %q", tx.Environment)
	}
}

func TestApplyInvariants_SandboxAllowed(t *testing.T) {
	v := mustVerifier(t, func(c *Config) { c.AllowSandbox = true })
	j := baseTx()
	j.Environment = iap.Environment("Sandbox")
	if _, err := v.applyInvariants(j); err != nil {
		t.Fatalf("sandbox with AllowSandbox=true should pass: %v", err)
	}
}

func TestApplyInvariants_Rejections(t *testing.T) {
	v := mustVerifier(t) // AllowSandbox=false
	tests := []struct {
		name    string
		mut     func(*iap.JWSTransaction)
		wantErr string
	}{
		{"bundle mismatch", func(j *iap.JWSTransaction) { j.BundleID = "com.evil.app" }, "bundle id mismatch"},
		{"sandbox rejected", func(j *iap.JWSTransaction) { j.Environment = iap.Environment("Sandbox") }, "sandbox transactions are not accepted"},
		{"unknown environment", func(j *iap.JWSTransaction) { j.Environment = iap.Environment("Xcode") }, "unknown environment"},
		{"unknown product", func(j *iap.JWSTransaction) { j.ProductID = "sub.999days" }, "unknown product id"},
		{"empty originalTransactionId", func(j *iap.JWSTransaction) { j.OriginalTransactionId = "" }, "originalTransactionId is empty"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			j := baseTx()
			tc.mut(j)
			_, err := v.applyInvariants(j)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestApplyInvariants_Revoked(t *testing.T) {
	v := mustVerifier(t)
	j := baseTx()
	j.RevocationDate = 1_700_400_000_000
	tx, err := v.applyInvariants(j)
	if !errors.Is(err, ErrRevoked) {
		t.Fatalf("want ErrRevoked, got %v", err)
	}
	if tx == nil || !tx.Revoked {
		t.Fatal("a revoked transaction must still be populated with Revoked=true")
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

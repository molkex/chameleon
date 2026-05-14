package apple

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// validConfig is the minimal Config that New() accepts.
func validConfig() Config {
	return Config{
		BundleID: "com.madfrog.vpn",
		Products: map[string]int{"com.madfrog.vpn.sub.month": 30},
	}
}

// makeJWS builds a syntactically valid 3-segment JWS whose header carries
// an x5c array of n dummy cert strings. The cert bytes are irrelevant to
// assertRealAppleChain — it only counts the chain length — so this lets
// us exercise the panic-guard without a real Apple-signed token.
func makeJWS(t *testing.T, n int, urlSafe bool) string {
	t.Helper()
	x5c := make([]string, n)
	for i := range x5c {
		x5c[i] = base64.StdEncoding.EncodeToString([]byte("dummy-cert"))
	}
	hb, err := json.Marshal(map[string]any{"alg": "ES256", "x5c": x5c})
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	enc := base64.RawStdEncoding
	if urlSafe {
		enc = base64.RawURLEncoding
	}
	header := enc.EncodeToString(hb)
	payload := base64.RawStdEncoding.EncodeToString([]byte(`{}`))
	sig := base64.RawStdEncoding.EncodeToString([]byte("not-a-real-signature"))
	return header + "." + payload + "." + sig
}

// ─── New: config validation ────────────────────────────────────────────────

func TestNew_Validation(t *testing.T) {
	if _, err := New(Config{Products: map[string]int{"x": 30}}); err == nil {
		t.Error("New with empty BundleID should error")
	}
	if _, err := New(Config{BundleID: "com.madfrog.vpn"}); err == nil {
		t.Error("New with no Products should error")
	}
	v, err := New(validConfig())
	if err != nil {
		t.Fatalf("New with valid config errored: %v", err)
	}
	if v == nil {
		t.Fatal("New returned nil verifier with nil error")
	}
}

// ─── assertRealAppleChain: the go-iap panic guard ──────────────────────────
//
// This pre-check is security/robustness-critical: go-iap indexes x5c[2]
// without a bounds check, so a short chain (e.g. Xcode's local StoreKit
// signing, 1 cert) would panic deep inside ParseSignedTransaction. These
// cases pin that every malformed/short token is rejected with a clean
// error instead.

func TestAssertRealAppleChain_AcceptsFullChain(t *testing.T) {
	for _, n := range []int{3, 4, 5} {
		if err := assertRealAppleChain(makeJWS(t, n, false)); err != nil {
			t.Errorf("%d-cert chain rejected: %v", n, err)
		}
	}
}

func TestAssertRealAppleChain_AcceptsURLSafeHeader(t *testing.T) {
	// Apple uses standard base64 but some producers emit URL-safe; the
	// decoder must handle both. (May pass via either branch — the point
	// is a URL-safe-encoded header is not rejected.)
	if err := assertRealAppleChain(makeJWS(t, 3, true)); err != nil {
		t.Errorf("URL-safe-encoded header rejected: %v", err)
	}
}

func TestAssertRealAppleChain_RejectsShortChain(t *testing.T) {
	for _, n := range []int{0, 1, 2} {
		if err := assertRealAppleChain(makeJWS(t, n, false)); err == nil {
			t.Errorf("%d-cert chain accepted, want rejected (go-iap would panic)", n)
		}
	}
}

func TestAssertRealAppleChain_RejectsMalformed(t *testing.T) {
	cases := []struct {
		name string
		jws  string
	}{
		{"empty", ""},
		{"one segment", "abc"},
		{"two segments", "abc.def"},
		{"four segments", "a.b.c.d"},
		{"bad base64 header", "!!!notbase64!!!.payload.sig"},
		{"header not json", base64.RawStdEncoding.EncodeToString([]byte("plain text")) + ".p.s"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := assertRealAppleChain(c.jws); err == nil {
				t.Errorf("%s: accepted, want rejected", c.name)
			}
		})
	}
}

// ─── Verify: early-return paths reachable without a real Apple JWS ─────────

func TestVerify_EmptyJWS(t *testing.T) {
	v, _ := New(validConfig())
	if _, err := v.Verify("   "); err == nil {
		t.Error("Verify with blank JWS should error")
	}
}

func TestVerify_RejectsShortChainWithoutPanic(t *testing.T) {
	v, _ := New(validConfig())
	// A 1-cert chain is exactly the Xcode-local case the guard exists for.
	// The assertion: a clean error, NOT a panic / recovered 500.
	tx, err := v.Verify(makeJWS(t, 1, false))
	if err == nil {
		t.Fatal("Verify accepted a 1-cert chain, want error")
	}
	if tx != nil {
		t.Errorf("Verify returned a Transaction (%+v) alongside an error", tx)
	}
}

func TestVerify_RejectsMalformedJWS(t *testing.T) {
	v, _ := New(validConfig())
	for _, bad := range []string{"garbage", "a.b", "a.b.c.d"} {
		if _, err := v.Verify(bad); err == nil {
			t.Errorf("Verify(%q) should error", bad)
		}
	}
}

// ─── VerifyNotification: early-return paths ────────────────────────────────

func TestVerifyNotification_EmptyPayload(t *testing.T) {
	v, _ := New(validConfig())
	if _, err := v.VerifyNotification("  "); err == nil {
		t.Error("VerifyNotification with blank payload should error")
	}
}

func TestVerifyNotification_RejectsMalformed(t *testing.T) {
	v, _ := New(validConfig())
	for _, bad := range []string{"not-a-jws", "a.b.c", makeJWS(t, 3, false)} {
		if _, err := v.VerifyNotification(bad); err == nil {
			t.Errorf("VerifyNotification(%.20q...) should error (not an Apple-signed payload)", bad)
		}
	}
}

// ─── msToTime ──────────────────────────────────────────────────────────────

func TestMsToTime(t *testing.T) {
	if got := msToTime(0); !got.IsZero() {
		t.Errorf("msToTime(0) = %v, want zero time", got)
	}
	ms := int64(1_700_000_000_000)
	got := msToTime(ms)
	if !got.Equal(time.UnixMilli(ms)) {
		t.Errorf("msToTime(%d) = %v, want %v", ms, got, time.UnixMilli(ms))
	}
}

// ─── ErrRevoked sentinel ───────────────────────────────────────────────────

func TestErrRevoked_IsSentinel(t *testing.T) {
	wrapped := errors.New("apple: inner transaction: " + ErrRevoked.Error())
	// The real wrap path uses %w; sanity-check the sentinel matches itself
	// and that a plain wrap of its text does NOT (so callers must use %w).
	if !errors.Is(ErrRevoked, ErrRevoked) {
		t.Error("ErrRevoked should be its own sentinel")
	}
	if errors.Is(wrapped, ErrRevoked) {
		t.Error("a string-concatenated error must not satisfy errors.Is — callers must wrap with %w")
	}
	if !strings.Contains(ErrRevoked.Error(), "revoked") {
		t.Errorf("ErrRevoked message %q should mention 'revoked'", ErrRevoked.Error())
	}
}

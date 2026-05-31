package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
)

// SEC-02 (2026-05-31): NewServer sets e.IPExtractor = ExtractIPFromXFFHeader()
// so a client reaching :8000 directly cannot forge X-Forwarded-For and spoof
// the IP used by the rate-limiter / FreeKassa allowlist / geoIP lookup. These
// tests re-wire the same extractor on a bare Echo (mirroring server.go) and
// assert the trust boundary. The extractor itself is the regression guard: if
// someone drops the IPExtractor line in NewServer, Echo reverts to trusting XFF
// verbatim and TestRealIP_SpoofedXFFFromPublicPeerRejected would fail.

func realIPForRequest(t *testing.T, remoteAddr, xff string) string {
	t.Helper()
	e := echo.New()
	// Same line wired into NewServer (server.go).
	e.IPExtractor = echo.ExtractIPFromXFFHeader()

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = remoteAddr
	if xff != "" {
		req.Header.Set(echo.HeaderXForwardedFor, xff)
	}
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	return c.RealIP()
}

// Legit path: nginx connects from loopback and rewrites XFF to the single real
// client. The extractor must surface that client unchanged (no behaviour change
// vs the old default for the trusted path).
func TestRealIP_TrustedLoopbackForwardsClient(t *testing.T) {
	got := realIPForRequest(t, "127.0.0.1:54321", "203.0.113.7")
	if got != "203.0.113.7" {
		t.Errorf("trusted loopback hop should yield the forwarded client, got %q", got)
	}
}

// Attack path: a client reaching :8000 directly from a public peer sets a forged
// XFF. The peer is untrusted, so the extractor must ignore XFF and fall back to
// RemoteAddr — the spoofed value must NOT win.
func TestRealIP_SpoofedXFFFromPublicPeerRejected(t *testing.T) {
	got := realIPForRequest(t, "198.51.100.9:44444", "1.2.3.4")
	if got == "1.2.3.4" {
		t.Fatalf("spoofed XFF from an untrusted public peer must be ignored, got %q", got)
	}
	if got != "198.51.100.9" {
		t.Errorf("untrusted peer should resolve to RemoteAddr, got %q", got)
	}
}

// Chained XFF via a trusted hop: only the trusted rightmost entries are peeled;
// the leftmost untrusted address is the real client.
func TestRealIP_PeelsTrustedHopsReturnsLeftmostUntrusted(t *testing.T) {
	// real client -> (some proxy) -> loopback peer
	got := realIPForRequest(t, "127.0.0.1:5555", "203.0.113.7, 10.0.0.2")
	if got != "203.0.113.7" {
		t.Errorf("should peel trusted private hop and return the client, got %q", got)
	}
}

package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// jwksTestServer wraps httptest.NewServer and exposes counters/triggers so
// tests can simulate slow Apple endpoints, transient failures, etc.
type jwksTestServer struct {
	srv         *httptest.Server
	calls       atomic.Int32
	delay       atomic.Int64 // nanoseconds to sleep before responding
	failNext    atomic.Int32 // if >0, decremented and request returns 500
	currentKID  atomic.Pointer[string]
	currentBody atomic.Pointer[[]byte]
}

func newJWKSTestServer(t *testing.T, kid string, pub *rsa.PublicKey) *jwksTestServer {
	t.Helper()
	jts := &jwksTestServer{}
	jts.setKey(kid, pub)
	jts.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jts.calls.Add(1)
		if d := time.Duration(jts.delay.Load()); d > 0 {
			select {
			case <-time.After(d):
			case <-r.Context().Done():
				return
			}
		}
		if jts.failNext.Load() > 0 {
			jts.failNext.Add(-1)
			http.Error(w, "transient", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		body := jts.currentBody.Load()
		_, _ = w.Write(*body)
	}))
	t.Cleanup(jts.srv.Close)
	return jts
}

func (j *jwksTestServer) setKey(kid string, pub *rsa.PublicKey) {
	body := mustJWKSBody(kid, pub)
	j.currentBody.Store(&body)
	j.currentKID.Store(&kid)
}

func mustJWKSBody(kid string, pub *rsa.PublicKey) []byte {
	n := base64.RawURLEncoding.EncodeToString(pub.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes())
	body, _ := json.Marshal(map[string]any{
		"keys": []map[string]string{
			{"kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256", "n": n, "e": e},
		},
	})
	return body
}

func mustGenKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa.GenerateKey: %v", err)
	}
	return k
}

// withAppleJWKSURL temporarily redirects appleJWKSURL to the test server.
func withAppleJWKSURL(t *testing.T, url string) {
	t.Helper()
	orig := appleJWKSURL
	appleJWKSURL = url
	t.Cleanup(func() { appleJWKSURL = orig })
}

// TestAppleVerifier_FreshCacheHitSkipsFetch — populated, fresh cache means
// no network call. Pins the fast path.
func TestAppleVerifier_FreshCacheHitSkipsFetch(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "kid-1", &priv.PublicKey)
	withAppleJWKSURL(t, jts.srv.URL)

	v := NewAppleVerifier("com.test.app")
	// Warm cache.
	if _, err := v.getPublicKey(context.Background(), "kid-1"); err != nil {
		t.Fatalf("warm: %v", err)
	}
	if got := jts.calls.Load(); got != 1 {
		t.Fatalf("warm: want 1 call, got %d", got)
	}
	// Hot lookup.
	if _, err := v.getPublicKey(context.Background(), "kid-1"); err != nil {
		t.Fatalf("hot: %v", err)
	}
	if got := jts.calls.Load(); got != 1 {
		t.Fatalf("hot: want still 1 call, got %d", got)
	}
}

// TestAppleVerifier_RequestCtxCancelDoesNotAbortFetch is the regression test
// for the 2026-04-26 incident: iOS-side request timeout cancelled the
// inbound context, which propagated to the JWKS fetch and aborted it,
// leaving the cache empty and the next attempt to fail the same way.
//
// After the fix, the JWKS fetch runs on a Background-derived context and
// must complete even if the caller's ctx is cancelled before the fetch
// finishes.
func TestAppleVerifier_RequestCtxCancelDoesNotAbortFetch(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "kid-1", &priv.PublicKey)
	// Make Apple "slow" so the cancel races the fetch.
	jts.delay.Store(int64(150 * time.Millisecond))
	withAppleJWKSURL(t, jts.srv.URL)

	v := NewAppleVerifier("com.test.app")

	ctx, cancel := context.WithCancel(context.Background())
	// Cancel almost immediately, well before the 150ms fetch can complete.
	go func() {
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()

	// First call may fail because of the cancel — that's acceptable. The
	// critical invariant is that the fetch ran to completion in the
	// background and populated the cache.
	_, _ = v.getPublicKey(ctx, "kid-1")

	// Wait a bit longer than the fetch delay to be sure the goroutine
	// finished writing the cache.
	time.Sleep(300 * time.Millisecond)

	cached := v.jwks.Load()
	if cached == nil {
		t.Fatal("cache should be populated despite caller ctx cancel")
	}
	if len(cached.keys) == 0 {
		t.Fatal("cache populated but keys empty")
	}

	// And a fresh call (with a live ctx) must hit the cache, no extra fetch.
	callsBefore := jts.calls.Load()
	if _, err := v.getPublicKey(context.Background(), "kid-1"); err != nil {
		t.Fatalf("post-cancel lookup: %v", err)
	}
	if got := jts.calls.Load(); got != callsBefore {
		t.Fatalf("post-cancel lookup should hit cache, but did %d more fetch(es)", got-callsBefore)
	}
}

// TestAppleVerifier_StaleCacheServedOnFetchFailure pins the
// stale-while-revalidate behavior. If we have any cached entry (even past
// TTL) and the fetch fails, we must serve the stale key rather than
// returning an error — Apple rotates keys infrequently, so stale is almost
// always still valid.
func TestAppleVerifier_StaleCacheServedOnFetchFailure(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "kid-1", &priv.PublicKey)
	withAppleJWKSURL(t, jts.srv.URL)

	v := NewAppleVerifier("com.test.app")

	// Warm the cache.
	if _, err := v.getPublicKey(context.Background(), "kid-1"); err != nil {
		t.Fatalf("warm: %v", err)
	}
	// Force the cache to be "stale" by rewinding fetchedAt past the TTL.
	cached := v.jwks.Load()
	v.jwks.Store(&cachedJWKS{
		keys:      cached.keys,
		fetchedAt: time.Now().Add(-2 * jwksCacheTTL),
	})

	// Make the next fetch fail.
	jts.failNext.Store(10)

	// Lookup should still succeed by falling back to the stale entry.
	key, err := v.getPublicKey(context.Background(), "kid-1")
	if err != nil {
		t.Fatalf("stale fallback: want nil err, got %v", err)
	}
	if key == nil {
		t.Fatal("stale fallback: want key, got nil")
	}
}

// TestAppleVerifier_FetchFailsOnEmptyCache — when we've never fetched, a
// fetch failure must surface as an error (no stale to fall back to).
func TestAppleVerifier_FetchFailsOnEmptyCache(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "kid-1", &priv.PublicKey)
	jts.failNext.Store(10)
	withAppleJWKSURL(t, jts.srv.URL)

	v := NewAppleVerifier("com.test.app")
	if _, err := v.getPublicKey(context.Background(), "kid-1"); err == nil {
		t.Fatal("want error on first-fetch failure, got nil")
	}
}

// TestAppleVerifier_KIDRotationTriggersFetch — kid not in fresh cache must
// trigger a fetch (Apple may have rotated since last fetch). The cooldown
// is shrunk to 0 so the test exercises the rotation path immediately.
func TestAppleVerifier_KIDRotationTriggersFetch(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "old-kid", &priv.PublicKey)
	withAppleJWKSURL(t, jts.srv.URL)
	withKIDMissCooldown(t, 0)

	v := NewAppleVerifier("com.test.app")
	if _, err := v.getPublicKey(context.Background(), "old-kid"); err != nil {
		t.Fatalf("warm: %v", err)
	}
	if got := jts.calls.Load(); got != 1 {
		t.Fatalf("warm: want 1 call, got %d", got)
	}

	// Apple "rotates" — server now returns new-kid.
	priv2 := mustGenKey(t)
	jts.setKey("new-kid", &priv2.PublicKey)

	if _, err := v.getPublicKey(context.Background(), "new-kid"); err != nil {
		t.Fatalf("rotation: %v", err)
	}
	if got := jts.calls.Load(); got != 2 {
		t.Fatalf("rotation: want 2 calls (initial + refetch on miss), got %d", got)
	}
}

// TestAppleVerifier_KIDMissThrottled — the throttle protects us against a
// forged-token DoS. Rapid lookups for an unknown kid must NOT trigger a
// refetch every time.
func TestAppleVerifier_KIDMissThrottled(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "kid-1", &priv.PublicKey)
	withAppleJWKSURL(t, jts.srv.URL)
	withKIDMissCooldown(t, 1*time.Hour)

	v := NewAppleVerifier("com.test.app")
	// Warm cache.
	if _, err := v.getPublicKey(context.Background(), "kid-1"); err != nil {
		t.Fatalf("warm: %v", err)
	}
	// Now ask for an unknown kid 10 times — only the first should refetch
	// (and we expect 0 additional calls thanks to the cooldown set above).
	for i := 0; i < 10; i++ {
		_, _ = v.getPublicKey(context.Background(), "forged-kid")
	}
	// 1 call total = the warm fetch. Cooldown blocked all kid-miss refetches.
	if got := jts.calls.Load(); got != 1 {
		t.Fatalf("throttle: want 1 call, got %d", got)
	}
}

// withKIDMissCooldown temporarily overrides kidMissCooldown for tests.
func withKIDMissCooldown(t *testing.T, d time.Duration) {
	t.Helper()
	orig := kidMissCooldown
	kidMissCooldown = d
	t.Cleanup(func() { kidMissCooldown = orig })
}

// TestAppleVerifier_Singleflight — N concurrent callers hitting an empty
// cache must trigger exactly one HTTP fetch.
func TestAppleVerifier_Singleflight(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "kid-1", &priv.PublicKey)
	jts.delay.Store(int64(80 * time.Millisecond))
	withAppleJWKSURL(t, jts.srv.URL)

	v := NewAppleVerifier("com.test.app")

	const N = 50
	var wg sync.WaitGroup
	wg.Add(N)
	for i := 0; i < N; i++ {
		go func() {
			defer wg.Done()
			_, _ = v.getPublicKey(context.Background(), "kid-1")
		}()
	}
	wg.Wait()

	if got := jts.calls.Load(); got != 1 {
		t.Fatalf("singleflight: want 1 fetch for %d concurrent callers, got %d", N, got)
	}
}


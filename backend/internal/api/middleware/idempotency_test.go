package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

// newTestRig spins up an Echo + miniredis Redis client suitable for
// driving the Idempotency middleware in isolation. Every test gets a
// fresh server so cache state never leaks between cases.
func newTestRig(t *testing.T) (*echo.Echo, *redis.Client, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	e := echo.New()
	e.Use(Idempotency(rdb, zap.NewNop()))
	return e, rdb, mr
}

// TestGETPassesThrough — read methods must never be cached. A handler that
// counts invocations is hit twice when the same GET is replayed even if a
// header is set.
func TestGETPassesThrough(t *testing.T) {
	e, _, _ := newTestRig(t)
	var hits int32
	e.GET("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusOK, "ok")
	})
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		req.Header.Set(IdempotencyKeyHeader, "same-key")
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		if rec.Header().Get(IdempotencyReplayedHeader) != "" {
			t.Errorf("GET should never set Idempotency-Replayed header")
		}
	}
	if hits != 2 {
		t.Errorf("handler hits = %d, want 2 (no caching for GET)", hits)
	}
}

// TestPOSTWithoutKeyPassesThrough — even a mutating method bypasses the
// cache when the client did not send Idempotency-Key (build-35 and older).
// Both calls must run the handler, neither response gets the replay header.
func TestPOSTWithoutKeyPassesThrough(t *testing.T) {
	e, _, _ := newTestRig(t)
	var hits int32
	e.POST("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusOK, "ok")
	})
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, req)
		if rec.Header().Get(IdempotencyReplayedHeader) != "" {
			t.Errorf("missing-key request should never set Idempotency-Replayed")
		}
	}
	if hits != 2 {
		t.Errorf("handler hits = %d, want 2 (no caching without key)", hits)
	}
}

// TestPOSTWithKeyCacheMissThenHit — the contract: first POST with a fresh
// key runs the handler and stashes the response; the second POST with the
// same key returns the cached body unchanged AND sets `Idempotency-Replayed:
// true`. The handler must run exactly once. This is the core property that
// stops hedged-race duplicate side effects.
func TestPOSTWithKeyCacheMissThenHit(t *testing.T) {
	e, _, _ := newTestRig(t)
	var hits int32
	e.POST("/register", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.JSON(http.StatusOK, map[string]any{"user_id": 12345})
	})

	// First call — cache miss.
	req1 := httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(`{"a":1}`))
	req1.Header.Set(IdempotencyKeyHeader, "k1")
	rec1 := httptest.NewRecorder()
	e.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusOK {
		t.Fatalf("call 1 status = %d, want 200", rec1.Code)
	}
	if rec1.Header().Get(IdempotencyReplayedHeader) != "" {
		t.Errorf("first call must not be marked replayed")
	}
	body1 := rec1.Body.String()

	// Second call — same key, intentionally different body to prove we
	// serve the cached response (proving same-key collapse, not body match).
	req2 := httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(`{"a":2}`))
	req2.Header.Set(IdempotencyKeyHeader, "k1")
	rec2 := httptest.NewRecorder()
	e.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("call 2 status = %d, want 200", rec2.Code)
	}
	if rec2.Header().Get(IdempotencyReplayedHeader) != "true" {
		t.Errorf("second call must set Idempotency-Replayed: true; got %q", rec2.Header().Get(IdempotencyReplayedHeader))
	}
	if rec2.Body.String() != body1 {
		t.Errorf("replayed body differs from cached: got %q, want %q", rec2.Body.String(), body1)
	}
	if hits != 1 {
		t.Errorf("handler hits = %d, want 1 (replay must not re-run handler)", hits)
	}
}

// TestPOSTDifferentKeysAreIndependent — same endpoint hit with two different
// keys must run the handler twice. Catches a regression where the cache
// key accidentally drops the user-supplied portion.
func TestPOSTDifferentKeysAreIndependent(t *testing.T) {
	e, _, _ := newTestRig(t)
	var hits int32
	e.POST("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusOK, "ok")
	})
	for _, k := range []string{"k-a", "k-b"} {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
		req.Header.Set(IdempotencyKeyHeader, k)
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, req)
	}
	if hits != 2 {
		t.Errorf("handler hits = %d, want 2 (different keys must not share cache)", hits)
	}
}

// TestPOSTWith5xxNotCached — 5xx responses are transient by contract; the
// next retry with the same key must re-run the handler so a flaky downstream
// gets a fresh chance. Caching a 500 would pin the failure for 24h.
func TestPOSTWith5xxNotCached(t *testing.T) {
	e, _, mr := newTestRig(t)
	var hits int32
	e.POST("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusInternalServerError, "boom")
	})

	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
		req.Header.Set(IdempotencyKeyHeader, "k-5xx")
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, req)
		if rec.Header().Get(IdempotencyReplayedHeader) != "" {
			t.Errorf("5xx must not be served from cache")
		}
	}
	if hits != 2 {
		t.Errorf("handler hits = %d, want 2 (5xx must not be cached)", hits)
	}
	// Sanity: nothing landed in Redis.
	keys := mr.Keys()
	for _, k := range keys {
		if strings.HasPrefix(k, idempotencyKeyPrefix) {
			t.Errorf("Redis still has cached idempotency entry %q after 5xx flow", k)
		}
	}
}

// TestPOSTWith4xxIsCached — 4xx is a deterministic client-error response
// (e.g. validation 400, conflict 409). Replay should return the same answer
// to spare the handler. Distinct from 5xx by deliberate design.
func TestPOSTWith4xxIsCached(t *testing.T) {
	e, _, _ := newTestRig(t)
	var hits int32
	e.POST("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusConflict, "already exists")
	})

	req1 := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
	req1.Header.Set(IdempotencyKeyHeader, "k-4xx")
	rec1 := httptest.NewRecorder()
	e.ServeHTTP(rec1, req1)

	req2 := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
	req2.Header.Set(IdempotencyKeyHeader, "k-4xx")
	rec2 := httptest.NewRecorder()
	e.ServeHTTP(rec2, req2)

	if rec2.Code != http.StatusConflict {
		t.Errorf("replayed status = %d, want 409", rec2.Code)
	}
	if rec2.Header().Get(IdempotencyReplayedHeader) != "true" {
		t.Errorf("4xx replay must set Idempotency-Replayed: true")
	}
	if hits != 1 {
		t.Errorf("handler hits = %d, want 1 (4xx must replay from cache)", hits)
	}
}

// TestPOSTOversizedResponseNotCached — guards the 256KB ceiling. A
// runaway endpoint that emits 300KB must not be persisted in Redis;
// downstream replays just re-run the handler.
func TestPOSTOversizedResponseNotCached(t *testing.T) {
	e, _, mr := newTestRig(t)
	big := strings.Repeat("a", idempotencyMaxResponseBytes+1024)
	var hits int32
	e.POST("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusOK, big)
	})

	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
		req.Header.Set(IdempotencyKeyHeader, "k-big")
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, req)
	}
	if hits != 2 {
		t.Errorf("handler hits = %d, want 2 (oversized response must skip cache)", hits)
	}
	for _, k := range mr.Keys() {
		if strings.HasPrefix(k, idempotencyKeyPrefix) {
			t.Errorf("oversized response leaked into Redis: %q", k)
		}
	}
}

// TestRedisDownBypasses — if Redis is unreachable the middleware must not
// fail the request. Handler still runs (possibly twice on retry, but that's
// the explicit fail-open contract — better duplicate side effects than a
// hard outage).
func TestRedisDownBypasses(t *testing.T) {
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	mr.Close() // simulate Redis crash before any traffic

	e := echo.New()
	e.Use(Idempotency(rdb, zap.NewNop()))
	var hits int32
	e.POST("/x", func(c echo.Context) error {
		atomic.AddInt32(&hits, 1)
		return c.String(http.StatusOK, "ok")
	})

	req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
	req.Header.Set(IdempotencyKeyHeader, "k-down")
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("Redis-down request must succeed (fail-open); got %d", rec.Code)
	}
	if hits != 1 {
		t.Errorf("handler hits = %d, want 1 (handler must still run when Redis is down)", hits)
	}
}

// TestSetNXRaceCollapses — the dedup invariant under concurrency. Two
// hedged requests racing past the cache miss must both return successfully,
// the handler may run on each (dedup is best-effort across siblings), but
// only ONE entry lands in Redis (SetNX semantics) and any subsequent third
// request gets the replay.
func TestSetNXRaceCollapses(t *testing.T) {
	e, _, mr := newTestRig(t)
	e.POST("/x", func(c echo.Context) error {
		return c.String(http.StatusOK, "ok")
	})

	// Two siblings — same key, body irrelevant.
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
		req.Header.Set(IdempotencyKeyHeader, "k-race")
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, req)
	}

	// At most one cache entry should exist.
	count := 0
	for _, k := range mr.Keys() {
		if strings.HasPrefix(k, idempotencyKeyPrefix) {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected exactly 1 cache entry after race; got %d", count)
	}

	// Third sibling must hit cache.
	req3 := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(""))
	req3.Header.Set(IdempotencyKeyHeader, "k-race")
	rec3 := httptest.NewRecorder()
	e.ServeHTTP(rec3, req3)
	if rec3.Header().Get(IdempotencyReplayedHeader) != "true" {
		t.Errorf("third sibling must replay; got header %q", rec3.Header().Get(IdempotencyReplayedHeader))
	}
}

package geoip

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// isPublicIP is the gate that decides whether we geolocate at all (it feeds
// strict-country routing, rate-limiting and the FreeKassa allowlist), so its
// classification must be exactly right.
func TestIsPublicIP(t *testing.T) {
	tests := []struct {
		ip   string
		want bool
	}{
		{"8.8.8.8", true},
		{"1.1.1.1", true},
		{"2606:4700:4700::1111", true},
		{"127.0.0.1", false},   // loopback
		{"::1", false},         // loopback v6
		{"10.0.0.1", false},    // private
		{"192.168.1.1", false}, // private
		{"172.16.5.4", false},  // private
		{"0.0.0.0", false},     // unspecified
		{"169.254.1.1", false}, // link-local
		{"fe80::1", false},     // link-local v6
		{"not-an-ip", false},   // unparseable
		{"", false},            // empty
	}
	for _, tc := range tests {
		t.Run(tc.ip, func(t *testing.T) {
			if got := isPublicIP(tc.ip); got != tc.want {
				t.Errorf("isPublicIP(%q) = %v, want %v", tc.ip, got, tc.want)
			}
		})
	}
}

// Lookup must short-circuit non-public IPs to a zero Result without any network
// call (callers fire-and-forget on every request).
func TestLookupSkipsNonPublic(t *testing.T) {
	r := New()
	for _, ip := range []string{"127.0.0.1", "10.0.0.1", "not-an-ip"} {
		if got := r.Lookup(context.Background(), ip); got != (Result{}) {
			t.Errorf("Lookup(%q) = %+v, want zero Result", ip, got)
		}
	}
}

// A fresh cache entry must be served without hitting the network.
func TestLookupServesFreshCache(t *testing.T) {
	r := New()
	want := Result{Country: "US", CountryName: "United States", City: "Mountain View"}
	r.cache["8.8.8.8"] = cacheEntry{res: want, expiry: time.Now().Add(time.Hour)}

	if got := r.Lookup(context.Background(), "8.8.8.8"); got != want {
		t.Errorf("Lookup cached = %+v, want %+v", got, want)
	}
}

// D7 (PRODUCT-MATURITY-LOOP): a SUCCESSFUL lookup is cached for ~cacheTTL (24h).
func TestLookupCachesSuccessLongTTL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"status":"success","countryCode":"RU","country":"Russia","city":"Moscow"}`))
	}))
	defer srv.Close()
	r := New()
	r.baseURL = srv.URL + "/json/"

	got := r.Lookup(context.Background(), "5.5.5.5")
	want := Result{Country: "RU", CountryName: "Russia", City: "Moscow"}
	if got != want {
		t.Fatalf("Lookup = %+v, want %+v", got, want)
	}
	e, ok := r.cache["5.5.5.5"]
	if !ok {
		t.Fatal("success not cached")
	}
	if d := time.Until(e.expiry); d < cacheTTL-time.Minute {
		t.Errorf("success TTL = %v, want ~%v", d, cacheTTL)
	}
}

// D7: a FAILED lookup must NOT pin a blank for 24h — it gets the short negative
// TTL so the next request can retry within minutes (transient ip-api outage /
// 45 req/min rate-limit must self-heal).
func TestLookupFailureUsesNegativeTTL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests) // simulate rate-limit
	}))
	defer srv.Close()
	r := New()
	r.baseURL = srv.URL + "/json/"

	if got := r.Lookup(context.Background(), "6.6.6.6"); got != (Result{}) {
		t.Errorf("failed Lookup = %+v, want zero Result", got)
	}
	e, ok := r.cache["6.6.6.6"]
	if !ok {
		t.Fatal("failure not cached (should be, briefly, to throttle)")
	}
	if d := time.Until(e.expiry); d > negativeTTL+time.Minute {
		t.Errorf("failure TTL = %v, want <= ~%v (not the 24h success TTL)", d, negativeTTL)
	}
}

// D7: status!="success" (e.g. private/reserved IP per ip-api) is also a
// non-definitive result → negative TTL, not 24h.
func TestLookupStatusFailUsesNegativeTTL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"status":"fail","message":"reserved range"}`))
	}))
	defer srv.Close()
	r := New()
	r.baseURL = srv.URL + "/json/"

	_ = r.Lookup(context.Background(), "7.7.7.7")
	e := r.cache["7.7.7.7"]
	if d := time.Until(e.expiry); d > negativeTTL+time.Minute {
		t.Errorf("status-fail TTL = %v, want negative TTL", d)
	}
}

// evictExpiredLocked drops expired entries and keeps fresh ones.
func TestEvictExpiredLocked(t *testing.T) {
	r := New()
	r.cache["fresh"] = cacheEntry{res: Result{Country: "RU"}, expiry: time.Now().Add(time.Hour)}
	r.cache["stale"] = cacheEntry{res: Result{}, expiry: time.Now().Add(-time.Hour)}
	r.evictExpiredLocked()
	if _, ok := r.cache["stale"]; ok {
		t.Error("expired entry not evicted")
	}
	if _, ok := r.cache["fresh"]; !ok {
		t.Error("fresh entry wrongly evicted")
	}
}

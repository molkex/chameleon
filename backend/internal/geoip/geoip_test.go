package geoip

import (
	"context"
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
		{"127.0.0.1", false},  // loopback
		{"::1", false},        // loopback v6
		{"10.0.0.1", false},   // private
		{"192.168.1.1", false},// private
		{"172.16.5.4", false}, // private
		{"0.0.0.0", false},    // unspecified
		{"169.254.1.1", false},// link-local
		{"fe80::1", false},    // link-local v6
		{"not-an-ip", false},  // unparseable
		{"", false},           // empty
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

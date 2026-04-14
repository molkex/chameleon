// Package geoip resolves an IP to country/city via the free ip-api.com
// service. Results are cached in-memory for 24h to avoid hammering the
// API (free tier: 45 req/min). Lookups are intended to run in a
// background goroutine — all methods are safe for concurrent use.
package geoip

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"sync"
	"time"
)

// Result is the geolocation data we persist.
type Result struct {
	Country     string // ISO code, e.g. "RU"
	CountryName string // e.g. "Russia"
	City        string // e.g. "Saint Petersburg"
}

// Resolver caches IP→Result lookups.
type Resolver struct {
	client *http.Client

	mu    sync.RWMutex
	cache map[string]cacheEntry
}

type cacheEntry struct {
	res    Result
	expiry time.Time
}

const cacheTTL = 24 * time.Hour

// New returns a ready-to-use Resolver.
func New() *Resolver {
	return &Resolver{
		client: &http.Client{Timeout: 5 * time.Second},
		cache:  make(map[string]cacheEntry),
	}
}

// Lookup resolves ip to a Result. Returns zero Result for unspecified,
// loopback, private, or otherwise non-public IPs. Errors are swallowed
// (returns zero Result) so callers can fire-and-forget.
func (r *Resolver) Lookup(ctx context.Context, ip string) Result {
	if !isPublicIP(ip) {
		return Result{}
	}

	r.mu.RLock()
	if e, ok := r.cache[ip]; ok && time.Now().Before(e.expiry) {
		r.mu.RUnlock()
		return e.res
	}
	r.mu.RUnlock()

	res := r.fetch(ctx, ip)
	r.mu.Lock()
	r.cache[ip] = cacheEntry{res: res, expiry: time.Now().Add(cacheTTL)}
	r.mu.Unlock()
	return res
}

type ipAPIResponse struct {
	Status      string `json:"status"`
	CountryCode string `json:"countryCode"`
	Country     string `json:"country"`
	City        string `json:"city"`
}

func (r *Resolver) fetch(ctx context.Context, ip string) Result {
	// ip-api.com free endpoint — no key required, ~45 req/min.
	// fields= limits payload, lang=en keeps names stable.
	url := "http://ip-api.com/json/" + ip + "?fields=status,country,countryCode,city&lang=en"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Result{}
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return Result{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Result{}
	}
	var body ipAPIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return Result{}
	}
	if body.Status != "success" {
		return Result{}
	}
	return Result{
		Country:     body.CountryCode,
		CountryName: body.Country,
		City:        body.City,
	}
}

func isPublicIP(s string) bool {
	ip := net.ParseIP(s)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() {
		return false
	}
	return true
}

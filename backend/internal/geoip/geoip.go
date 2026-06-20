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
	client  *http.Client
	baseURL string // ip-api json endpoint prefix (overridable in tests)

	mu    sync.RWMutex
	cache map[string]cacheEntry
}

type cacheEntry struct {
	res    Result
	expiry time.Time
}

const (
	// cacheTTL is how long a SUCCESSFUL lookup is trusted.
	cacheTTL = 24 * time.Hour
	// negativeTTL is how long a FAILED lookup (network error, non-200,
	// rate-limit, status!=success) is remembered. D7 (PRODUCT-MATURITY-LOOP):
	// the old code cached the zero Result for a full 24h on ANY failure, so a
	// transient ip-api outage or a sign-up burst hitting the 45 req/min free
	// tier pinned blank country/city for that IP for a day (and backfill saved
	// the blanks). A short negative TTL still throttles a hammering caller but
	// lets the next request retry within minutes.
	negativeTTL = 10 * time.Minute
	// maxEntries bounds the cache (the map was previously unbounded).
	maxEntries = 50000
)

// New returns a ready-to-use Resolver.
func New() *Resolver {
	return &Resolver{
		client:  &http.Client{Timeout: 5 * time.Second},
		baseURL: "http://ip-api.com/json/",
		cache:   make(map[string]cacheEntry),
	}
}

// Lookup resolves ip to a Result. Returns zero Result for unspecified,
// loopback, private, or otherwise non-public IPs. Errors are swallowed
// (returns zero Result) so callers can fire-and-forget — but a failed lookup
// is only cached briefly (negativeTTL) so it self-heals.
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

	res, ok := r.fetch(ctx, ip)
	ttl := negativeTTL
	if ok {
		ttl = cacheTTL
	}

	r.mu.Lock()
	if len(r.cache) >= maxEntries {
		r.evictExpiredLocked()
		if len(r.cache) >= maxEntries {
			r.cache = make(map[string]cacheEntry) // hard reset; rare safety valve
		}
	}
	r.cache[ip] = cacheEntry{res: res, expiry: time.Now().Add(ttl)}
	r.mu.Unlock()
	return res
}

// evictExpiredLocked drops expired entries. Caller must hold r.mu.
func (r *Resolver) evictExpiredLocked() {
	now := time.Now()
	for k, e := range r.cache {
		if now.After(e.expiry) {
			delete(r.cache, k)
		}
	}
}

type ipAPIResponse struct {
	Status      string `json:"status"`
	CountryCode string `json:"countryCode"`
	Country     string `json:"country"`
	City        string `json:"city"`
}

// fetch returns the geolocation and whether it was a DEFINITIVE success worth
// caching long-term. ok=false on any transient failure so the caller uses the
// short negative TTL instead of pinning a blank for 24h.
func (r *Resolver) fetch(ctx context.Context, ip string) (res Result, ok bool) {
	// ip-api.com free endpoint — no key required, ~45 req/min.
	// fields= limits payload, lang=en keeps names stable.
	url := r.baseURL + ip + "?fields=status,country,countryCode,city&lang=en"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Result{}, false
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return Result{}, false
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return Result{}, false
	}
	var body ipAPIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return Result{}, false
	}
	if body.Status != "success" {
		return Result{}, false
	}
	return Result{
		Country:     body.CountryCode,
		CountryName: body.Country,
		City:        body.City,
	}, true
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

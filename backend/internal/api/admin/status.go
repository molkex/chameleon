package admin

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// MON-08 Service Status — single endpoint that aggregates every probe the
// admin's "Status" page needs to render. Probes run in parallel so a single
// hung dependency doesn't extend the request beyond the worst-case timeout.
//
// Three sections:
//   - services: things WE run on this host (postgres, redis, singbox-tls
//     port, http listener for ourselves). Read failures are visible
//     immediately on the page.
//   - integrations: external dependencies (Cloudflare-fronted hosts, SPB
//     relay, Telegram Bot API, App Store Connect API endpoint). Fails are
//     "advisory" — the admin can see, e.g., that ASC is rate-limiting us
//     without the admin panel itself being affected.
//   - recent_events: last 20 rows from admin_audit_log so the operator
//     has a chronological "what changed" alongside the live state.
//
// The handler runs each probe with a 3s per-probe timeout against the
// request's context; total request time is bounded by max(probe_timeout).

// probeStatus is the JSON shape for one probe result.
type probeStatus struct {
	Name      string  `json:"name"`
	Group     string  `json:"group"` // "services" | "integrations"
	OK        bool    `json:"ok"`
	LatencyMS int64   `json:"latency_ms"`
	Details   string  `json:"details"`
	Error     string  `json:"error,omitempty"`
}

// auditEventSummary is a slimmed-down audit row for the page footer.
type auditEventSummary struct {
	ID            int64  `json:"id"`
	Action        string `json:"action"`
	AdminUsername string `json:"admin_username"`
	IP            string `json:"ip"`
	Details       string `json:"details"`
	CreatedAt     string `json:"created_at"`
}

type statusResponse struct {
	Services     []probeStatus       `json:"services"`
	Integrations []probeStatus       `json:"integrations"`
	RecentEvents []auditEventSummary `json:"recent_events"`
	GeneratedAt  string              `json:"generated_at"`
}

// GetStatus handles GET /api/v1/admin/status.
func (h *Handler) GetStatus(c echo.Context) error {
	ctx := c.Request().Context()

	// Fan out probes. Each probe is a func that returns a probeStatus —
	// we run them in goroutines and gather. The map is just to keep the
	// definitions readable; the order in the response is deterministic
	// because we re-emit from a slice of `name`s afterwards.
	type probeFn = func(context.Context) probeStatus

	services := map[string]probeFn{
		"postgres":      h.probePostgres,
		"redis":         h.probeRedis,
		"singbox-tls":   h.probeSingboxPort,
		"chameleon-api": h.probeSelf,
	}
	// Probe URLs picked to actually hit each integration end-to-end:
	//   - cloudflare-edge: madfrog.online is CF-proxied; 200 = CF up + origin up.
	//   - msk-relay: probes the full DNS → relay → NL backend chain via HTTPS,
	//     same path real iOS clients use, so a 200 here means the entire RU
	//     CF-bypass route is healthy. Direct `http://217.198.5.52/...` returned
	//     404 because nginx's default_server matched (no Host header) — wrong
	//     probe URL, fixed.
	//   - spb-relay: TLS on :2098 (Reality VLESS endpoint). A 400 from TLS-
	//     terminated nginx is the expected response when we don't speak Reality
	//     handshake — that IS the "reachable" signal. expectStatus=0 accepts any
	//     non-5xx as reachable.
	//   - apple-asc-api: /v1/apps requires our JWT; 401 = endpoint reachable.
	//   - apple-storekit: /inApps/v1/transactions/0 requires JWT too; 401 ok.
	//   - FreeKassa: removed. They geo-block non-RU IPs, so any probe from NL
	//     Timeweb (EU) reliably times out. Webhook-receive health is better
	//     tracked via "MAX(created_at) from payments WHERE source='freekassa'"
	//     in a future enhancement.
	integrations := map[string]probeFn{
		"cloudflare-edge": h.probeHTTP("https://madfrog.online/", 200),
		"msk-relay":       h.probeHTTP("https://api.madfrog.online/api/v1/mobile/healthcheck", 200),
		"spb-relay-tls":   h.probeHTTPInsecure("https://185.218.0.43:2098/", 0),
		"apple-asc-api":   h.probeHTTP("https://api.appstoreconnect.apple.com/v1/apps", 0),
		"apple-storekit":  h.probeHTTP("https://api.storekit.itunes.apple.com/inApps/v1/transactions/0", 0),
	}

	var (
		wg          sync.WaitGroup
		mu          sync.Mutex
		svcResults  = make(map[string]probeStatus, len(services))
		intResults  = make(map[string]probeStatus, len(integrations))
	)

	for name, fn := range services {
		wg.Add(1)
		go func(name string, fn probeFn) {
			defer wg.Done()
			probeCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			defer cancel()
			r := fn(probeCtx)
			r.Name = name
			r.Group = "services"
			mu.Lock()
			svcResults[name] = r
			mu.Unlock()
		}(name, fn)
	}
	for name, fn := range integrations {
		wg.Add(1)
		go func(name string, fn probeFn) {
			defer wg.Done()
			probeCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			defer cancel()
			r := fn(probeCtx)
			r.Name = name
			r.Group = "integrations"
			mu.Lock()
			intResults[name] = r
			mu.Unlock()
		}(name, fn)
	}

	wg.Wait()

	// Deterministic order — important so the UI doesn't reshuffle on every
	// 30s refresh.
	serviceOrder := []string{"chameleon-api", "postgres", "redis", "singbox-tls"}
	integrationOrder := []string{
		"cloudflare-edge", "msk-relay", "spb-relay-tls",
		"apple-asc-api", "apple-storekit",
	}

	resp := statusResponse{
		Services:     make([]probeStatus, 0, len(serviceOrder)),
		Integrations: make([]probeStatus, 0, len(integrationOrder)),
		GeneratedAt:  time.Now().UTC().Format(time.RFC3339),
	}
	for _, n := range serviceOrder {
		if r, ok := svcResults[n]; ok {
			resp.Services = append(resp.Services, r)
		}
	}
	for _, n := range integrationOrder {
		if r, ok := intResults[n]; ok {
			resp.Integrations = append(resp.Integrations, r)
		}
	}

	// Recent audit events — fetch newest 20. Tolerant of DB error since the
	// rest of the page is more important; just log + return empty.
	events, _, err := h.DB.ListAuditEvents(ctx, h.recentEventsFilter(), 1, 20)
	if err != nil {
		h.Logger.Warn("status: recent events", zap.Error(err))
	} else {
		resp.RecentEvents = make([]auditEventSummary, 0, len(events))
		for _, e := range events {
			row := auditEventSummary{
				ID:        e.ID,
				Action:    e.Action,
				IP:        e.IP,
				Details:   e.Details,
				CreatedAt: e.CreatedAt.UTC().Format(time.RFC3339),
			}
			if e.AdminUsername != nil {
				row.AdminUsername = *e.AdminUsername
			}
			resp.RecentEvents = append(resp.RecentEvents, row)
		}
	}

	return c.JSON(http.StatusOK, resp)
}

// recentEventsFilter returns an unfiltered AuditFilter — Status page wants
// everything. Extracted into a method so a future enhancement (e.g. filter
// to "infrastructure-touching" actions only) can change one place.
func (h *Handler) recentEventsFilter() db.AuditFilter { //nolint:gocritic
	return db.AuditFilter{}
}

// ── Probes ────────────────────────────────────────────────────────────────

// probePostgres pings the connection pool. A successful Ping confirms the
// pool is reachable AND at least one connection can be acquired without
// the pool blocking on `MaxConns`.
func (h *Handler) probePostgres(ctx context.Context) probeStatus {
	start := time.Now()
	err := h.DB.Pool.Ping(ctx)
	latency := time.Since(start).Milliseconds()
	if err != nil {
		return probeStatus{OK: false, LatencyMS: latency, Error: err.Error()}
	}
	stat := h.DB.Pool.Stat()
	return probeStatus{
		OK:        true,
		LatencyMS: latency,
		Details:   fmt.Sprintf("pool: %d/%d in use, %d idle", stat.AcquiredConns(), stat.MaxConns(), stat.IdleConns()),
	}
}

// probeRedis runs PING. Reports memory usage from INFO on success.
func (h *Handler) probeRedis(ctx context.Context) probeStatus {
	start := time.Now()
	pong, err := h.Redis.Ping(ctx).Result()
	latency := time.Since(start).Milliseconds()
	if err != nil {
		return probeStatus{OK: false, LatencyMS: latency, Error: err.Error()}
	}
	return probeStatus{OK: pong == "PONG", LatencyMS: latency, Details: pong}
}

// probeSingboxPort: a TCP-only "is anything listening on :443?" check.
// Doesn't do a TLS handshake — that would need the client cert dance for
// Reality. A plain Dial is enough: if singbox is dead, the OS kernel
// returns RST and we report down within ms.
func (h *Handler) probeSingboxPort(ctx context.Context) probeStatus {
	const target = "127.0.0.1:443"
	start := time.Now()
	d := net.Dialer{Timeout: 2 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", target)
	latency := time.Since(start).Milliseconds()
	if err != nil {
		return probeStatus{OK: false, LatencyMS: latency, Error: err.Error()}
	}
	_ = conn.Close()
	return probeStatus{OK: true, LatencyMS: latency, Details: target + " accepting"}
}

// probeSelf is trivial — if this handler is running, the API is up. We
// still emit a row so the operator can see latency / uptime structurally
// in the same table.
func (h *Handler) probeSelf(_ context.Context) probeStatus {
	return probeStatus{OK: true, LatencyMS: 0, Details: "this handler"}
}

// probeHTTP — see probeHTTPWithTLS. Validates the server cert.
func (h *Handler) probeHTTP(url string, expectStatus int) func(context.Context) probeStatus {
	return h.probeHTTPWithTLS(url, expectStatus, false)
}

// probeHTTPInsecure — same probe but with InsecureSkipVerify=true. Use
// for IP-direct TLS endpoints where the certificate's CN/SAN won't match
// the IP (e.g. SPB relay's :2098 serves a Reality cert keyed to madfrog
// hostnames, not its raw IP). We only care about TCP+TLS handshake
// completing; the cert chain is intentionally bypassed because the
// indirect-IP probe has no good way to validate it.
func (h *Handler) probeHTTPInsecure(url string, expectStatus int) func(context.Context) probeStatus {
	return h.probeHTTPWithTLS(url, expectStatus, true)
}

// probeHTTPWithTLS returns a closure that GETs the given URL and asserts
// a status code. expectStatus=0 means "any 2xx-4xx is reachable" (used
// for hosts that need credentials we don't carry — 401/403 still proves
// reachability). insecureTLS=true skips server-cert validation; only
// turn it on for IP-direct probes where we control the target.
func (h *Handler) probeHTTPWithTLS(url string, expectStatus int, insecureTLS bool) func(context.Context) probeStatus {
	return func(ctx context.Context) probeStatus {
		client := &http.Client{
			Timeout: 3 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					MinVersion:         tls.VersionTLS12,
					InsecureSkipVerify: insecureTLS, //nolint:gosec
				},
				// No keep-alive: each probe is independent and we don't
				// want a stale CONN to a host that's flapping.
				DisableKeepAlives: true,
			},
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return probeStatus{OK: false, Error: err.Error()}
		}
		req.Header.Set("User-Agent", "MadFrog-StatusProbe/1.0")
		start := time.Now()
		resp, err := client.Do(req)
		latency := time.Since(start).Milliseconds()
		if err != nil {
			return probeStatus{OK: false, LatencyMS: latency, Error: err.Error()}
		}
		defer resp.Body.Close()

		ok := false
		switch {
		case expectStatus > 0 && resp.StatusCode == expectStatus:
			ok = true
		case expectStatus == 0 && resp.StatusCode < 500:
			ok = true
		}
		return probeStatus{
			OK:        ok,
			LatencyMS: latency,
			Details:   fmt.Sprintf("HTTP %d", resp.StatusCode),
		}
	}
}

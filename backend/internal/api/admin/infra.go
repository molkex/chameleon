package admin

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// MON-04 infra/health — backs the "System Health" strip at the top of the
// admin dashboard. It answers one question at a glance: is the platform
// alive? We surface the Four Golden Signals (latency / traffic / errors /
// saturation) the same way Grafana does, but natively in the SPA under the
// admin's existing JWT so there's no second login or iframe.
//
// Data source is the local Prometheus (MON-04, 127.0.0.1:9091). The backend
// runs network_mode: host on NL so it reaches Prometheus directly. Each
// metric is one instant query; they fan out in parallel like status.go so a
// slow query can't serialise the others. A query that errors or returns no
// samples yields a nil pointer in the JSON ("unknown" in the UI) — the strip
// must never 500 the dashboard.
//
// Saturation (CPU/RAM/disk) comes from node-exporter; latency/traffic/errors
// from chameleon_http_request_duration_seconds; live VPN from
// chameleon_vpn_users_online; monitoring self-health from `up`.

const defaultPrometheusURL = "http://127.0.0.1:9091"

// infraResponse is the JSON shape consumed by the dashboard health strip.
// Pointer fields are null when the underlying query failed or had no data,
// so the UI can render "—" instead of a misleading zero.
type infraResponse struct {
	// Saturation — host (node-exporter).
	CPUPct    *float64 `json:"cpu_pct"`
	RAMPct    *float64 `json:"ram_pct"`
	RAMUsedGB *float64 `json:"ram_used_gb"`
	RAMTotGB  *float64 `json:"ram_total_gb"`
	DiskPct   *float64 `json:"disk_pct"`

	// Golden signals — backend (chameleon HTTP histogram).
	LatencyP95MS *float64 `json:"latency_p95_ms"`
	ReqPerSec    *float64 `json:"req_per_sec"`
	Err5xxPct    *float64 `json:"err_5xx_pct"`

	// Live VPN.
	VPNOnline *float64 `json:"vpn_online"`

	// Monitoring self-health: scrape targets up / total.
	TargetsUp    *float64 `json:"targets_up"`
	TargetsTotal *float64 `json:"targets_total"`

	// PrometheusOK is false when Prometheus itself was unreachable — in that
	// case every metric above is null and the UI shows a "monitoring down"
	// state rather than a falsely-green strip.
	PrometheusOK bool   `json:"prometheus_ok"`
	GeneratedAt  string `json:"generated_at"`
}

// GetInfra handles GET /api/v1/admin/stats/infra.
func (h *Handler) GetInfra(c echo.Context) error {
	ctx := c.Request().Context()

	base := h.PrometheusURL
	if base == "" {
		base = defaultPrometheusURL
	}

	// queries maps a response field to its PromQL. Disk uses mountpoint="/"
	// — node-exporter runs with --path.rootfs=/host, but the rootfs mount is
	// still reported as "/". 5xx ratio guards divide-by-zero with clamp_min
	// so an idle backend reports 0% errors, not NaN.
	queries := map[string]string{
		"cpu":       `100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m])))`,
		"ram":       `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)`,
		"ram_used":  `(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1073741824`,
		"ram_total": `node_memory_MemTotal_bytes / 1073741824`,
		"disk":      `100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})`,
		"p95":       `histogram_quantile(0.95, sum(rate(chameleon_http_request_duration_seconds_bucket[5m])) by (le)) * 1000`,
		"reqps":     `sum(rate(chameleon_http_request_duration_seconds_count[5m]))`,
		"err5xx":    `100 * sum(rate(chameleon_http_request_duration_seconds_count{status_class="5xx"}[5m])) / clamp_min(sum(rate(chameleon_http_request_duration_seconds_count[5m])), 1)`,
		"vpn":       `chameleon_vpn_users_online`,
		"up":        `sum(up)`,
		"up_total":  `count(up)`,
	}

	pc := &promClient{base: base, client: &http.Client{Timeout: 4 * time.Second}}

	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		results = make(map[string]*float64, len(queries))
		anyErr  bool
	)
	for key, q := range queries {
		wg.Add(1)
		go func(key, q string) {
			defer wg.Done()
			qCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
			defer cancel()
			val, err := pc.queryScalar(qCtx, q)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				anyErr = true
				h.Logger.Debug("infra: prometheus query failed",
					zap.String("metric", key), zap.Error(err))
				return
			}
			results[key] = val
		}(key, q)
	}
	wg.Wait()

	resp := infraResponse{
		CPUPct:       results["cpu"],
		RAMPct:       results["ram"],
		RAMUsedGB:    results["ram_used"],
		RAMTotGB:     results["ram_total"],
		DiskPct:      results["disk"],
		LatencyP95MS: results["p95"],
		ReqPerSec:    results["reqps"],
		Err5xxPct:    results["err5xx"],
		VPNOnline:    results["vpn"],
		TargetsUp:    results["up"],
		TargetsTotal: results["up_total"],
		// If every query failed, Prometheus is almost certainly unreachable.
		// (De Morgan of !(anyErr && len(results)==0) — staticcheck QF1001.)
		PrometheusOK: !anyErr || len(results) != 0,
		GeneratedAt:  time.Now().UTC().Format(time.RFC3339),
	}

	return c.JSON(http.StatusOK, resp)
}

// promClient is a minimal Prometheus HTTP API client — just enough for
// instant queries returning a single scalar/vector sample. We don't pull in
// the official client_golang/api dependency for three queries.
type promClient struct {
	base   string
	client *http.Client
}

// queryScalar runs an instant query and returns the first sample's value.
// Returns (nil, nil) when the query succeeds but yields no samples (e.g. a
// metric that hasn't been observed yet) so the caller renders "—" without
// treating it as an error.
func (p *promClient) queryScalar(ctx context.Context, query string) (*float64, error) {
	endpoint := p.base + "/api/v1/query?query=" + url.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("prometheus: HTTP %d", resp.StatusCode)
	}

	var pr promQueryResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, err
	}
	if pr.Status != "success" {
		return nil, fmt.Errorf("prometheus: status %q", pr.Status)
	}
	if len(pr.Data.Result) == 0 {
		return nil, nil
	}
	// Each result's Value is [<unix_ts float>, "<sample string>"].
	if len(pr.Data.Result[0].Value) != 2 {
		return nil, fmt.Errorf("prometheus: malformed value tuple")
	}
	s, ok := pr.Data.Result[0].Value[1].(string)
	if !ok {
		return nil, fmt.Errorf("prometheus: value not a string")
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil, err
	}
	// PromQL can yield NaN (e.g. histogram_quantile over an empty range).
	// JSON can't represent NaN, and it isn't a meaningful health number, so
	// treat it as "no data".
	if f != f { // NaN check
		return nil, nil
	}
	return &f, nil
}

// promQueryResponse mirrors the subset of the Prometheus /api/v1/query
// response we read. resultType is "vector" for our instant queries; each
// result carries a "value" tuple [timestamp, "stringValue"].
type promQueryResponse struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Value []any `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

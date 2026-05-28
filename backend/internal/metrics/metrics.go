// Package metrics holds the Prometheus collectors that expose backend
// runtime, VPN, funnel, and HTTP/DB/cache telemetry on /metrics.
//
// One Metrics struct is created at startup in cmd/chameleon/main.go and
// passed into every component that needs to record observations. All
// label cardinality is bounded — every label value comes from a fixed
// allow-list (event whitelist, signup providers, payment sources, HTTP
// status class, DB verb) or from Echo's route pattern (c.Path()) which is
// the number of registered routes, not the URL space.
//
// MON-04 (2026-05-28).
package metrics

import (
	"bufio"
	"context"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.uber.org/zap"
)

// Metrics groups every Prometheus collector exposed by the backend.
//
// Construct once with New(). Pass by pointer; the underlying collectors
// are safe for concurrent use.
type Metrics struct {
	registry *prometheus.Registry

	// --- Live VPN load -------------------------------------------------
	VPNUsersOnline       prometheus.Gauge
	VPNThroughputBytes   *prometheus.CounterVec // labels: direction=rx|tx
	VPNTCPRetransTotal   prometheus.Counter
	VPNTCPSegmentsSent   prometheus.Counter
	VPNActiveConnections prometheus.Gauge

	// --- Funnel --------------------------------------------------------
	SignupsTotal   *prometheus.CounterVec // labels: provider
	PaymentsTotal  *prometheus.CounterVec // labels: source, status
	AppEventsTotal *prometheus.CounterVec // labels: name (whitelisted)
	DAUUsers       prometheus.Gauge

	// --- Backend internals --------------------------------------------
	HTTPDuration     *prometheus.HistogramVec // labels: method, route, status_class
	DBQueryDuration  *prometheus.HistogramVec // labels: operation
	RedisCacheHits   *prometheus.CounterVec   // labels: op
	RedisCacheMisses *prometheus.CounterVec   // labels: op

	// procStatsBaseline holds the last-read /proc/net/dev counter for the
	// monitored interface so we can emit a delta per tick. atomic int64s
	// keep the read-update loop lock-free.
	prevRxBytes      atomic.Int64
	prevTxBytes      atomic.Int64
	prevTCPRetrans   atomic.Int64
	prevTCPOutSegs   atomic.Int64
	procBaselineSet  atomic.Bool
}

// HTTPBuckets are the latency buckets used for chameleon_http_request_duration_seconds.
// Picked to be useful at both web-scale (5ms) and timeout-scale (10s).
var HTTPBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// DBBuckets are slightly coarser than HTTP — DB calls rarely beat 1ms.
var DBBuckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5}

// signupProviders is the bounded label set for chameleon_signups_total{provider}.
// Anything not in this set is normalised to "other" via Provider().
var signupProviders = map[string]struct{}{
	"apple":    {},
	"google":   {},
	"device":   {},
	"telegram": {},
	"email":    {},
}

// paymentSources / paymentStatuses bound chameleon_payments_total labels.
var paymentSources = map[string]struct{}{
	"apple_iap": {},
	"freekassa": {},
	"admin":     {},
}

var paymentStatuses = map[string]struct{}{
	"completed": {},
	"pending":   {},
	"failed":    {},
	"refunded":  {},
}

// appEventNames is the cardinality fence for chameleon_app_events_total{name}.
// Adding a new event name? Allow-list it here AND in iOS EventTracker —
// otherwise it lands in the "other" bucket and dashboards lose the signal.
var appEventNames = map[string]struct{}{
	"app.launch":              {},
	"app.foreground":          {},
	"app.background":          {},
	"paywall.view":            {},
	"paywall.purchase_start":  {},
	"paywall.purchase_success": {},
	"vpn.connect.start":       {},
	"vpn.connect.success":     {},
	"vpn.connect.fail":        {},
}

// New constructs a Metrics with every collector registered against a
// dedicated *prometheus.Registry. We don't use the default registry so
// tests can stand up isolated instances and so an accidental
// double-import never causes a duplicate-registration panic.
func New() *Metrics {
	reg := prometheus.NewRegistry()

	m := &Metrics{
		registry: reg,

		VPNUsersOnline: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "chameleon_vpn_users_online",
			Help: "Current count of unique active VPN sessions (refreshed every ~15s from clash_api /connections).",
		}),
		VPNThroughputBytes: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "chameleon_vpn_throughput_bytes_total",
			Help: "Total bytes through the monitored interface since process start. Sampled every ~15s from /proc/net/dev.",
		}, []string{"direction"}),
		VPNTCPRetransTotal: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "chameleon_vpn_tcp_retransmit_total",
			Help: "Cumulative TCP retransmits (Tcp.RetransSegs from /proc/net/snmp). Counter is reset when /proc/net/snmp counters roll, but Prometheus rate() handles that.",
		}),
		VPNTCPSegmentsSent: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "chameleon_vpn_tcp_segments_sent_total",
			Help: "Cumulative TCP segments sent (Tcp.OutSegs from /proc/net/snmp). Combined with retransmit_total in Grafana to surface the retransmit rate.",
		}),
		VPNActiveConnections: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "chameleon_vpn_active_connections",
			Help: "Current count of established TCP connections (best-effort sampled from clash_api /connections).",
		}),

		SignupsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "chameleon_signups_total",
			Help: "Successful user registrations partitioned by auth provider. Provider label is bounded to {apple, google, device, telegram, email, other}.",
		}, []string{"provider"}),
		PaymentsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "chameleon_payments_total",
			Help: "Payment ledger events. Source ∈ {apple_iap, freekassa, admin, other}; status ∈ {completed, pending, failed, refunded, other}.",
		}, []string{"source", "status"}),
		AppEventsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "chameleon_app_events_total",
			Help: "iOS client events received via /events/batch. Name is bounded to a whitelist; unknown names fall into 'other'.",
		}, []string{"name"}),
		DAUUsers: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "chameleon_dau_users",
			Help: "Daily active users — distinct users with last_seen within the last 24 hours. Refreshed every ~60s.",
		}),

		HTTPDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "chameleon_http_request_duration_seconds",
			Help:    "HTTP request latency by route pattern, method, and status class. Route label uses Echo's c.Path() (route pattern, NOT the raw URL) to keep cardinality bounded.",
			Buckets: HTTPBuckets,
		}, []string{"method", "route", "status_class"}),
		DBQueryDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "chameleon_db_query_duration_seconds",
			Help:    "DB query latency by operation verb. Operation label is the first SQL verb (SELECT/INSERT/UPDATE/DELETE/other), capped to bound cardinality.",
			Buckets: DBBuckets,
		}, []string{"operation"}),
		RedisCacheHits: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "chameleon_redis_cache_hit_total",
			Help: "Redis cache hits partitioned by logical operation name (e.g. 'idempotency', 'jwks').",
		}, []string{"op"}),
		RedisCacheMisses: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "chameleon_redis_cache_miss_total",
			Help: "Redis cache misses partitioned by logical operation name (same labels as the hit counter).",
		}, []string{"op"}),
	}

	// Register custom collectors.
	reg.MustRegister(
		m.VPNUsersOnline,
		m.VPNThroughputBytes,
		m.VPNTCPRetransTotal,
		m.VPNTCPSegmentsSent,
		m.VPNActiveConnections,
		m.SignupsTotal,
		m.PaymentsTotal,
		m.AppEventsTotal,
		m.DAUUsers,
		m.HTTPDuration,
		m.DBQueryDuration,
		m.RedisCacheHits,
		m.RedisCacheMisses,
	)

	// Default Prometheus collectors — Go runtime + process. These give
	// us go_goroutines, go_memstats_*, process_resident_memory_bytes,
	// process_cpu_seconds_total etc. "for free".
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	return m
}

// Handler returns the http.Handler that serves the registry in Prometheus
// text format. Wire it at GET /metrics (outside any auth middleware) —
// Prometheus scrapes from localhost.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{
		// EnableOpenMetrics: false — Grafana/Prometheus both accept the
		// classic exposition format and we have no exemplars to ship.
		Registry: m.registry,
	})
}

// Registry exposes the underlying *prometheus.Registry. Tests use this to
// gather collectors without going through HTTP. Production code shouldn't
// touch it.
func (m *Metrics) Registry() *prometheus.Registry {
	return m.registry
}

// Provider normalises a free-text auth_provider string into the bounded
// label set used by chameleon_signups_total. Anything unknown lands in
// "other" so a future provider addition doesn't blow up cardinality
// silently.
func Provider(raw string) string {
	v := strings.ToLower(strings.TrimSpace(raw))
	if _, ok := signupProviders[v]; ok {
		return v
	}
	return "other"
}

// PaymentSource normalises a payments.Source-like string into the bounded
// label set used by chameleon_payments_total{source}.
func PaymentSource(raw string) string {
	v := strings.ToLower(strings.TrimSpace(raw))
	if _, ok := paymentSources[v]; ok {
		return v
	}
	return "other"
}

// PaymentStatus normalises status into the bounded label set.
func PaymentStatus(raw string) string {
	v := strings.ToLower(strings.TrimSpace(raw))
	if _, ok := paymentStatuses[v]; ok {
		return v
	}
	return "other"
}

// AppEventName normalises an iOS event name into the whitelist + other.
// Anything not whitelisted goes into the "other" bucket; that means we
// can still count "weird events" without exploding label cardinality.
func AppEventName(raw string) string {
	v := strings.ToLower(strings.TrimSpace(raw))
	if _, ok := appEventNames[v]; ok {
		return v
	}
	return "other"
}

// StatusClass turns an HTTP status code into "2xx" / "3xx" / "4xx" /
// "5xx" / "1xx". Bounded by definition.
func StatusClass(code int) string {
	switch {
	case code >= 500:
		return "5xx"
	case code >= 400:
		return "4xx"
	case code >= 300:
		return "3xx"
	case code >= 200:
		return "2xx"
	case code >= 100:
		return "1xx"
	default:
		return "unknown"
	}
}

// DBOperation extracts the first SQL verb (SELECT/INSERT/UPDATE/DELETE)
// from a query string. Anything else collapses to "other". This is the
// label fence for chameleon_db_query_duration_seconds.
func DBOperation(query string) string {
	q := strings.TrimSpace(query)
	if q == "" {
		return "other"
	}
	// Pull the first token (case-insensitive).
	end := len(q)
	for i, r := range q {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			end = i
			break
		}
	}
	verb := strings.ToUpper(q[:end])
	switch verb {
	case "SELECT", "INSERT", "UPDATE", "DELETE":
		return verb
	default:
		return "other"
	}
}

// VPNStatsProvider is the minimal contract the refresh goroutine needs
// from the VPN engine — keeps the metrics package decoupled from the
// concrete *vpn.SingboxEngine type, which would create an import cycle.
type VPNStatsProvider interface {
	OnlineUsers(ctx context.Context) (int, error)
	CurrentSpeed(ctx context.Context) (uploadBPS, downloadBPS int64, connections int, err error)
}

// RefreshVPNStats polls live VPN telemetry at the given interval and
// updates the gauges/counters. Cleanly exits when ctx is cancelled.
//
// Sources:
//   - clash_api /connections      → users_online, active_connections
//   - /proc/net/dev (procNetDev)  → throughput counters (delta-since-baseline)
//   - /proc/net/snmp              → tcp_retransmit_total, tcp_segments_sent_total
//
// Reading /proc files inside Docker reads the container's namespace by
// default, which is fine for the VPN container's eth0. On macOS dev the
// files don't exist; we no-op and log once.
func (m *Metrics) RefreshVPNStats(ctx context.Context, provider VPNStatsProvider, iface string, interval time.Duration, logger *zap.Logger) {
	if interval <= 0 {
		interval = 15 * time.Second
	}
	if iface == "" {
		iface = "eth0"
	}
	logger = logger.Named("metrics.vpn-refresh")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Single immediate tick so /metrics is useful as soon as Prometheus
	// scrapes, instead of returning zero gauges for the first interval.
	m.refreshVPNTick(ctx, provider, iface, logger)

	for {
		select {
		case <-ctx.Done():
			logger.Info("vpn metrics refresh stopped")
			return
		case <-ticker.C:
			m.refreshVPNTick(ctx, provider, iface, logger)
		}
	}
}

func (m *Metrics) refreshVPNTick(ctx context.Context, provider VPNStatsProvider, iface string, logger *zap.Logger) {
	if provider != nil {
		if online, err := provider.OnlineUsers(ctx); err == nil {
			m.VPNUsersOnline.Set(float64(online))
		} else {
			logger.Debug("vpn: online users probe failed", zap.Error(err))
		}
		if _, _, conns, err := provider.CurrentSpeed(ctx); err == nil {
			m.VPNActiveConnections.Set(float64(conns))
		} else {
			logger.Debug("vpn: current speed probe failed", zap.Error(err))
		}
	}

	// /proc/net/dev — throughput deltas.
	if rx, tx, ok := readProcNetDev(iface); ok {
		if m.procBaselineSet.Load() {
			prevRx := m.prevRxBytes.Load()
			prevTx := m.prevTxBytes.Load()
			if rx >= prevRx {
				m.VPNThroughputBytes.WithLabelValues("rx").Add(float64(rx - prevRx))
			}
			if tx >= prevTx {
				m.VPNThroughputBytes.WithLabelValues("tx").Add(float64(tx - prevTx))
			}
		}
		m.prevRxBytes.Store(rx)
		m.prevTxBytes.Store(tx)
	}

	// /proc/net/snmp — TCP segments + retransmits.
	if retrans, outSegs, ok := readProcNetSNMP(); ok {
		if m.procBaselineSet.Load() {
			prevR := m.prevTCPRetrans.Load()
			prevO := m.prevTCPOutSegs.Load()
			if retrans >= prevR {
				m.VPNTCPRetransTotal.Add(float64(retrans - prevR))
			}
			if outSegs >= prevO {
				m.VPNTCPSegmentsSent.Add(float64(outSegs - prevO))
			}
		}
		m.prevTCPRetrans.Store(retrans)
		m.prevTCPOutSegs.Store(outSegs)
	}

	m.procBaselineSet.Store(true)
}

// RefreshDAU polls users.last_seen at the given interval and updates the
// chameleon_dau_users gauge. We accept the raw *pgxpool.Pool through a
// thin adapter to avoid pulling pgx into the metrics-package public API.
func (m *Metrics) RefreshDAU(ctx context.Context, pool *pgxpool.Pool, interval time.Duration, logger *zap.Logger) {
	if interval <= 0 {
		interval = 60 * time.Second
	}
	logger = logger.Named("metrics.dau-refresh")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	m.dauTick(ctx, pool, logger)

	for {
		select {
		case <-ctx.Done():
			logger.Info("dau metrics refresh stopped")
			return
		case <-ticker.C:
			m.dauTick(ctx, pool, logger)
		}
	}
}

func (m *Metrics) dauTick(ctx context.Context, pool *pgxpool.Pool, logger *zap.Logger) {
	if pool == nil {
		return
	}
	queryCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var dau int64
	row := pool.QueryRow(queryCtx,
		"SELECT COUNT(DISTINCT id) FROM users WHERE last_seen >= NOW() - INTERVAL '24 hours'")
	if err := row.Scan(&dau); err != nil {
		logger.Debug("dau query failed", zap.Error(err))
		return
	}
	m.DAUUsers.Set(float64(dau))
}

// ObserveHTTP records one HTTP request observation. Cheap — uses the
// WithLabelValues hot path (no map alloc per call).
func (m *Metrics) ObserveHTTP(method, route string, status int, d time.Duration) {
	if route == "" {
		// Echo returns "" for routes that didn't match any pattern (404
		// from the router itself). Bucket those into a single label so
		// scanners hitting random URLs don't explode cardinality.
		route = "unmatched"
	}
	m.HTTPDuration.
		WithLabelValues(method, route, StatusClass(status)).
		Observe(d.Seconds())
}

// ObserveDB records one DB query observation, classified by SQL verb.
func (m *Metrics) ObserveDB(query string, d time.Duration) {
	m.DBQueryDuration.WithLabelValues(DBOperation(query)).Observe(d.Seconds())
}

// CountSignup bumps chameleon_signups_total for the given provider.
func (m *Metrics) CountSignup(provider string) {
	m.SignupsTotal.WithLabelValues(Provider(provider)).Inc()
}

// CountPayment bumps chameleon_payments_total for the given source/status.
func (m *Metrics) CountPayment(source, status string) {
	m.PaymentsTotal.WithLabelValues(PaymentSource(source), PaymentStatus(status)).Inc()
}

// CountAppEvent bumps chameleon_app_events_total for the given event
// name (whitelisted or 'other').
func (m *Metrics) CountAppEvent(name string) {
	m.AppEventsTotal.WithLabelValues(AppEventName(name)).Inc()
}

// CacheHit / CacheMiss are convenience wrappers that nil-check the
// receiver — handlers may receive a nil *Metrics in tests where the
// dependency isn't wired.
func (m *Metrics) CacheHit(op string) {
	if m == nil {
		return
	}
	m.RedisCacheHits.WithLabelValues(op).Inc()
}

func (m *Metrics) CacheMiss(op string) {
	if m == nil {
		return
	}
	m.RedisCacheMisses.WithLabelValues(op).Inc()
}

// readProcNetDev returns (rx_bytes, tx_bytes, ok) for the named interface
// by parsing /proc/net/dev. ok=false on any read/parse error or platform
// where /proc isn't available (macOS dev).
func readProcNetDev(iface string) (int64, int64, bool) {
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return 0, 0, false
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	prefix := iface + ":"
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		// Format:
		//   eth0: 12345 67  0 0 0 0 0 0 9876 543  0 0 0 0 0 0
		// Fields after the colon: rx_bytes rx_packets ... tx_bytes tx_packets ...
		// rx_bytes is field 1, tx_bytes is field 9 (1-indexed) of the
		// counters block.
		rest := strings.TrimSpace(line[len(prefix):])
		fields := strings.Fields(rest)
		if len(fields) < 16 {
			return 0, 0, false
		}
		rx, err1 := strconv.ParseInt(fields[0], 10, 64)
		tx, err2 := strconv.ParseInt(fields[8], 10, 64)
		if err1 != nil || err2 != nil {
			return 0, 0, false
		}
		return rx, tx, true
	}
	return 0, 0, false
}

// readProcNetSNMP returns (RetransSegs, OutSegs, ok) by parsing
// /proc/net/snmp. The file is two-line-per-protocol: a header row of
// field names, followed by a row of values keyed by the same protocol
// name. We look for the "Tcp:" pair.
func readProcNetSNMP() (int64, int64, bool) {
	f, err := os.Open("/proc/net/snmp")
	if err != nil {
		return 0, 0, false
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	var header, values string
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "Tcp:") {
			if header == "" {
				header = line
			} else {
				values = line
				break
			}
		}
	}
	if header == "" || values == "" {
		return 0, 0, false
	}
	hFields := strings.Fields(header)
	vFields := strings.Fields(values)
	if len(hFields) != len(vFields) {
		return 0, 0, false
	}
	var retrans, outSegs int64
	var haveRetrans, haveOut bool
	for i, name := range hFields {
		switch name {
		case "RetransSegs":
			if v, err := strconv.ParseInt(vFields[i], 10, 64); err == nil {
				retrans = v
				haveRetrans = true
			}
		case "OutSegs":
			if v, err := strconv.ParseInt(vFields[i], 10, 64); err == nil {
				outSegs = v
				haveOut = true
			}
		}
	}
	if !haveRetrans || !haveOut {
		return 0, 0, false
	}
	return retrans, outSegs, true
}

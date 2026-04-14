package vpn

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"
)

const recentUserTTL = 2 * time.Minute // consider a user "online" for 2 min after last connection

// StatsCollector periodically collects traffic stats from sing-box.
//
// Global metrics (online users, session totals, realtime speed) come from
// clash_api /connections. Per-user cumulative traffic comes from the v2ray_api
// gRPC StatsService (via v2rayStats), which is the only source sing-box exposes
// for persistent per-user counters.
type StatsCollector struct {
	mu      sync.RWMutex
	baseURL string
	client  *http.Client
	logger  *zap.Logger

	// v2rayStats is the per-user traffic source. May be nil if v2ray_api is
	// not configured; in that case QueryTraffic returns an empty slice.
	v2rayStats *v2rayStatsClient

	// recentUsers tracks when each user/IP was last seen with an active connection.
	// Used to report online users even when connections are short-lived.
	recentUsers map[string]time.Time

	// prevUpload/prevDownload track global totals to detect new traffic.
	prevUpload   int64
	prevDownload int64

	// Speed tracking: stores last-seen totals and timestamp for delta calculation.
	speedLastUpload   int64
	speedLastDownload int64
	speedLastTime     time.Time
}

// trafficSnapshot stores cumulative upload/download for delta calculation.
type trafficSnapshot struct {
	Upload   int64
	Download int64
}

// NewStatsCollector creates a collector that polls the clash_api at the given address.
//
// The baseURL should be the full HTTP URL, e.g. "http://127.0.0.1:9090".
// If v2rayAPIAddr is non-empty (e.g. "127.0.0.1:8080"), per-user traffic is
// collected via gRPC from sing-box's experimental.v2ray_api stats service.
func NewStatsCollector(baseURL string, v2rayAPIAddr string, logger *zap.Logger) *StatsCollector {
	c := &StatsCollector{
		baseURL: strings.TrimRight(baseURL, "/"),
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
		logger:      logger.Named("stats-collector"),
		recentUsers: make(map[string]time.Time),
	}
	if v2rayAPIAddr != "" {
		c.v2rayStats = newV2rayStatsClient(v2rayAPIAddr, logger)
	}
	return c
}

// clashConnections is the JSON response from GET /connections.
type clashConnections struct {
	DownloadTotal int64             `json:"downloadTotal"`
	UploadTotal   int64             `json:"uploadTotal"`
	Connections   []clashConnection `json:"connections"`
}

// clashConnection represents a single connection from the clash_api.
type clashConnection struct {
	ID       string        `json:"id"`
	Metadata clashMetadata `json:"metadata"`
	Upload   int64         `json:"upload"`
	Download int64         `json:"download"`
	Chains   []string      `json:"chains"`
	Rule     string        `json:"rule"`
	Start    string        `json:"start"`
}

// clashMetadata holds connection metadata.
type clashMetadata struct {
	Network     string `json:"network"`
	Type        string `json:"type"`
	SrcIP       string `json:"sourceIP"`
	DstIP       string `json:"destinationIP"`
	SrcPort     string `json:"sourcePort"`
	DstPort     string `json:"destinationPort"`
	Host        string `json:"host"`
	InboundName string `json:"inboundName"`
	InboundUser string `json:"inboundUser"`
}

// QueryTraffic returns per-user traffic deltas since the last call.
//
// Data comes from sing-box's experimental.v2ray_api gRPC StatsService, which
// exposes absolute cumulative byte counters per user. The first call establishes
// a baseline and returns nil; subsequent calls return deltas.
//
// Returns an empty slice (not an error) if v2ray_api is not configured, to keep
// the traffic collector loop running even if stats collection is disabled.
func (s *StatsCollector) QueryTraffic(ctx context.Context) ([]UserTraffic, error) {
	if s.v2rayStats == nil {
		return nil, nil
	}
	return s.v2rayStats.QueryUserTraffic(ctx)
}

// OnlineUsers returns the count of recently active users.
//
// sing-box 1.13 clash_api connections are short-lived (HTTP request/response),
// so we detect activity by checking if global traffic totals have increased.
// A user is considered "online" for 5 minutes after their last activity.
func (s *StatsCollector) OnlineUsers(ctx context.Context) (int, error) {
	conns, err := s.fetchConnections(ctx)
	if err != nil {
		return 0, fmt.Errorf("online users: %w", err)
	}

	now := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	// Collect currently active users from live connections.
	activeNow := make(map[string]struct{})
	for _, c := range conns.Connections {
		key := c.Metadata.InboundUser
		if key == "" && strings.Contains(c.Metadata.Type, "vless") {
			key = c.Metadata.SrcIP
		}
		if key != "" {
			activeNow[key] = struct{}{}
		}
	}

	// Update recent users map with currently active.
	for key := range activeNow {
		s.recentUsers[key] = now
	}
	s.prevUpload = conns.UploadTotal
	s.prevDownload = conns.DownloadTotal

	// Count users seen within TTL, evict old entries.
	count := 0
	for key, lastSeen := range s.recentUsers {
		if now.Sub(lastSeen) > recentUserTTL {
			delete(s.recentUsers, key)
		} else {
			count++
		}
	}

	return count, nil
}

// SessionTraffic returns the total upload and download bytes for the current sing-box session.
// These are the global counters from the clash_api /connections endpoint.
func (s *StatsCollector) SessionTraffic(ctx context.Context) (upload, download int64, err error) {
	conns, err := s.fetchConnections(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("session traffic: %w", err)
	}
	return conns.UploadTotal, conns.DownloadTotal, nil
}

// CurrentSpeed fetches /connections from the clash API and returns:
//   - uploadBPS: upload bytes per second since last call
//   - downloadBPS: download bytes per second since last call
//   - connections: number of currently active connections
//
// On the first call, speed will be 0 (establishes baseline).
func (s *StatsCollector) CurrentSpeed(ctx context.Context) (uploadBPS, downloadBPS int64, connections int, err error) {
	conns, err := s.fetchConnections(ctx)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("current speed: %w", err)
	}

	now := time.Now()
	connections = len(conns.Connections)

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.speedLastTime.IsZero() {
		// First call — establish baseline.
		s.speedLastUpload = conns.UploadTotal
		s.speedLastDownload = conns.DownloadTotal
		s.speedLastTime = now
		return 0, 0, connections, nil
	}

	elapsed := now.Sub(s.speedLastTime).Seconds()
	if elapsed < 0.1 {
		// Too soon, return 0 to avoid division by near-zero.
		return 0, 0, connections, nil
	}

	deltaUp := conns.UploadTotal - s.speedLastUpload
	deltaDown := conns.DownloadTotal - s.speedLastDownload

	// Protect against counter resets (sing-box restart).
	if deltaUp < 0 {
		deltaUp = 0
	}
	if deltaDown < 0 {
		deltaDown = 0
	}

	uploadBPS = int64(float64(deltaUp) / elapsed)
	downloadBPS = int64(float64(deltaDown) / elapsed)

	s.speedLastUpload = conns.UploadTotal
	s.speedLastDownload = conns.DownloadTotal
	s.speedLastTime = now

	return uploadBPS, downloadBPS, connections, nil
}

// fetchConnections calls GET /connections on the clash_api.
func (s *StatsCollector) fetchConnections(ctx context.Context) (*clashConnections, error) {
	url := s.baseURL + "/connections"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("GET %s: status %d: %s", url, resp.StatusCode, string(body))
	}

	var conns clashConnections
	if err := json.NewDecoder(resp.Body).Decode(&conns); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	return &conns, nil
}

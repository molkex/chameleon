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

// StatsCollector periodically collects traffic stats from the sing-box clash_api.
//
// It communicates with the clash_api REST endpoint to fetch connection data
// and derive per-user traffic statistics.
type StatsCollector struct {
	mu         sync.RWMutex
	baseURL    string
	client     *http.Client
	logger     *zap.Logger

	// prevTraffic stores cumulative traffic from the last query so we can
	// compute deltas (traffic since last query).
	prevTraffic map[string]trafficSnapshot
}

// trafficSnapshot stores cumulative upload/download for delta calculation.
type trafficSnapshot struct {
	Upload   int64
	Download int64
}

// NewStatsCollector creates a collector that polls the clash_api at the given address.
//
// The baseURL should be the full HTTP URL, e.g. "http://127.0.0.1:9090".
func NewStatsCollector(baseURL string, logger *zap.Logger) *StatsCollector {
	return &StatsCollector{
		baseURL: strings.TrimRight(baseURL, "/"),
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
		logger:      logger.Named("stats-collector"),
		prevTraffic: make(map[string]trafficSnapshot),
	}
}

// clashConnections is the JSON response from GET /connections.
type clashConnections struct {
	DownloadTotal int64            `json:"downloadTotal"`
	UploadTotal   int64            `json:"uploadTotal"`
	Connections   []clashConnection `json:"connections"`
}

// clashConnection represents a single connection from the clash_api.
type clashConnection struct {
	ID       string            `json:"id"`
	Metadata clashMetadata     `json:"metadata"`
	Upload   int64             `json:"upload"`
	Download int64             `json:"download"`
	Chains   []string          `json:"chains"`
	Rule     string            `json:"rule"`
	Start    string            `json:"start"`
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

// QueryTraffic fetches current traffic from the clash_api /connections endpoint
// and returns per-user traffic deltas since the last query.
//
// On the first call, returns zero deltas (establishes baseline).
func (s *StatsCollector) QueryTraffic(ctx context.Context) ([]UserTraffic, error) {
	conns, err := s.fetchConnections(ctx)
	if err != nil {
		return nil, fmt.Errorf("query traffic: %w", err)
	}

	// Aggregate traffic by inbound user (username).
	currentTraffic := make(map[string]trafficSnapshot)
	for _, c := range conns.Connections {
		username := c.Metadata.InboundUser
		if username == "" {
			continue
		}
		snap := currentTraffic[username]
		snap.Upload += c.Upload
		snap.Download += c.Download
		currentTraffic[username] = snap
	}

	s.mu.Lock()
	prev := s.prevTraffic
	s.prevTraffic = currentTraffic
	s.mu.Unlock()

	// Compute deltas.
	var result []UserTraffic
	for username, curr := range currentTraffic {
		p := prev[username]
		delta := UserTraffic{
			Username: username,
			Upload:   curr.Upload - p.Upload,
			Download: curr.Download - p.Download,
		}
		// Protect against counter resets (sing-box restart).
		if delta.Upload < 0 {
			delta.Upload = curr.Upload
		}
		if delta.Download < 0 {
			delta.Download = curr.Download
		}
		if delta.Upload > 0 || delta.Download > 0 {
			result = append(result, delta)
		}
	}

	s.logger.Debug("queried traffic",
		zap.Int("active_users", len(currentTraffic)),
		zap.Int("users_with_traffic", len(result)),
	)

	return result, nil
}

// OnlineUsers returns the count of unique connected users from /connections.
func (s *StatsCollector) OnlineUsers(ctx context.Context) (int, error) {
	conns, err := s.fetchConnections(ctx)
	if err != nil {
		return 0, fmt.Errorf("online users: %w", err)
	}

	seen := make(map[string]struct{})
	for _, c := range conns.Connections {
		username := c.Metadata.InboundUser
		if username != "" {
			seen[username] = struct{}{}
		}
	}

	count := len(seen)
	s.logger.Debug("counted online users", zap.Int("count", count))
	return count, nil
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

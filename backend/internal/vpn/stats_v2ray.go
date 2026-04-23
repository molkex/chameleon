package vpn

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	statscmd "github.com/chameleonvpn/chameleon/internal/vpn/v2rayapi/command"
)

// v2rayStatsClient queries per-user traffic counters from sing-box's
// experimental.v2ray_api stats service via gRPC.
//
// sing-box stores absolute cumulative byte counters under names like
// "user>>>{username}>>>traffic>>>uplink" and ">>>downlink". We pull them
// all via QueryStats with pattern "user>>>", compute deltas against the
// previous snapshot, and expose them to the traffic collector.
type v2rayStatsClient struct {
	addr   string
	logger *zap.Logger

	mu    sync.Mutex
	conn  *grpc.ClientConn
	stats statscmd.StatsServiceClient

	prev map[string]trafficSnapshot
}

func newV2rayStatsClient(addr string, logger *zap.Logger) *v2rayStatsClient {
	return &v2rayStatsClient{
		addr:   addr,
		logger: logger.Named("v2ray-stats"),
		prev:   make(map[string]trafficSnapshot),
	}
}

func (c *v2rayStatsClient) dial(ctx context.Context) error {
	if c.stats != nil {
		return nil
	}
	dialCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	conn, err := grpc.DialContext(dialCtx, c.addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		return fmt.Errorf("dial %s: %w", c.addr, err)
	}
	c.conn = conn
	c.stats = statscmd.NewStatsServiceClient(conn)
	return nil
}

func (c *v2rayStatsClient) close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		_ = c.conn.Close()
		c.conn = nil
		c.stats = nil
	}
}

// QueryUserTraffic returns per-user traffic deltas since the last call.
//
// The first call establishes a baseline and returns an empty slice.
// Counter resets (sing-box restart) are detected when current < previous
// and the full current value is reported as the delta.
func (c *v2rayStatsClient) QueryUserTraffic(ctx context.Context) ([]UserTraffic, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.dial(ctx); err != nil {
		return nil, err
	}

	reqCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	resp, err := c.stats.QueryStats(reqCtx, &statscmd.QueryStatsRequest{
		Pattern: "user>>>",
		Reset_:  false,
	})
	if err != nil {
		// Connection may be stale after sing-box restart; drop and retry next time.
		if c.conn != nil {
			_ = c.conn.Close()
			c.conn = nil
			c.stats = nil
		}
		return nil, fmt.Errorf("QueryStats: %w", err)
	}

	// Aggregate by username: sum uplink + downlink counters.
	curr := make(map[string]trafficSnapshot)
	for _, st := range resp.GetStat() {
		name := st.GetName()
		// Expected: user>>>{username}>>>traffic>>>uplink|downlink
		parts := strings.Split(name, ">>>")
		if len(parts) != 4 || parts[0] != "user" || parts[2] != "traffic" {
			continue
		}
		user := parts[1]
		dir := parts[3]
		snap := curr[user]
		switch dir {
		case "uplink":
			snap.Upload = st.GetValue()
		case "downlink":
			snap.Download = st.GetValue()
		}
		curr[user] = snap
	}

	firstRun := len(c.prev) == 0 && len(curr) > 0
	var deltas []UserTraffic
	for user, now := range curr {
		p := c.prev[user]
		delta := UserTraffic{
			Username: user,
			Upload:   now.Upload - p.Upload,
			Download: now.Download - p.Download,
		}
		// Counter reset (sing-box restart): use absolute value.
		if delta.Upload < 0 {
			delta.Upload = now.Upload
		}
		if delta.Download < 0 {
			delta.Download = now.Download
		}
		if delta.Upload > 0 || delta.Download > 0 {
			deltas = append(deltas, delta)
		}
	}
	c.prev = curr

	if firstRun {
		// First call establishes baseline; callers should ignore deltas.
		return nil, nil
	}
	return deltas, nil
}

package admin

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"math"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/cluster"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
)

// syncResponse is returned by POST /api/admin/nodes/sync.
type syncResponse struct {
	Status      string `json:"status"`
	ActiveUsers int    `json:"active_users"`
}

// statsResponse is the simplified stats for GET /api/admin/stats.
type statsResponse struct {
	OnlineUsers  int   `json:"online_users"`
	TotalTraffic int64 `json:"total_traffic"`
}

// dashboardStatsResponse is returned by GET /api/admin/stats/dashboard.
// Compatible with the React SPA's DashboardResponse interface.
type dashboardStatsResponse struct {
	Stats              dashboardStats         `json:"stats"`
	VPN                vpnStats               `json:"vpn"`
	RecentTransactions []recentTransactionDTO `json:"recent_transactions"`
	ExpiringUsers      []interface{}          `json:"expiring_users"`
	Payments           paymentsBlockDTO       `json:"payments"`
}

// paymentsBlockDTO carries the dashboard payments rollup. Periods is keyed by
// window ("today"/"7d"/"30d"/"all") so the SPA can switch tabs client-side
// without re-fetching. Revenue maps are major units keyed by ISO-4217.
//
// Note: Apple IAP rows currently carry no amount (price isn't in the StoreKit
// JWS), so Apple shows in Count but not Revenue — only FreeKassa (RUB) money
// lands in the Revenue maps today.
type paymentsBlockDTO struct {
	Periods map[string]paymentPeriodDTO `json:"periods"`
}

type paymentPeriodDTO struct {
	Revenue      map[string]float64 `json:"revenue"`
	Refunds      map[string]float64 `json:"refunds"`
	Count        int                `json:"count"`
	RefundCount  int                `json:"refund_count"`
	UniquePayers int                `json:"unique_payers"`
	BySource     []paymentSourceDTO `json:"by_source"`
}

type paymentSourceDTO struct {
	Source  string             `json:"source"`
	Count   int                `json:"count"`
	Revenue map[string]float64 `json:"revenue"`
}

type recentTransactionDTO struct {
	UserID       *int64  `json:"user_id"`
	Amount       float64 `json:"amount"`
	Currency     string  `json:"currency"`
	Source       string  `json:"source"`
	Days         int     `json:"days"`
	Status       string  `json:"status"`
	CreatedAtFmt string  `json:"created_at_fmt"`
}

type dashboardStats struct {
	TotalUsers  int64 `json:"total_users"`
	// Provisioned = is_active && vpn_uuid IS NOT NULL. NOT engagement
	// — for a VPN app this is ~= TotalUsers. Kept for backwards-compat
	// with the SPA's existing DashboardResponse interface; new code
	// should prefer Active24h / Active30d below.
	ActiveUsers int64 `json:"active_users"`
	TodayNew    int64 `json:"today_new"`
	// Active24h / Active30d = users with last_seen within the window.
	// These are the real engagement counts and what the dashboard
	// surfaces as "Active (24h)" and "Active (30d)" cards (added 2026-05-28).
	Active24h   int64 `json:"active_24h"`
	Active30d   int64 `json:"active_30d"`
}

type vpnStats struct {
	VPNUsers       int     `json:"vpn_users"`
	ActiveUsers    int     `json:"active_users"`
	TotalTrafficGB float64 `json:"total_traffic_gb"`
}

// nodeResponse is the JSON representation of a node for the admin API.
// Fields match the React SPA's Node interface.
type nodeResponse struct {
	Key          string           `json:"key"`
	Name         string           `json:"name"`
	Flag         string           `json:"flag"`
	IP           string           `json:"ip"`
	IsActive     bool             `json:"is_active"`
	LatencyMS    *int             `json:"latency_ms"`
	UserCount    int              `json:"user_count"`
	OnlineUsers  int              `json:"online_users"`
	TotalTraffic int64            `json:"total_traffic"`
	TrafficUp    int64            `json:"traffic_up"`
	TrafficDown  int64            `json:"traffic_down"`
	SpeedUp      int64            `json:"speed_up"`
	SpeedDown    int64            `json:"speed_down"`
	Connections  int              `json:"connections"`
	UptimeHours  *float64         `json:"uptime_hours"`
	Version      *string          `json:"xray_version"` // legacy field name, shows sing-box version
	Protocols    []protocolStatus `json:"protocols"`
	CPU          *float64         `json:"cpu"`
	RAMUsed      *float64         `json:"ram_used"`
	RAMTotal     *float64         `json:"ram_total"`
	Disk         *float64         `json:"disk"`
	LastSyncAt   *time.Time        `json:"last_sync_at,omitempty"`
	SyncStatus   string            `json:"sync_status,omitempty"`
	SyncedUsers  int               `json:"synced_users,omitempty"`
	ProviderName string            `json:"provider_name,omitempty"`
	CostMonthly  float64           `json:"cost_monthly,omitempty"`
	ProviderURL  string            `json:"provider_url,omitempty"`
	Notes        string            `json:"notes,omitempty"`
	Containers   []containerInfo   `json:"containers,omitempty"`
}

type containerInfo struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

type protocolStatus struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Port    int    `json:"port"`
}

// protocolInfo is returned by GET /admin/protocols.
type protocolInfo struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name"`
	Enabled     bool   `json:"enabled"`
}

type listNodesResponse struct {
	Nodes             []nodeResponse `json:"nodes"`
	TotalCostMonthlyRub float64      `json:"total_cost_monthly_rub"`
}

// SyncConfig handles POST /api/admin/nodes/sync
//
// Reloads user list from the database and pushes it to the VPN engine.
// Returns the number of active users after reload.
func (h *Handler) SyncConfig(c echo.Context) error {
	ctx := c.Request().Context()

	if h.VPN == nil {
		return echo.NewHTTPError(http.StatusServiceUnavailable, "VPN engine not configured")
	}

	// Load active VPN users from database.
	dbUsers, err := h.DB.ListActiveVPNUsers(ctx)
	if err != nil {
		h.Logger.Error("admin: sync config: list users", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list users")
	}

	// Convert and reload users in VPN engine.
	vpnUsers := cluster.DBUsersToVPNUsers(dbUsers)
	activeCount, err := h.VPN.ReloadUsers(ctx, vpnUsers)
	if err != nil {
		h.Logger.Error("admin: sync config: reload users", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to sync VPN config")
	}

	h.Logger.Info("admin: config synced",
		zap.Int("active_users", activeCount))

	// Audit MED-014 followup (security-review 2026-05-27): mass sync is
	// exactly the kind of event we want a clean trail for during incident
	// response. The other mutating admin handlers already record audit;
	// this was the only gap in the wired set.
	h.recordAudit(c, "node.sync_config", fmt.Sprintf("active_users=%d", activeCount))

	return c.JSON(http.StatusOK, syncResponse{
		Status:      "ok",
		ActiveUsers: activeCount,
	})
}

// GetStats handles GET /api/admin/stats
//
// Returns basic VPN statistics: online users, total traffic.
func (h *Handler) GetStats(c echo.Context) error {
	ctx := c.Request().Context()

	resp := statsResponse{}

	if h.VPN != nil {
		online, err := h.VPN.OnlineUsers(ctx)
		if err != nil {
			h.Logger.Warn("admin: stats: online users", zap.Error(err))
		} else {
			resp.OnlineUsers = online
		}
	}

	totalTraffic, err := h.DB.TotalTraffic(ctx)
	if err != nil {
		h.Logger.Warn("admin: stats: total traffic", zap.Error(err))
	} else {
		resp.TotalTraffic = totalTraffic
	}

	return c.JSON(http.StatusOK, resp)
}

// GetDashboard handles GET /api/admin/stats/dashboard
//
// Returns the full dashboard stats for the React SPA.
func (h *Handler) GetDashboard(c echo.Context) error {
	ctx := c.Request().Context()

	totalUsers, err := h.DB.CountTotalUsers(ctx)
	if err != nil {
		h.Logger.Error("admin: dashboard: count total users", zap.Error(err))
		totalUsers = 0
	}

	activeUsers, err := h.DB.CountActiveUsers(ctx)
	if err != nil {
		h.Logger.Error("admin: dashboard: count active users", zap.Error(err))
		activeUsers = 0
	}

	active24h, err := h.DB.CountActive24h(ctx)
	if err != nil {
		h.Logger.Error("admin: dashboard: count active 24h", zap.Error(err))
		active24h = 0
	}

	active30d, err := h.DB.CountActive30d(ctx)
	if err != nil {
		h.Logger.Error("admin: dashboard: count active 30d", zap.Error(err))
		active30d = 0
	}

	todayNew, err := h.DB.CountTodayUsers(ctx)
	if err != nil {
		h.Logger.Error("admin: dashboard: count today users", zap.Error(err))
		todayNew = 0
	}

	totalTraffic, err := h.DB.TotalTraffic(ctx)
	if err != nil {
		h.Logger.Error("admin: dashboard: total traffic", zap.Error(err))
		totalTraffic = 0
	}

	onlineUsers := 0
	if h.VPN != nil {
		online, err := h.VPN.OnlineUsers(ctx)
		if err != nil {
			h.Logger.Warn("admin: dashboard: online users", zap.Error(err))
		} else {
			onlineUsers = online
		}
	}

	trafficGB := float64(totalTraffic) / 1073741824 // bytes -> GB

	// Payments rollup. Degrade gracefully: a stalled payments query must not
	// take down the whole dashboard, so on error we serve empty blocks.
	payments := paymentsBlockDTO{Periods: map[string]paymentPeriodDTO{}}
	if block, err := h.DB.PaymentsBlock(ctx); err != nil {
		h.Logger.Error("admin: dashboard: payments block", zap.Error(err))
	} else {
		for key, p := range block {
			payments.Periods[key] = toPaymentPeriodDTO(p)
		}
	}

	recent := []recentTransactionDTO{}
	if rows, err := h.DB.RecentPayments(ctx, 10); err != nil {
		h.Logger.Error("admin: dashboard: recent payments", zap.Error(err))
	} else {
		for _, r := range rows {
			recent = append(recent, toRecentTransactionDTO(r))
		}
	}

	return c.JSON(http.StatusOK, dashboardStatsResponse{
		Stats: dashboardStats{
			TotalUsers:  totalUsers,
			ActiveUsers: activeUsers,
			TodayNew:    todayNew,
			Active24h:   active24h,
			Active30d:   active30d,
		},
		VPN: vpnStats{
			VPNUsers:       int(activeUsers),
			ActiveUsers:    onlineUsers,
			TotalTrafficGB: trafficGB,
		},
		RecentTransactions: recent,
		ExpiringUsers:      []interface{}{},
		Payments:           payments,
	})
}

func toPaymentPeriodDTO(p *db.PaymentPeriodStats) paymentPeriodDTO {
	sources := make([]paymentSourceDTO, 0, len(p.BySource))
	for _, s := range p.BySource {
		sources = append(sources, paymentSourceDTO{
			Source:  s.Source,
			Count:   s.Count,
			Revenue: s.Revenue,
		})
	}
	return paymentPeriodDTO{
		Revenue:      p.Revenue,
		Refunds:      p.Refunds,
		Count:        p.Count,
		RefundCount:  p.RefundCount,
		UniquePayers: p.UniquePayers,
		BySource:     sources,
	}
}

func toRecentTransactionDTO(r db.RecentPayment) recentTransactionDTO {
	var amount float64
	if r.AmountMinor != nil {
		amount = float64(*r.AmountMinor) / 100.0
	}
	return recentTransactionDTO{
		UserID:       r.UserID,
		Amount:       amount,
		Currency:     r.Currency,
		Source:       r.Source,
		Days:         r.Days,
		Status:       r.Status,
		CreatedAtFmt: r.CreatedAt.Format("2006-01-02 15:04"),
	}
}

// ListNodes handles GET /api/admin/nodes
//
// Returns all cluster nodes: local node + peer nodes + relay nodes.
func (h *Handler) ListNodes(c echo.Context) error {
	ctx := c.Request().Context()

	// Collect local node status.
	local := h.buildLocalNodeStatus(ctx)

	nodes := []nodeResponse{local}

	// Query peer nodes in parallel with a 3s timeout.
	if h.Config.Cluster.Enabled && len(h.Config.Cluster.Peers) > 0 {
		peerNodes := h.queryPeerNodes(ctx)
		nodes = append(nodes, peerNodes...)
	}

	// Discover relay servers from DB and check their health.
	// Skip relays that were already fetched as peers (e.g., SPB with metrics-agent).
	peerIPs := make(map[string]bool)
	for _, n := range nodes {
		if n.IP != "" {
			peerIPs[n.IP] = true
		}
	}
	remoteNodes := h.buildRemoteNodes(ctx, local.IP)
	for _, rn := range remoteNodes {
		if !peerIPs[rn.IP] {
			nodes = append(nodes, rn)
		}
	}

	// Calculate total monthly cost from all servers in DB.
	allServers, _ := h.DB.ListAllServers(ctx)
	var totalCost float64
	for _, s := range allServers {
		totalCost += s.CostMonthly
	}

	return c.JSON(http.StatusOK, listNodesResponse{
		Nodes:               nodes,
		TotalCostMonthlyRub: totalCost,
	})
}

// NodeStatus handles GET /api/cluster/node-status
//
// Returns this node's status without auth — used by peer nodes to aggregate
// the cluster view. Protected by cluster network only.
func (h *Handler) NodeStatus(c echo.Context) error {
	ctx := c.Request().Context()
	node := h.buildLocalNodeStatus(ctx)
	return c.JSON(http.StatusOK, node)
}

// buildLocalNodeStatus collects metrics for the local node.
func (h *Handler) buildLocalNodeStatus(ctx context.Context) nodeResponse {
	activeUsers, _ := h.DB.CountActiveUsers(ctx)

	onlineUsers := 0
	var uptimeHours *float64
	var trafficUp, trafficDown int64
	var speedUp, speedDown int64
	var connections int
	if h.VPN != nil {
		online, err := h.VPN.OnlineUsers(ctx)
		if err == nil {
			onlineUsers = online
		}
		if err := h.VPN.Health(ctx); err == nil {
			uptime := h.VPN.UptimeHours()
			uptimeHours = &uptime
		}
		// Real-time session traffic from clash API.
		up, down, err := h.VPN.SessionTraffic(ctx)
		if err == nil {
			trafficUp = up
			trafficDown = down
		}
		// Real-time speed and connection count.
		sUp, sDown, conns, err := h.VPN.CurrentSpeed(ctx)
		if err == nil {
			speedUp = sUp
			speedDown = sDown
			connections = conns
		}
	}

	// Fallback: if clash API returned 0, use DB cumulative.
	if trafficUp == 0 && trafficDown == 0 {
		totalTraffic, _ := h.DB.TotalTraffic(ctx)
		trafficDown = totalTraffic
	}

	// Determine node IP from DB servers (skip relays).
	nodeIP := h.Config.Server.Host
	nodeKey := h.Config.Cluster.NodeID
	// Map node ID to server key: "de-1" → "de", "nl-1" → "nl"
	serverKey := strings.TrimSuffix(strings.Split(nodeKey, "-")[0], "")
	dbServers, _ := h.DB.ListActiveServers(ctx)
	for _, s := range dbServers {
		if s.Key == serverKey {
			nodeIP = s.Host
			break
		}
	}

	// System metrics from host (rounded for clean display).
	metrics := collectSystemMetrics()

	// Cluster sync status.
	syncStatus := "disabled"
	syncedUsers := 0
	var lastSyncAt *time.Time
	if h.Config.Cluster.Enabled {
		syncStatus = "ok"
		syncedUsers = int(activeUsers)
		now := time.Now().UTC()
		lastSyncAt = &now
	}

	version := "sing-box 1.13.6"
	latency := 0

	return nodeResponse{
		Key:          nodeKey,
		Name:         nodeName(nodeKey),
		Flag:         nodeFlag(nodeKey),
		IP:           nodeIP,
		IsActive:     true,
		LatencyMS:    &latency,
		UserCount:    int(activeUsers),
		OnlineUsers:  onlineUsers,
		TotalTraffic: trafficUp + trafficDown,
		TrafficUp:    trafficUp,
		TrafficDown:  trafficDown,
		SpeedUp:      speedUp,
		SpeedDown:    speedDown,
		Connections:  connections,
		UptimeHours:  uptimeHours,
		Version:      &version,
		Protocols: []protocolStatus{
			{Name: "VLESS Reality", Enabled: true, Port: h.Config.VPN.ListenPort},
		},
		CPU:         roundPtr(metrics.CPUPercent, 1),
		RAMUsed:     roundPtr(metrics.RAMUsedMB, 0),
		RAMTotal:    roundPtr(metrics.RAMTotalMB, 0),
		Disk:        roundPtr(metrics.DiskPercent, 1),
		LastSyncAt:  lastSyncAt,
		SyncStatus:  syncStatus,
		SyncedUsers: syncedUsers,
		Containers:  collectContainerStatus(),
	}
}

// queryPeerNodes fetches node status from all cluster peers in parallel.
// Returns a slice of nodeResponses; unreachable peers are marked as inactive.
func (h *Handler) queryPeerNodes(ctx context.Context) []nodeResponse {
	peers := h.Config.Cluster.Peers
	results := make([]nodeResponse, len(peers))

	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	for i, peer := range peers {
		wg.Add(1)
		go func(idx int, p config.PeerConfig) {
			defer wg.Done()

			node, err := fetchPeerStatus(ctx, p.URL, h.ClusterSecret)
			if err != nil {
				h.Logger.Debug("peer node unreachable",
					zap.String("peer_id", p.ID),
					zap.Error(err),
				)
				// Return offline placeholder.
				results[idx] = nodeResponse{
					Key:       p.ID,
					Name:      nodeName(p.ID),
					Flag:      nodeFlag(p.ID),
					IsActive:  false,
					Protocols: []protocolStatus{},
				}
				return
			}
			// Round metrics from peer for clean display.
			node.CPU = roundPtr(node.CPU, 1)
			node.RAMUsed = roundPtr(node.RAMUsed, 0)
			node.RAMTotal = roundPtr(node.RAMTotal, 0)
			node.Disk = roundPtr(node.Disk, 1)
			results[idx] = node
		}(i, peer)
	}

	wg.Wait()
	return results
}

// buildRemoteNodes lists every active VPN server that isn't the local node,
// grouped by host (a box hosting several legs — e.g. the SPB relay's relay-fr +
// relay-nl — collapses to one node), each with a TCP reachability probe. It
// replaces the old buildRelayNodes, which surfaced ONLY "relay-"-prefixed
// servers — so the GRA exit (gra1) and the MSK relay (key "msk") were invisible
// on the nodes page (user-reported "ноды не все", 2026-06-06).
func (h *Handler) buildRemoteNodes(ctx context.Context, localIP string) []nodeResponse {
	servers, err := h.DB.ListActiveServers(ctx)
	if err != nil {
		return nil
	}

	// Group active servers by host, skipping the local node.
	type hostInfo struct {
		host    string
		name    string
		flag    string
		ports   []int
		isRelay bool
	}
	var order []string
	seen := map[string]*hostInfo{}
	for _, s := range servers {
		if s.Host == "" || s.Host == localIP {
			continue
		}
		relay := s.Role == "relay" || strings.HasPrefix(s.Key, "relay-") || s.Key == "msk"
		hi, ok := seen[s.Host]
		if !ok {
			hi = &hostInfo{host: s.Host, name: s.Name, flag: s.Flag}
			seen[s.Host] = hi
			order = append(order, s.Host)
		}
		hi.isRelay = hi.isRelay || relay
		if s.Port > 0 {
			hi.ports = append(hi.ports, s.Port)
		}
	}

	var nodes []nodeResponse
	for _, host := range order {
		hi := seen[host]
		// Probe the first real port; fall back to 443 (relays like MSK carry a
		// port=0 row but still listen on 443/nginx).
		probePort := 443
		if len(hi.ports) > 0 {
			probePort = hi.ports[0]
		}
		active := false
		var latency *int
		start := time.Now()
		if conn, derr := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", hi.host, probePort), 2*time.Second); derr == nil {
			_ = conn.Close()
			active = true
			ms := int(time.Since(start).Milliseconds())
			latency = &ms
		}

		version := "sing-box exit"
		protoName := "VLESS Reality"
		key := hi.host
		if hi.isRelay {
			version = "nginx relay"
			protoName = "TCP Relay"
			key = "relay-" + hi.host
		}
		name := hi.name
		if name == "" {
			name = hi.host
		}
		nodes = append(nodes, nodeResponse{
			Key:       key,
			Name:      name,
			Flag:      hi.flag,
			IP:        hi.host,
			IsActive:  active,
			LatencyMS: latency,
			Version:   &version,
			Protocols: []protocolStatus{
				{Name: protoName, Enabled: active, Port: probePort},
			},
		})
	}

	return nodes
}

// fetchPeerStatus calls GET /api/cluster/node-status on a peer and decodes the response.
func fetchPeerStatus(ctx context.Context, peerURL string, clusterSecret string) (nodeResponse, error) {
	url := peerURL + "/api/cluster/node-status"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nodeResponse{}, err
	}
	if clusterSecret != "" {
		req.Header.Set("Authorization", "Bearer "+clusterSecret)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nodeResponse{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		return nodeResponse{}, fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
	}

	var node nodeResponse
	if err := json.NewDecoder(resp.Body).Decode(&node); err != nil {
		return nodeResponse{}, fmt.Errorf("decode: %w", err)
	}
	return node, nil
}

// vpnProtocols derives the protocol list from this node's VPN config (pure, so
// it's unit-testable). VLESS Reality is always on; Hysteria2/TUIC are enabled
// only when their port is set AND a UDP cert is configured to pin (mirrors the
// gate in clientconfig.go — no cert ⇒ the leg is never emitted). Previously this
// was hardcoded to VLESS-only, so the live Hysteria2 fallback was invisible in
// admin (user-reported "протоколы не все", 2026-06-06).
func vpnProtocols(listenPort, hysteria2Port, tuicPort int, udpCertPath string) []protocolInfo {
	udpReady := udpCertPath != ""
	return []protocolInfo{
		{Name: "vless-reality-tcp", DisplayName: "VLESS Reality TCP", Enabled: true},
		{Name: "hysteria2", DisplayName: "Hysteria2 (Salamander)", Enabled: hysteria2Port > 0 && udpReady},
		{Name: "tuic", DisplayName: "TUIC v5", Enabled: tuicPort > 0 && udpReady},
	}
}

// ListProtocols handles GET /api/admin/protocols
//
// Returns the list of VPN protocols configured on this node.
func (h *Handler) ListProtocols(c echo.Context) error {
	v := h.Config.VPN
	return c.JSON(http.StatusOK, map[string]interface{}{
		"protocols": vpnProtocols(v.ListenPort, v.Hysteria2Port, v.TUICPort, v.UDPCertPath),
	})
}

// GetShield handles GET /api/admin/shield
//
// Returns the ChameleonShield route configuration: all VPN routes from the
// database with priorities (sort_order), weights, and active/inactive status.
// The recommended route is the first active one by sort_order.
func (h *Handler) GetShield(c echo.Context) error {
	ctx := c.Request().Context()

	servers, err := h.DB.ListAllServers(ctx)
	if err != nil {
		h.Logger.Error("admin: shield: list servers", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to load routes")
	}

	type routeInfo struct {
		Priority int    `json:"priority"`
		Weight   int    `json:"weight"`
		Status   string `json:"status"`
		Host     string `json:"host"`
		Port     int    `json:"port"`
		Flag     string `json:"flag"`
		Type     string `json:"type"` // "direct" or "relay"
	}

	routes := make(map[string]routeInfo, len(servers))
	var fallbackOrder []string
	recommended := ""

	for i, s := range servers {
		status := "inactive"
		if s.IsActive {
			status = "active"
		}

		routeType := "direct"
		if strings.HasPrefix(s.Key, "relay-") {
			routeType = "relay"
		}

		label := fmt.Sprintf("%s %s", s.Flag, s.Name)
		routes[label] = routeInfo{
			Priority: i + 1,
			Weight:   100,
			Status:   status,
			Host:     s.Host,
			Port:     s.Port,
			Flag:     s.Flag,
			Type:     routeType,
		}
		fallbackOrder = append(fallbackOrder, label)

		if recommended == "" && s.IsActive {
			recommended = label
		}
	}

	return c.JSON(http.StatusOK, map[string]interface{}{
		"protocols":      routes,
		"recommended":    recommended,
		"fallback_order": fallbackOrder,
		"updated_at":     time.Now().Unix(),
	})
}

// RestartSingbox handles POST /api/admin/nodes/restart-singbox
// (also POST /api/admin/nodes/restart-xray for backward compat)
//
// Restarts the VPN engine by stopping and starting it.
func (h *Handler) RestartSingbox(c echo.Context) error {
	if h.VPN == nil {
		return echo.NewHTTPError(http.StatusServiceUnavailable, "VPN engine not configured")
	}

	ctx := c.Request().Context()

	// Reload users (effectively a restart of the config).
	dbUsers, err := h.DB.ListActiveVPNUsers(ctx)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list users")
	}
	vpnUsers := cluster.DBUsersToVPNUsers(dbUsers)
	count, err := h.VPN.ReloadUsers(ctx, vpnUsers)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to restart VPN")
	}

	h.Logger.Info("admin: VPN engine restarted", zap.Int("active_users", count))
	// Audit MED-014: a restart drops every live connection for ~5s while
	// singbox respawns. Worth tracking who fires it.
	h.recordAudit(c, "node.restart_singbox", fmt.Sprintf("active_users=%d", count))
	return c.JSON(http.StatusOK, map[string]interface{}{
		"status":       "ok",
		"active_users": count,
	})
}

// roundPtr rounds a *float64 to the given number of decimal places.
func roundPtr(v *float64, decimals int) *float64 {
	if v == nil {
		return nil
	}
	shift := math.Pow(10, float64(decimals))
	rounded := math.Round(*v*shift) / shift
	return &rounded
}

// nodeName returns a human-readable name for a node ID.
func nodeName(nodeID string) string {
	names := map[string]string{
		"de-1": "Germany (DE)",
		"nl-1": "Netherlands (NL)",
	}
	if name, ok := names[nodeID]; ok {
		return name
	}
	return nodeID
}

// nodeFlag returns an emoji flag for a node ID.
func nodeFlag(nodeID string) string {
	flags := map[string]string{
		"de-1": "🇩🇪",
		"nl-1": "🇳🇱",
	}
	if flag, ok := flags[nodeID]; ok {
		return flag
	}
	return ""
}

// ListServers handles GET /api/admin/servers
//
// Returns the list of VPN servers from the database (without credentials).
func (h *Handler) ListServers(c echo.Context) error {
	ctx := c.Request().Context()

	servers, err := h.DB.ListAllServers(ctx)
	if err != nil {
		h.Logger.Error("admin: list servers", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list servers")
	}

	resp := make([]serverResponse, len(servers))
	var totalCost float64
	for i, s := range servers {
		resp[i] = toServerResponse(&s)
		totalCost += s.CostMonthly
	}

	return c.JSON(http.StatusOK, map[string]interface{}{
		"servers":              resp,
		"total_cost_monthly_rub": totalCost,
	})
}

// serverRequest is the JSON body for create/update server endpoints.
type serverRequest struct {
	Key              string  `json:"key"`
	Name             string  `json:"name"`
	Flag             string  `json:"flag"`
	Host             string  `json:"host"`
	Port             int     `json:"port"`
	Domain           string  `json:"domain"`
	SNI              string  `json:"sni"`
	RealityPublicKey string  `json:"reality_public_key"`
	IsActive         bool    `json:"is_active"`
	SortOrder        int     `json:"sort_order"`
	ProviderName     string  `json:"provider_name"`
	CostMonthly      float64 `json:"cost_monthly"`
	ProviderURL      string  `json:"provider_url"`
	ProviderLogin    string  `json:"provider_login"`
	ProviderPassword string  `json:"provider_password"`
	Notes            string  `json:"notes"`
}

// serverResponse is the JSON representation of a VPN server for the admin API.
// Excludes sensitive fields (provider_login, provider_password).
type serverResponse struct {
	ID               int64   `json:"id"`
	Key              string  `json:"key"`
	Name             string  `json:"name"`
	Flag             string  `json:"flag"`
	Host             string  `json:"host"`
	Port             int     `json:"port"`
	Domain           string  `json:"domain"`
	SNI              string  `json:"sni"`
	RealityPublicKey string  `json:"reality_public_key"`
	IsActive         bool    `json:"is_active"`
	SortOrder        int     `json:"sort_order"`
	ProviderName     string  `json:"provider_name"`
	CostMonthly      float64 `json:"cost_monthly"`
	ProviderURL      string  `json:"provider_url"`
	Notes            string  `json:"notes"`
	CreatedAt        string  `json:"created_at"`
	UpdatedAt        string  `json:"updated_at"`
}

// toServerResponse converts a db.VPNServer to the safe API response (no credentials).
func toServerResponse(s *db.VPNServer) serverResponse {
	return serverResponse{
		ID:               s.ID,
		Key:              s.Key,
		Name:             s.Name,
		Flag:             s.Flag,
		Host:             s.Host,
		Port:             s.Port,
		Domain:           s.Domain,
		SNI:              s.SNI,
		RealityPublicKey: s.RealityPublicKey,
		IsActive:         s.IsActive,
		SortOrder:        s.SortOrder,
		ProviderName:     s.ProviderName,
		CostMonthly:      s.CostMonthly,
		ProviderURL:      s.ProviderURL,
		Notes:            s.Notes,
		CreatedAt:        s.CreatedAt.Format(time.RFC3339),
		UpdatedAt:        s.UpdatedAt.Format(time.RFC3339),
	}
}

// credentialsRequest is the JSON body for POST /api/admin/servers/:id/credentials.
type credentialsRequest struct {
	Password string `json:"password"`
}

// credentialsResponse is returned by GET credentials endpoint after re-auth.
type credentialsResponse struct {
	ProviderLogin    string `json:"provider_login"`
	ProviderPassword string `json:"provider_password"`
}

// CreateServer handles POST /api/admin/servers
func (h *Handler) CreateServer(c echo.Context) error {
	var req serverRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}
	if req.Key == "" || req.Name == "" || req.Host == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "key, name and host are required")
	}
	if req.Port == 0 {
		req.Port = 2096
	}

	server, err := h.DB.CreateServer(c.Request().Context(), &db.VPNServer{
		Key:              req.Key,
		Name:             req.Name,
		Flag:             req.Flag,
		Host:             req.Host,
		Port:             req.Port,
		Domain:           req.Domain,
		SNI:              req.SNI,
		RealityPublicKey: req.RealityPublicKey,
		IsActive:         req.IsActive,
		SortOrder:        req.SortOrder,
		ProviderName:     req.ProviderName,
		CostMonthly:      req.CostMonthly,
		ProviderURL:      req.ProviderURL,
		ProviderLogin:    req.ProviderLogin,
		ProviderPassword: req.ProviderPassword,
		Notes:            req.Notes,
	})
	if err != nil {
		h.Logger.Error("admin: create server", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to create server")
	}

	h.Logger.Info("admin: server created", zap.String("key", server.Key))
	// Audit MED-014: server adds change the topology of the user-facing
	// VPN pool — every one should be attributable.
	h.recordAudit(c, "server.create",
		fmt.Sprintf("key=%s host=%s port=%d active=%t", server.Key, server.Host, server.Port, server.IsActive))
	return c.JSON(http.StatusCreated, toServerResponse(server))
}

// UpdateServer handles PUT /api/admin/servers/:id
func (h *Handler) UpdateServer(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid server id")
	}

	var req serverRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}
	if req.Key == "" || req.Name == "" || req.Host == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "key, name and host are required")
	}
	if req.Port == 0 {
		req.Port = 2096
	}

	server, err := h.DB.UpdateServer(c.Request().Context(), id, &db.VPNServer{
		Key:              req.Key,
		Name:             req.Name,
		Flag:             req.Flag,
		Host:             req.Host,
		Port:             req.Port,
		Domain:           req.Domain,
		SNI:              req.SNI,
		RealityPublicKey: req.RealityPublicKey,
		IsActive:         req.IsActive,
		SortOrder:        req.SortOrder,
		ProviderName:     req.ProviderName,
		CostMonthly:      req.CostMonthly,
		ProviderURL:      req.ProviderURL,
		ProviderLogin:    req.ProviderLogin,
		ProviderPassword: req.ProviderPassword,
		Notes:            req.Notes,
	})
	if err != nil {
		h.Logger.Error("admin: update server", zap.Error(err), zap.Int64("id", id))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to update server")
	}

	h.Logger.Info("admin: server updated", zap.String("key", server.Key))
	// Audit MED-014: edits to a live server (host/port/SNI/active flag)
	// can re-route or take down user traffic — keep an explicit trail.
	h.recordAudit(c, "server.update",
		fmt.Sprintf("id=%d key=%s host=%s port=%d active=%t", id, server.Key, server.Host, server.Port, server.IsActive))
	return c.JSON(http.StatusOK, toServerResponse(server))
}

// DeleteServer handles DELETE /api/admin/servers/:id
func (h *Handler) DeleteServer(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid server id")
	}

	deleted, err := h.DB.DeleteServer(c.Request().Context(), id)
	if err != nil {
		h.Logger.Error("admin: delete server", zap.Error(err), zap.Int64("id", id))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to delete server")
	}
	if !deleted {
		return echo.NewHTTPError(http.StatusNotFound, "server not found")
	}

	h.Logger.Info("admin: server deleted", zap.Int64("id", id))
	// Audit MED-014: deleting a server removes it from the user-facing
	// pool and may strand active sessions — always record.
	h.recordAudit(c, "server.delete", fmt.Sprintf("id=%d", id))
	return c.NoContent(http.StatusNoContent)
}

// GetServerCredentials handles POST /api/admin/servers/:id/credentials
//
// Returns provider_login and provider_password for a server.
// Requires the admin to re-authenticate by sending their password in the request body.
func (h *Handler) GetServerCredentials(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid server id")
	}

	var req credentialsRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}
	if req.Password == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "password is required for re-authentication")
	}

	// Get admin username from JWT claims.
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
	}

	ctx := c.Request().Context()

	// Re-authenticate: verify admin password.
	adminUser, err := h.DB.FindAdminByUsername(ctx, claims.Username)
	if err != nil {
		h.Logger.Error("admin: credentials: find admin", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "internal error")
	}
	if adminUser == nil {
		return echo.NewHTTPError(http.StatusUnauthorized, "admin user not found")
	}

	matches, _ := auth.VerifyPassword(req.Password, adminUser.PasswordHash)
	if !matches {
		// Audit MED-014: a failed re-auth on a credential-reveal endpoint
		// is high-signal — could be a session theft attempt.
		h.recordAudit(c, "server.credentials.reauth_failed", fmt.Sprintf("server_id=%d", id))
		return echo.NewHTTPError(http.StatusForbidden, "invalid password")
	}

	// Fetch server credentials.
	server, err := h.DB.FindServerByID(ctx, id)
	if err != nil {
		h.Logger.Error("admin: credentials: find server", zap.Error(err), zap.Int64("id", id))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to find server")
	}
	if server == nil {
		return echo.NewHTTPError(http.StatusNotFound, "server not found")
	}

	h.Logger.Info("admin: credentials revealed",
		zap.String("admin", claims.Username),
		zap.Int64("server_id", id))

	// Audit MED-014: provider credentials are the highest-value secret
	// exposed via the admin panel — record every reveal.
	h.recordAudit(c, "server.credentials.reveal", fmt.Sprintf("server_id=%d", id))

	return c.JSON(http.StatusOK, credentialsResponse{
		ProviderLogin:    server.ProviderLogin,
		ProviderPassword: server.ProviderPassword,
	})
}

// trafficOutlierRow is the JSON shape for one top-traffic user. Bytes is in
// raw bytes — the SPA formats GB/MB locally so units stay consistent with
// the rest of the admin (cumulative_traffic is also GB on the wire).
type trafficOutlierRow struct {
	UserID      int64   `json:"user_id"`
	VPNUsername string  `json:"vpn_username"`
	GB          float64 `json:"gb"`
	LastSeen    *string `json:"last_seen"`
	LastCountry string  `json:"last_country"`
	IsActive    bool    `json:"is_active"`
}

type trafficOutliersResponse struct {
	Users []trafficOutlierRow `json:"users"`
	Days  int                 `json:"days"`
	Limit int                 `json:"limit"`
}

// TrafficOutliers handles GET /api/v1/admin/stats/traffic-outliers
//
// Query params: days (default 7, clamped 1-90), limit (default 10, clamped
// 1-100). Returns the top-N users by SUM(used_traffic) over the window.
// Read-only — open to viewer / operator / admin like the other /stats reads.
func (h *Handler) TrafficOutliers(c echo.Context) error {
	days, _ := strconv.Atoi(c.QueryParam("days"))
	limit, _ := strconv.Atoi(c.QueryParam("limit"))

	rows, err := h.DB.TopTrafficUsers(c.Request().Context(), days, limit)
	if err != nil {
		h.Logger.Error("admin: traffic outliers", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to query traffic outliers")
	}

	out := make([]trafficOutlierRow, 0, len(rows))
	for _, r := range rows {
		row := trafficOutlierRow{
			UserID:      r.UserID,
			VPNUsername: r.VPNUsername,
			GB:          math.Round(float64(r.Bytes)/1073741824*100) / 100,
			LastCountry: r.LastCountry,
			IsActive:    r.IsActive,
		}
		if r.LastSeen != nil {
			s := r.LastSeen.UTC().Format(time.RFC3339)
			row.LastSeen = &s
		}
		out = append(out, row)
	}

	// Echo back the clamped values so the SPA can render "Top 10, last 7d"
	// without re-deriving from its own query string.
	resolvedDays := days
	if resolvedDays < 1 {
		resolvedDays = 7
	}
	if resolvedDays > 90 {
		resolvedDays = 90
	}
	resolvedLimit := limit
	if resolvedLimit < 1 {
		resolvedLimit = 10
	}
	if resolvedLimit > 100 {
		resolvedLimit = 100
	}

	return c.JSON(http.StatusOK, trafficOutliersResponse{
		Users: out,
		Days:  resolvedDays,
		Limit: resolvedLimit,
	})
}

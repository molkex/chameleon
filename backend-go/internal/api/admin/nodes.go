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
	Stats              dashboardStats       `json:"stats"`
	VPN                vpnStats             `json:"vpn"`
	RecentTransactions []interface{}        `json:"recent_transactions"`
	ExpiringUsers      []interface{}        `json:"expiring_users"`
}

type dashboardStats struct {
	TotalUsers  int64 `json:"total_users"`
	ActiveUsers int64 `json:"active_users"`
	TodayNew    int64 `json:"today_new"`
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
	UptimeHours  *float64         `json:"uptime_hours"`
	Version      *string          `json:"xray_version"` // legacy field name, shows sing-box version
	Protocols    []protocolStatus `json:"protocols"`
	CPU          *float64         `json:"cpu"`
	RAMUsed      *float64         `json:"ram_used"`
	RAMTotal     *float64         `json:"ram_total"`
	Disk         *float64         `json:"disk"`
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

	return c.JSON(http.StatusOK, dashboardStatsResponse{
		Stats: dashboardStats{
			TotalUsers:  totalUsers,
			ActiveUsers: activeUsers,
			TodayNew:    todayNew,
		},
		VPN: vpnStats{
			VPNUsers:       int(activeUsers),
			ActiveUsers:    onlineUsers,
			TotalTrafficGB: trafficGB,
		},
		RecentTransactions: []interface{}{},
		ExpiringUsers:      []interface{}{},
	})
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
	relayNodes := h.buildRelayNodes(ctx)
	nodes = append(nodes, relayNodes...)

	return c.JSON(http.StatusOK, listNodesResponse{
		Nodes:               nodes,
		TotalCostMonthlyRub: 0,
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
	if h.VPN != nil {
		online, err := h.VPN.OnlineUsers(ctx)
		if err == nil {
			onlineUsers = online
		}
		if err := h.VPN.Health(ctx); err == nil {
			uptime := h.VPN.UptimeHours()
			uptimeHours = &uptime
		}
	}

	totalTraffic, _ := h.DB.TotalTraffic(ctx)

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

	// System metrics from host.
	metrics := collectSystemMetrics()

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
		TotalTraffic: totalTraffic,
		TrafficUp:    0,
		TrafficDown:  totalTraffic,
		UptimeHours:  uptimeHours,
		Version:      &version,
		Protocols: []protocolStatus{
			{Name: "VLESS Reality", Enabled: true, Port: h.Config.VPN.ListenPort},
		},
		CPU:      metrics.CPUPercent,
		RAMUsed:  metrics.RAMUsedMB,
		RAMTotal: metrics.RAMTotalMB,
		Disk:     metrics.DiskPercent,
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

			node, err := fetchPeerStatus(ctx, p.URL)
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
			results[idx] = node
		}(i, peer)
	}

	wg.Wait()
	return results
}

// buildRelayNodes finds relay servers in the DB and checks TCP connectivity.
// Relays are grouped by unique IP (e.g., SPB relay has relay-de and relay-nl on same IP).
func (h *Handler) buildRelayNodes(ctx context.Context) []nodeResponse {
	servers, err := h.DB.ListActiveServers(ctx)
	if err != nil {
		return nil
	}

	// Collect unique relay IPs with their ports.
	type relayInfo struct {
		ip    string
		ports []int
	}
	seen := map[string]*relayInfo{}
	for _, s := range servers {
		if !strings.HasPrefix(s.Key, "relay-") {
			continue
		}
		if ri, ok := seen[s.Host]; ok {
			ri.ports = append(ri.ports, s.Port)
		} else {
			seen[s.Host] = &relayInfo{ip: s.Host, ports: []int{s.Port}}
		}
	}

	var nodes []nodeResponse
	for _, ri := range seen {
		// TCP health check on first port with 2s timeout.
		active := false
		var latency *int
		start := time.Now()
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", ri.ip, ri.ports[0]), 2*time.Second)
		if err == nil {
			conn.Close()
			active = true
			ms := int(time.Since(start).Milliseconds())
			latency = &ms
		}

		version := "nginx relay"
		nodes = append(nodes, nodeResponse{
			Key:       fmt.Sprintf("relay-%s", ri.ip),
			Name:      "SPB Relay",
			Flag:      "🇷🇺",
			IP:        ri.ip,
			IsActive:  active,
			LatencyMS: latency,
			Version:   &version,
			Protocols: []protocolStatus{
				{Name: "TCP Relay", Enabled: active, Port: ri.ports[0]},
			},
		})
	}

	return nodes
}

// fetchPeerStatus calls GET /api/cluster/node-status on a peer and decodes the response.
func fetchPeerStatus(ctx context.Context, peerURL string) (nodeResponse, error) {
	url := peerURL + "/api/cluster/node-status"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nodeResponse{}, err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nodeResponse{}, err
	}
	defer resp.Body.Close()

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

// ListProtocols handles GET /api/admin/protocols
//
// Returns the list of VPN protocols configured on this node.
func (h *Handler) ListProtocols(c echo.Context) error {
	protocols := []protocolInfo{
		{
			Name:        "vless-reality-tcp",
			DisplayName: "VLESS Reality TCP",
			Enabled:     true,
		},
	}
	return c.JSON(http.StatusOK, map[string]interface{}{
		"protocols": protocols,
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
	return c.JSON(http.StatusOK, map[string]interface{}{
		"status":       "ok",
		"active_users": count,
	})
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
// Returns the list of VPN servers from the database.
func (h *Handler) ListServers(c echo.Context) error {
	ctx := c.Request().Context()

	servers, err := h.DB.ListAllServers(ctx)
	if err != nil {
		h.Logger.Error("admin: list servers", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list servers")
	}

	return c.JSON(http.StatusOK, servers)
}

// serverRequest is the JSON body for create/update server endpoints.
type serverRequest struct {
	Key              string `json:"key"`
	Name             string `json:"name"`
	Flag             string `json:"flag"`
	Host             string `json:"host"`
	Port             int    `json:"port"`
	Domain           string `json:"domain"`
	SNI              string `json:"sni"`
	RealityPublicKey string `json:"reality_public_key"`
	IsActive         bool   `json:"is_active"`
	SortOrder        int    `json:"sort_order"`
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
	})
	if err != nil {
		h.Logger.Error("admin: create server", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to create server")
	}

	h.Logger.Info("admin: server created", zap.String("key", server.Key))
	return c.JSON(http.StatusCreated, server)
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
	})
	if err != nil {
		h.Logger.Error("admin: update server", zap.Error(err), zap.Int64("id", id))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to update server")
	}

	h.Logger.Info("admin: server updated", zap.String("key", server.Key))
	return c.JSON(http.StatusOK, server)
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
	return c.NoContent(http.StatusNoContent)
}

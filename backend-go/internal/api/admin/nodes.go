package admin

import (
	"net/http"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// syncResponse is returned by POST /api/admin/nodes/sync.
type syncResponse struct {
	Status      string `json:"status"`
	ActiveUsers int    `json:"active_users"`
}

// statsResponse is the simplified stats for GET /api/admin/stats.
type statsResponse struct {
	OnlineUsers   int   `json:"online_users"`
	TotalUpload   int64 `json:"total_upload"`
	TotalDownload int64 `json:"total_download"`
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
	TotalUsers        int64              `json:"total_users"`
	ActiveUsers       int64              `json:"active_users"`
	TodayNew          int64              `json:"today_new"`
	RevenueByСurrency map[string]float64 `json:"revenue_by_currency"`
	TodayRevenue      map[string]float64 `json:"today_revenue"`
	TodayTransactions int                `json:"today_transactions"`
	TodayPaid         int                `json:"today_paid"`
	Conversion30D     float64            `json:"conversion_30d"`
	Churned7D         int                `json:"churned_7d"`
	Rev7DLabels       []string           `json:"rev_7d_labels"`
	Rev7DData         []float64          `json:"rev_7d_data"`
}

type vpnStats struct {
	VPNUsers    int     `json:"vpn_users"`
	ActiveUsers int     `json:"active_users"`
	BWInGB      float64 `json:"bw_in_gb"`
	BWOutGB     float64 `json:"bw_out_gb"`
}

// nodeResponse is the JSON representation of a node for the admin API.
type nodeResponse struct {
	Key         string            `json:"key"`
	Name        string            `json:"name"`
	Flag        string            `json:"flag"`
	IP          string            `json:"ip"`
	IsActive    bool              `json:"is_active"`
	LatencyMS   int               `json:"latency_ms"`
	CPU         *float32          `json:"cpu"`
	RAMUsed     *float32          `json:"ram_used"`
	RAMTotal    *float32          `json:"ram_total"`
	Disk        *float32          `json:"disk"`
	UserCount   int               `json:"user_count"`
	OnlineUsers int               `json:"online_users"`
	TrafficUp   int64             `json:"traffic_up"`
	TrafficDown int64             `json:"traffic_down"`
	UptimeHours *float64          `json:"uptime_hours"`
	XrayVersion *string           `json:"xray_version"`
	Protocols   []protocolStatus  `json:"protocols"`
}

type protocolStatus struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Port    int    `json:"port"`
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

	// Convert to VPN engine format.
	vpnUsers := make([]vpn.VPNUser, 0, len(dbUsers))
	for _, u := range dbUsers {
		if u.VPNUsername == nil || u.VPNUUID == nil {
			continue
		}
		vu := vpn.VPNUser{
			Username: *u.VPNUsername,
			UUID:     *u.VPNUUID,
		}
		if u.VPNShortID != nil {
			vu.ShortID = *u.VPNShortID
		}
		vpnUsers = append(vpnUsers, vu)
	}

	// Reload users in VPN engine.
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
		resp.TotalUpload = totalTraffic / 2   // Approximate split
		resp.TotalDownload = totalTraffic / 2
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
			TotalUsers:        totalUsers,
			ActiveUsers:       activeUsers,
			TodayNew:          todayNew,
			RevenueByСurrency: map[string]float64{},
			TodayRevenue:      map[string]float64{},
			TodayTransactions: 0,
			TodayPaid:         0,
			Conversion30D:     0,
			Churned7D:         0,
			Rev7DLabels:       []string{},
			Rev7DData:         []float64{},
		},
		VPN: vpnStats{
			VPNUsers:    int(activeUsers),
			ActiveUsers: onlineUsers,
			BWInGB:      trafficGB * 0.7, // Approximate: 70% download, 30% upload
			BWOutGB:     trafficGB * 0.3,
		},
		RecentTransactions: []interface{}{},
		ExpiringUsers:      []interface{}{},
	})
}

// ListNodes handles GET /api/admin/nodes
//
// Returns the list of VPN nodes. Currently returns the local node from config.
func (h *Handler) ListNodes(c echo.Context) error {
	ctx := c.Request().Context()

	nodes := make([]nodeResponse, 0, len(h.Config.VPN.Servers))

	activeUsers, _ := h.DB.CountActiveUsers(ctx)

	onlineUsers := 0
	if h.VPN != nil {
		online, err := h.VPN.OnlineUsers(ctx)
		if err == nil {
			onlineUsers = online
		}
	}

	totalTraffic, _ := h.DB.TotalTraffic(ctx)

	for _, srv := range h.Config.VPN.Servers {
		node := nodeResponse{
			Key:         srv.Key,
			Name:        srv.Name,
			Flag:        srv.Flag,
			IP:          srv.Host,
			IsActive:    true,
			LatencyMS:   1,
			UserCount:   int(activeUsers),
			OnlineUsers: onlineUsers,
			TrafficUp:   int64(float64(totalTraffic) * 0.3),
			TrafficDown: int64(float64(totalTraffic) * 0.7),
			Protocols:   []protocolStatus{},
		}
		nodes = append(nodes, node)
	}

	// If no servers in config, show at least the local node.
	if len(nodes) == 0 {
		nodes = append(nodes, nodeResponse{
			Key:         h.Config.Cluster.NodeID,
			Name:        "Local Node",
			Flag:        "",
			IP:          h.Config.Server.Host,
			IsActive:    true,
			LatencyMS:   1,
			UserCount:   int(activeUsers),
			OnlineUsers: onlineUsers,
			TrafficUp:   int64(float64(totalTraffic) * 0.3),
			TrafficDown: int64(float64(totalTraffic) * 0.7),
			Protocols:   []protocolStatus{},
		})
	}

	return c.JSON(http.StatusOK, listNodesResponse{
		Nodes:               nodes,
		TotalCostMonthlyRub: 0,
	})
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

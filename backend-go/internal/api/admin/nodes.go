package admin

import (
	"net/http"
	"strconv"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/cluster"
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
type nodeResponse struct {
	Key          string           `json:"key"`
	Name         string           `json:"name"`
	Flag         string           `json:"flag"`
	IP           string           `json:"ip"`
	IsActive     bool             `json:"is_active"`
	UserCount    int              `json:"user_count"`
	OnlineUsers  int              `json:"online_users"`
	TotalTraffic int64            `json:"total_traffic"`
	Protocols    []protocolStatus `json:"protocols"`
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
			Key:          srv.Key,
			Name:         srv.Name,
			Flag:         srv.Flag,
			IP:           srv.Host,
			IsActive:     true,
			UserCount:    int(activeUsers),
			OnlineUsers:  onlineUsers,
			TotalTraffic: totalTraffic,
			Protocols:    []protocolStatus{},
		}
		nodes = append(nodes, node)
	}

	// If no servers in config, show at least the local node.
	if len(nodes) == 0 {
		nodes = append(nodes, nodeResponse{
			Key:          h.Config.Cluster.NodeID,
			Name:         "Local Node",
			IP:           h.Config.Server.Host,
			IsActive:     true,
			UserCount:    int(activeUsers),
			OnlineUsers:  onlineUsers,
			TotalTraffic: totalTraffic,
			Protocols:    []protocolStatus{},
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

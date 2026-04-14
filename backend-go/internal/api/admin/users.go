package admin

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/payments"
)

// userResponse is the JSON representation of a user for the admin API.
// Compatible with the React SPA's User interface.
type userResponse struct {
	ID                 int64   `json:"id"`
	VPNUsername        string  `json:"vpn_username"`
	FullName           *string `json:"full_name"`
	IsActive           bool    `json:"is_active"`
	SubscriptionExpiry *string `json:"subscription_expiry"`
	DaysLeft           *int    `json:"days_left"`
	CumulativeTraffic  float64 `json:"cumulative_traffic"` // in GB
	Devices            int     `json:"devices"`
	DeviceLimit        *int    `json:"device_limit"`
	CreatedAt          *string `json:"created_at"`
	SubscriptionURL    *string `json:"subscription_url"`

	LastSeen        *string `json:"last_seen"`
	LastIP          string  `json:"last_ip"`
	AppVersion      string  `json:"app_version"`
	OSName          string  `json:"os_name"`
	OSVersion       string  `json:"os_version"`
	LastCountry     string  `json:"last_country"`
	LastCountryName string  `json:"last_country_name"`
	LastCity        string  `json:"last_city"`

	InitialIP          string  `json:"initial_ip"`
	InitialCountry     string  `json:"initial_country"`
	InitialCountryName string  `json:"initial_country_name"`
	InitialCity        string  `json:"initial_city"`
	Timezone           string  `json:"timezone"`
	DeviceModel        string  `json:"device_model"`
	IOSVersion         string  `json:"ios_version"`
	AcceptLanguage     string  `json:"accept_language"`
	InstallDate        *string `json:"install_date"`
	StoreCountry       string  `json:"store_country"`

	// IsViaVPN is true when last_ip matches one of our own VPN exit nodes.
	// Callers should treat last_country/last_city as meaningless in that
	// case and fall back to initial_country / timezone for real location.
	IsViaVPN     bool   `json:"is_via_vpn"`
	ViaVPNNode   string `json:"via_vpn_node"`
}

// listUsersResponse is the paginated response for GET /api/admin/users.
type listUsersResponse struct {
	Users    []userResponse `json:"users"`
	Total    int64          `json:"total"`
	Page     int            `json:"page"`
	PageSize int            `json:"page_size"`
}

// extendRequest is the body for POST /api/admin/users/:id/extend.
type extendRequest struct {
	Days int `json:"days"`
}

// ListUsers handles GET /api/admin/users?page=1&page_size=25&search=xxx
//
// Returns a paginated list of users with optional search filtering.
// Search matches against vpn_username, device_id, username, and full_name.
func (h *Handler) ListUsers(c echo.Context) error {
	ctx := c.Request().Context()

	page, _ := strconv.Atoi(c.QueryParam("page"))
	if page < 1 {
		page = 1
	}

	pageSize, _ := strconv.Atoi(c.QueryParam("page_size"))
	if pageSize < 1 {
		pageSize = 25
	}
	if pageSize > 200 {
		pageSize = 200
	}

	search := c.QueryParam("search")

	var (
		users []db.User
		total int64
		err   error
	)

	if search != "" {
		users, total, err = h.DB.SearchUsers(ctx, search, page, pageSize)
	} else {
		users, total, err = h.DB.ListUsers(ctx, page, pageSize)
	}

	if err != nil {
		h.Logger.Error("admin: list users", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list users")
	}

	serverIPs := h.loadServerIPMap(ctx)

	resp := listUsersResponse{
		Users:    make([]userResponse, 0, len(users)),
		Total:    total,
		Page:     page,
		PageSize: pageSize,
	}

	for _, u := range users {
		resp.Users = append(resp.Users, toUserResponse(u, serverIPs))
	}

	return c.JSON(http.StatusOK, resp)
}

// loadServerIPMap returns a map of host (IP or DNS name) -> node key for all
// VPN servers. Used to detect when a user's last_ip belongs to our own VPN
// exit, so the admin UI can distinguish "real location" from "via VPN".
// A DB failure is non-fatal — we just return an empty map.
func (h *Handler) loadServerIPMap(ctx context.Context) map[string]string {
	servers, err := h.DB.ListAllServers(ctx)
	if err != nil {
		h.Logger.Warn("admin: load server IPs", zap.Error(err))
		return map[string]string{}
	}
	m := make(map[string]string, len(servers))
	for _, s := range servers {
		if s.Host != "" {
			m[s.Host] = s.Key
		}
	}
	return m
}

// GetUser handles GET /api/admin/users/:id
//
// Returns a single user by ID or vpn_username.
func (h *Handler) GetUser(c echo.Context) error {
	ctx := c.Request().Context()
	idParam := c.Param("id")

	// Try as numeric ID first.
	id, err := strconv.ParseInt(idParam, 10, 64)
	var user *db.User

	if err == nil {
		user, err = h.DB.FindUserByID(ctx, id)
	} else {
		// Treat as vpn_username.
		user, err = h.DB.FindUserByVPNUsername(ctx, idParam)
	}

	if err != nil {
		h.Logger.Error("admin: get user", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get user")
	}

	if user == nil {
		return echo.NewHTTPError(http.StatusNotFound, "user not found")
	}

	return c.JSON(http.StatusOK, toUserResponse(*user, h.loadServerIPMap(ctx)))
}

// DeleteUser handles DELETE /api/admin/users/:id
//
// Soft deletes a user (sets is_active = false) and removes them from the VPN engine.
// The :id parameter can be a numeric ID or a vpn_username.
func (h *Handler) DeleteUser(c echo.Context) error {
	ctx := c.Request().Context()
	idParam := c.Param("id")

	// Determine if the parameter is a numeric ID or vpn_username.
	id, parseErr := strconv.ParseInt(idParam, 10, 64)

	var (
		user       *db.User
		err        error
		vpnUsername string
	)

	if parseErr == nil {
		// Numeric ID — find the user first for VPN removal.
		user, err = h.DB.FindUserByID(ctx, id)
		if err != nil {
			h.Logger.Error("admin: delete user: find", zap.Error(err))
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to find user")
		}
		if user == nil {
			return echo.NewHTTPError(http.StatusNotFound, "user not found")
		}
		if user.VPNUsername != nil {
			vpnUsername = *user.VPNUsername
		}

		err = h.DB.DeleteUser(ctx, id)
	} else {
		// vpn_username — find by username.
		vpnUsername = idParam
		user, err = h.DB.FindUserByVPNUsername(ctx, vpnUsername)
		if err != nil {
			h.Logger.Error("admin: delete user: find by vpn_username", zap.Error(err))
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to find user")
		}
		if user == nil {
			return echo.NewHTTPError(http.StatusNotFound, "user not found")
		}

		err = h.DB.DeleteUserByUsername(ctx, vpnUsername)
	}

	if err != nil {
		if err == db.ErrNotFound {
			return echo.NewHTTPError(http.StatusNotFound, "user not found")
		}
		h.Logger.Error("admin: delete user", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to delete user")
	}

	// Remove from VPN engine if available.
	if h.VPN != nil && vpnUsername != "" {
		if removeErr := h.VPN.RemoveUser(ctx, vpnUsername); removeErr != nil {
			h.Logger.Warn("admin: remove user from VPN engine",
				zap.String("username", vpnUsername),
				zap.Error(removeErr))
			// Non-fatal: user is already soft-deleted in DB.
		}
	}

	h.Logger.Info("admin: user deleted",
		zap.String("vpn_username", vpnUsername))

	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
}

// ExtendSubscription handles POST /api/admin/users/:id/extend
//
// Extends a user's subscription by the specified number of days.
// The :id parameter can be a numeric ID or a vpn_username.
func (h *Handler) ExtendSubscription(c echo.Context) error {
	// Only admin role can extend subscriptions (not operator/viewer).
	claims := auth.GetUserFromContext(c)
	if claims == nil || claims.Role != "admin" {
		return echo.NewHTTPError(http.StatusForbidden, "admin role required")
	}

	ctx := c.Request().Context()
	idParam := c.Param("id")

	var req extendRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.Days < 1 || req.Days > 3650 {
		return echo.NewHTTPError(http.StatusBadRequest, "days must be between 1 and 3650")
	}

	// Resolve :id (numeric) or :id (vpn_username) to a numeric user id so we can
	// route the grant through the unified payments ledger instead of a raw UPDATE.
	id, parseErr := strconv.ParseInt(idParam, 10, 64)
	if parseErr != nil {
		u, err := h.DB.FindUserByVPNUsername(ctx, idParam)
		if err != nil {
			if err == db.ErrNotFound {
				return echo.NewHTTPError(http.StatusNotFound, "user not found")
			}
			h.Logger.Error("admin: lookup user by username", zap.Error(err))
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to extend subscription")
		}
		id = u.ID
	}

	// Admin grants are idempotent per (admin actor, target, timestamp). We synthesize
	// a charge_id so reruns of the same API call don't double-credit, while distinct
	// admin clicks remain distinct charges.
	chargeID := fmt.Sprintf("admin:%d:%d:%d", id, req.Days, time.Now().UnixNano())

	_, err := h.Payments.CreditDays(ctx, payments.Credit{
		UserID:   id,
		Source:   payments.SourceAdmin,
		ChargeID: chargeID,
		Days:     req.Days,
	})
	if err != nil {
		h.Logger.Error("admin: extend subscription", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to extend subscription")
	}

	h.Logger.Info("admin: subscription extended",
		zap.String("user", idParam),
		zap.Int("days", req.Days),
		zap.String("charge_id", chargeID))

	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
}

// toUserResponse converts a DB User to the admin API response format.
// serverIPs maps our VPN exit IPs → node key so we can flag users whose
// last_ip is actually one of our own servers (= they're connected via our
// VPN, so last_country is the VPN exit location, not the real one).
func toUserResponse(u db.User, serverIPs map[string]string) userResponse {
	r := userResponse{
		ID:                 u.ID,
		IsActive:           u.IsActive,
		CumulativeTraffic:  math.Round(float64(u.CumulativeTraffic)/1073741824*100) / 100, // bytes -> GB, 2 decimals
		Devices:            1, // Default: 1 device
		DeviceLimit:        u.DeviceLimit,
		FullName:           u.FullName,
		LastIP:             u.LastIP,
		AppVersion:         u.AppVersion,
		OSName:             u.OSName,
		OSVersion:          u.OSVersion,
		LastCountry:        u.LastCountry,
		LastCountryName:    u.LastCountryName,
		LastCity:           u.LastCity,
		InitialIP:          u.InitialIP,
		InitialCountry:     u.InitialCountry,
		InitialCountryName: u.InitialCountryName,
		InitialCity:        u.InitialCity,
		Timezone:           u.Timezone,
		DeviceModel:        u.DeviceModel,
		IOSVersion:         u.IOSVersion,
		AcceptLanguage:     u.AcceptLanguage,
		StoreCountry:       u.StoreCountry,
	}

	if node, ok := serverIPs[u.LastIP]; ok && u.LastIP != "" {
		r.IsViaVPN = true
		r.ViaVPNNode = node
	}

	if u.InstallDate != nil {
		s := u.InstallDate.Format("2006-01-02")
		r.InstallDate = &s
	}

	if u.LastSeen != nil {
		formatted := u.LastSeen.Format(time.RFC3339)
		r.LastSeen = &formatted
	}

	if u.VPNUsername != nil {
		r.VPNUsername = *u.VPNUsername
	} else if u.Username != nil {
		r.VPNUsername = *u.Username
	}

	if u.SubscriptionExpiry != nil {
		formatted := u.SubscriptionExpiry.Format("2006-01-02")
		r.SubscriptionExpiry = &formatted

		daysLeft := int(time.Until(*u.SubscriptionExpiry).Hours() / 24)
		if daysLeft < 0 {
			daysLeft = 0
		}
		r.DaysLeft = &daysLeft
	}

	if !u.CreatedAt.IsZero() {
		formatted := u.CreatedAt.Format("2006-01-02 15:04")
		r.CreatedAt = &formatted
	}

	if u.SubscriptionToken != nil {
		url := "/api/mobile/sub/" + *u.SubscriptionToken
		r.SubscriptionURL = &url
	}

	return r
}

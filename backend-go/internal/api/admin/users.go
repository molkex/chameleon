package admin

import (
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
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

	resp := listUsersResponse{
		Users:    make([]userResponse, 0, len(users)),
		Total:    total,
		Page:     page,
		PageSize: pageSize,
	}

	for _, u := range users {
		resp.Users = append(resp.Users, toUserResponse(u))
	}

	return c.JSON(http.StatusOK, resp)
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

	return c.JSON(http.StatusOK, toUserResponse(*user))
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
	ctx := c.Request().Context()
	idParam := c.Param("id")

	var req extendRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.Days < 1 || req.Days > 3650 {
		return echo.NewHTTPError(http.StatusBadRequest, "days must be between 1 and 3650")
	}

	// Determine if the parameter is a numeric ID or vpn_username.
	id, parseErr := strconv.ParseInt(idParam, 10, 64)

	var err error
	if parseErr == nil {
		err = h.DB.ExtendSubscription(ctx, id, req.Days)
	} else {
		err = h.DB.ExtendSubscriptionByUsername(ctx, idParam, req.Days)
	}

	if err != nil {
		if err == db.ErrNotFound {
			return echo.NewHTTPError(http.StatusNotFound, "user not found")
		}
		h.Logger.Error("admin: extend subscription", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to extend subscription")
	}

	h.Logger.Info("admin: subscription extended",
		zap.String("user", idParam),
		zap.Int("days", req.Days))

	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
}

// toUserResponse converts a DB User to the admin API response format.
func toUserResponse(u db.User) userResponse {
	r := userResponse{
		ID:                u.ID,
		IsActive:          u.IsActive,
		CumulativeTraffic: math.Round(float64(u.CumulativeTraffic)/1073741824*100) / 100, // bytes -> GB, 2 decimals
		Devices:           1, // Default: 1 device
		DeviceLimit:       u.DeviceLimit,
		FullName:          u.FullName,
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

package admin

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
)

// createAdminRequest is the body for POST /api/admin/admins.
type createAdminRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Role     string `json:"role"`
}

// adminResponse is the JSON representation of an admin user.
type adminResponse struct {
	ID        int64   `json:"id"`
	Username  string  `json:"username"`
	Role      string  `json:"role"`
	IsActive  bool    `json:"is_active"`
	LastLogin *string `json:"last_login"`
	CreatedAt *string `json:"created_at"`
}

// ListAdmins handles GET /api/admin/admins
//
// Returns all active admin users.
func (h *Handler) ListAdmins(c echo.Context) error {
	ctx := c.Request().Context()

	admins, err := h.DB.ListAdmins(ctx)
	if err != nil {
		h.Logger.Error("admin: list admins", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to list admins")
	}

	resp := make([]adminResponse, 0, len(admins))
	for _, a := range admins {
		resp = append(resp, toAdminResponse(a))
	}

	return c.JSON(http.StatusOK, resp)
}

// CreateAdmin handles POST /api/admin/admins
//
// Creates a new admin user with the specified username, password, and role.
func (h *Handler) CreateAdmin(c echo.Context) error {
	var req createAdminRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.Username == "" || req.Password == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "username and password are required")
	}
	const minPasswordLen = 12
	if len(req.Password) < minPasswordLen {
		return echo.NewHTTPError(http.StatusBadRequest, fmt.Sprintf("password must be at least %d characters", minPasswordLen))
	}

	// Validate role.
	validRoles := map[string]bool{"admin": true, "operator": true, "viewer": true}
	if !validRoles[req.Role] {
		req.Role = "viewer"
	}

	// Hash the password.
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		h.Logger.Error("admin: create admin: hash password", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to create admin")
	}

	ctx := c.Request().Context()
	admin, err := h.DB.CreateAdmin(ctx, req.Username, hash, req.Role)
	if err != nil {
		h.Logger.Error("admin: create admin", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to create admin")
	}

	h.Logger.Info("admin: admin created",
		zap.String("username", req.Username),
		zap.String("role", req.Role))

	return c.JSON(http.StatusCreated, toAdminResponse(*admin))
}

// DeleteAdmin handles DELETE /api/admin/admins/:id
//
// Soft-deletes an admin user. Refuses to delete the caller's own row to
// avoid the lock-out scenario where an admin removes the last active
// account (including their own).
func (h *Handler) DeleteAdmin(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid admin id")
	}

	if claims, ok := c.Get("auth_claims").(*auth.Claims); ok && claims != nil && claims.UserID == id {
		return echo.NewHTTPError(http.StatusBadRequest, "cannot delete your own admin account")
	}

	ctx := c.Request().Context()
	if err := h.DB.DeleteAdmin(ctx, id); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			return echo.NewHTTPError(http.StatusNotFound, "admin not found")
		}
		h.Logger.Error("admin: delete admin", zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to delete admin")
	}

	h.Logger.Info("admin: admin deleted", zap.Int64("id", id))
	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
}

// toAdminResponse converts a DB AdminUser to the admin API response format.
func toAdminResponse(a db.AdminUser) adminResponse {
	r := adminResponse{
		ID:       a.ID,
		Username: a.Username,
		Role:     a.Role,
		IsActive: a.IsActive,
	}

	if a.LastLogin != nil {
		formatted := a.LastLogin.Format("2006-01-02 15:04")
		r.LastLogin = &formatted
	}

	if !a.CreatedAt.IsZero() {
		formatted := a.CreatedAt.Format("2006-01-02 15:04")
		r.CreatedAt = &formatted
	}

	return r
}

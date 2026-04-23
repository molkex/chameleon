package mobile

import (
	"net/http"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

var validThemes = map[string]bool{
	"calm": true,
	"neon": true,
}

type setThemeRequest struct {
	Theme string `json:"theme"`
}

// SetTheme persists the user's UI theme preference (for analytics + cross-device sync).
// The device remains source of truth; the backend is best-effort storage.
func (h *Handler) SetTheme(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
	}

	var req setThemeRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid body")
	}
	if !validThemes[req.Theme] {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid theme")
	}

	if err := h.DB.SetUserTheme(c.Request().Context(), claims.UserID, req.Theme); err != nil {
		h.Logger.Warn("SetUserTheme failed", zap.Int64("user_id", claims.UserID), zap.Error(err))
		return echo.NewHTTPError(http.StatusInternalServerError, "db error")
	}

	return c.JSON(http.StatusOK, map[string]string{"theme": req.Theme})
}

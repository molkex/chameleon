// Package admin — promo.go: CRUD for promo codes (PROMO-CODES). The mobile
// paywall validates + redeems via internal/api/mobile; here an operator mints,
// edits, toggles and deletes codes.
package admin

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/promo"
	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

type promoReq struct {
	Code        string  `json:"code"`
	DiscountPct int     `json:"discount_pct"`
	Active      bool    `json:"active"`
	PerUserOnce bool    `json:"per_user_once"`
	MaxUses     *int    `json:"max_uses"`   // null = unlimited
	ExpiresAt   *string `json:"expires_at"` // RFC3339 or null
	Note        string  `json:"note"`
}

func (r promoReq) toModel() (*db.PromoCode, error) {
	code := promo.Normalize(r.Code)
	if code == "" {
		return nil, errors.New("code is required")
	}
	if len(code) > 64 {
		return nil, errors.New("code too long")
	}
	if r.DiscountPct < 1 || r.DiscountPct > 100 {
		return nil, errors.New("discount_pct must be 1..100")
	}
	if r.MaxUses != nil && *r.MaxUses < 1 {
		return nil, errors.New("max_uses must be >= 1 or null")
	}
	var expires *time.Time
	if r.ExpiresAt != nil && strings.TrimSpace(*r.ExpiresAt) != "" {
		t, err := time.Parse(time.RFC3339, strings.TrimSpace(*r.ExpiresAt))
		if err != nil {
			return nil, errors.New("bad expires_at (use RFC3339)")
		}
		expires = &t
	}
	return &db.PromoCode{
		Code: code, DiscountPct: r.DiscountPct, Active: r.Active,
		PerUserOnce: r.PerUserOnce, MaxUses: r.MaxUses, ExpiresAt: expires,
		Note: strings.TrimSpace(r.Note),
	}, nil
}

func promoDTO(p db.PromoCode) map[string]any {
	m := map[string]any{
		"id": p.ID, "code": p.Code, "discount_pct": p.DiscountPct, "active": p.Active,
		"per_user_once": p.PerUserOnce, "used_count": p.UsedCount, "redemptions": p.RedemptionCount,
		"note": p.Note, "created_by": p.CreatedBy, "created_at": p.CreatedAt, "updated_at": p.UpdatedAt,
	}
	if p.MaxUses != nil {
		m["max_uses"] = *p.MaxUses
	}
	if p.ExpiresAt != nil {
		m["expires_at"] = p.ExpiresAt
	}
	return m
}

// ListPromoCodes — GET /admin/promo.
func (h *Handler) ListPromoCodes(c echo.Context) error {
	list, err := h.DB.ListPromoCodes(c.Request().Context(), 200)
	if err != nil {
		h.Logger.Error("promo list", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	out := make([]map[string]any, 0, len(list))
	for _, p := range list {
		out = append(out, promoDTO(p))
	}
	return c.JSON(http.StatusOK, map[string]any{"promo_codes": out})
}

// CreatePromoCode — POST /admin/promo (adminOnly).
func (h *Handler) CreatePromoCode(c echo.Context) error {
	var req promoReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	p, err := req.toModel()
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	if claims := auth.GetUserFromContext(c); claims != nil {
		p.CreatedBy = claims.Username
	}
	created, err := h.DB.CreatePromoCode(c.Request().Context(), p)
	switch {
	case err == nil:
		return c.JSON(http.StatusOK, promoDTO(*created))
	case errors.Is(err, db.ErrConflict):
		return c.JSON(http.StatusConflict, map[string]string{"error": "code already exists"})
	default:
		h.Logger.Error("promo create", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

// UpdatePromoCode — PUT /admin/promo/:id (adminOnly).
func (h *Handler) UpdatePromoCode(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad id"})
	}
	var req promoReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	p, err := req.toModel()
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	p.ID = id
	updated, err := h.DB.UpdatePromoCode(c.Request().Context(), p)
	switch {
	case err == nil:
		return c.JSON(http.StatusOK, promoDTO(*updated))
	case errors.Is(err, db.ErrNotFound):
		return c.JSON(http.StatusNotFound, map[string]string{"error": "not found"})
	default:
		h.Logger.Error("promo update", zap.Int64("id", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

// DeletePromoCode — DELETE /admin/promo/:id (adminOnly).
func (h *Handler) DeletePromoCode(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad id"})
	}
	switch err := h.DB.DeletePromoCode(c.Request().Context(), id); {
	case err == nil:
		return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
	case errors.Is(err, db.ErrNotFound):
		return c.JSON(http.StatusNotFound, map[string]string{"error": "not found"})
	default:
		h.Logger.Error("promo delete", zap.Int64("id", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

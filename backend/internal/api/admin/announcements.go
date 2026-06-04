// Package admin — announcements.go: CRUD for in-app announcements
// (INAPP-ANNOUNCEMENTS). The mobile client reads the active set via
// mobile/announcements.go; here an operator creates / edits / toggles / deletes.
package admin

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

const (
	maxAnnTitleLen = 100
	maxAnnBodyLen  = 1000
)

var validAnnKinds = map[string]bool{"info": true, "promo": true, "update": true}

type announcementReq struct {
	Title    string  `json:"title"`
	Body     string  `json:"body"`
	Kind     string  `json:"kind"`
	Active   bool    `json:"active"`
	StartsAt *string `json:"starts_at"` // RFC3339 or null/empty
	EndsAt   *string `json:"ends_at"`
	CTALabel string  `json:"cta_label"`
	CTAURL   string  `json:"cta_url"`
}

func parseAnnTime(s *string) (*time.Time, error) {
	if s == nil || strings.TrimSpace(*s) == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(*s))
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// toModel validates the request and maps it to a db.Announcement (sans id/created_by).
func (r announcementReq) toModel() (*db.Announcement, error) {
	title := strings.TrimSpace(r.Title)
	body := strings.TrimSpace(r.Body)
	if title == "" || body == "" {
		return nil, errors.New("title and body are required")
	}
	if len([]rune(title)) > maxAnnTitleLen || len([]rune(body)) > maxAnnBodyLen {
		return nil, errors.New("title or body too long")
	}
	kind := strings.TrimSpace(r.Kind)
	if kind == "" {
		kind = "info"
	}
	if !validAnnKinds[kind] {
		return nil, errors.New("invalid kind")
	}
	starts, err := parseAnnTime(r.StartsAt)
	if err != nil {
		return nil, errors.New("bad starts_at (use RFC3339)")
	}
	ends, err := parseAnnTime(r.EndsAt)
	if err != nil {
		return nil, errors.New("bad ends_at (use RFC3339)")
	}
	a := &db.Announcement{Title: title, Body: body, Kind: kind, Active: r.Active, StartsAt: starts, EndsAt: ends}
	if s := strings.TrimSpace(r.CTALabel); s != "" {
		a.CTALabel = &s
	}
	if s := strings.TrimSpace(r.CTAURL); s != "" {
		a.CTAURL = &s
	}
	return a, nil
}

func announcementDTO(a db.Announcement) map[string]any {
	m := map[string]any{
		"id": a.ID, "title": a.Title, "body": a.Body, "kind": a.Kind,
		"active": a.Active, "created_by": a.CreatedBy,
		"created_at": a.CreatedAt, "updated_at": a.UpdatedAt,
	}
	if a.StartsAt != nil {
		m["starts_at"] = a.StartsAt
	}
	if a.EndsAt != nil {
		m["ends_at"] = a.EndsAt
	}
	if a.CTALabel != nil {
		m["cta_label"] = *a.CTALabel
	}
	if a.CTAURL != nil {
		m["cta_url"] = *a.CTAURL
	}
	return m
}

// ListAnnouncements — GET /admin/announcements.
func (h *Handler) ListAnnouncements(c echo.Context) error {
	list, err := h.DB.ListAnnouncements(c.Request().Context(), 100)
	if err != nil {
		h.Logger.Error("announcements list", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	out := make([]map[string]any, 0, len(list))
	for _, a := range list {
		out = append(out, announcementDTO(a))
	}
	return c.JSON(http.StatusOK, map[string]any{"announcements": out})
}

// CreateAnnouncement — POST /admin/announcements (adminOnly).
func (h *Handler) CreateAnnouncement(c echo.Context) error {
	var req announcementReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	a, err := req.toModel()
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	if claims := auth.GetUserFromContext(c); claims != nil {
		a.CreatedBy = claims.Username
	}
	created, err := h.DB.CreateAnnouncement(c.Request().Context(), a)
	if err != nil {
		h.Logger.Error("announcements create", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
	return c.JSON(http.StatusOK, announcementDTO(*created))
}

// UpdateAnnouncement — PUT /admin/announcements/:id (adminOnly).
func (h *Handler) UpdateAnnouncement(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad id"})
	}
	var req announcementReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad request"})
	}
	a, err := req.toModel()
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	a.ID = id
	updated, err := h.DB.UpdateAnnouncement(c.Request().Context(), a)
	switch {
	case err == nil:
		return c.JSON(http.StatusOK, announcementDTO(*updated))
	case errors.Is(err, db.ErrNotFound):
		return c.JSON(http.StatusNotFound, map[string]string{"error": "not found"})
	default:
		h.Logger.Error("announcements update", zap.Int64("id", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

// DeleteAnnouncement — DELETE /admin/announcements/:id (adminOnly).
func (h *Handler) DeleteAnnouncement(c echo.Context) error {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "bad id"})
	}
	switch err := h.DB.DeleteAnnouncement(c.Request().Context(), id); {
	case err == nil:
		return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
	case errors.Is(err, db.ErrNotFound):
		return c.JSON(http.StatusNotFound, map[string]string{"error": "not found"})
	default:
		h.Logger.Error("announcements delete", zap.Int64("id", id), zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

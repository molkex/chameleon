package cluster

import (
	"crypto/subtle"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
)

// ClusterAuth returns middleware that validates Bearer token for cluster endpoints.
func ClusterAuth(secret string) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			if secret == "" {
				return c.JSON(http.StatusForbidden, map[string]string{"error": "cluster secret not configured — refusing all cluster requests"})
			}
			auth := c.Request().Header.Get("Authorization")
			if auth == "" {
				return c.JSON(http.StatusUnauthorized, map[string]string{"error": "missing authorization"})
			}
			token := strings.TrimPrefix(auth, "Bearer ")
			if subtle.ConstantTimeCompare([]byte(token), []byte(secret)) != 1 {
				return c.JSON(http.StatusForbidden, map[string]string{"error": "invalid cluster secret"})
			}
			return next(c)
		}
	}
}

// RegisterRoutes adds internal cluster sync endpoints to the given Echo group.
// These endpoints are NOT public-facing — they should be accessible only from
// trusted peer nodes (e.g., via firewall rules or private network).
//
// Endpoints:
//
//	GET  /api/cluster/pull?since=<RFC3339> — return users changed since timestamp
//	POST /api/cluster/push                 — receive user changes from a peer
func RegisterRoutes(g *echo.Group, database *db.DB, cfg config.ClusterConfig, logger *zap.Logger) {
	h := &clusterHandler{
		db:     database,
		config: cfg,
		logger: logger.Named("cluster.api"),
	}

	g.GET("/pull", h.handlePull)
	g.POST("/push", h.handlePush)
}

// clusterHandler holds dependencies for cluster API endpoints.
type clusterHandler struct {
	db     *db.DB
	config config.ClusterConfig
	logger *zap.Logger
}

// handlePull returns users changed since the given timestamp.
// Query parameter: since (RFC3339 format, optional — defaults to epoch).
//
// Response: PullResponse with the node's ID and changed users.
func (h *clusterHandler) handlePull(c echo.Context) error {
	sinceStr := c.QueryParam("since")
	var since time.Time
	if sinceStr != "" {
		var err error
		since, err = time.Parse(time.RFC3339Nano, sinceStr)
		if err != nil {
			return c.JSON(http.StatusBadRequest, map[string]string{
				"error": "invalid 'since' parameter: expected RFC3339 format",
			})
		}
	}

	peerID := c.Request().Header.Get("X-Cluster-Node-ID")
	h.logger.Debug("pull request",
		zap.String("peer_id", peerID),
		zap.Time("since", since),
	)

	ctx := c.Request().Context()

	users, err := h.db.UsersChangedSince(ctx, since)
	if err != nil {
		h.logger.Error("failed to query changed users", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, map[string]string{
			"error": "internal error",
		})
	}

	servers, err := h.db.ServersChangedSince(ctx, since)
	if err != nil {
		h.logger.Error("failed to query changed servers", zap.Error(err))
		// Non-fatal: return users without servers
		servers = nil
	}

	resp := PullResponse{
		NodeID:  h.config.NodeID,
		Users:   dbUsersToSyncUsers(users),
		Servers: dbServersToSyncServers(servers),
	}

	h.logger.Debug("pull response",
		zap.String("peer_id", peerID),
		zap.Int("users", len(resp.Users)),
	)

	return c.JSON(http.StatusOK, resp)
}

// handlePush receives user changes from a peer and upserts them into the local DB.
// Conflict resolution: latest updated_at wins (handled by UpsertUserByVPNUUID).
//
// Request body: PushRequest
// Response: PushResponse with counts of received and applied records.
func (h *clusterHandler) handlePush(c echo.Context) error {
	var req PushRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{
			"error": "invalid request body",
		})
	}

	// Cap pushed payload — even with a valid CLUSTER_SECRET, a buggy or
	// compromised peer should not be able to wipe-and-replace the whole DB
	// in one call. 10k users / 1k servers is well above any realistic delta.
	const maxUsersPerPush = 10000
	const maxServersPerPush = 1000
	if len(req.Users) > maxUsersPerPush || len(req.Servers) > maxServersPerPush {
		h.logger.Warn("push request exceeds limits",
			zap.String("peer_id", req.NodeID),
			zap.Int("users", len(req.Users)),
			zap.Int("servers", len(req.Servers)),
		)
		return c.JSON(http.StatusRequestEntityTooLarge, map[string]string{
			"error": "push payload too large",
		})
	}

	h.logger.Debug("push request",
		zap.String("peer_id", req.NodeID),
		zap.Int("users", len(req.Users)),
	)

	ctx := c.Request().Context()
	dbUsers := syncUsersToDBUsers(req.Users)

	var applied int
	for i := range dbUsers {
		updated, err := h.db.UpsertUserByVPNUUID(ctx, &dbUsers[i])
		if err != nil {
			// Unique-constraint conflict on vpn_username is expected during
			// cluster sync because vpn_username is deterministic on device_id
			// (sha256(device_id)[:8]). After delete+re-register the same device
			// gets a new vpn_uuid but the same vpn_username, so the row landed
			// from the peer collides with a local row that has a different
			// vpn_uuid. Logged at warn — sync continues, the local row wins
			// (newer registration). ROADMAP: rework vpn_username generation
			// to be salted by vpn_uuid so this stops happening.
			if isDuplicateVPNUsername(err) {
				h.logger.Warn("skipping pushed user due to vpn_username conflict",
					zap.String("vpn_uuid", safeDeref(dbUsers[i].VPNUUID)),
				)
			} else {
				h.logger.Error("failed to upsert pushed user",
					zap.String("vpn_uuid", safeDeref(dbUsers[i].VPNUUID)),
					zap.Error(err),
				)
			}
			continue
		}
		if updated {
			applied++
		}
	}

	// Upsert servers
	var serversApplied int
	for _, ss := range req.Servers {
		srv := syncServerToDBServer(ss)
		updated, err := h.db.UpsertServerByKey(ctx, &srv)
		if err != nil {
			h.logger.Error("failed to upsert pushed server", zap.String("key", ss.Key), zap.Error(err))
			continue
		}
		if updated {
			serversApplied++
		}
	}

	h.logger.Info("push complete",
		zap.String("peer_id", req.NodeID),
		zap.Int("users_received", len(req.Users)),
		zap.Int("users_applied", applied),
		zap.Int("servers_received", len(req.Servers)),
		zap.Int("servers_applied", serversApplied),
	)

	return c.JSON(http.StatusOK, PushResponse{
		Received: len(req.Users) + len(req.Servers),
		Applied:  applied + serversApplied,
	})
}

// Package admin provides HTTP handlers for the Chameleon VPN admin API.
//
// All handlers are methods on the Handler struct, which holds shared
// dependencies (DB, Redis, JWT, VPN engine, config, logger).
package admin

import (
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Handler holds all dependencies needed by admin API handlers.
type Handler struct {
	DB     *db.DB
	Redis  *redis.Client
	JWT    *auth.JWTManager
	VPN    vpn.Engine // may be nil if VPN engine is not configured
	Config *config.Config
	Logger *zap.Logger
}

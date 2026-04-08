// Package mobile provides HTTP handlers for the Chameleon VPN mobile API.
//
// All handlers are methods on the Handler struct, which holds shared
// dependencies (DB, JWT, Apple verifier, VPN engine, config, logger).
package mobile

import (
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// Handler holds all dependencies needed by mobile API handlers.
type Handler struct {
	DB     *db.DB
	JWT    *auth.JWTManager
	Apple  *auth.AppleVerifier
	VPN    vpn.Engine // may be nil if VPN engine is not configured
	Config *config.Config
	Logger *zap.Logger
}

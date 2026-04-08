// Package api provides HTTP routing and handler registration for the Chameleon VPN backend.
//
// This package initializes the Echo HTTP framework and wires together
// mobile, admin, and middleware sub-packages.
package api

import (
	"github.com/labstack/echo/v4"
)

// NewRouter creates and configures a new Echo instance with all route groups.
// This is a placeholder that will be expanded as handlers are implemented.
func NewRouter() *echo.Echo {
	e := echo.New()
	e.HideBanner = true
	e.HidePort = true
	return e
}

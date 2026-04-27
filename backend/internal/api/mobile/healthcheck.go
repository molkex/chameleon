package mobile

import (
	"net/http"
	"strings"

	"github.com/labstack/echo/v4"
)

// healthcheckBodySize is the size of the dummy payload returned by
// /healthcheck. Sized at 32 KB so the response is large enough to actually
// traverse RU LTE bulk-traffic throttles (small probes — gstatic 204,
// captive.apple.com — pass even when bulk traffic is throttled because RKN
// throttling targets sustained flows). The iOS TunnelStallProbe validates
// `data.count >= 16384` and the throttle scenario consistently fails to
// deliver that much within the 8 s probe timeout, surfacing the stall that
// sing-box's HEAD-based urltest probe cannot detect on its own.
const healthcheckBodySize = 32 * 1024

// healthcheckBody is the static plain-text payload served at /healthcheck.
// Static so we don't pay random-generation cost on every probe; iOS only
// validates length, not content, so randomness adds nothing. The repeating
// 'A' pattern is gzip-friendly but Cache-Control: no-store prevents any
// hop from caching it — we want the bytes to actually traverse the path.
var healthcheckBody = strings.Repeat("A", healthcheckBodySize)

// Healthcheck serves a fixed-size body that the iOS TunnelStallProbe uses
// for throughput-based tunnel health detection. No auth, no identifiers,
// no cookies — Apple Review-friendly. iOS calls this every 30 s while the
// tunnel is up; with the 32 KB body that's ~3.8 MB/h overhead, comparable
// to a single static asset on a normal browsing session.
//
// Why this exists vs reusing /health: /health is internal infra probing
// (Docker healthcheck, deploy.sh) returning a tiny `ok`. Adding 32 KB to
// it would inflate every Docker probe. The mobile probe needs its own
// public, no-auth, fixed-size endpoint with no-store caching.
func (h *Handler) Healthcheck(c echo.Context) error {
	c.Response().Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Response().Header().Set("Pragma", "no-cache")
	c.Response().Header().Set("X-Content-Type-Options", "nosniff")
	return c.String(http.StatusOK, healthcheckBody)
}

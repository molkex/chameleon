package mobile

import (
	"fmt"
	"strings"

	"github.com/labstack/echo/v4"

	"github.com/chameleonvpn/chameleon/internal/geoip"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// preferredFirstLeaf is the leaf tag we recommend as the cold-start default
// for every user, everywhere. Justification (build 56, 2026-05-13): field
// logs show DE OVH (162.19.242.30, our de-direct-de outbound) is widely
// DPI-blocked from RU networks — TLS handshake succeeds but real traffic
// dies within seconds with "use of closed network connection". NL Timeweb
// (147.45.252.234, our nl-direct-nl2) has substantially better reachability
// under DPI conditions.
//
// We apply this hint universally rather than gating on user geography:
//   - For DPI-region users (RU/BY/CN/IR/...): NL is the only reliably
//     working option on cold start. Geo-gating would help only those we
//     successfully identify; missing edge cases (Belarus user with English
//     iOS, RU user roaming abroad) would still hit the dead-DE path.
//   - For non-DPI users (US/EU/JP/...): NL works fine. urltest converges
//     to lowest-RTT within ~10s if DE is genuinely faster, so the hint's
//     impact is at worst neutral.
//
// One rule, no special cases — easier to reason about and to test.
//
// Phase 1 of the smart-selection plan (mihomo Smart group cherry-pick)
// will replace this static hint with per-flow adaptive selection that
// works equally well for all users without any geo signals at all.
const preferredFirstLeaf = "nl-direct-nl2"

// resolveOutboundHint returns the recommended_first leaf tag for the
// generator. Returns preferredFirstLeaf if present in availableLeaves,
// otherwise empty string (config drift safeguard — never ship a hint for
// a leaf that doesn't exist).
//
// No geo / locale / IP signals are consulted: we apply the same hint to
// every request. See preferredFirstLeaf doc for the rationale.
func resolveOutboundHint(availableLeaves []string) string {
	for _, leaf := range availableLeaves {
		if leaf == preferredFirstLeaf {
			return preferredFirstLeaf
		}
	}
	return ""
}

// resolveOutboundHintForRequest is the production wrapper: synthesises the
// list of available leaf tags from server/chain entries and delegates to
// resolveOutboundHint. The echo.Context and geoip.Resolver parameters are
// retained for forward compatibility with Phase 1+ where adaptive selection
// will consume request signals — Phase 0 doesn't use them.
func resolveOutboundHintForRequest(_ echo.Context, _ *geoip.Resolver, servers []vpn.ServerEntry, chains []vpn.ChainedEntry) string {
	return resolveOutboundHint(availableLeafTags(servers, chains))
}

// availableLeafTags synthesises the list of leaf tags that clientconfig.go
// will emit for a given set of servers + chains. Must stay in sync with
// the tag formatters in clientconfig.go (we cover direct, h2, tuic, via).
// Tested transitively via TestRecommendedFirst* — if a leaf isn't named the
// same way as clientconfig.go names it, the RecommendedFirst pin will be a
// silent no-op and TestRecommendedFirstReordersAutoLeaves will catch it.
func availableLeafTags(servers []vpn.ServerEntry, chains []vpn.ChainedEntry) []string {
	var tags []string
	for _, srv := range servers {
		if srv.Role != "" && srv.Role != "exit" {
			continue
		}
		// Whitelist-bypass servers feed an isolated group, not the Auto pool,
		// so they're not candidates for the hint.
		if srv.Category != "" && srv.Category != "standard" {
			continue
		}
		cc := strings.ToLower(srv.CountryCode)
		if cc == "" {
			continue
		}
		tags = append(tags, fmt.Sprintf("%s-direct-%s", cc, srv.Key))
		if srv.Hysteria2Port > 0 {
			tags = append(tags, fmt.Sprintf("%s-h2-%s", cc, srv.Key))
		}
		if srv.TUICPort > 0 {
			tags = append(tags, fmt.Sprintf("%s-tuic-%s", cc, srv.Key))
		}
	}
	for _, ch := range chains {
		cc := strings.ToLower(ch.ExitCountryCode)
		if cc == "" {
			continue
		}
		tags = append(tags, fmt.Sprintf("%s-via-%s", cc, ch.RelayKey))
	}
	return tags
}

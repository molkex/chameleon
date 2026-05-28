package vpn

import (
	"hash/fnv"
)

// uTLS fingerprint constants — must be a subset of sing-box 1.13's accepted
// `tls.utls.fingerprint` values. Inventing new values silently breaks the
// client (sing-box rejects the config on parse).
//
// Authoritative list from sing-box 1.13 docs:
//   chrome, firefox, safari, ios, android, edge, 360, qq, random
//
// We deliberately use only "real browser" values (chrome, safari, firefox,
// edge) so each handshake looks like an ordinary desktop browser. ios /
// android / 360 / qq are intentionally excluded — they're rarer in normal
// HTTPS traffic and would actually MAKE our handshakes stand out instead of
// blending them in.
const (
	fpChrome  = "chrome"
	fpSafari  = "safari"
	fpFirefox = "firefox"
	fpEdge    = "edge"
)

// validUTLSFingerprints lists every value selectFingerprint may emit. Tests
// assert every output is in this set so a typo in the bucket table can't
// produce a config that sing-box rejects at parse-time.
var validUTLSFingerprints = map[string]struct{}{
	fpChrome:  {},
	fpSafari:  {},
	fpFirefox: {},
	fpEdge:    {},
}

// selectFingerprint picks a uTLS fingerprint for a user deterministically
// from their stable identity (VPN username). LAUNCH-12.
//
// Strategy: per-user deterministic, weighted by approximate global browser
// market share so the aggregate distribution of our users' ClientHellos
// matches normal background HTTPS traffic. Same user → same fingerprint
// across reconnects, so RKN traffic analysis on a single user sees a stable
// fingerprint (like a real browser) instead of churn (which itself would
// look unusual). To rotate, the user gets a new vpn_username — which we
// don't do today.
//
// Distribution buckets (hash mod 100):
//
//	 0..64  → chrome   (65%)
//	65..84  → safari   (20%)
//	85..94  → firefox  (10%)
//	95..99  → edge     ( 5%)
//
// FNV-1a is used over SHA-256 because this is a load-distribution hash, not
// a security primitive — uniformity is what we need, and FNV is faster and
// allocates nothing. Empty user ID falls back to chrome (the dominant bucket
// — safe default in the unusual case where username is missing).
func selectFingerprint(userID string) string {
	if userID == "" {
		return fpChrome
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(userID))
	switch bucket := h.Sum32() % 100; {
	case bucket < 65:
		return fpChrome
	case bucket < 85:
		return fpSafari
	case bucket < 95:
		return fpFirefox
	default:
		return fpEdge
	}
}

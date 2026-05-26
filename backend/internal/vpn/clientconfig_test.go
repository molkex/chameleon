package vpn

import (
	"encoding/json"
	"slices"
	"testing"
)

// fixture assembles a minimal but realistic EngineConfig + user + server set
// for exercising generateClientConfig. Mirrors the 2026-04-25 production shape
// (DE as standard exit with h2/tuic, NL as same, SPB relays as whitelist_bypass,
// MSK as relay that produces de-via-msk + nl-via-msk chains).
func fixture() (EngineConfig, VPNUser, []ServerEntry, []ChainedEntry) {
	engine := EngineConfig{
		ListenPort: 443,
		Reality: RealityConfig{
			PrivateKey: "KNNykKLLBlq7Jj_wO4UF8OTMJn3whOm4yvqXPgy6b1Y",
			PublicKey:  "YFdu6tIo4524vI0q3eSXLJdySAwBJ2toXbr_NSKYQQs",
			ShortIDs:   []string{""},
			SNI:        "ads.adfox.ru",
		},
		UrltestInterval: "3m",
	}
	user := VPNUser{
		Username: "device_testuser",
		UUID:     "68ba1e44-74ab-425b-b12d-1cfae8348325",
	}
	servers := []ServerEntry{
		{
			Key:              "de",
			Name:             "Germany",
			Host:             "162.19.242.30",
			Port:             443,
			Hysteria2Port:    443,
			TUICPort:         8443,
			RealityPublicKey: "YFdu6tIo4524vI0q3eSXLJdySAwBJ2toXbr_NSKYQQs",
			Role:             "exit",
			CountryCode:      "DE",
			Category:         "standard",
		},
		{
			Key:              "nl2",
			Name:             "Netherlands",
			Host:             "147.45.252.234",
			Port:             443,
			Hysteria2Port:    443,
			TUICPort:         8443,
			RealityPublicKey: "QTC2XRuUaiWO2A1CNbps_9wJp-vaQ2zMYu0VPrS65QM",
			Role:             "exit",
			CountryCode:      "NL",
			Category:         "standard",
		},
		{
			Key:              "relay-de",
			Name:             "SPB-DE",
			Host:             "185.218.0.43",
			Port:             443,
			RealityPublicKey: "YFdu6tIo4524vI0q3eSXLJdySAwBJ2toXbr_NSKYQQs",
			Role:             "exit",
			Category:         "whitelist_bypass",
		},
		{
			Key:              "relay-nl",
			Name:             "SPB-NL",
			Host:             "185.218.0.43",
			Port:             2098,
			RealityPublicKey: "QTC2XRuUaiWO2A1CNbps_9wJp-vaQ2zMYu0VPrS65QM",
			Role:             "exit",
			Category:         "whitelist_bypass",
		},
	}
	chains := []ChainedEntry{
		{
			RelayKey:        "msk",
			RelayHost:       "217.198.5.52",
			RelayListenPort: 2096,
			RelayRealityPub: "I84vSWkXXJGJU3KreRsR1ztmy1u6PyeYXCKMrYXX_zY",
			RelaySNI:        "music.yandex.ru",
			ExitKey:         "de",
			ExitCountryCode: "DE",
		},
		{
			RelayKey:        "msk",
			RelayHost:       "217.198.5.52",
			RelayListenPort: 2097,
			RelayRealityPub: "I84vSWkXXJGJU3KreRsR1ztmy1u6PyeYXCKMrYXX_zY",
			RelaySNI:        "music.yandex.ru",
			ExitKey:         "nl2",
			ExitCountryCode: "NL",
		},
	}
	return engine, user, servers, chains
}

// parseGenerated renders the fixture through generateClientConfig and
// returns the parsed JSON. Test helpers below query this shape.
func parseGenerated(t *testing.T) map[string]any {
	t.Helper()
	engine, user, servers, chains := fixture()
	raw, err := generateClientConfig(engine, user, servers, chains)
	if err != nil {
		t.Fatalf("generateClientConfig: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return out
}

// outboundByTag returns the outbound dict for a given tag, or nil if absent.
func outboundByTag(cfg map[string]any, tag string) map[string]any {
	obs, _ := cfg["outbounds"].([]any)
	for _, o := range obs {
		m, ok := o.(map[string]any)
		if !ok {
			continue
		}
		if m["tag"] == tag {
			return m
		}
	}
	return nil
}

// outboundMembers returns the "outbounds" list of a group by tag.
func outboundMembers(cfg map[string]any, tag string) []string {
	g := outboundByTag(cfg, tag)
	if g == nil {
		return nil
	}
	raw, _ := g["outbounds"].([]any)
	var out []string
	for _, m := range raw {
		if s, ok := m.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// TestProxySelectorContainsAutoAndCountryGroups verifies the Proxy selector
// (build 39+ return-to-urltest): top-level user choice has Auto, per-country
// urltest groups, and every leaf as a direct member. sing-box's `urltest`
// outbound runs end-to-end HTTP HEAD probes through each leaf and pins to
// the lowest-latency working one — it correctly identifies broken paths
// (e.g., RKN-blocked direct on RU LTE: TCP handshake succeeds but Reality
// data dies after) which a TCP-only probe in the iOS host process cannot.
func TestProxySelectorContainsAutoAndCountryGroups(t *testing.T) {
	cfg := parseGenerated(t)
	members := outboundMembers(cfg, "Proxy")
	if len(members) == 0 {
		t.Fatal("Proxy selector has no members")
	}

	// Must contain Auto urltest at index 0 (so the cold-start tunnel without
	// a UI selection lands on it via Proxy.default).
	if len(members) == 0 || members[0] != "Auto" {
		t.Errorf("Proxy first member must be \"Auto\"; got %v", members)
	}

	// Country urltest groups must be members so the user can pick a country.
	for _, group := range []string{"🇩🇪 Германия", "🇳🇱 Нидерланды"} {
		if !slices.Contains(members, group) {
			t.Errorf("Proxy missing country urltest group %q; got %v", group, members)
		}
	}

	// Standard leaves — every protocol × country combination — also listed
	// so power-mode pins (specific leaf override via Clash API) work.
	expectedLeaves := []string{
		"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk",
		"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk",
	}
	for _, leaf := range expectedLeaves {
		if !slices.Contains(members, leaf) {
			t.Errorf("Proxy missing standard leaf %q; got %v", leaf, members)
		}
	}

	// Whitelist-bypass group tag present (for manual override).
	if !slices.Contains(members, "🇷🇺 Россия (обход белых списков)") {
		t.Errorf("Proxy missing whitelist-bypass group tag; got %v", members)
	}

	// Whitelist-bypass leaves also exposed directly for manual pinning.
	for _, leaf := range []string{"ru-spb-de", "ru-spb-nl"} {
		if !slices.Contains(members, leaf) {
			t.Errorf("Proxy missing whitelist-bypass leaf %q; got %v", leaf, members)
		}
	}
}

// TestUrltestGroupsHaveProbeURL asserts that Auto and per-country urltest
// groups have probe URL + interval set. Without these sing-box won't probe
// at all and the group degrades to "always pick the first member" — losing
// the auto-failover behaviour we rely on for RU-LTE-blocked paths.
func TestUrltestGroupsHaveProbeURL(t *testing.T) {
	cfg := parseGenerated(t)
	for _, tag := range []string{"Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"} {
		g := outboundByTag(cfg, tag)
		if g == nil {
			t.Errorf("urltest group %q not emitted", tag)
			continue
		}
		if g["type"] != "urltest" {
			t.Errorf("group %q type=%v, want urltest", tag, g["type"])
		}
		if u, _ := g["url"].(string); u == "" {
			t.Errorf("group %q has empty probe URL", tag)
		}
		if iv, _ := g["interval"].(string); iv == "" {
			t.Errorf("group %q has empty interval", tag)
		}
	}
}

// TestUrltestGroupsRecoverFast asserts the build-39+40 fast-recovery values:
// interval=10s, tolerance=0, AND interrupt_exist_connections=true on the
// LEAF-level urltest groups (Auto + per-country inner _<cc>_leaves).
//
// interval/tolerance: old defaults (5m / 50ms) left users on a dead leaf for
// up to 5 minutes when RKN started throttling DE direct post-handshake on RU
// LTE — sing-box invalidates leaf history on dial error, but the tiny gstatic
// 204 probe re-stamps "OK" histories within seconds, masking the stall.
// Aggressive 10s reprobe + zero tolerance ensures any latency degradation
// triggers an immediate reselect.
//
// interrupt_exist_connections (build 40 fix, 2026-04-26): without this flag,
// when urltest re-elects to a healthy leaf the existing TCP sockets stay
// glued to the old (dead) outbound and time out at the OS TCP layer (75s+).
// User-visible: pages stuck for 1m+, "open new tab" required to recover.
// Field log 2026-04-26 confirmed 1m23s/1m24s/1m41s stuck connections to
// dead 162.19.242.30 after urltest had already switched to de-via-msk.
//
// Build-42 simplification: country urltests are flat single-country groups
// again — all urltests in the config (Auto + per-country) share the same
// fast-recovery parameters.
func TestUrltestGroupsRecoverFast(t *testing.T) {
	cfg := parseGenerated(t)
	for _, tag := range []string{"Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"} {
		g := outboundByTag(cfg, tag)
		if g == nil {
			t.Errorf("urltest group %q not emitted", tag)
			continue
		}
		if iv, _ := g["interval"].(string); iv != "10s" {
			t.Errorf("group %q interval=%q, want %q", tag, iv, "10s")
		}
		// Tolerance is encoded as JSON number; absent (omitempty when 0)
		// or 0 — both are acceptable.
		if tol, ok := g["tolerance"]; ok {
			if n, _ := tol.(float64); n != 0 {
				t.Errorf("group %q tolerance=%v, want 0 (or omitted)", tag, n)
			}
		}
		// Build-40: interrupt_exist_connections MUST be true on urltest
		// groups, else stuck TCP sockets through dead outbound persist 75s+.
		iec, ok := g["interrupt_exist_connections"]
		if !ok {
			t.Errorf("group %q missing interrupt_exist_connections — must be true (build 40)", tag)
			continue
		}
		b, _ := iec.(bool)
		if !b {
			t.Errorf("group %q interrupt_exist_connections=%v, want true (build 40)", tag, b)
		}
	}
}

// TestCountryGroupsAreStrictSingleCountry asserts the build-42 strict-country
// architecture: each user-visible country group ("🇩🇪 Германия" /
// "🇳🇱 Нидерланды") is a flat urltest whose members are ONLY leaves of that
// country. No cross-country fallback — picking a country means "exit via this
// country or fail" (Google-geo correctness over best-effort reachability).
// Cross-country failover is opt-in via the explicit "Auto" urltest.
//
// Regression guard: build-41 wrapped country groups in nested urltests with
// other countries as fallback members; that silently re-routed users (e.g.
// DE→NL when DE-side leaves all timed out under RU LTE OVH-ASN block), and
// Google geo-targeted the exit country instead of the user's pin.
func TestCountryGroupsAreStrictSingleCountry(t *testing.T) {
	cfg := parseGenerated(t)

	// No build-41 inner `_<cc>_leaves` groups must exist anymore — they're
	// the smoking gun for the cross-country wrapper architecture.
	for _, innerTag := range []string{"_de_leaves", "_nl_leaves"} {
		if g := outboundByTag(cfg, innerTag); g != nil {
			t.Errorf("inner urltest %q must NOT be emitted (build-42 strict-country regression)", innerTag)
		}
	}

	// "🇩🇪 Германия": flat urltest, members are DE leaves only.
	deGroup := outboundByTag(cfg, "🇩🇪 Германия")
	if deGroup == nil {
		t.Fatal("country group 🇩🇪 Германия not emitted")
	}
	if deGroup["type"] != "urltest" {
		t.Errorf("🇩🇪 Германия type=%v, want urltest", deGroup["type"])
	}
	deMembers := outboundMembers(cfg, "🇩🇪 Германия")
	for _, want := range []string{"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk"} {
		if !slices.Contains(deMembers, want) {
			t.Errorf("🇩🇪 Германия missing DE leaf %q; got %v", want, deMembers)
		}
	}
	for _, leaf := range deMembers {
		if !startsWith(leaf, "de-") {
			t.Errorf("🇩🇪 Германия contains non-DE leaf %q (cross-country leak)", leaf)
		}
	}

	// "🇳🇱 Нидерланды": flat urltest, members are NL leaves only.
	nlGroup := outboundByTag(cfg, "🇳🇱 Нидерланды")
	if nlGroup == nil {
		t.Fatal("country group 🇳🇱 Нидерланды not emitted")
	}
	if nlGroup["type"] != "urltest" {
		t.Errorf("🇳🇱 Нидерланды type=%v, want urltest", nlGroup["type"])
	}
	nlMembers := outboundMembers(cfg, "🇳🇱 Нидерланды")
	for _, want := range []string{"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk"} {
		if !slices.Contains(nlMembers, want) {
			t.Errorf("🇳🇱 Нидерланды missing NL leaf %q; got %v", want, nlMembers)
		}
	}
	for _, leaf := range nlMembers {
		if !startsWith(leaf, "nl-") {
			t.Errorf("🇳🇱 Нидерланды contains non-NL leaf %q (cross-country leak)", leaf)
		}
	}
}

// TestWhitelistBypassGroupIsSelectorNotUrltest — the isolated group where
// SPB-via-DE and SPB-via-NL live MUST be a selector so the user's explicit
// pick between them is honoured. If this regresses to urltest, urltest's
// RTT probe would silently swap the two on every probe cycle, flipping
// the exit country behind the user's back.
func TestWhitelistBypassGroupIsSelectorNotUrltest(t *testing.T) {
	cfg := parseGenerated(t)
	g := outboundByTag(cfg, "🇷🇺 Россия (обход белых списков)")
	if g == nil {
		t.Fatal("whitelist-bypass group not emitted")
	}
	if g["type"] != "selector" {
		t.Errorf("whitelist-bypass must be selector, got %v", g["type"])
	}
	// Default must be set so a fresh tunnel has a deterministic leg.
	if g["default"] == nil || g["default"] == "" {
		t.Errorf("whitelist-bypass selector missing default")
	}
}

// TestProxySelectorDefault asserts Proxy.Default = "Auto" so a fresh
// tunnel without an explicit UI pick lands on the Auto urltest group, which
// in turn picks the lowest-latency working leaf via end-to-end HTTP HEAD
// probes.
//
// Also asserts Proxy.interrupt_exist_connections=true (build 40 evening fix):
// the urltest auto-recovery chain only works end-to-end when EVERY selector
// in the path TUN→Mode→Proxy→Auto→leaf has interrupt=true. Field log
// 2026-04-26 22:52 confirmed: with Proxy.interrupt=false the inbound from
// upstream Mode selector keeps the user connection alive, glued to the dead
// path even after Auto urltest already re-elected.
func TestProxySelectorDefault(t *testing.T) {
	cfg := parseGenerated(t)
	proxy := outboundByTag(cfg, "Proxy")
	if proxy == nil {
		t.Fatal("Proxy selector not found")
	}
	def, _ := proxy["default"].(string)
	if def != "Auto" {
		t.Errorf("Proxy.default = %q — must be \"Auto\" (build 39+ return-to-urltest)", def)
	}
	if outboundByTag(cfg, def) == nil {
		t.Errorf("Proxy.default = %q does not exist as an outbound", def)
	}
	// Build-40 evening: Proxy MUST also propagate interrupt-on-switch so the
	// urltest re-election kills user-facing connections through the dead leaf.
	iec, ok := proxy["interrupt_exist_connections"]
	if !ok {
		t.Errorf("Proxy missing interrupt_exist_connections — must be true (build 40 chain fix)")
	} else if b, _ := iec.(bool); !b {
		t.Errorf("Proxy.interrupt_exist_connections=%v, want true (build 40 chain fix)", b)
	}
}

// TestUserUUIDWiredIntoEveryLeaf — a regression here means some users get
// a config with a stale or mismatched UUID and all their probes REALITY-
// reject or VLESS-auth-reject on the server side.
func TestUserUUIDWiredIntoEveryLeaf(t *testing.T) {
	cfg := parseGenerated(t)
	_, user, _, _ := fixture()
	obs, _ := cfg["outbounds"].([]any)
	for _, o := range obs {
		m, ok := o.(map[string]any)
		if !ok {
			continue
		}
		tag, _ := m["tag"].(string)
		t_, _ := m["type"].(string)
		switch t_ {
		case "vless", "tuic":
			if m["uuid"] != user.UUID {
				t.Errorf("%s leaf %q has wrong uuid %v", t_, tag, m["uuid"])
			}
		case "hysteria2":
			if m["password"] != user.UUID {
				t.Errorf("hysteria2 leaf %q has wrong password %v", tag, m["password"])
			}
		}
	}
}

// TestHysteria2AndTUICOmittedWhenPortsZero — if a server row has no
// hysteria2_port / tuic_port set, the corresponding leaf must not appear
// in the client config. A stray leaf would send the client's first
// selectOutbound call at a dead port.
func TestHysteria2AndTUICOmittedWhenPortsZero(t *testing.T) {
	engine, user, servers, chains := fixture()
	// Disable h2/tuic on DE only.
	for i := range servers {
		if servers[i].Key == "de" {
			servers[i].Hysteria2Port = 0
			servers[i].TUICPort = 0
		}
	}
	raw, err := generateClientConfig(engine, user, servers, chains)
	if err != nil {
		t.Fatalf("generateClientConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	if outboundByTag(cfg, "de-h2-de") != nil {
		t.Error("de-h2-de emitted despite Hysteria2Port=0")
	}
	if outboundByTag(cfg, "de-tuic-de") != nil {
		t.Error("de-tuic-de emitted despite TUICPort=0")
	}
	// NL still has them.
	if outboundByTag(cfg, "nl-h2-nl2") == nil {
		t.Error("nl-h2-nl2 missing — NL h2 shouldn't have been affected")
	}
}

// TestProxySelectorLeafOrder asserts that standard leaves appear in
// legSortKey order (direct before via before h2 before tuic) within the
// section of Proxy members that lists them as direct children. Auto and
// country group tags appear before the leaf section and are skipped.
func TestProxySelectorLeafOrder(t *testing.T) {
	cfg := parseGenerated(t)
	members := outboundMembers(cfg, "Proxy")
	// Collect only standard leaves: exclude Auto, country group tags
	// (🇩🇪/🇳🇱/🇷🇺-prefixed), and whitelist ru-spb-* leaves.
	var leaves []string
	for _, m := range members {
		if m == "Auto" || startsWith(m, "🇩🇪") || startsWith(m, "🇳🇱") || startsWith(m, "🇷🇺") {
			continue
		}
		if startsWith(m, "ru-spb-") {
			continue
		}
		leaves = append(leaves, m)
	}
	for i := 1; i < len(leaves); i++ {
		if legSortKey(leaves[i]) < legSortKey(leaves[i-1]) {
			t.Errorf("Proxy leaves out of legSortKey order at index %d: %q before %q", i, leaves[i-1], leaves[i])
		}
	}
}

func startsWith(s, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	return s[:len(prefix)] == prefix
}

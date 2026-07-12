package vpn

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

const (
	// categoryWhitelistBypass marks servers that are useful only in narrow
	// "RU whitelists are active" scenarios. Must match db.VPNServer.Category.
	categoryWhitelistBypass = "whitelist_bypass"

	// whitelistBypassGroupTag is the user-facing label of the isolated
	// whitelist-bypass group in the Proxy selector. Localised to Russian
	// since the feature is only useful inside RU.
	whitelistBypassGroupTag = "🇷🇺 Россия (обход белых списков)"
)

// relayOnlyExitKeys lists exit `Key`s whose DIRECT legs are intentionally
// NOT emitted into client configs: from RU their direct :443 path passes
// short urltest probes but hangs on sustained traffic (DNS-over-HTTPS to
// 1.1.1.1 stalls → sites won't load). Such exits are reachable only via
// their relay chain (e.g. pl-via-msk). Incident: 2026-07-12 "Польша не
// грузит сайты" — urltest kept electing pl-direct-waw1 over the working
// relay. Remove a key here only if that exit's direct path becomes usable
// from RU again.
var relayOnlyExitKeys = map[string]bool{
	"waw1": true,
}

// legSortKey returns a comparable string that orders leaf tags within a
// country urltest: direct first, then chain (via-*), then h2/tuic. Keeps
// log ordering stable + predictable; urltest itself picks lowest RTT.
func legSortKey(tag string) string {
	switch {
	case strings.Contains(tag, "-direct-"):
		return "0-" + tag
	case strings.Contains(tag, "-via-"):
		return "1-" + tag
	case strings.Contains(tag, "-h2-"):
		return "2-" + tag
	case strings.Contains(tag, "-tuic-"):
		return "3-" + tag
	default:
		return "9-" + tag
	}
}

// countryCodeFromTag extracts the lowercase country code prefix from a leaf
// tag. Tag shape is "{cc}-{kind}-{key}" — first dash-separated segment is
// the country code. Returns empty string for malformed tags.
func countryCodeFromTag(tag string) string {
	if idx := strings.Index(tag, "-"); idx > 0 {
		return strings.ToLower(tag[:idx])
	}
	return ""
}

// countryDisplay maps an ISO country code to the user-facing label shown in
// the Proxy selector's children. Must stay in sync with iOS
// `PathPicker.countryCode(forSelectedTag:)` which does the inverse mapping.
func countryDisplay(cc string) string {
	switch strings.ToLower(cc) {
	case "de":
		return "🇩🇪 Германия"
	case "nl":
		return "🇳🇱 Нидерланды"
	case "fr":
		return "🇫🇷 Франция"
	case "us":
		return "🇺🇸 США"
	case "ru":
		return "🇷🇺 Россия"
	case "pl":
		return "🇵🇱 Польша"
	default:
		return ""
	}
}

// generateClientConfig creates a sing-box client config JSON for iOS/macOS.
//
// Outbound topology (build 39+): all leaf selection is done by the iOS main
// app's PathPicker (NWConnection probes in host process). The extension
// receives ONE leaf pre-selected, avoiding urltest Go-heap spikes (>44 MB)
// that risked the 50 MB NE jetsam cap on cold-start.
//
//   Proxy (selector, default=<first NL/standard leaf>)
//     ├─ de-direct-de, de-h2-de, de-tuic-de, de-via-msk, …  (standard leaves)
//     ├─ nl-direct-nl2, nl-h2-nl2, …
//     ├─ 🇷🇺 Россия (обход)   (selector, whitelist_bypass, isolated)
//     └─ ru-spb-de, ru-spb-nl, …   (whitelist leaves, directly selectable)
//   Mode selectors              — RU Traffic, Blocked Traffic, Default Route
//   Leaf outbounds              — individual protocol outbounds
//   System                      — direct, block
//
// Leaf tag format: "{cc}-{kind}-{key}" (lowercase, dash-joined).
//   kind = direct|h2|tuic|via
//   The iOS PathPicker derives country from the tag prefix (e.g. "nl-" → NL).
//
// Whitelist-bypass group: servers with Category='whitelist_bypass' are
// projected into a single dedicated selector "🇷🇺 Россия (обход белых списков)"
// (constant defined below). They're excluded from standard leaves — whitelist
// bypass is a narrow manual-only option, never an auto pick.
func generateClientConfig(engineCfg EngineConfig, user VPNUser, servers []ServerEntry, chains []ChainedEntry) ([]byte, error) {
	// Split servers by role + category:
	//   standardExits    — role='exit', category='standard'          → country groups + Auto
	//   whitelistExits   — role='exit', category='whitelist_bypass'  → isolated group
	// Relay rows (role='relay') never produce direct leaves — they're only
	// consumed as metadata hosts by ChainedEntry records.
	var standardExits, whitelistExits []ServerEntry
	for _, s := range servers {
		if s.Role != "" && s.Role != "exit" {
			continue
		}
		switch s.Category {
		case categoryWhitelistBypass:
			whitelistExits = append(whitelistExits, s)
		default:
			standardExits = append(standardExits, s)
		}
	}
	if len(standardExits) == 0 && len(chains) == 0 && len(whitelistExits) == 0 {
		return nil, fmt.Errorf("generate client config: no exit servers or relay chains provided")
	}

	defaultSNI := engineCfg.Reality.SNI
	if defaultSNI == "" {
		defaultSNI = "ads.adfox.ru"
	}
	defaultShortID := user.ShortID
	if defaultShortID == "" && len(engineCfg.Reality.ShortIDs) > 0 {
		defaultShortID = engineCfg.Reality.ShortIDs[0]
	}

	// LAUNCH-12: per-user deterministic uTLS fingerprint rotation.
	// Same user always gets the same fingerprint (reconnect-stable, debuggable),
	// but across the user base the distribution mimics real browser market
	// share — so our aggregate ClientHello traffic blends into normal HTTPS
	// instead of all looking like one fingerprint to RKN DPI. Hash input is
	// the VPN username (stable per user). See clientconfig_fingerprint.go.
	utlsFP := selectFingerprint(user.Username)

	// Accumulators — every leaf outbound is registered here once, regardless
	// of which group it lands in.
	var allLeafOutbounds []clientOutbound
	var autoLegs []string      // standard leaves — go directly into Proxy selector
	var whitelistLegs []string // whitelist-bypass leaves — feed the isolated selector group

	makeVless := func(tag, server string, port int, pub, sni, shortID string) clientOutbound {
		return clientOutbound{
			Type:       "vless",
			Tag:        tag,
			Server:     server,
			ServerPort: port,
			UUID:       user.UUID,
			Flow:       "xtls-rprx-vision",
			TLS: &clientTLS{
				Enabled:    true,
				ServerName: sni,
				UTLS:       &clientUTLS{Enabled: true, Fingerprint: utlsFP},
				Reality:    &clientReality{Enabled: true, PublicKey: pub, ShortID: shortID},
			},
			PacketEncoding: "xudp",
		}
	}

	// --- Standard direct exits (VLESS Reality + optional H2/TUIC) ---
	for _, srv := range standardExits {
		cc := strings.ToUpper(srv.CountryCode)
		if cc == "" {
			// A standard exit without country_code can't be rendered under
			// a country group. Skip loudly — admin must fix the DB row.
			continue
		}

		// relayOnlyExitKeys: this exit's direct :443 leg (and any h2/tuic
		// legs) must never be generated — see var doc above. The relay-chain
		// loop below is untouched, so e.g. pl-via-msk still gets emitted.
		if relayOnlyExitKeys[srv.Key] {
			continue
		}

		sni := srv.SNI
		if sni == "" {
			sni = defaultSNI
		}
		pub := srv.RealityPublicKey
		if pub == "" {
			pub = engineCfg.Reality.PublicKey
		}

		vlessTag := fmt.Sprintf("%s-direct-%s", strings.ToLower(cc), srv.Key)
		allLeafOutbounds = append(allLeafOutbounds, makeVless(vlessTag, srv.Host, srv.Port, pub, sni, defaultShortID))
		autoLegs = append(autoLegs, vlessTag)

		// SEC-03: the Hysteria2/TUIC UDP exits use a self-signed TLS cert. We
		// PIN it (tls.certificate) so the leg is MITM-resistant — never
		// insecure:true. Without a pinned cert (engineCfg.UDPCertPEM empty) we
		// cannot verify the exit, so we SKIP these legs rather than disabling
		// verification. On prod the UDP ports are currently unset, so this is a
		// no-op; it closes the footgun where enabling a port would silently
		// ship insecure TLS.
		udpPinned := engineCfg.UDPCertPEM != ""
		if srv.Hysteria2Port > 0 && udpPinned {
			h2Tag := fmt.Sprintf("%s-h2-%s", strings.ToLower(cc), srv.Key)
			// Salamander obfs must mirror the server inbound (same PSK), else
			// the tunnel handshakes but carries no traffic. Omitted when the
			// server isn't running obfs (empty PSK).
			var h2obfs *clientObfs
			if engineCfg.Hysteria2ObfsPassword != "" {
				h2obfs = &clientObfs{Type: "salamander", Password: engineCfg.Hysteria2ObfsPassword}
			}
			allLeafOutbounds = append(allLeafOutbounds, clientOutbound{
				Type:       "hysteria2",
				Tag:        h2Tag,
				Server:     srv.Host,
				ServerPort: srv.Hysteria2Port,
				Password:   user.UUID,
				Obfs:       h2obfs,
				TLS: &clientTLS{
					Enabled:     true,
					ServerName:  sni,
					Certificate: []string{engineCfg.UDPCertPEM},
				},
			})
			autoLegs = append(autoLegs, h2Tag)
		}
		if srv.TUICPort > 0 && udpPinned {
			tuicTag := fmt.Sprintf("%s-tuic-%s", strings.ToLower(cc), srv.Key)
			allLeafOutbounds = append(allLeafOutbounds, clientOutbound{
				Type:              "tuic",
				Tag:               tuicTag,
				Server:            srv.Host,
				ServerPort:        srv.TUICPort,
				UUID:              user.UUID,
				Password:          user.UUID,
				CongestionControl: "bbr",
				TLS: &clientTLS{
					Enabled:     true,
					ServerName:  sni,
					Certificate: []string{engineCfg.UDPCertPEM},
				},
			})
			autoLegs = append(autoLegs, tuicTag)
		}
	}

	// --- Relay chain outbounds (RU-entry → WG → foreign exit) ---
	// Always categorised as 'standard' — chains exit via standard countries.
	for _, ch := range chains {
		cc := strings.ToUpper(ch.ExitCountryCode)
		if cc == "" {
			continue
		}

		sni := ch.RelaySNI
		if sni == "" {
			sni = defaultSNI
		}
		shortID := ch.RelayShortID
		if shortID == "" {
			shortID = defaultShortID
		}

		chainTag := fmt.Sprintf("%s-via-%s", strings.ToLower(cc), ch.RelayKey)
		allLeafOutbounds = append(allLeafOutbounds, makeVless(chainTag, ch.RelayHost, ch.RelayListenPort, ch.RelayRealityPub, sni, shortID))
		autoLegs = append(autoLegs, chainTag)
	}

	// --- Whitelist-bypass exits (legacy SPB; isolated group) ---
	// Tags prefixed with "ru-spb-" since entry is always RU for these.
	for _, srv := range whitelistExits {
		sni := srv.SNI
		if sni == "" {
			sni = defaultSNI
		}
		pub := srv.RealityPublicKey
		if pub == "" {
			pub = engineCfg.Reality.PublicKey
		}
		// Normalize legacy "relay-de" / "relay-nl" keys to "spb-de" / "spb-nl"
		// for tag cleanliness. Semantics is: "RU SPB entry → <key> exit".
		suffix := strings.TrimPrefix(srv.Key, "relay-")
		tag := fmt.Sprintf("ru-spb-%s", suffix)
		allLeafOutbounds = append(allLeafOutbounds, makeVless(tag, srv.Host, srv.Port, pub, sni, defaultShortID))
		whitelistLegs = append(whitelistLegs, tag)
	}

	if len(autoLegs) == 0 && len(whitelistLegs) == 0 {
		return nil, fmt.Errorf("generate client config: no usable legs (standard=%d chains=%d whitelist=%d)", len(standardExits), len(chains), len(whitelistExits))
	}

	// --- Whitelist-bypass isolated group (if any rows exist) ---
	// Rendered as a `selector`, NOT `urltest`: the two SPB legs exit in
	// different countries (SPB→DE vs SPB→NL), so auto-pickoff by RTT would
	// silently override the user's deliberate country choice. `selector`
	// honours the pin set via Clash API. Whitelist-bypass is manual-only
	// by design — never part of standard leaves.
	var whitelistGroupTag string
	var whitelistGroupOutbound *clientOutbound
	if len(whitelistLegs) > 0 {
		whitelistGroupTag = whitelistBypassGroupTag
		sort.Strings(whitelistLegs)
		ob := clientOutbound{
			Type:                      "selector",
			Tag:                       whitelistGroupTag,
			Outbounds:                 whitelistLegs,
			Default:                   whitelistLegs[0],
			InterruptExistConnections: boolPtr(false),
		}
		whitelistGroupOutbound = &ob
	}

	// --- urltest groups: Auto (all leaves) + per-country ---
	// Build-39 return-to-urltest: sing-box's `urltest` outbound probes each
	// member end-to-end via HTTP HEAD periodically and pins to the lowest-
	// latency working leaf. Replaces build-38's iOS-side TCP probe + custom
	// fallback watchdog — TCP probe is a false-positive on RKN-blocked direct
	// paths (handshake succeeds, Reality data dies after), and a custom
	// watchdog reading global bytes-flow counters can't distinguish Proxy
	// stalls from native LTE direct traffic. urltest catches both because it
	// actually completes a request through the leaf.
	sortedLeaves := append([]string(nil), autoLegs...)
	sort.SliceStable(sortedLeaves, func(i, j int) bool {
		return legSortKey(sortedLeaves[i]) < legSortKey(sortedLeaves[j])
	})

	// Probe target: small, globally reliable, deterministic 204 response.
	// Same target sing-box's own examples and most popular GUIs use.
	const urltestProbeURL = "https://www.gstatic.com/generate_204"
	// Build-39 (2026-04-26): drop interval 5m → 10s, tolerance 50 → 0.
	// 5m left users on a dead leaf for up to 5 minutes when RKN started
	// throttling direct-DE post-handshake on RU LTE — sing-box's
	// `history.DeleteURLTestHistory` invalidates on dial error, but the next
	// CheckOutbounds re-stamps a "OK" history because the gstatic 204 probe
	// (~50 byte response) passes even when bulk traffic to the same IP times
	// out. With 10s interval we re-test every 10s instead of every 5m, and
	// tolerance:0 means any latency improvement triggers reselect (pseudo-
	// load-balance, since sing-box has no native `load_balance` group).
	// Probe overhead: 4 leaves × ~50ms / 10s = ~2% per-tunnel.
	//
	// Build-40 (2026-04-26): interrupt_exist_connections=true on urltest groups.
	// Without this, when urltest re-elects to a healthy leaf, existing TCP
	// sockets stay glued to the old (dead) outbound and time out at the OS
	// TCP layer (75s+). User-visible: pages stuck for 1m+, "open new tab"
	// to recover. Field log 2026-04-26 confirmed: 1m23s/1m24s/1m41s stuck
	// connections to dead 162.19.242.30 after urltest had already switched
	// to de-via-msk. With interrupt=true, sing-box closes inbound conns
	// routed through old outbound on switch — Safari pipelines auto-recreate.
	const urltestInterval = "10s"
	const urltestTolerance = 0

	autoUrltest := clientOutbound{
		Type:                      "urltest",
		Tag:                       "Auto",
		Outbounds:                 sortedLeaves,
		URL:                       urltestProbeURL,
		Interval:                  urltestInterval,
		Tolerance:                 urltestTolerance,
		InterruptExistConnections: boolPtr(true),
	}

	// Country urltest groups. Tag format is `{cc}-...`, so we group by the
	// country-code prefix. Country labels (display names with emoji) are
	// produced by `countryDisplay`. We always emit a group per country that
	// has at least 1 leaf, even if it's a single leaf — sing-box's urltest
	// degrades gracefully to "always pick that one" with 1 member.
	leavesByCountry := map[string][]string{}
	for _, leaf := range sortedLeaves {
		cc := countryCodeFromTag(leaf)
		if cc == "" {
			continue
		}
		leavesByCountry[cc] = append(leavesByCountry[cc], leaf)
	}
	// Stable iteration order so JSON output is reproducible.
	var countryCodes []string
	for cc := range leavesByCountry {
		countryCodes = append(countryCodes, cc)
	}
	sort.Strings(countryCodes)

	// Build-42 (2026-05-23): country groups are strict single-country urltests.
	// Reverts build-41's nested cross-country fallback because it silently
	// re-routed the user's deliberate country pick — when ALL DE leaves
	// returned `unavailable` (RU LTE OVH-ASN block), the outer urltest jumped
	// to NL leaves while the UI still showed "🇩🇪 Германия", and Google
	// geo-targeted the user as NL. Strict semantics: picking a country means
	// "exit via this country or fail" — cross-country failover is opt-in via
	// the explicit "Auto" group.
	var countryGroups []clientOutbound
	var countryGroupTags []string
	for _, cc := range countryCodes {
		tag := countryDisplay(cc)
		if tag == "" {
			tag = strings.ToUpper(cc)
		}
		countryGroups = append(countryGroups, clientOutbound{
			Type:                      "urltest",
			Tag:                       tag,
			Outbounds:                 leavesByCountry[cc],
			URL:                       urltestProbeURL,
			Interval:                  urltestInterval,
			Tolerance:                 urltestTolerance,
			InterruptExistConnections: boolPtr(true),
		})
		countryGroupTags = append(countryGroupTags, tag)
	}

	// --- "Proxy" selector — top-level user choice ---
	// Members order: [Auto, country urltests..., individual leaves..., 🇷🇺
	// Россия (обход), whitelist leaves]. Default = "Auto" so a fresh tunnel
	// without a UI selection lands on the urltest's pick automatically.
	// Specific leaves are also listed so the user can pin a single protocol
	// in power-mode via Clash API.
	proxyMembers := []string{"Auto"}
	proxyMembers = append(proxyMembers, countryGroupTags...)
	proxyMembers = append(proxyMembers, sortedLeaves...)
	if whitelistGroupTag != "" {
		proxyMembers = append(proxyMembers, whitelistGroupTag)
	}
	proxyMembers = append(proxyMembers, whitelistLegs...)
	// Build-40 (2026-04-26 evening): InterruptExistConnections=true on Proxy too.
	// Previously was `false` to avoid killing in-flight connections on manual
	// server-pin via Clash API. But that broke the urltest auto-recovery chain:
	// when Auto urltest re-elects to a healthy leaf it closes its own inbound
	// (Proxy→Auto), but with Proxy.interrupt=false the upstream chain
	// (TUN→BlockedTraffic→Proxy) keeps the user-visible connection alive, glued
	// to the now-dead path via the OLD Proxy→Auto leg. Field log 2026-04-26
	// 22:52: connections to 162.19.242.30 still timing out 1m54s after urltest
	// already switched to de-via-msk. Trade-off: rare manual-pin via power-mode
	// also closes connections (one TLS handshake reconnect — mild UX hiccup).
	// Auto-recovery for the 99% case wins.
	proxyOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "Proxy",
		Outbounds:                 proxyMembers,
		Default:                   "Auto",
		InterruptExistConnections: boolPtr(true),
	}

	// --- Mode selectors (unchanged semantics from pre-relay architecture) ---
	// Three-way routing mode is implemented via three selectors. The iOS app
	// flips all three together via Clash API to switch modes without
	// reconnecting. See ExtensionProvider.applyRoutingMode().
	//
	//   Mode       | RU Traffic | Blocked Traffic | Default Route
	//   smart      | direct     | Proxy           | direct         ← default
	//   ru-direct  | direct     | Proxy           | Proxy
	//   full-vpn   | Proxy      | Proxy           | Proxy
	ruTrafficOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "RU Traffic",
		Outbounds:                 []string{"direct", "Proxy"},
		Default:                   "direct",
		InterruptExistConnections: boolPtr(true),
	}
	blockedTrafficOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "Blocked Traffic",
		Outbounds:                 []string{"Proxy", "direct"},
		Default:                   "Proxy",
		InterruptExistConnections: boolPtr(true),
	}
	defaultRouteOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "Default Route",
		Outbounds:                 []string{"direct", "Proxy"},
		Default:                   "direct",
		InterruptExistConnections: boolPtr(true),
	}

	// System outbounds.
	directOutbound := clientOutbound{Type: "direct", Tag: "direct"}
	blockOutbound := clientOutbound{Type: "block", Tag: "block"}

	// Outbound order matters: selectors reference downstream tags, and
	// downstream tags must be declared after their referencing selector in
	// sing-box 1.13. Topology (build-41):
	//   Proxy (selector)            → references Auto, country urltests, leaves
	//   Mode selectors              → reference Proxy / direct
	//   Auto urltest                → all leaves cross-country (opt-in fallback)
	//   Country urltests            → strict single-country leaves only (build-42)
	//   Whitelist group (selector)  → references whitelist leaves
	//   All leaves                  → individual outbounds
	//   System                      → direct, block
	allOutbounds := []clientOutbound{proxyOutbound}
	allOutbounds = append(allOutbounds, ruTrafficOutbound, blockedTrafficOutbound, defaultRouteOutbound)
	allOutbounds = append(allOutbounds, autoUrltest)
	allOutbounds = append(allOutbounds, countryGroups...)
	if whitelistGroupOutbound != nil {
		allOutbounds = append(allOutbounds, *whitelistGroupOutbound)
	}
	allOutbounds = append(allOutbounds, allLeafOutbounds...)
	allOutbounds = append(allOutbounds, directOutbound, blockOutbound)

	// --- Resolve DNS/MTU defaults (unchanged from pre-relay) ---
	clientMTU := engineCfg.ClientMTU
	if clientMTU == 0 {
		clientMTU = 1400
	}
	dnsRemote := engineCfg.DNSRemote
	if dnsRemote == "" {
		dnsRemote = "https://1.1.1.1/dns-query"
	}
	dnsDirect := engineCfg.DNSDirect
	if dnsDirect == "" {
		// Yandex DNS — resolves .ru zones faster and more reliably than Google.
		dnsDirect = "https://77.88.8.8/dns-query"
	}
	_ = dnsRemote // DNS server list below uses plain IPs, kept in EngineConfig for future DoH migration.
	_ = dnsDirect

	config := clientConfig{
		Log: clientLog{Level: "info"},
		DNS: clientDNSConfig{
			Servers: []clientDNSServer{
				// detour:"Proxy" — resolve non-RU domains THROUGH the exit so DNS
				// geolocates to the exit country (was leaking RU: queries went out
				// the local/Yandex path → Google/Gemini/OpenAI saw a Russian
				// resolver even on an NL exit IP). .ru/banks still use dns-direct
				// (Yandex, no detour) via the DNS rules below.
				{Tag: "dns-remote", Type: "https", Server: "1.1.1.1", Detour: "Proxy"},
				{Tag: "dns-direct", Type: "https", Server: "77.88.8.8"},
				// dns-fakeip removed 2026-06-21 (PRODUCT-MATURITY-LOOP): dead server —
				// no DNS rule or route strategy referenced it, but sing-box still
				// allocated its 198.18.0.0/15 fakeip bookkeeping in the memory-tight NE.
				// Real device logs show the fork oom-killer resetting at 40 MiB; dropping
				// unused allocations is one safe reduction.
			},
			Rules: []clientDNSRule{
				{DomainSuffix: ruAlwaysDirectDomains, Server: "dns-direct"},
				{DomainSuffix: []string{".ru"}, Server: "dns-direct"},
			},
			IndependentCache: true,
		},
		Inbounds: []clientInbound{{
			Type: "tun", Tag: "tun-in",
			Address:   []string{"172.19.0.1/30"},
			MTU:       clientMTU,
			AutoRoute: true,
			Stack:     "system",
		}},
		Outbounds: allOutbounds,
		Route: clientRoute{
			Final: "Default Route",
			RuleSet: []clientRuleSet{
				{
					Tag:            "geoip-ru",
					Type:           "remote",
					Format:         "binary",
					URL:            "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
					DownloadDetour: "direct",
					UpdateInterval: "168h",
				},
				{
					Tag:            "refilter",
					Type:           "remote",
					Format:         "binary",
					URL:            "https://raw.githubusercontent.com/teidesu/rkn-singbox/ruleset/rkn-ruleset.srs",
					DownloadDetour: "direct",
					UpdateInterval: "168h",
				},
			},
			Rules: []clientRouteRule{
				{Action: "sniff"},
				{Protocol: "dns", Action: "hijack-dns"},
				{ClashMode: "Direct", Outbound: "direct"},
				{Network: "udp", Port: 443, Action: "reject", NoDrop: boolPtr(true)},
				{IPIsPrivate: boolPtr(true), Outbound: "direct"},
				{DomainSuffix: ruAlwaysDirectDomains, Outbound: "direct"},
				{RuleSet: "refilter", Outbound: "Blocked Traffic"},
				{DomainSuffix: []string{".ru"}, Outbound: "RU Traffic"},
				{RuleSet: "geoip-ru", Outbound: "RU Traffic"},
			},
			// Default resolution for proxied connections now goes through the exit
			// (dns-remote, detour:Proxy) instead of the Russian resolver, so the
			// connection's domain→IP step doesn't leak RU. .ru / banks are still
			// pinned to dns-direct by the DNS rules above (rule wins over default).
			DefaultDomainResolver: &clientDomainResolver{
				Server:   "dns-remote",
				Strategy: "ipv4_only",
			},
		},
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("generate client config: marshal: %w", err)
	}
	return data, nil
}

func boolPtr(v bool) *bool { return &v }

// ---------------------------------------------------------------------------
// Client config JSON structures
// ---------------------------------------------------------------------------

type clientConfig struct {
	Log           clientLog           `json:"log"`
	DNS           clientDNSConfig     `json:"dns"`
	Inbounds      []clientInbound     `json:"inbounds"`
	Outbounds     []clientOutbound    `json:"outbounds"`
	Route         clientRoute         `json:"route"`
	Experimental  *clientExperimental `json:"experimental,omitempty"`
	ConfigVersion int64               `json:"config_version,omitempty"`
	// Marker is a human-readable identifier of THIS revision of the
	// config-generation code (set from configBuildMarker constant). iOS
	// surfaces it as `cfg:<marker>` in the debug footer. Underscore prefix
	// keeps it a "private" extension that sing-box itself ignores
	// gracefully (unknown JSON keys are skipped at parse).
	Marker string `json:"_marker,omitempty"`
}

type clientLog struct {
	Level string `json:"level"`
}

type clientDNSConfig struct {
	Servers          []clientDNSServer `json:"servers"`
	Rules            []clientDNSRule   `json:"rules,omitempty"`
	FakeIP           *clientFakeIP     `json:"fakeip,omitempty"`
	IndependentCache bool              `json:"independent_cache,omitempty"`
}

type clientDNSServer struct {
	Tag             string `json:"tag"`
	Type            string `json:"type"`
	Server          string `json:"server,omitempty"`
	ServerName      string `json:"server_name,omitempty"`
	AddressResolver string `json:"address_resolver,omitempty"`
	Strategy        string `json:"strategy,omitempty"`
	Detour          string `json:"detour,omitempty"`
	Inet4Range      string `json:"inet4_range,omitempty"`
}

type clientDNSRule struct {
	ClashMode    string   `json:"clash_mode,omitempty"`
	QueryType    []string `json:"query_type,omitempty"`
	Outbound     []string `json:"outbound,omitempty"`
	DomainSuffix []string `json:"domain_suffix,omitempty"`
	RuleSet      string   `json:"rule_set,omitempty"`
	Server       string   `json:"server"`
}

type clientFakeIP struct {
	Enabled    bool   `json:"enabled"`
	Inet4Range string `json:"inet4_range"`
}

type clientInbound struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Address   []string `json:"address,omitempty"`
	MTU       int      `json:"mtu,omitempty"`
	AutoRoute bool     `json:"auto_route,omitempty"`
	Stack     string   `json:"stack,omitempty"`
}

type clientOutbound struct {
	Type                      string           `json:"type"`
	Tag                       string           `json:"tag"`
	Server                    string           `json:"server,omitempty"`
	ServerPort                int              `json:"server_port,omitempty"`
	UUID                      string           `json:"uuid,omitempty"`
	Password                  string           `json:"password,omitempty"`
	Flow                      string           `json:"flow,omitempty"`
	Obfs                      *clientObfs      `json:"obfs,omitempty"`
	TLS                       *clientTLS       `json:"tls,omitempty"`
	Multiplex                 *clientMultiplex `json:"multiplex,omitempty"`
	PacketEncoding            string           `json:"packet_encoding,omitempty"`
	CongestionControl         string           `json:"congestion_control,omitempty"`
	Outbounds                 []string         `json:"outbounds,omitempty"`
	URL                       string           `json:"url,omitempty"`
	Interval                  string           `json:"interval,omitempty"`
	Tolerance                 int              `json:"tolerance,omitempty"`
	Default                   string           `json:"default,omitempty"`
	InterruptExistConnections *bool            `json:"interrupt_exist_connections,omitempty"`
}

type clientTLS struct {
	Enabled    bool           `json:"enabled"`
	ServerName string         `json:"server_name"`
	Insecure   *bool          `json:"insecure,omitempty"`
	// Certificate pins one or more trusted server certs (PEM). SEC-03: used to
	// verify the Hysteria2/TUIC self-signed UDP cert instead of insecure:true.
	Certificate []string       `json:"certificate,omitempty"`
	UTLS        *clientUTLS    `json:"utls,omitempty"`
	Reality     *clientReality `json:"reality,omitempty"`
}

// clientObfs mirrors the server's Hysteria2 Salamander obfs block. Type is
// "salamander"; Password is the shared PSK and MUST match the server inbound.
type clientObfs struct {
	Type     string `json:"type"`
	Password string `json:"password"`
}

type clientUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint"`
}

type clientReality struct {
	Enabled   bool   `json:"enabled"`
	PublicKey string `json:"public_key"`
	ShortID   string `json:"short_id"`
}

type clientMultiplex struct {
	Enabled    bool   `json:"enabled"`
	Protocol   string `json:"protocol"`
	MaxStreams int    `json:"max_streams"`
	Padding    bool   `json:"padding"`
}

type clientRoute struct {
	RuleSet               []clientRuleSet       `json:"rule_set,omitempty"`
	Rules                 []clientRouteRule     `json:"rules"`
	Final                 string                `json:"final,omitempty"`
	AutoDetectInterface   bool                  `json:"auto_detect_interface,omitempty"`
	DefaultDomainResolver *clientDomainResolver `json:"default_domain_resolver,omitempty"`
}

type clientRuleSet struct {
	Tag            string `json:"tag"`
	Type           string `json:"type"`
	Format         string `json:"format,omitempty"`
	URL            string `json:"url,omitempty"`
	DownloadDetour string `json:"download_detour,omitempty"`
	UpdateInterval string `json:"update_interval,omitempty"`
}

type clientRouteRule struct {
	ClashMode    string   `json:"clash_mode,omitempty"`
	Protocol     string   `json:"protocol,omitempty"`
	Network      string   `json:"network,omitempty"`
	Port         int      `json:"port,omitempty"`
	IPIsPrivate  *bool    `json:"ip_is_private,omitempty"`
	DomainSuffix []string `json:"domain_suffix,omitempty"`
	RuleSet      string   `json:"rule_set,omitempty"`
	Action       string   `json:"action,omitempty"`
	Outbound     string   `json:"outbound,omitempty"`
	NoDrop       *bool    `json:"no_drop,omitempty"`
}

type clientDomainResolver struct {
	Server   string `json:"server"`
	Strategy string `json:"strategy"`
}

type clientExperimental struct {
	ClashAPI *clientClashAPI `json:"clash_api,omitempty"`
}

type clientClashAPI struct {
	ExternalController string `json:"external_controller"`
}

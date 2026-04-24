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

// countryDisplay returns the user-visible label for a country urltest,
// derived purely from the ISO-3166-1 alpha-2 code — NOT from any server
// row's Name field, so e.g. a DB row named "Netherlands 2" doesn't bleed
// into the picker UI. Unknown codes fall through to the code itself.
//
// Labels are Russian to match the primary user audience (iOS app runs in
// RU locale for the overwhelming majority of users). iOS can override
// purely on the client via its own localization if needed.
func countryDisplay(cc string) string {
	switch strings.ToUpper(cc) {
	case "NL":
		return "🇳🇱 Нидерланды"
	case "DE":
		return "🇩🇪 Германия"
	case "RU":
		return "🇷🇺 Россия"
	default:
		return cc
	}
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

// generateClientConfig creates a sing-box client config JSON for iOS/macOS.
//
// Outbound topology (2026-04-24, migrations 010+011):
//
//   Proxy (selector, default=Auto)
//     ├─ Auto
//     ├─ 🇳🇱 Нидерланды       (urltest, standard, country)
//     ├─ 🇩🇪 Германия          (urltest, standard, country)
//     └─ 🇷🇺 Россия (обход)   (urltest, whitelist_bypass, isolated)
//   Auto (urltest)              — every standard leaf (no whitelist_bypass)
//   Mode selectors              — RU Traffic, Blocked Traffic, Default Route
//   Leaf outbounds              — de-direct, de-h2, de-tuic, de-via-msk,
//                                 nl-direct-nl2, nl-via-msk, ru-spb-de, ru-spb-nl, …
//   System                      — direct, block
//
// Leaf tag format: "{cc}-{kind}-{key}" (lowercase, dash-joined).
//   kind = direct|h2|tuic|via
//   The iOS picker uses the owning urltest's tag for display; leaf tags are
//   opaque IDs — keeping them short and structured simplifies sing-box logs.
//
// Country urltest tag: "{flagEmoji} {localizedName}" derived from CountryCode
// via countryDisplay() below. Deriving from CC (not from first server row's
// Name) means rows like "Netherlands 2" don't bleed into the picker label.
//
// Whitelist-bypass group: servers with Category='whitelist_bypass' are
// projected into a single dedicated urltest "🇷🇺 Россия (обход белых списков)"
// (constant defined below). They're excluded from per-country groups AND
// from the global Auto urltest — whitelist bypass is a narrow manual-only
// option, never an auto pick.
//
// See memory/project_relay_architecture_poc.md for design history.
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

	// Accumulators — every leaf outbound is registered here once, regardless
	// of which group it lands in.
	var allLeafOutbounds []clientOutbound
	tagsByCountry := map[string][]string{}
	var autoLegs []string     // standard leaves only — feeds the global Auto urltest
	var whitelistLegs []string // whitelist-bypass leaves — feed the isolated group

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
				UTLS:       &clientUTLS{Enabled: true, Fingerprint: "chrome"},
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
		tagsByCountry[cc] = append(tagsByCountry[cc], vlessTag)
		autoLegs = append(autoLegs, vlessTag)

		if srv.Hysteria2Port > 0 {
			h2Tag := fmt.Sprintf("%s-h2-%s", strings.ToLower(cc), srv.Key)
			allLeafOutbounds = append(allLeafOutbounds, clientOutbound{
				Type:       "hysteria2",
				Tag:        h2Tag,
				Server:     srv.Host,
				ServerPort: srv.Hysteria2Port,
				Password:   user.UUID,
				TLS: &clientTLS{
					Enabled:    true,
					ServerName: sni,
					Insecure:   boolPtr(true),
				},
			})
			tagsByCountry[cc] = append(tagsByCountry[cc], h2Tag)
			autoLegs = append(autoLegs, h2Tag)
		}
		if srv.TUICPort > 0 {
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
					Enabled:    true,
					ServerName: sni,
					Insecure:   boolPtr(true),
				},
			})
			tagsByCountry[cc] = append(tagsByCountry[cc], tuicTag)
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
		tagsByCountry[cc] = append(tagsByCountry[cc], chainTag)
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

	urltestInterval := engineCfg.UrltestInterval
	if urltestInterval == "" {
		urltestInterval = "3m"
	}

	// --- Per-country urltests ---
	// Sort countries: NL first (LTE-native for RU users — the "just works"
	// default), then alphabetical. Order matters: it's what the user sees
	// in the picker.
	countryCodes := make([]string, 0, len(tagsByCountry))
	for cc := range tagsByCountry {
		countryCodes = append(countryCodes, cc)
	}
	sort.SliceStable(countryCodes, func(i, j int) bool {
		a, b := countryCodes[i], countryCodes[j]
		if a == "NL" && b != "NL" {
			return true
		}
		if b == "NL" && a != "NL" {
			return false
		}
		return a < b
	})

	var countryTags []string
	var countryOutbounds []clientOutbound
	for _, cc := range countryCodes {
		displayTag := countryDisplay(cc)
		// Sort within-country: direct first (fast path on unblocked nets);
		// then via-* (relay chains); then h2/tuic. urltest picks lowest RTT
		// regardless of order, but stable order makes logs readable.
		legs := append([]string(nil), tagsByCountry[cc]...)
		sort.SliceStable(legs, func(i, j int) bool {
			return legSortKey(legs[i]) < legSortKey(legs[j])
		})
		countryOutbounds = append(countryOutbounds, clientOutbound{
			Type:                      "urltest",
			Tag:                       displayTag,
			Outbounds:                 legs,
			URL:                       "https://cp.cloudflare.com",
			Interval:                  urltestInterval,
			Tolerance:                 100,
			InterruptExistConnections: boolPtr(false),
		})
		countryTags = append(countryTags, displayTag)
	}

	// --- Whitelist-bypass isolated group (if any rows exist) ---
	// Rendered as a `selector`, NOT `urltest`: the two SPB legs exit in
	// different countries (SPB→DE vs SPB→NL), so auto-pickoff by RTT would
	// silently override the user's deliberate country choice. `selector`
	// honours the pin set via Clash API. Whitelist-bypass is manual-only
	// by design — never part of global "Auto".
	var whitelistGroupTag string
	if len(whitelistLegs) > 0 {
		whitelistGroupTag = whitelistBypassGroupTag
		sort.Strings(whitelistLegs)
		countryOutbounds = append(countryOutbounds, clientOutbound{
			Type:                      "selector",
			Tag:                       whitelistGroupTag,
			Outbounds:                 whitelistLegs,
			Default:                   whitelistLegs[0],
			InterruptExistConnections: boolPtr(false),
		})
	}

	// --- "Auto" — best across all STANDARD legs (never whitelist-bypass) ---
	autoOutbound := clientOutbound{
		Type:                      "urltest",
		Tag:                       "Auto",
		Outbounds:                 append([]string(nil), autoLegs...),
		URL:                       "https://cp.cloudflare.com",
		Interval:                  urltestInterval,
		Tolerance:                 100,
		InterruptExistConnections: boolPtr(false),
	}

	// --- "Proxy" selector — top-level user choice ---
	// Auto → country groups (ordered) → whitelist-bypass group → individual
	// leaves. Leaves are appended as direct children so the iOS app can pin
	// a specific protocol/leg via Clash API (`selectOutbound("Proxy", leaf)`).
	// Country groups remain urltest for Auto-like failover; the leaves here
	// are just selectable shortcuts that bypass the RTT picker when the user
	// has a deliberate preference (e.g. "force TUIC" when Reality is blocked
	// on their network, or "force via-MSK" on RU LTE). Without this, the
	// urltest inside a country group can't be pinned via Clash API
	// ("outbound is not a selector" error) and the user's leaf pick is lost.
	proxyMembers := append([]string{"Auto"}, countryTags...)
	if whitelistGroupTag != "" {
		proxyMembers = append(proxyMembers, whitelistGroupTag)
	}
	for _, leaf := range autoLegs {
		proxyMembers = append(proxyMembers, leaf)
	}
	for _, leaf := range whitelistLegs {
		proxyMembers = append(proxyMembers, leaf)
	}
	proxyOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "Proxy",
		Outbounds:                 proxyMembers,
		Default:                   "Auto",
		InterruptExistConnections: boolPtr(false),
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
	// sing-box 1.13. "Proxy" references "Auto" + country urltests, so Proxy
	// goes first, then Auto + countries, then leaf server outbounds, then
	// mode selectors (which only reference "Proxy"/"direct").
	allOutbounds := []clientOutbound{proxyOutbound, autoOutbound}
	allOutbounds = append(allOutbounds, countryOutbounds...)
	allOutbounds = append(allOutbounds, ruTrafficOutbound, blockedTrafficOutbound, defaultRouteOutbound)
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
				{Tag: "dns-remote", Type: "https", Server: "1.1.1.1"},
				{Tag: "dns-direct", Type: "https", Server: "77.88.8.8"},
				{Tag: "dns-fakeip", Type: "fakeip", Inet4Range: "198.18.0.0/15"},
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
			DefaultDomainResolver: &clientDomainResolver{
				Server:   "dns-direct",
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
	UTLS       *clientUTLS    `json:"utls,omitempty"`
	Reality    *clientReality `json:"reality,omitempty"`
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

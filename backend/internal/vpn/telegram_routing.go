package vpn

// telegramDomains is the list of domain_suffix entries that match all
// Telegram user-facing traffic: client app endpoints, bot API, web client,
// in-app browser, MTProto control. domain_suffix matches subdomains by
// default — e.g. "telegram.org" matches "api.telegram.org", "core.telegram.org",
// "web.telegram.org", etc.
//
// Used to route Telegram traffic through the "RU Traffic" mode selector
// (not hardcoded direct). Effect per mode:
//   - Smart / Split-tunnel (RU Traffic = direct): Telegram bypasses VPN →
//     direct connection to nearest Telegram CDN, ~10-30ms RTT in RU instead
//     of 100-200ms via VPN exit. Telegram is unblocked in RU (since 2020),
//     so direct is safe and fast.
//   - Full-VPN (RU Traffic = Proxy): Telegram goes through VPN, respecting
//     the user's explicit "everything through VPN" choice (e.g. they want
//     Telegram to see a NL IP).
var telegramDomains = []string{
	"t.me",
	"telegram.org",
	"telegram.me",
	"telegram-cdn.org",
	"tdesktop.com",
	"telesco.pe",
}

// telegramCIDRs is the Telegram-Inc-published list of IP CIDRs that carry
// MTProto, media CDN, and bot API traffic. Source:
// https://core.telegram.org/resources/cidr.txt (snapshot 2026-05-13).
//
// We include these so that even when DNS resolves to a Telegram-internal
// address NOT covered by our domain list (e.g. raw MTProto via ip-only
// connect, or rare CDN subdomains), the IP-level match still routes
// through "RU Traffic". Without IP matching, traffic to e.g. 91.105.192.100
// would fall through to Default Route — that's exactly the bug field log
// 2026-05-13 exposed (Telegram CDN IPs registered to "Telegram Messenger
// Inc, NL" so geoip-ru doesn't catch them).
var telegramCIDRs = []string{
	// DC1-DC5 + edge IPv4 ranges. Each /22 = 1024 addresses.
	"91.108.4.0/22",
	"91.108.8.0/22",
	"91.108.12.0/22",
	"91.108.16.0/22",
	"91.108.20.0/22",
	"91.108.56.0/22",
	// Russia-facing CDN entries — physically in NL/UK per ip-api.com,
	// registered to Telegram Messenger Inc and partner ISPs. These are
	// the IPs the field log 2026-05-13 showed traffic going to.
	"91.105.192.0/23",
	"95.161.64.0/20",
	// NL Telegram core (149.154.160.0/20 covers main NL bouquet).
	"149.154.160.0/20",
	"149.154.164.0/22",
	"149.154.168.0/22",
	"149.154.172.0/22",
	// Other anchored ranges.
	"185.76.151.0/24",
	// IPv6 ranges. iOS app currently disables IPv6 in TUN, but include
	// for completeness if/when IPv6 gets re-enabled.
	"2001:67c:4e8::/48",
	"2001:b28:f23c::/48",
	"2001:b28:f23d::/48",
	"2001:b28:f23f::/48",
	"2a0a:f280::/29",
}

package vpn

// ruAlwaysDirectDomains is the curated list of domains that MUST bypass the
// VPN tunnel regardless of user preference.
//
// Rationale: these services (Russian banks, gov portals, telecoms, Yandex,
// VK, marketplaces, media) actively fingerprint VPN egress IPs and will
// block the account, refuse transactions, or serve endless captchas if
// reached through the proxy. Forcing them direct is user-friendly AND
// reduces the VPN-detection signal RU apps rely on.
//
// Entries are matched as `domain_suffix` in sing-box — so "sberbank.ru"
// also covers "online.sberbank.ru". Keep entries lowercase, no leading dot.
var ruAlwaysDirectDomains = []string{
	// --- Banks ---
	"sberbank.ru", "sber.ru", "sberbank.com",
	"tbank.ru", "tinkoff.ru",
	"vtb.ru",
	"alfabank.ru",
	"gazprombank.ru",
	"open.ru",
	"raiffeisen.ru",
	"pochtabank.ru",
	"psbank.ru",
	"sovcombank.ru",
	"mkb.ru",
	"uralsib.ru",
	"bspb.ru",
	"mtsbank.ru",
	"homecredit.ru",

	// --- Gov / tax / payments ---
	"gosuslugi.ru",
	"nalog.ru", "nalog.gov.ru",
	"mos.ru",
	"cbr.ru",
	"rosreestr.ru", "rosreestr.gov.ru",
	"pfr.gov.ru",
	"fssp.gov.ru",
	"mvd.ru",
	"roskazna.gov.ru",
	"nspk.ru", "mir-connect.ru",
	"yoomoney.ru",
	"qiwi.com",

	// --- Telecoms (billing + self-service) ---
	"mts.ru",
	"megafon.ru",
	"beeline.ru",
	"tele2.ru",
	"yota.ru",
	"rt.ru",

	// --- Marketplaces / delivery ---
	"ozon.ru", "ozonusercontent.com",
	"wildberries.ru", "wb.ru", "wbstatic.net", "wbbasket.ru",
	"yandex.market", "market.yandex.ru",
	"megamarket.ru",
	"lamoda.ru",
	"dns-shop.ru",
	"mvideo.ru",
	"eldorado.ru",
	"sbermarket.ru",
	"samokat.ru",
	"vkusvill.ru",
	"perekrestok.ru",
	"delivery-club.ru",
	"dodopizza.ru",

	// --- Yandex ecosystem (geo-gated + captcha-heavy) ---
	"yandex.ru", "yandex.net", "yandex.com",
	"yastatic.net", "ya.ru",
	"kinopoisk.ru",

	// --- VK / OK ---
	"vk.com", "vk.ru",
	"userapi.com", "vkuser.net", "vkcdn.ru",
	"ok.ru", "okcdn.ru",

	// --- RU-only media ---
	"kion.ru",
	"okko.tv",
	"ivi.ru",
	"more.tv",
	"premier.one",
	"wink.ru",
	"start.ru",
	"rutube.ru",

	// --- Transport / tickets ---
	"rzd.ru",
	"aeroflot.ru",
	"pobeda.aero",
	"s7.ru",
	"uralairlines.ru",
	"tutu.ru",

	// --- Classifieds / maps ---
	"avito.ru",
	"cian.ru",
	"hh.ru",
	"2gis.ru",
}

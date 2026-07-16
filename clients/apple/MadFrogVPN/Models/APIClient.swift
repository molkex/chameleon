import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Derived device metadata sent as HTTP headers on every API request.
/// Standard, non-sensitive data (model identifier, install date) — no
/// sensors, no permissions, no App Tracking Transparency required.
private enum DeviceTelemetry {

    /// Hardware model identifier, e.g. "iPhone15,2". Stable across launches.
    static let modelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var id = ""
        for child in mirror.children {
            if let value = child.value as? Int8, value != 0 {
                id.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return id.isEmpty ? "unknown" : id
    }()

    /// First-launch date in ISO-8601 (YYYY-MM-DD), persisted in UserDefaults.
    static var installDateISO: String {
        let key = "chameleon.installDate"
        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: key) {
            return cached
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let today = formatter.string(from: Date())
        defaults.set(today, forKey: key)
        return today
    }
}

enum APIError: LocalizedError {
    case invalidCode
    case networkError(String)
    case serverError(Int)
    case noConfig
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "api.error.invalid_code".localized
        case .networkError(let msg): return String(format: "api.error.network".localized, msg)
        case .serverError(let code): return String(format: "api.error.server".localized, code)
        case .noConfig: return "api.error.no_config".localized
        case .unauthorized: return "api.error.unauthorized".localized
        }
    }
}

struct AuthResult: Codable {
    let accessToken: String
    let refreshToken: String
    let username: String
    let isNew: Bool?
    /// Backend user id. Optional so older endpoints/responses still decode.
    /// Used to tie StoreKit purchases to the account (appAccountToken) and for
    /// diagnostics — see ACCT-IDENTITY.
    let userID: Int64?
    /// SUBSCRIPTION-ON-AUTH (2026-06-17): subscription expiry (unix seconds) so
    /// the app applies the subscription the moment sign-in succeeds, without
    /// depending on the separate /config fetch (whose X-Expire can be lost to an
    /// RU network blip). nil = no active coverage.
    let subscriptionExpiry: Int64?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case username
        case isNew = "is_new"
        case userID = "user_id"
        case subscriptionExpiry = "subscription_expiry"
    }
}

/// Result of `POST /api/mobile/auth/refresh`.
///
/// The backend ROTATES the refresh token on every call: each refresh token is
/// single-use and gets blacklisted (SHA-256) in Redis for 30 days. So the
/// response carries a brand-new `refreshToken` that the caller MUST persist.
/// Dropping it (keeping the old, now-consumed token) makes the *next* refresh
/// resend a blacklisted token → backend 401 "refresh token already used" →
/// forced visible re-login every ~24h. That was Pain #2.
struct RefreshResult {
    let accessToken: String
    /// The rotated, single-use refresh token. Persist this, not the old one.
    let refreshToken: String
    /// Access-token expiry (unix → Date). Optional so an older backend that
    /// omits `expires_at` still decodes. Available for future proactive refresh.
    let expiresAt: Date?
    /// SUBSCRIPTION-ON-AUTH: subscription expiry (unix seconds) so a silent
    /// refresh re-applies the subscription without a /config round-trip. nil =
    /// not present in this response.
    let subscriptionExpiry: Int64?
}

/// Delegate that trusts all certificates **only for known fallback hosts**.
/// When Cloudflare is blocked (e.g. in Russia), the app falls back to direct
/// IP or the SPB relay which present self-signed or IP-based certificates.
/// Risk is bounded by:
///   1. host whitelist below (so this delegate cannot accidentally trust
///      arbitrary upstreams if a config bug routes a request elsewhere),
///   2. VLESS Reality encryption on the VPN tunnel itself.
/// TODO (ROADMAP security HIGH): replace with cert pinning once backend
/// publishes its serving cert fingerprint via /api/v1/server/info.
private final class InsecureDelegate: NSObject, URLSessionDelegate {
    /// Hosts where we accept any server cert. Keep in sync with
    /// AppConfig.directBackendIPs and AppConfig.russianRelayURL.
    private static let trustedHosts: Set<String> = {
        var hosts = Set(AppConfig.directBackendIPs)
        if let relayHost = URL(string: AppConfig.russianRelayURL)?.host {
            hosts.insert(relayHost)
        }
        return hosts
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        if Self.trustedHosts.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // Unknown host on the fallback session — refuse rather than blindly trust.
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// build-88 testability extract: pure decision describing which legs the
/// hedged race in `dataWithFallback` should dispatch. Pulled out so the
/// sensitive/auth/region gating can be exercised in a unit test without
/// spinning real URLSession / NWConnection legs.
///
/// Invariants (mirrored by APIClientSensitiveFlagTests):
///   * `sensitive=true` zeroes BOTH `directIPs` and `httpEightyIPs`
///     (audit H-001 / H-002): refresh tokens, magic tokens and signed JWS
///     bodies must never traverse a cleartext HTTP:80 leg or a direct-IP
///     TLS leg with disabled cert validation.
///   * Authenticated requests (`Authorization` header present, modelled
///     here as `isAuthenticated=true`) skip HTTP:80 even when not
///     sensitive — sending a Bearer over cleartext is unacceptable.
///   * RU region filters out the OVH Frankfurt direct IP (162.19.242.30)
///     because RU mobile carriers ASN-block it; that filter applies to
///     both direct-IP and HTTP:80 leg lists.
///   * The primary HTTPS leg always fires (`primary == true`); the
///     race only widens with extra legs.
struct RaceLegPlan: Equatable {
    var primary: Bool
    var directIPs: [String]
    var httpEightyIPs: [String]
}

/// Winner policy for the hedged race — controls which statuses a FALLBACK leg
/// (direct-IP / HTTP:80) may win with. The PRIMARY leg is always authoritative
/// (wins on any status < 500) regardless of policy.
///
/// AUTH-DIRECT-IP-INTERACTIVE (2026-06-17): interactive sign-in (Apple/Google/
/// magic-verify) historically used a bare `session.data` with NO fallback,
/// deliberately, because under `.anyBelow500` a transport-mangled 4xx from a
/// fallback leg (an IP-host nginx 400, a torn-TLS direct leg) could WIN over
/// primary's correct 200 and make a valid login look "invalid" (build-53). That
/// left RU sign-in with no recovery when Cloudflare stalls. `.definitiveAuthOnly`
/// fixes both: a fallback leg may win ONLY on a 2xx (success) or 401 (a real
/// backend "unauthorized" — nginx on a raw IP returns 400/404, never 401, so a
/// 401 means the request actually reached the app-layer auth check). Any other
/// fallback 4xx is treated as non-winning noise, so it can't shadow primary.
enum FallbackWinPolicy {
    /// Current default: a fallback leg wins on any status < 500. Keeps
    /// fetchAndSaveConfig's 404→re-register propagation working.
    case anyBelow500
    /// Auth sign-in: a fallback leg wins ONLY on 2xx or 401.
    case definitiveAuthOnly
    /// Config fetch (2026-07-11): the same build-53 shape hit `/config` —
    /// live-verified a stale/dead direct-IP leg (post-failover NL, dead SPB)
    /// answering a fast empty-body 400 that could win the race over a
    /// slower-but-correct primary/decoy, surfacing as a spurious "no config"
    /// on a real device even though a working leg existed. `GetConfig`'s own
    /// handler only ever emits 2xx (success), 401 (bad/expired JWT — checked
    /// before user lookup), 403 (deactivated / subscription expired), 404
    /// (user row missing — drives the ACCT-IDENTITY re-register ladder), or
    /// 409 (VPN credentials not provisioned yet) — every OTHER 4xx (like the
    /// dead legs' raw 400) can only come from something that isn't our app
    /// actually answering, so it must not be allowed to shadow a real leg.
    case definitiveConfigOnly
}

class APIClient {
    private let session: URLSession
    private let fallbackSession: URLSession

    /// AUTH-LEG-TELEMETRY (PRODUCT-MATURITY-LOOP 2026-06-21): which leg carried the
    /// last SENSITIVE (sign-in) request — "primary" | "decoy" | "http-<ip>" | nil
    /// (all failed). AppState reads this after a sign-in and emits it so the
    /// otherwise-invisible RU residential failure mode becomes measurable from real
    /// users (who win on CF vs the decoy, and how often nothing wins).
    private(set) var lastSensitiveAuthLeg: String?

    /// build-88 testability extract — see `RaceLegPlan` doc.
    static func raceLegPlan(sensitive: Bool,
                            isAuthenticated: Bool,
                            region: String?,
                            availableIPs: [String]) -> RaceLegPlan {
        // Region filter applies to all direct legs: RU mobile ASN-blocks the
        // retired OVH Frankfurt IP, and its 6s timeout would serialise the race.
        let directIPs: [String]
        if region == "RU" {
            directIPs = availableIPs.filter { $0 != "162.19.242.30" }
        } else {
            directIPs = availableIPs
        }
        if sensitive {
            // AUTH-RKN-DIRECT-IP (2026-06-09): sign-in (apple/google/register/
            // refresh) is the ONE flow with no DNS-diverse fallback — it hit only
            // api.madfrog.online, whose single IP can stall per-network (the
            // documented Cloudflare-SNI-filter class, feedback_cloudflare_ru),
            // giving "не получилось войти" / "works only through another VPN".
            //   * H-001 still holds → NEVER the HTTP:80 cleartext legs (a Bearer
            //     must not traverse plaintext).
            //   * H-002 is RESOLVED by H-002b (build 89): DirectConnection now
            //     fully validates the server cert chain against the SNI
            //     (SecPolicyCreateSSL + SecTrustEvaluateWithError), and NL:443 /
            //     SPB:443 present a VALID Let's Encrypt cert for api.madfrog.online
            //     — so the direct-IP TLS legs are MITM-safe and auth CAN race them.
            // This restores the documented "race direct IPs, never trust a single
            // path" resilience for the auth flow, with no MITM exposure.
            return RaceLegPlan(primary: true, directIPs: directIPs, httpEightyIPs: [])
        }
        let httpEightyIPs: [String]
        if isAuthenticated {
            httpEightyIPs = []
        } else {
            httpEightyIPs = directIPs
        }
        return RaceLegPlan(primary: true, directIPs: directIPs, httpEightyIPs: httpEightyIPs)
    }

    /// Whether a FALLBACK leg (direct-IP / HTTP:80) may win the hedged race with
    /// `status` under `policy`. Pure + static so the winner rule is unit-testable
    /// without live networking. The PRIMARY leg does NOT use this — it is always
    /// authoritative on any status < 500 (see dataWithFallback). A 5xx never wins
    /// from any leg (the server is failing; let another leg or the caller decide).
    static func fallbackLegWins(status: Int, policy: FallbackWinPolicy) -> Bool {
        guard status < 500 else { return false }
        switch policy {
        case .anyBelow500:
            return true
        case .definitiveAuthOnly:
            // Only a real success or a backend "unauthorized" is a definitive
            // auth outcome. A raw-IP nginx 400/404 or a torn-TLS leg must NOT
            // shadow primary's 200 (build-53). 401 reaching the app means the
            // request truly hit the backend auth check.
            return (200...299).contains(status) || status == 401
        case .definitiveConfigOnly:
            // Mirrors GetConfig's actual response surface (see enum doc) —
            // anything else (the dead legs' raw 400) is transport noise, not
            // a real backend answer, and must not shadow a working leg.
            return (200...299).contains(status) || status == 401 || status == 403
                || status == 404 || status == 409
        }
    }

    /// RU-DECOY-SNI (2026-06-17): whether to add the clean-SNI decoy leg
    /// (ads.adfox.ru → MSK, pinned cert). It's the most reliable backend path
    /// when RKN SNI-filters api.madfrog.online, so it runs for every sensitive
    /// request (sign-in / refresh) and for any request from RU or an unknown
    /// region. Confirmed non-RU regions skip it — their primary path is clean
    /// and the extra dial would be wasted.
    static func shouldUseDecoyLeg(sensitive: Bool, region: String?) -> Bool {
        if sensitive { return true }
        return region == nil || region == "RU"
    }

    /// RU-DECOY-FIRST (2026-06-17): how long the filtered-SNI legs (primary +
    /// direct-IP) are held so the clean-SNI decoy can win first WITHOUT any
    /// api.madfrog.online ClientHello leaving the device. Non-zero only for
    /// sensitive auth — that's where a leaked SNI trips the TSPU and poisons
    /// the next sign-in. See dataWithFallback for the full rationale.
    static func poisonHoldMs(sensitive: Bool) -> Int { sensitive ? 2000 : 0 }

    /// Decoy-leg lead time. T+0 for sensitive auth (it must beat the held
    /// poisoning legs); a light 150ms stagger otherwise so a healthy primary
    /// still wins without a redundant relay dial.
    static func decoyLeadMs(sensitive: Bool) -> Int { sensitive ? 0 : 150 }

    init() {
        let config = URLSessionConfiguration.default
        // RU operators frequently SNI-filter Cloudflare ranges; in that case
        // session.data(for:) blocks for the full timeout before the race can
        // try a direct IP. Lowered from 8s → 4s so the user doesn't sit on
        // the spinner for 8 seconds before the working leg responds. The
        // direct-IP legs use shorter timeouts (6s NWConnection) so the
        // race effectively settles in <5s end-to-end on bad networks.
        config.timeoutIntervalForRequest = 4
        // Cap total time including retries/redirects/body upload so a stuck
        // server can't keep a request hanging forever past the per-request
        // timeout. Higher than per-request because some endpoints
        // (registration, restore-purchases) can legitimately take a few
        // round-trips. ROADMAP iOS-13.
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        let fallbackConfig = URLSessionConfiguration.default
        fallbackConfig.timeoutIntervalForRequest = 8
        fallbackConfig.timeoutIntervalForResource = 30
        fallbackSession = URLSession(configuration: fallbackConfig, delegate: InsecureDelegate(), delegateQueue: nil)
    }

    /// Injects telemetry headers (timezone, device model, precise iOS version,
    /// install date) into every outgoing API request. These are standard HTTP
    /// headers, not device sensors — no permission prompt, no App Tracking
    /// Transparency, so they don't trigger App Store privacy disclosures
    /// beyond what any networked app already collects. Used to show real
    /// device info in the admin panel even when the user is connected through
    /// our own VPN (in which case their IP resolves to our exit node, not
    /// their actual location).
    private func applyTelemetry(to request: URLRequest) -> URLRequest {
        var req = request
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        #if canImport(UIKit)
        req.setValue(PlatformDevice.systemVersion, forHTTPHeaderField: "X-iOS-Version")
        #endif
        req.setValue(DeviceTelemetry.modelIdentifier, forHTTPHeaderField: "X-Device-Model")
        req.setValue(DeviceTelemetry.installDateISO, forHTTPHeaderField: "X-Install-Date")
        // STALL-ON-NETSWITCH-LEAN-FIX (2026-07-16): CFBundleVersion (build
        // number), NOT the marketing version — lets /config gate the
        // urltest-vs-lean shape per client build (clientconfig.go leanMode).
        // Distinct from the analytics X-App-Version header (EventTracker),
        // which carries CFBundleShortVersionString for a different purpose.
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty {
            req.setValue(build, forHTTPHeaderField: "X-App-Build")
        }
        // STORE-COUNTRY: App Store storefront, cached at launch (SubscriptionManager).
        if let store = UserDefaults.standard.string(forKey: AppConstants.storeCountryKey), !store.isEmpty {
            req.setValue(store, forHTTPHeaderField: "X-Store-Country")
        }
        // Explicit Accept-Language — the backend uses the first token to
        // localize transactional emails (magic link). URLSession does set
        // this by default but only in iOS/macOS locales; explicit keeps
        // the signal predictable across environments.
        if let code = Locale.current.language.languageCode?.identifier {
            req.setValue(code, forHTTPHeaderField: "Accept-Language")
        }
        return req
    }

    /// Cloudflare is SNI-filtered in RU (2026-04). Race URLSession
    /// against SNI-spoofed NWConnection dials to hardcoded backend IPs.
    ///
    /// `sensitive: true` opts the request out of BOTH fallback legs:
    /// HTTP:80 cleartext (refresh tokens, magic tokens, signed JWS would
    /// be exposed on hostile networks) and direct-IP TLS (cert validation
    /// is currently disabled — see DirectConnection.swift — so Bearer
    /// headers on direct-IP legs can be MitM'd). 2026-05-26 audit
    /// H-001 / H-002. The cost is no fallback for sensitive endpoints
    /// when Cloudflare is blocked; revisit when DirectConnection learns
    /// to validate the cert chain against the SNI.
    private func dataWithFallback(for request: URLRequest, sensitive: Bool = false, winPolicy: FallbackWinPolicy = .anyBelow500) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw APIError.networkError("missing URL")
        }

        if sensitive { lastSensitiveAuthLeg = nil }   // reset; a throw below leaves it nil = "all failed"

        let method = request.httpMethod ?? "GET"
        let path: String = {
            if let q = url.query, !q.isEmpty { return "\(url.path)?\(q)" }
            return url.path.isEmpty ? "/" : url.path
        }()

        // Build-36: idempotency key for mutating methods. The same key flows
        // to every hedged leg (primary, direct-IP, http:80) via the shared
        // request, so a backend dedup middleware can collapse duplicate
        // arrivals from the race into one logical effect.
        var augmentedRequest = request
        var idempotencyKey: String?
        if method != "GET" && method != "HEAD" && request.value(forHTTPHeaderField: "Idempotency-Key") == nil {
            let key = UUID().uuidString
            augmentedRequest.setValue(key, forHTTPHeaderField: "Idempotency-Key")
            idempotencyKey = key
        }

        var reqHeaders = augmentedRequest.allHTTPHeaderFields ?? [:]
        if reqHeaders["User-Agent"] == nil { reqHeaders["User-Agent"] = AppConfig.userAgent }
        if request.httpBody != nil, reqHeaders["Content-Type"] == nil {
            reqHeaders["Content-Type"] = "application/json"
        }
        let body = request.httpBody

        let raceStart = DispatchTime.now()
        let idempLog = idempotencyKey.map { String($0.prefix(8)) } ?? "n/a"
        AppLogger.network.info("race.start path=\(path, privacy: .public) method=\(method, privacy: .public) idempkey=\(idempLog, privacy: .public)")

        // RU-DECOY-FIRST (2026-06-17): on a sensitive (sign-in / refresh)
        // request, HOLD every leg that carries the filtered SNI
        // (api.madfrog.online) — the primary and the direct-IP legs — for
        // `poisonDelayMs`, and let the clean-SNI decoy lead at T+0. Measured
        // failure: each sign-in emitted an api.madfrog.online TLS ClientHello
        // (the primary; NL/MSK logged it as a 499 once the decoy won), which
        // trips RKN's TSPU. The first attempt slips through, but the TSPU then
        // escalates and RSTs *everything* to the relay — including the decoy —
        // so the SECOND sign-in hangs. By holding the poisoning legs behind the
        // decoy, a sub-second decoy win cancels them while they're still
        // asleep: ZERO filtered-SNI ClientHellos leave the device, so the TSPU
        // never escalates and every subsequent sign-in keeps working. The hold
        // only costs latency on the rare network where the decoy itself fails.
        let poisonDelayMs = Self.poisonHoldMs(sensitive: sensitive)

        return try await withThrowingTaskGroup(of: (Data, URLResponse, String)?.self) { group in
            group.addTask { [session] in
                if poisonDelayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(poisonDelayMs))
                    if Task.isCancelled { return nil }
                }
                AppLogger.network.info("race.primary.start path=\(path, privacy: .public) delay=\(poisonDelayMs, privacy: .public)ms elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                do {
                    let (data, response) = try await session.data(for: augmentedRequest)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                    if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                        AppLogger.network.info("race.primary.done rejected status=\(http.statusCode, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        TunnelFileLogger.log("race.primary rejected status=\(http.statusCode) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                        return nil
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    AppLogger.network.info("race.primary.done ok status=\(status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                    TunnelFileLogger.log("race.primary ok status=\(status) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                    return (data, response, "primary")
                } catch {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                    AppLogger.network.error("race.primary.done error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                    TunnelFileLogger.log("race.primary error=\(error.localizedDescription) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                    return nil
                }
            }

            let sni = AppConfig.baseURLHost
            // build-88 testability extract: the leg-selection decision lives
            // in `Self.raceLegPlan` so it can be unit-tested. The behaviour
            // is unchanged from before the extract:
            //   * sensitive=true → NEVER the HTTP:80 cleartext legs (H-001), but
            //     the cert-validated direct-IP TLS legs ARE allowed (H-002 closed
            //     by H-002b: DirectConnection validates the chain vs the SNI) so
            //     auth survives a stalled primary (AUTH-RKN-DIRECT-IP 2026-06-09).
            //   * RU region → drop the OVH Frankfurt IP (162.19.242.30)
            //     because RU mobile ASN-blocks it and the 6s timeout would
            //     otherwise delay the race.
            //   * Authenticated requests skip the HTTP:80 leg list (no
            //     Bearer over cleartext).
            let isAuthenticatedHeader = request.value(forHTTPHeaderField: "Authorization") != nil
            let plan = Self.raceLegPlan(
                sensitive: sensitive,
                isAuthenticated: isAuthenticatedHeader,
                region: Locale.current.region?.identifier,
                availableIPs: AppConfig.directBackendIPs
            )
            let raceIPs = plan.directIPs
            if sensitive {
                AppLogger.network.info("race.sensitive=true direct_tls_legs=\(raceIPs.count, privacy: .public) http80=skipped")
            } else if Locale.current.region?.identifier == "RU" {
                AppLogger.network.info("race.region ru=true skipped=DE")
            }

            // RU-DECOY-SNI (2026-06-17): the highest-priority hedge. Dials the
            // MSK relay with a clean SNI (ads.adfox.ru) RKN won't RST and a
            // pinned self-signed cert, routing to the API via the Host header.
            // Fires at T+150ms so a genuinely-fast primary still wins first, but
            // ahead of the direct-IP legs (which all carry the filtered SNI).
            if Self.shouldUseDecoyLeg(sensitive: sensitive, region: Locale.current.region?.identifier) {
                // Lead at T+0 for sensitive auth (the poisoning legs are held
                // behind it); a light 150ms stagger otherwise so a fast primary
                // on a healthy network still wins without a redundant dial.
                let decoyDelayMs = Self.decoyLeadMs(sensitive: sensitive)
                // RU-DECOY-2ND (2026-06-21): race the clean-SNI decoy across BOTH RU
                // relays (MSK + SPB) so sign-in survives one relay dying — MSK alone
                // was a SPOF. Same pinned cert on both, so a relay not yet serving the
                // decoy SNI just pin-mismatches and drops out (safe before SPB is wired).
                for decoy in AppConfig.decoyRelays {
                    let decoyIP = decoy.ip
                    let decoyPort = decoy.port
                    group.addTask {
                        if decoyDelayMs > 0 { try? await Task.sleep(for: .milliseconds(decoyDelayMs)) }
                        if Task.isCancelled { return nil }
                        AppLogger.network.info("race.decoy.start sni=\(AppConfig.decoySNI, privacy: .public) ip=\(decoyIP, privacy: .public) port=\(decoyPort, privacy: .public) elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                        do {
                            let (bodyData, meta) = try await DirectConnection.request(
                                ip: decoyIP, port: decoyPort, sni: AppConfig.decoySNI,
                                method: method, path: path,
                                headers: reqHeaders, body: body,
                                timeout: 6, pinnedCertSHA256: AppConfig.decoyCertPin
                            )
                            let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                            if !Self.fallbackLegWins(status: meta.status, policy: winPolicy) {
                                AppLogger.network.info("race.decoy.done rejected ip=\(decoyIP, privacy: .public) status=\(meta.status, privacy: .public) policy=\(String(describing: winPolicy), privacy: .public) elapsed=\(ms, privacy: .public)ms")
                                TunnelFileLogger.log("race.decoy rejected ip=\(decoyIP) status=\(meta.status) policy=\(winPolicy) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                                return nil
                            }
                            let response = HTTPURLResponse(
                                url: url, statusCode: meta.status,
                                httpVersion: "HTTP/1.1", headerFields: meta.headers
                            )!
                            AppLogger.network.info("race.decoy.done ok ip=\(decoyIP, privacy: .public) status=\(meta.status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                            TunnelFileLogger.log("race.decoy ok ip=\(decoyIP) status=\(meta.status) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                            return (bodyData, response, "decoy")
                        } catch {
                            let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                            AppLogger.network.error("race.decoy.done error ip=\(decoyIP, privacy: .public) error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                            TunnelFileLogger.log("race.decoy error ip=\(decoyIP) error=\(error.localizedDescription) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                            return nil
                        }
                    }
                }
            }
            // Build-36: hedged dispatch (Dean & Barroso "Tail at Scale").
            // Primary fires at T+0; each direct leg waits legIndex*250ms before
            // its real work, so a fast primary saves the rest from ever starting.
            // 4xx is no longer discarded as a "bad leg" — it propagates so the
            // caller (e.g. fetchAndSaveConfig 404→re-register) can react.
            for (i, ip) in raceIPs.enumerated() {
                let legIndex = 1 + i
                group.addTask {
                    // Direct-IP legs also carry the filtered SNI, so on sensitive
                    // auth they sit behind the same poison hold as the primary —
                    // they only fire if the decoy didn't win in time.
                    let staggerMs = poisonDelayMs + legIndex * 250
                    try? await Task.sleep(for: .milliseconds(staggerMs))
                    if Task.isCancelled { return nil }
                    AppLogger.network.info("race.direct.start ip=\(ip, privacy: .public) delay=\(staggerMs, privacy: .public)ms elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                    do {
                        let (bodyData, meta) = try await DirectConnection.request(
                            ip: ip, port: 443, sni: sni,
                            method: method, path: path,
                            headers: reqHeaders, body: body,
                            timeout: 6
                        )
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        if !Self.fallbackLegWins(status: meta.status, policy: winPolicy) {
                            AppLogger.network.info("race.direct.done ip=\(ip, privacy: .public) rejected status=\(meta.status, privacy: .public) policy=\(String(describing: winPolicy), privacy: .public) elapsed=\(ms, privacy: .public)ms")
                            TunnelFileLogger.log("race.direct rejected ip=\(ip) status=\(meta.status) policy=\(winPolicy) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                            return nil
                        }
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: meta.status,
                            httpVersion: "HTTP/1.1",
                            headerFields: meta.headers
                        )!
                        AppLogger.network.info("race.direct.done ip=\(ip, privacy: .public) ok status=\(meta.status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        TunnelFileLogger.log("race.direct ok ip=\(ip) status=\(meta.status) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                        return (bodyData, response, "direct-\(ip)")
                    } catch {
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        AppLogger.network.error("race.direct.done ip=\(ip, privacy: .public) error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        TunnelFileLogger.log("race.direct error ip=\(ip) error=\(error.localizedDescription) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                        return nil
                    }
                }
            }

            // HTTP port 80 legs — RU operators often don't block TCP:80 even
            // when TCP:443 is TCP-RST'd on foreign IPs. Backend nginx accepts
            // port-80 requests whose Host is the raw IP (no 301 redirect).
            //
            // Audit H-001: the prior `isAuthenticated` gate only checked the
            // Authorization header, missing endpoints that put refresh_token /
            // magic token / signed JWS in the request body (refreshAccessToken,
            // requestMagicLink, registerDevice, verifySubscription). Now we
            // ALSO require `!sensitive` — sensitive callers opt in explicitly
            // and never see HTTP:80 legs. NL + bypass relay direct legs are
            // also skipped above when sensitive (H-002).
            //
            // build-88: gating now lives in `RaceLegPlan.httpEightyIPs`
            // (empty when sensitive OR authenticated). The wrapping `if` is
            // kept for indentation parity with the prior diff.
            let httpEightyIPs = plan.httpEightyIPs
            if !httpEightyIPs.isEmpty {
            // HTTP legs continue the hedge ladder after direct legs.
            let httpStartIndex = 1 + raceIPs.count
            for (i, ip) in httpEightyIPs.enumerated() {
                let legIndex = httpStartIndex + i
                group.addTask { [fallbackSession] in
                    let staggerMs = legIndex * 250
                    try? await Task.sleep(for: .milliseconds(staggerMs))
                    if Task.isCancelled { return nil }
                    AppLogger.network.info("race.http.start ip=\(ip, privacy: .public) delay=\(staggerMs, privacy: .public)ms elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                    guard var httpURL = URLComponents(string: "http://\(ip)") else { return nil }
                    httpURL.path = url.path
                    httpURL.query = url.query
                    guard let finalURL = httpURL.url else { return nil }
                    var httpReq = augmentedRequest
                    httpReq.url = finalURL
                    httpReq.timeoutInterval = 8
                    httpReq.setValue(nil, forHTTPHeaderField: "Host")
                    httpReq.setValue(nil, forHTTPHeaderField: "Authorization")
                    do {
                        let (data, response) = try await fallbackSession.data(for: httpReq)
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if !Self.fallbackLegWins(status: status, policy: winPolicy) {
                            AppLogger.network.info("race.http.done ip=\(ip, privacy: .public) rejected status=\(status, privacy: .public) policy=\(String(describing: winPolicy), privacy: .public) elapsed=\(ms, privacy: .public)ms")
                            TunnelFileLogger.log("race.http rejected ip=\(ip) status=\(status) policy=\(winPolicy) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                            return nil
                        }
                        AppLogger.network.info("race.http.done ip=\(ip, privacy: .public) ok status=\(status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        TunnelFileLogger.log("race.http ok ip=\(ip) status=\(status) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                        return (data, response, "http-\(ip)")
                    } catch {
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        AppLogger.network.error("race.http.done ip=\(ip, privacy: .public) error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        TunnelFileLogger.log("race.http error ip=\(ip) error=\(error.localizedDescription) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                        return nil
                    }
                }
            }
            } // httpEightyIPs non-empty

            for try await result in group {
                if let winner = result {
                    group.cancelAll()
                    if sensitive { lastSensitiveAuthLeg = winner.2 }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                    AppLogger.network.info("race.winner leg=\(winner.2, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                    TunnelFileLogger.log("race.winner leg=\(winner.2) path=\(path) elapsed=\(Int(ms))ms", category: "network")
                    return (winner.0, winner.1)
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
            AppLogger.network.error("race.failed elapsed=\(ms, privacy: .public)ms")
            TunnelFileLogger.log("race.failed path=\(path) elapsed=\(Int(ms))ms — all legs rejected/errored, see race.* lines above", category: "network")
            throw APIError.networkError("all paths failed")
        }
    }

    /// AUTH-RETRY (2026-06-17): sign-in over a flaky RU network sometimes hits a
    /// brief window where EVERY leg (CF + direct IPs) momentarily fails → the
    /// race throws "all paths failed" and the user had to tap the button again.
    /// This wraps the auth race with up to 3 attempts (700ms / 1400ms backoff),
    /// so a short network blip is ridden out silently. Only the transient
    /// "all paths failed" is retried — a real 401/4xx surfaces immediately.
    private func dataWithFallbackRetryingAuth(for request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error = APIError.networkError("all paths failed")
        for attempt in 1...3 {
            do {
                return try await dataWithFallback(for: request, sensitive: true, winPolicy: .definitiveAuthOnly)
            } catch let err as APIError {
                if case .networkError(let msg) = err, msg.contains("all paths failed") {
                    lastError = err
                    AppLogger.network.info("auth retry \(attempt, privacy: .public)/3 after all-paths-failed")
                    if attempt < 3 { try? await Task.sleep(for: .milliseconds(700 * attempt)) }
                    continue
                }
                throw err  // a definitive auth outcome (401, decode, etc.) — don't retry
            }
        }
        throw lastError
    }

    // MARK: - Standalone Device Registration

    /// Register device for trial access.
    func registerDevice() async throws -> AuthResult {
        let deviceId = PlatformDevice.identifier

        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/register") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["device_id": deviceId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 6s per attempt. The outer dataWithFallback adds two more attempts
        // with 7s + 10s caps, so the user waits at most ~23s before seeing
        // an error. Was 15s which meant a bad primary (Cloudflare slow or
        // blocked by local DPI) felt like "infinite loading" to users.
        request.timeoutInterval = 6

        do {
            // Audit H-001/H-002: registerDevice mints fresh access+refresh
            // tokens. No HTTP:80 or direct-IP TLS legs — primary HTTPS only.
            let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request), sensitive: true)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 || http.statusCode == 201 else {
                throw APIError.serverError(http.statusCode)
            }
            return try JSONDecoder().decode(AuthResult.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Code Activation (from Telegram bot)

    /// Activate with code from Telegram bot (POST to /api/mobile/auth/activate).
    func activateCode(_ code: String) async throws -> String {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/activate") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["code": code]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: applyTelemetry(to: request))
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }

            switch http.statusCode {
            case 200:
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard let username = json["username"] as? String, !username.isEmpty else {
                    throw APIError.noConfig
                }
                return username
            case 404: throw APIError.invalidCode
            default: throw APIError.serverError(http.statusCode)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Config Download

    /// Download sing-box config from the mobile config endpoint (9 clean outbounds).
    /// Always uses /api/v1/mobile/config — passes username as query param, Bearer token if available.
    func fetchConfig(username: String, accessToken: String? = nil, mode: String = "smart") async throws -> (config: String, expire: Int) {
        guard var components = URLComponents(string: AppConstants.mobileConfigURL) else {
            throw APIError.networkError("Invalid config URL")
        }
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "mode", value: mode),
        ]
        guard let url = components.url else {
            throw APIError.networkError("Invalid config URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await dataWithFallback(
                for: applyTelemetry(to: request),
                winPolicy: .definitiveConfigOnly
            )
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 else {
                throw APIError.serverError(http.statusCode)
            }
            guard let config = String(data: data, encoding: .utf8), !config.isEmpty else {
                throw APIError.noConfig
            }
            // Reject error responses disguised as 200 OK
            if config.contains("\"error\"") && !config.contains("\"outbounds\"") {
                throw APIError.serverError(404)
            }
            let expire = Int(http.value(forHTTPHeaderField: "X-Expire") ?? "0") ?? 0
            return (config, expire)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Apple Sign In

    /// Sign in with Apple — trial or return existing account.
    ///
    /// IMPORTANT: this path does NOT use `dataWithFallback`. The hedged race
    /// occasionally elects a transport-mangled 4xx (e.g. an HTTP:80 fallback
    /// leg or a direct-IP leg whose Host header doesn't match the backend
    /// vhost) over the primary's correct 200, which surfaces in the UI as
    /// "Sign in failed (400)". Apple Review hit exactly that on build 53
    /// (May 12 2026, reviewer IP 75.164.164.127, iPhone 17 Pro Max).
    ///
    /// For an auth handshake, correctness beats redundancy: the user can
    /// retry, but they cannot recover from a silently-failed sign-in. We
    /// therefore go straight at the primary host with a generous timeout.
    func signInWithApple(identityToken: String) async throws -> AuthResult {
        let deviceId = PlatformDevice.identifier
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/apple") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identity_token": identityToken,
            "device_id": deviceId,
        ])
        request.timeoutInterval = 20

        // AUTH-DIRECT-IP-INTERACTIVE (2026-06-17): race the cert-validated
        // direct-IP legs (sensitive:true) under the .definitiveAuthOnly winner
        // rule so a stalled Cloudflare primary in RU can't strand sign-in, while
        // a transport-mangled fallback 4xx still can't shadow primary's 200.
        do {
            let (data, response) = try await dataWithFallbackRetryingAuth(for: applyTelemetry(to: request))
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 else {
                throw APIError.serverError(http.statusCode)
            }
            return try JSONDecoder().decode(AuthResult.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            // Bubble up decode error explicitly so AppState can show a
            // distinct message instead of a generic "network error".
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Google Sign In

    /// Sign in with Google — trial or return existing account.
    /// `idToken` is the ID token returned by GoogleSignIn SDK.
    ///
    /// Same reasoning as signInWithApple — races the cert-validated direct-IP
    /// legs under .definitiveAuthOnly (fallback wins only on 2xx/401), so RU
    /// Cloudflare stalls don't strand sign-in and a mangled fallback 4xx can't
    /// shadow primary's 200.
    func signInWithGoogle(idToken: String) async throws -> AuthResult {
        let deviceId = PlatformDevice.identifier
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/google") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id_token": idToken,
            "device_id": deviceId,
        ])
        request.timeoutInterval = 20

        // AUTH-DIRECT-IP-INTERACTIVE (2026-06-17): same as signInWithApple —
        // race the cert-validated direct-IP legs under .definitiveAuthOnly so a
        // stalled RU Cloudflare primary can't strand sign-in, with no risk of a
        // mangled fallback 4xx shadowing primary's 200.
        do {
            let (data, response) = try await dataWithFallbackRetryingAuth(for: applyTelemetry(to: request))
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 else {
                throw APIError.serverError(http.statusCode)
            }
            return try JSONDecoder().decode(AuthResult.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Magic Link

    /// Request a magic link email. The server responds 204 regardless of
    /// whether the email is known — this avoids leaking which addresses
    /// have accounts. UI should show "if an account exists, check your
    /// email" to match.
    func requestMagicLink(email: String) async throws {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/magic/request") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        request.timeoutInterval = 6

        // Audit H-001/H-002: magic link delivery includes a token in the
        // email; even though the body here is just an email address, we
        // treat this as sensitive end-to-end (no HTTP:80, no direct-IP TLS).
        let (_, response) = try await dataWithFallback(for: applyTelemetry(to: request), sensitive: true)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        switch http.statusCode {
        case 204, 200: return
        case 429: throw APIError.serverError(429)
        default:   throw APIError.serverError(http.statusCode)
        }
    }

    /// Redeem a magic-link token received via Universal Link.
    func verifyMagicLink(token: String) async throws -> AuthResult {
        let deviceId = PlatformDevice.identifier
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/magic/verify") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "device_id": deviceId,
        ])
        request.timeoutInterval = 20

        // AUTH-DIRECT-IP-INTERACTIVE (2026-06-17): race the cert-validated
        // direct-IP legs so a stalled Cloudflare primary in RU doesn't make a
        // valid magic-link look "invalid". The .definitiveAuthOnly winner rule
        // means a fallback leg can only win on 2xx/401 — a transport-mangled 4xx
        // (the build-53 fear that originally forced a bare single path) can no
        // longer shadow primary's 200.
        do {
            let (data, response) = try await dataWithFallbackRetryingAuth(for: applyTelemetry(to: request))
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 else {
                throw APIError.serverError(http.statusCode)
            }
            return try JSONDecoder().decode(AuthResult.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Token Refresh

    /// Exchange refresh token for a new access token.
    ///
    /// Routes through `dataWithFallback` (same as `/config`) so a user on a
    /// network where Cloudflare → primary host is blocked (RU LTE, throttled
    /// CDN edges) can still refresh their access token via a direct backend
    /// IP. Previously this used only `session.data(for:)`, so a primary-host
    /// outage silently fell through to `reRegisterDevice()` and the user
    /// lost their subscription tier by getting a fresh anonymous account.
    func refreshAccessToken(_ refreshToken: String) async throws -> RefreshResult {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/refresh") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 10

        // Audit H-001/H-002: refresh_token in request body, access_token
        // in response. No HTTP:80 leg, no direct-IP TLS leg.
        let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request), sensitive: true)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.unauthorized
        }
        // Parsing is a pure helper (testability extract, mirrors raceLegPlan):
        // it surfaces the ROTATED refresh_token so the caller can persist it.
        guard let result = Self.parseRefreshResponse(data, sentRefreshToken: refreshToken) else {
            throw APIError.unauthorized
        }
        return result
    }

    /// Parse a successful `/api/mobile/auth/refresh` body. Pure + static so the
    /// rotation invariant is unit-testable without a live backend.
    ///
    /// The backend rotates the refresh token, so the response's `refresh_token`
    /// MUST win over the one we sent. If the backend omits it (older server),
    /// fall back to `sentRefreshToken` so the caller never persists an empty
    /// string. Returns nil iff `access_token` is missing (→ treat as 401).
    static func parseRefreshResponse(_ data: Data, sentRefreshToken: String) -> RefreshResult? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["access_token"] as? String else {
            return nil
        }
        let rotated = (json["refresh_token"] as? String) ?? sentRefreshToken
        let expiresAt = (json["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let subExpiry = (json["subscription_expiry"] as? NSNumber)?.int64Value
        return RefreshResult(accessToken: token, refreshToken: rotated, expiresAt: expiresAt, subscriptionExpiry: subExpiry)
    }

    // MARK: - Support chat

    /// POST a support message AS THE USER — used by the in-chat "send diagnostic"
    /// button (the widget normally does this from JS; the native button needs its
    /// own path to attach device/VPN state the webview can't see). Single request
    /// to the non-CF api host — NO direct-IP fallback race (a POST must not
    /// double-send).
    func sendSupportMessage(text: String, accessToken: String) async throws {
        guard let url = URL(string: AppConstants.baseURL + "/api/v1/mobile/support/messages") else {
            throw APIError.networkError("Invalid support URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
    }

    /// Response of POST /support/attachments/presign.
    private struct SupportPresignResponse: Decodable {
        let uploadURL: String
        let key: String
        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case key
        }
    }

    /// POST a support message AS THE USER WITH AN ATTACHMENT — used by the
    /// "Отправить лог" button to ship the real singbox.log (the diagnostic
    /// snapshot rides as the message body). Three steps, mirroring the web
    /// widget's sendAttachment:
    ///   1. presign a short-lived B2 PUT URL (Bearer-auth, our api host),
    ///   2. PUT the raw bytes straight to B2 — a CLEAN request with only
    ///      Content-Type (the signature is in the URL; adding Authorization /
    ///      telemetry headers is unnecessary and risks the SigV4 host match),
    ///   3. POST the message referencing the uploaded key.
    /// Single request each to the non-CF api host — NO direct-IP fallback race
    /// (a POST must not double-send).
    func sendSupportAttachment(
        text: String,
        fileData: Data,
        filename: String,
        mime: String,
        accessToken: String
    ) async throws {
        // 1. presign
        guard let presignURL = URL(string: AppConstants.baseURL + "/api/v1/mobile/support/attachments/presign") else {
            throw APIError.networkError("Invalid support URL")
        }
        var presignReq = URLRequest(url: presignURL)
        presignReq.httpMethod = "POST"
        presignReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        presignReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        presignReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "filename": filename, "mime": mime, "size": fileData.count,
        ])
        presignReq.timeoutInterval = 15
        let (presignData, presignResp) = try await URLSession.shared.data(for: applyTelemetry(to: presignReq))
        guard let presignHTTP = presignResp as? HTTPURLResponse else { throw APIError.networkError("No response") }
        if presignHTTP.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(presignHTTP.statusCode) else { throw APIError.serverError(presignHTTP.statusCode) }
        let presign = try JSONDecoder().decode(SupportPresignResponse.self, from: presignData)

        // 2. PUT raw bytes to B2 (presigned — clean request, no auth/telemetry)
        guard let putURL = URL(string: presign.uploadURL) else { throw APIError.networkError("Invalid upload URL") }
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        putReq.setValue(mime, forHTTPHeaderField: "Content-Type")
        putReq.httpBody = fileData
        putReq.timeoutInterval = 30
        let (_, putResp) = try await URLSession.shared.data(for: putReq)
        guard let putHTTP = putResp as? HTTPURLResponse, (200...299).contains(putHTTP.statusCode) else {
            throw APIError.networkError("Upload failed")
        }

        // 3. POST the message referencing the uploaded key
        guard let msgURL = URL(string: AppConstants.baseURL + "/api/v1/mobile/support/messages") else {
            throw APIError.networkError("Invalid support URL")
        }
        var msgReq = URLRequest(url: msgURL)
        msgReq.httpMethod = "POST"
        msgReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        msgReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        msgReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "attachment_key": presign.key,
            "attachment_mime": mime,
            "attachment_name": filename,
            "attachment_size": fileData.count,
        ])
        msgReq.timeoutInterval = 15
        let (_, msgResp) = try await URLSession.shared.data(for: applyTelemetry(to: msgReq))
        guard let msgHTTP = msgResp as? HTTPURLResponse else { throw APIError.networkError("No response") }
        if msgHTTP.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(msgHTTP.statusCode) else { throw APIError.serverError(msgHTTP.statusCode) }
    }

    // MARK: - Push Notifications

    /// Register the APNs device token with the backend (SUPPORT-CHAT P4) so it
    /// can push "support reply" notifications. Mirrors `sendSupportMessage`:
    /// single request to the non-CF api host — NO direct-IP fallback race (a
    /// POST must not double-send), Bearer-authenticated, 15s timeout, 2xx = OK.
    /// `token` is the hex-encoded APNs device token.
    func registerPushToken(_ token: String, accessToken: String) async throws {
        guard let url = URL(string: AppConstants.baseURL + "/api/v1/mobile/push/register") else {
            throw APIError.networkError("Invalid push URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "platform": "ios"])
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
    }

    // MARK: - In-app announcements (INAPP-ANNOUNCEMENTS)

    /// Fetch the announcements currently in their show-window. Best-effort, read
    /// only — single request to the non-CF api host (no fallback race needed).
    func fetchActiveAnnouncements(accessToken: String) async throws -> [Announcement] {
        guard let url = URL(string: AppConstants.baseURL + "/api/v1/mobile/announcements/active") else {
            throw APIError.networkError("Invalid announcements URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse else { throw APIError.networkError("No response") }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.serverError(http.statusCode) }

        struct Resp: Decodable { let announcements: [Announcement] }
        return try JSONDecoder().decode(Resp.self, from: data).announcements
    }

    // MARK: - Subscription Verification

    /// Result of POST /api/mobile/subscription/verify.
    struct SubscriptionVerification: Decodable {
        let status: String
        let productId: String
        let subscriptionExpiry: Int64
        let alreadyApplied: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case productId = "product_id"
            case subscriptionExpiry = "subscription_expiry"
            case alreadyApplied = "already_applied"
        }
    }

    // MARK: - User Preferences

    /// Persist the user's chosen UI theme server-side (analytics + cross-device).
    /// Device is the source of truth — this is best-effort and errors are ignored
    /// by callers. Requires a valid access token.
    /// Permanently deactivate the authenticated user account.
    /// Required by App Store Review 5.1.1(v). Server returns 204 on success.
    func deleteAccount(accessToken: String) async throws {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/user") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 204 || http.statusCode == 200 else {
            throw APIError.serverError(http.statusCode)
        }
    }

    // MARK: - FreeKassa Payments

    /// A plan returned by GET /api/mobile/plans.
    struct PaymentPlan: Decodable, Identifiable {
        let id: String
        let title: String
        let days: Int
        let priceRub: Int
        let badge: String?

        enum CodingKeys: String, CodingKey {
            case id, title, days, badge
            case priceRub = "price_rub"
        }
    }

    struct PaymentPlansResponse: Decodable {
        let plans: [PaymentPlan]
        let methods: [String]
        let currency: String
    }

    struct PaymentInitiateResult: Decodable {
        let paymentId: String
        let paymentURL: String
        let amount: Int
        let currency: String
        let days: Int

        enum CodingKeys: String, CodingKey {
            case amount, currency, days
            case paymentId = "payment_id"
            case paymentURL = "payment_url"
        }
    }

    struct PaymentStatus: Decodable {
        let status: String // "pending" | "completed"
        let subscriptionExpiry: Int64?

        enum CodingKeys: String, CodingKey {
            case status
            case subscriptionExpiry = "subscription_expiry"
        }
    }

    /// Fetch the paywall catalog. No auth required.
    func fetchPlans() async throws -> PaymentPlansResponse {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/plans") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(PaymentPlansResponse.self, from: data)
    }

    /// Start a FreeKassa order. Returns a payment URL the app should open in
    /// external Safari so Apple treats it as "user visited a website".
    func initiatePayment(plan: String, method: String, email: String, accessToken: String) async throws -> PaymentInitiateResult {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/payment/initiate") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "plan": plan,
            "method": method,
            "email": email,
        ])
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else {
            throw APIError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(PaymentInitiateResult.self, from: data)
    }

    /// Check whether the FreeKassa webhook has already credited this order.
    func paymentStatus(paymentId: String, accessToken: String) async throws -> PaymentStatus {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/payment/status/\(paymentId)") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else {
            throw APIError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(PaymentStatus.self, from: data)
    }

    /// Send a StoreKit 2 signed JWS to the backend for verification and crediting.
    /// The backend validates the JWS chain against Apple's root CA and extends
    /// the user's subscription. Idempotent on originalTransactionId, so retries
    /// from spotty networks are safe.
    func verifySubscription(signedJWS: String, accessToken: String) async throws -> SubscriptionVerification {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/subscription/verify") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["signed_transaction": signedJWS])
        request.timeoutInterval = 20

        do {
            // Audit H-001/H-002: signed JWS payload from StoreKit + access
            // token in Bearer header. Sensitive — no HTTP:80, no direct-IP TLS.
            let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request), sensitive: true)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.networkError("No response")
            }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 else {
                throw APIError.serverError(http.statusCode)
            }
            return try JSONDecoder().decode(SubscriptionVerification.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    /// Send a one-line diagnostic event to the backend so ops can see
    /// when a country / SPB relay started failing for real users. The
    /// backend appends to a file log, no PII is sent — just the event,
    /// the failed country tag, the leaf tags that were tried, and a
    /// rough network type label.
    ///
    /// Best-effort: any error (network, server, auth) is swallowed.
    /// Build-33 fallback decisions never block on telemetry.
    func reportDiagnostic(
        event: String,
        country: String,
        deadLeaves: [String],
        networkType: String,
        accessToken: String?
    ) async throws {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/diagnostic") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "event": event,
            "country": country,
            "dead_leaves": deadLeaves,
            "network_type": networkType,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Fire and forget — even a 401 here is fine, server can log
        // unauthenticated diagnostics if it wants. Caller never throws.
        _ = try? await URLSession.shared.data(for: applyTelemetry(to: request))
    }

    /// POST /api/v1/mobile/events/batch — drain the EventTracker queue.
    ///
    /// USR-09 Phase 2 (2026-05-28). The body shape mirrors what the Go
    /// `eventBatchRequest` expects:
    ///
    ///     { "events": [
    ///         { "name": "paywall.view",
    ///           "occurred_at": "2026-05-28T00:00:00Z",
    ///           "properties": { ... },
    ///           "device_id": "iPhone14,7" } ] }
    ///
    /// Returns the number of rows the server reports as accepted.
    /// `-1` is returned when the call failed outright (network error or
    /// non-2xx) — the tracker uses that signal to keep the batch in its
    /// in-memory queue for the next flush.
    ///
    /// Auth required: the endpoint is JWT-gated. Without a token we
    /// simply skip; pre-signup analytics will need a separate endpoint
    /// when there are pre-signup events to send (none today).
    func sendEventBatch(
        _ events: [[String: Any]],
        accessToken: String?,
        appVersion: String,
        platform: String,
        deviceID: String?
    ) async -> Int {
        guard !events.isEmpty else { return 0 }
        guard let token = accessToken, !token.isEmpty else { return -1 }
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/events/batch") else {
            return -1
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(platform, forHTTPHeaderField: "X-Platform")
        if let deviceID, !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-Model")
        }

        let payload: [String: Any] = ["events": events]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return -1
        }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: applyTelemetry(to: request))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return -1
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accepted = obj["accepted"] as? Int {
                return accepted
            }
            // 2xx with unparseable body — treat as "server received it"
            // so the queue drains. iOS keeps no copy; the server log is
            // the source of truth.
            return events.count
        } catch {
            return -1
        }
    }
}

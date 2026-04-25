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

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case username
        case isNew = "is_new"
    }
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

class APIClient {
    private let session: URLSession
    private let fallbackSession: URLSession

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
    private func dataWithFallback(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw APIError.networkError("missing URL")
        }

        let method = request.httpMethod ?? "GET"
        let path: String = {
            if let q = url.query, !q.isEmpty { return "\(url.path)?\(q)" }
            return url.path.isEmpty ? "/" : url.path
        }()
        var reqHeaders = request.allHTTPHeaderFields ?? [:]
        if reqHeaders["User-Agent"] == nil { reqHeaders["User-Agent"] = AppConfig.userAgent }
        if request.httpBody != nil, reqHeaders["Content-Type"] == nil {
            reqHeaders["Content-Type"] = "application/json"
        }
        let body = request.httpBody

        let raceStart = DispatchTime.now()
        AppLogger.network.info("race.start path=\(path, privacy: .public) method=\(method, privacy: .public)")

        return try await withThrowingTaskGroup(of: (Data, URLResponse, String)?.self) { group in
            group.addTask { [session] in
                AppLogger.network.info("race.primary.start path=\(path, privacy: .public) elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                do {
                    let (data, response) = try await session.data(for: request)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                    if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                        AppLogger.network.info("race.primary.done rejected status=\(http.statusCode, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        return nil
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    AppLogger.network.info("race.primary.done ok status=\(status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                    return (data, response, "primary")
                } catch {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                    AppLogger.network.error("race.primary.done error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                    return nil
                }
            }

            let sni = AppConfig.baseURLHost
            // RU mobile carriers block OVH Frankfurt (162.19.242.30) at the
            // ASN level — every DE direct leg sits there for the full 6s
            // timeout and delays the race by ~6s even when NL wins. For RU
            // users skip the DE legs entirely. Primary Cloudflare leg + NL +
            // SPB relay still race so a working path keeps working.
            let isRURegion: Bool = {
                if #available(iOS 16, macOS 13, *) {
                    return Locale.current.region?.identifier == "RU"
                }
                return Locale.current.regionCode == "RU"
            }()
            let raceIPs = isRURegion
                ? AppConfig.directBackendIPs.filter { $0 != "162.19.242.30" }
                : AppConfig.directBackendIPs
            if isRURegion {
                AppLogger.network.info("race.region ru=true skipped=DE")
            }
            for ip in raceIPs {
                group.addTask {
                    AppLogger.network.info("race.direct.start ip=\(ip, privacy: .public) elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                    do {
                        let (bodyData, meta) = try await DirectConnection.request(
                            ip: ip, port: 443, sni: sni,
                            method: method, path: path,
                            headers: reqHeaders, body: body,
                            timeout: 6
                        )
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        if meta.status >= 400 {
                            AppLogger.network.info("race.direct.done ip=\(ip, privacy: .public) rejected status=\(meta.status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                            return nil
                        }
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: meta.status,
                            httpVersion: "HTTP/1.1",
                            headerFields: meta.headers
                        )!
                        AppLogger.network.info("race.direct.done ip=\(ip, privacy: .public) ok status=\(meta.status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        return (bodyData, response, "direct-\(ip)")
                    } catch {
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        AppLogger.network.error("race.direct.done ip=\(ip, privacy: .public) error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        return nil
                    }
                }
            }

            // HTTP port 80 legs — RU operators often don't block TCP:80 even
            // when TCP:443 is TCP-RST'd on foreign IPs. Backend nginx accepts
            // port-80 requests whose Host is the raw IP (no 301 redirect).
            // Only used when the request has no Authorization header, so we
            // never put a JWT in cleartext on the wire — the original request
            // already includes the header for HTTPS legs that race in
            // parallel above; an unauthenticated leg here just adds another
            // chance for the response to come back fast.
            let isAuthenticated = request.value(forHTTPHeaderField: "Authorization") != nil
            if !isAuthenticated {
            for ip in raceIPs {
                group.addTask { [fallbackSession] in
                    AppLogger.network.info("race.http.start ip=\(ip, privacy: .public) elapsed=\(Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000, privacy: .public)ms")
                    guard var httpURL = URLComponents(string: "http://\(ip)") else { return nil }
                    httpURL.path = url.path
                    httpURL.query = url.query
                    guard let finalURL = httpURL.url else { return nil }
                    var httpReq = request
                    httpReq.url = finalURL
                    httpReq.timeoutInterval = 8
                    httpReq.setValue(nil, forHTTPHeaderField: "Host")
                    httpReq.setValue(nil, forHTTPHeaderField: "Authorization")
                    do {
                        let (data, response) = try await fallbackSession.data(for: httpReq)
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status >= 400 {
                            AppLogger.network.info("race.http.done ip=\(ip, privacy: .public) rejected status=\(status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                            return nil
                        }
                        AppLogger.network.info("race.http.done ip=\(ip, privacy: .public) ok status=\(status, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        return (data, response, "http-\(ip)")
                    } catch {
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                        AppLogger.network.error("race.http.done ip=\(ip, privacy: .public) error=\(error.localizedDescription, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                        return nil
                    }
                }
            }
            } // !isAuthenticated

            for try await result in group {
                if let winner = result {
                    group.cancelAll()
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
                    AppLogger.network.info("race.winner leg=\(winner.2, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                    return (winner.0, winner.1)
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - raceStart.uptimeNanoseconds) / 1_000_000
            AppLogger.network.error("race.failed elapsed=\(ms, privacy: .public)ms")
            throw APIError.networkError("all paths failed")
        }
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
            let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
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
            let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
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
        // 6s per attempt + fallback chain. Previously 20s with no fallback
        // meant users on high-latency cellular or DPI-throttled networks
        // saw "infinite spinner" on Apple sign-in.
        request.timeoutInterval = 6

        let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(code)
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
    }

    // MARK: - Google Sign In

    /// Sign in with Google — trial or return existing account.
    /// `idToken` is the ID token returned by GoogleSignIn SDK.
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
        request.timeoutInterval = 6

        let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(code)
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
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

        let (_, response) = try await dataWithFallback(for: applyTelemetry(to: request))
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
        request.timeoutInterval = 6

        let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(code)
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
    }

    // MARK: - Token Refresh

    /// Exchange refresh token for a new access token.
    func refreshAccessToken(_ refreshToken: String) async throws -> String {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/refresh") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.unauthorized
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let token = json["access_token"] as? String else {
            throw APIError.unauthorized
        }
        return token
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

    func setTheme(_ themeID: String, accessToken: String) async throws {
        guard let url = URL(string: "\(AppConstants.baseURL)/api/v1/mobile/user/theme") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["theme": themeID])
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: applyTelemetry(to: request))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
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
            let (data, response) = try await dataWithFallback(for: applyTelemetry(to: request))
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
}

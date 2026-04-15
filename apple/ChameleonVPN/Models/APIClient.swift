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
        case .invalidCode: return "Неверный код активации"
        case .networkError(let msg): return "Ошибка сети: \(msg)"
        case .serverError(let code): return "Ошибка сервера: \(code)"
        case .noConfig: return "Пустой конфиг"
        case .unauthorized: return "Требуется авторизация"
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

/// Delegate that trusts all certificates for direct-IP and relay fallback paths.
/// This is intentional: when Cloudflare is blocked (e.g. in Russia), the app falls back
/// to direct IP or SPB relay which use self-signed or IP-based certificates.
/// Risk is mitigated by VLESS Reality encryption on the VPN tunnel itself.
private class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

class APIClient {
    private let session: URLSession
    private let fallbackSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)

        let fallbackConfig = URLSessionConfiguration.default
        fallbackConfig.timeoutIntervalForRequest = 5
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
        req.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-iOS-Version")
        #endif
        req.setValue(DeviceTelemetry.modelIdentifier, forHTTPHeaderField: "X-Device-Model")
        req.setValue(DeviceTelemetry.installDateISO, forHTTPHeaderField: "X-Install-Date")
        return req
    }

    /// Try primary URL, then Russian relay, then direct IP
    private func dataWithFallback(for request: URLRequest) async throws -> (Data, URLResponse) {
        // 1. Try primary (Cloudflare)
        do {
            return try await session.data(for: request)
        } catch {
            guard let url = request.url else { throw error }
            let urlString = url.absoluteString

            // 2. Try Russian relay (SPB) — local traffic, less likely blocked
            if let relayURL = URL(string: urlString.replacingOccurrences(
                of: AppConfig.baseURL, with: AppConfig.russianRelayURL)) {
                var relayRequest = request
                relayRequest.url = relayURL
                relayRequest.timeoutInterval = 7
                if let result = try? await fallbackSession.data(for: relayRequest) {
                    return result
                }
            }

            // 3. Try direct IP (last resort)
            guard let ipURL = URL(string: urlString.replacingOccurrences(
                of: AppConfig.baseURL, with: AppConfig.fallbackBaseURL))
            else { throw error }
            var ipRequest = request
            ipRequest.url = ipURL
            ipRequest.timeoutInterval = 10
            return try await fallbackSession.data(for: ipRequest)
        }
    }

    // MARK: - Standalone Device Registration

    /// Register device for trial access.
    func registerDevice() async throws -> AuthResult {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        guard let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/register") else {
            throw APIError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["device_id": deviceId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

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
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
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

        let (data, response) = try await session.data(for: applyTelemetry(to: request))
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
}

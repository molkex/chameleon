import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
    let expire: Int?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case username
        case expire
        case status
    }
}

/// Delegate that trusts all certificates (for direct IP fallback)
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

        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["device_id": deviceId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await dataWithFallback(for: request)
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
        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["code": code]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
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
        var components = URLComponents(string: AppConstants.mobileConfigURL)!
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "mode", value: mode),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await dataWithFallback(for: request)
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
    func signInWithApple(identityToken: String, userIdentifier: String) async throws -> AuthResult {
        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/apple")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identity_token": identityToken,
            "user_identifier": userIdentifier,
        ])
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(code)
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
    }

    /// Sign in with Apple AND link to existing account via activation code.
    /// Used for "У меня есть код" flow: Apple proves identity, code finds the account.
    func signInWithAppleAndCode(identityToken: String, userIdentifier: String, code: String) async throws -> AuthResult {
        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/apple/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identity_token": identityToken,
            "user_identifier": userIdentifier,
            "code": code,
        ])
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 404 { throw APIError.invalidCode }
        guard http.statusCode == 200 else {
            throw APIError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
    }

    // MARK: - Token Refresh

    /// Exchange refresh token for a new access token.
    func refreshAccessToken(_ refreshToken: String) async throws -> String {
        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.unauthorized
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let token = json["access_token"] as? String else {
            throw APIError.unauthorized
        }
        return token
    }
}

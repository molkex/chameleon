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

class APIClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: CertificatePinner(), delegateQueue: nil)
    }

    // MARK: - Standalone Device Registration

    /// Register device for trial access (3 days, no Telegram needed).
    func registerDevice() async throws -> (username: String, expire: Int) {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["device_id": deviceId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw APIError.serverError(code)
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let username = json["username"] as? String else {
                throw APIError.noConfig
            }
            let expire = json["expire"] as? Int ?? 0
            return (username, expire)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Code Activation (from Telegram bot)

    /// Activate with code from Telegram bot (POST to /api/mobile/activate).
    func activateCode(_ code: String) async throws -> String {
        let url = URL(string: "\(AppConstants.baseURL)/api/mobile/activate")!
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
        var queryItems = [URLQueryItem(name: "mode", value: mode)]
        if !username.isEmpty {
            queryItems.append(URLQueryItem(name: "username", value: username))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        if let token = accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
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

    // MARK: - Support Chat

    /// Fetch support messages. Pass `beforeId` for pagination.
    func fetchSupportMessages(accessToken: String, beforeId: Int? = nil) async throws -> SupportMessagesResponse {
        var components = URLComponents(string: "\(AppConstants.baseURL)/api/mobile/support/messages")!
        if let beforeId {
            components.queryItems = [URLQueryItem(name: "before_id", value: "\(beforeId)")]
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else { throw APIError.serverError(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SupportMessagesResponse.self, from: data)
    }

    /// Send a support message (text and/or images). Images are sent as JPEG via multipart.
    func sendSupportMessage(accessToken: String, content: String?, images: [UIImage]) async throws -> SupportMessage {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(AppConstants.baseURL)/api/mobile/support/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        let crlf = "\r\n"

        // Append text content field if present
        if let content, !content.isEmpty {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"content\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(content.data(using: .utf8)!)
            body.append(crlf.data(using: .utf8)!)
        }

        // Append image fields
        for (index, image) in images.enumerated() {
            guard let jpegData = image.jpegData(compressionQuality: 0.7) else { continue }
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"images\"; filename=\"image_\(index).jpg\"\(crlf)".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(jpegData)
            body.append(crlf.data(using: .utf8)!)
        }

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw APIError.serverError(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SupportMessage.self, from: data)
    }

    /// Get count of unread messages from admin (for badge).
    func fetchSupportUnread(accessToken: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "\(AppConstants.baseURL)/api/mobile/support/unread")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else { throw APIError.serverError(http.statusCode) }

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return json["unread_count"] as? Int ?? 0
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

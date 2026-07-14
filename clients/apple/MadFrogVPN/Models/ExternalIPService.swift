import Foundation

/// Decoded response from `https://api.ipify.org?format=json` → `{"ip":"1.2.3.4"}`.
/// Extracted as a pure, dependency-free decoder so it's unit-testable without
/// any networking (see `Tests/UnitTests/ExternalIPServiceTests.swift`).
struct IPifyResponse: Decodable, Equatable {
    let ip: String

    /// Returns nil on any malformed/unexpected payload — callers treat that
    /// identically to a network failure (show "—", maybe retry once).
    static func decode(_ data: Data) -> IPifyResponse? {
        try? JSONDecoder().decode(IPifyResponse.self, from: data)
    }
}

/// Fetches the device's current VPN egress IP with ONE lightweight HTTP
/// request — no polling, no background timer. Home-STATS feature (2026-07-14):
/// the paying user has no way to see the VPN is actually doing anything, so
/// the home screen gets a compact ↑/↓ + IP strip. This service owns only the
/// IP half; live traffic totals are already pushed by the existing
/// `CommandClientWrapper` (see `ConnectionStatsFormatter.swift`).
///
/// Lifecycle is driven entirely by the caller's SwiftUI `.task(id:)` — see
/// `MainViewNeon.ipRefreshKey`. There is no internal `Timer`/retry-loop state:
/// `refresh()` does one attempt, one retry on failure, then gives up and
/// leaves `ip` as whatever it last successfully resolved to (nil if never).
/// Because `URLSession.data(for:)` honors Swift Task cancellation, tearing
/// down the SwiftUI task (app backgrounded, tunnel disconnected, server
/// changed) cleanly aborts any in-flight request — nothing leaks.
@MainActor
@Observable
final class ExternalIPService {
    private(set) var ip: String?

    /// Ephemeral session dedicated to this one-off lookup — no shared cookie
    /// jar / cache to keep around, no reuse across app launches needed.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = ExternalIPService.timeout
        config.timeoutIntervalForResource = ExternalIPService.timeout
        return URLSession(configuration: config)
    }()

    /// Project rule: every network call gets a timeout. 10s here per the
    /// HOME-STATS spec (this is a "nice to have" display, not gating).
    static let timeout: TimeInterval = 10
    private static let retryDelay: Duration = .seconds(1)
    private static let endpoint = URL(string: "https://api.ipify.org?format=json")!

    /// Clears the shown IP. Called when the tunnel disconnects or the app
    /// backgrounds so the row falls back to the "—" placeholder instead of
    /// showing a stale address from a previous session/server.
    func reset() {
        ip = nil
    }

    /// One attempt + at most one retry, then stop. Never retries forever.
    func refresh() async {
        if let result = await Self.fetchOnce(session: session) {
            ip = result
            return
        }
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: Self.retryDelay)
        guard !Task.isCancelled else { return }
        if let result = await Self.fetchOnce(session: session) {
            ip = result
        }
        // Second failure: leave `ip` as-is (nil on first-ever call) — the
        // UI shows "—" rather than looping forever.
    }

    private static func fetchOnce(session: URLSession) async -> String? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return decode(data)?.ip
        } catch {
            return nil
        }
    }

    /// Exposed for testing the parse step without hitting the network.
    static func decode(_ data: Data) -> IPifyResponse? {
        IPifyResponse.decode(data)
    }
}

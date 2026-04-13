import Foundation
import Network

/// Out-of-band latency prober for VPN servers.
///
/// Measures raw TCP handshake RTT (SYN → SYN-ACK → ACK) to each server's
/// host:port using `NWConnection`. This runs **outside** the VPN tunnel, so
/// values are available before the user ever connects, and reflect real
/// network distance rather than proxying overhead.
///
/// Results are cached by server tag. Callers observe `results` (on main actor)
/// and re-render when values change.
@MainActor
@Observable
final class PingService {
    /// Ping results keyed by ServerItem.tag. Value is RTT in milliseconds,
    /// or 0 if the probe failed / timed out.
    var results: [String: Int] = [:]

    /// True while at least one probe is in flight.
    var isProbing = false

    private let timeout: TimeInterval = 2.0
    private let cacheKey = "PingService.cache.v1"
    private let cacheTTL: TimeInterval = 10 * 60 // 10 minutes

    init() {
        loadCache()
    }

    /// Probe all given servers in parallel. Safe to call repeatedly; later
    /// calls overwrite earlier results for the same tag.
    func probe(_ servers: [ServerItem]) async {
        let targets = servers.filter { !$0.host.isEmpty && $0.port > 0 }
        guard !targets.isEmpty else { return }
        isProbing = true
        defer { isProbing = false }

        await withTaskGroup(of: (String, Int).self) { group in
            for server in targets {
                group.addTask { [timeout] in
                    let ms = await Self.measure(host: server.host, port: server.port, timeout: timeout)
                    return (server.tag, ms)
                }
            }
            for await (tag, ms) in group {
                // Preserve last-good value on transient failure so the UI
                // doesn't flicker back to "— мс" on a single dropped probe.
                if ms > 0 {
                    results[tag] = ms
                } else if results[tag] == nil {
                    results[tag] = 0
                }
            }
        }
        saveCache()
    }

    /// Latency for a given server tag, or 0 if not yet measured / failed.
    func latency(for tag: String) -> Int {
        results[tag] ?? 0
    }

    // MARK: - Persistence

    private struct CacheEntry: Codable {
        let ms: Int
        let ts: TimeInterval
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return }
        let cutoff = Date().timeIntervalSince1970 - cacheTTL
        var fresh: [String: Int] = [:]
        for (tag, entry) in decoded where entry.ts >= cutoff && entry.ms > 0 {
            fresh[tag] = entry.ms
        }
        results = fresh
    }

    private func saveCache() {
        let now = Date().timeIntervalSince1970
        let entries = results.compactMapValues { ms -> CacheEntry? in
            guard ms > 0 else { return nil }
            return CacheEntry(ms: ms, ts: now)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Probe implementation

    /// Measure TCP handshake RTT in milliseconds. Returns 0 on failure/timeout.
    ///
    /// We use `NWConnection` with a dedicated concurrent queue so many probes
    /// can run without blocking each other. The connection is torn down as
    /// soon as it transitions to `.ready` — we don't need to send any bytes.
    nonisolated private static func measure(host: String, port: Int, timeout: TimeInterval) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return 0 }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.other]

        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "ping.probe.\(host):\(port)")

        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let start = DispatchTime.now()
            let finished = ManagedAtomic(false)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.exchange(true) { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    let ms = Int(elapsed / 1_000_000)
                    connection.cancel()
                    cont.resume(returning: ms)
                case .failed, .cancelled:
                    if finished.exchange(true) { return }
                    connection.cancel()
                    cont.resume(returning: 0)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout watchdog.
            queue.asyncAfter(deadline: .now() + timeout) {
                if finished.exchange(true) { return }
                connection.cancel()
                cont.resume(returning: 0)
            }
        }
    }
}

/// Tiny atomic bool wrapper — avoids pulling in swift-atomics just for this.
/// Uses NSLock which is cheap and enough for single-flag coordination.
private final class ManagedAtomic {
    private var value: Bool
    private let lock = NSLock()
    init(_ initial: Bool) { self.value = initial }
    /// Set to true; returns the PREVIOUS value. If true, the caller should bail.
    func exchange(_ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}

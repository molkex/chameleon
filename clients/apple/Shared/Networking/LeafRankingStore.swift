import Foundation

/// Persisted measurement of a single leaf's TCP-probe latency. The measured
/// time is wall-clock (UTC); we use it to age-out stale entries via
/// `PathPicker.defaultCacheTTL`.
public struct LeafLatency: Codable, Sendable, Equatable {
    public let tag: String
    public let latencyMs: Int
    public let success: Bool
    public let measuredAt: Date

    public init(tag: String, latencyMs: Int, success: Bool, measuredAt: Date) {
        self.tag = tag
        self.latencyMs = latencyMs
        self.success = success
        self.measuredAt = measuredAt
    }
}

/// Persists per-leaf probe outcomes between launches. Keyed lookup, not a
/// running history — every probe overwrites the previous entry for that tag,
/// so reads return the most recent measurement only. This is intentional:
/// `PathPicker` is a "what's fastest right now?" engine, not an analytics
/// pipeline.
///
/// Storage backend is App Group `UserDefaults` so the value survives app
/// kills and is shared with the PacketTunnel extension. The extension's
/// `TunnelHealthMonitor` writes failures here when it detects a stalled
/// outbound — the next main-app launch sees the marker and avoids the dead
/// leaf via `cachedBestLeaf`. UserDefaults reads/writes are atomic per-key,
/// so cross-process access is safe; the type is intentionally not
/// `@MainActor` so the extension's stat-watchdog queue can write directly.
final class LeafRankingStore: @unchecked Sendable {

    /// Key under which the JSON-encoded `[LeafLatency]` is stored.
    static let storageKey = "pathPicker.leafRankings.v1"

    private let defaults: UserDefaults?
    private let storageKey: String

    /// Default initialiser uses the App Group container so the data is
    /// readable from any process that joins the group. Falls back to nil
    /// (every read returns []) if the entitlement is misconfigured —
    /// matches `ConfigStore`'s behaviour for the same failure.
    init(
        defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
        storageKey: String = LeafRankingStore.storageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Read all stored measurements. Empty list if nothing persisted yet
    /// or if decoding fails (we never throw on read — the cache is a hint,
    /// not a source of truth).
    func load() -> [LeafLatency] {
        guard let data = defaults?.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder.iso.decode([LeafLatency].self, from: data)) ?? []
    }

    /// Replace the persisted measurements with `rankings`. Overwrite, not
    /// merge — callers that want to retain prior state should `load()`,
    /// merge in memory, then `save()`.
    func save(_ rankings: [LeafLatency]) {
        guard let data = try? JSONEncoder.iso.encode(rankings) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    /// Upsert a single measurement. Existing entry for the same tag is
    /// replaced. Hot-path entry point used by `PathPicker.recordSuccess`
    /// / `recordFailure` and by the probe loop.
    func update(tag: String, latencyMs: Int, success: Bool, at date: Date) {
        var current = load()
        let entry = LeafLatency(tag: tag, latencyMs: latencyMs, success: success, measuredAt: date)
        if let idx = current.firstIndex(where: { $0.tag == tag }) {
            current[idx] = entry
        } else {
            current.append(entry)
        }
        save(current)
    }

    /// Drop every entry from the store. Wired into `ConfigStore.clear()` so
    /// signing out doesn't leave stale latencies that persist into a fresh
    /// account's connect flow.
    func clear() {
        defaults?.removeObject(forKey: storageKey)
    }
}

/// Shared ISO-8601 formatter with fractional seconds. Default
/// `JSONEncoder.dateEncodingStrategy.iso8601` truncates to whole seconds,
/// which is fine for `measuredAt` semantics in production but breaks unit
/// tests that round-trip sub-millisecond timestamps. Picking a custom
/// formatter once at init keeps encode/decode symmetric.
private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private extension JSONEncoder {
    /// Encoder used by `LeafRankingStore`. Pinned to ISO-8601 (with
    /// fractional seconds) so the JSON survives codec changes between
    /// Swift versions and is human-readable in `defaults read` dumps.
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            guard let date = isoFormatter.date(from: str) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(str)"
                )
            }
            return date
        }
        return d
    }()
}

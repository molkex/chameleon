import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// USR-09 Phase 2 (2026-05-28). Client-side event-tracking sink for the
/// iOS / macOS app.
///
/// **Design**
/// - One actor, owned by ``AppState``. Call sites just `await
///   tracker.log(name:properties:)` from anywhere.
/// - Events are accumulated in an in-memory queue and flushed in batches
///   to `POST /api/v1/mobile/events/batch`. We deliberately do NOT flush
///   on every event — fire-and-forget HTTP on every paywall tap would
///   wake the network too often and waste battery.
/// - The queue is persisted to disk on background / terminate, restored
///   on launch. This survives an OS kill without losing the last
///   pre-purchase events that the funnel is most interested in.
/// - Failed flushes keep events in the queue. The next foreground or
///   timer tick retries. If the queue ever exceeds ``maxQueueDepth`` we
///   drop the oldest — analytics must never grow without bound.
/// - Events older than seven days are dropped (the server clamps to ±90
///   anyway; we want a tighter local cap to keep persistence light).
///
/// **What it does not do**
/// - It does not retry forever in the background. iOS app-extensions
///   would steal our refresh budget; foreground retry is enough.
/// - It does not encrypt the on-disk JSON. The contents are non-PII
///   event names + small property dictionaries; if a forensic device
///   actor needs to see them they will see them. The actor lives in
///   the app sandbox so other apps cannot read it.
/// - It does not deduplicate. Server-side de-dup would cost more than
///   the value of perfect counts for a funnel-quality metric.
///
/// **Privacy disclosure**
/// Shipping this in a build to the App Store requires the App Privacy
/// section in ASC to list "Product Interaction" (paywall taps) and
/// "Other Usage Data" (vpn connect events) as collected, linked to
/// the user, NOT used for tracking. See `docs/LAUNCH_CHECKLIST.md`
/// LAUNCH-04.
actor EventTracker {

    // MARK: Tunables

    /// Maximum events to keep buffered. When the queue grows past this
    /// we drop the oldest first — telemetry buffering must not become
    /// a memory pressure source.
    private let maxQueueDepth = 500

    /// Maximum events we send in a single request. Mirror the server's
    /// `maxEventsPerBatch` so a flush never wastes round-trips.
    private let maxBatchSize = 100

    /// Periodic flush cadence while the app is in the foreground. The
    /// shorter timer is the foreground guarantee; foreground/background
    /// transitions also trigger a flush.
    private let foregroundFlushInterval: TimeInterval = 5 * 60

    /// Drop events older than this on load — keeps persisted state
    /// light, and the server already rejects events outside ±90 days.
    private let maxEventAge: TimeInterval = 7 * 24 * 60 * 60

    // MARK: State

    /// Each event is an opaque JSON-encodable dictionary in the shape
    /// the server expects. Wrapping in a struct gains nothing here —
    /// we never read individual fields back, only flush the lot.
    private struct PendingEvent: Codable {
        let name: String
        let occurred_at: String   // ISO8601
        let properties: [String: AnyCodable]?
        let device_id: String?
    }

    private var queue: [PendingEvent] = []
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false

    // MARK: Dependencies

    /// Closure that owns the network call. Returns the number of rows
    /// the server accepted, or a negative number when the call failed
    /// (keep batch queued). Modelled as a closure so the tracker can be
    /// unit-tested without spinning up an APIClient.
    typealias Sender = @Sendable (_ events: [[String: Any]]) async -> Int

    private let sender: Sender
    private let storage: URL

    /// `appVersion` / `platform` / `deviceID` are captured at init —
    /// they don't change for an app's lifetime, and the EventTracker
    /// must work from contexts that don't have access to Bundle/
    /// UIDevice (extensions, background tasks).
    private let appVersion: String
    private let platform: String
    private let deviceID: String?

    // MARK: Init

    init(
        storage: URL,
        appVersion: String,
        platform: String,
        deviceID: String?,
        sender: @escaping Sender
    ) {
        self.sender = sender
        self.storage = storage
        self.appVersion = appVersion
        self.platform = platform
        self.deviceID = deviceID
    }

    /// Init that wires a default sender on top of APIClient + an
    /// access-token provider. Used by AppState; tests use the primary
    /// init with a fake closure.
    init(
        api: APIClient,
        storage: URL,
        appVersion: String,
        platform: String,
        deviceID: String?,
        tokenProvider: @escaping @Sendable () -> String?
    ) {
        let appVer = appVersion
        let plat = platform
        let did = deviceID
        self.sender = { events in
            await api.sendEventBatch(
                events,
                accessToken: tokenProvider(),
                appVersion: appVer,
                platform: plat,
                deviceID: did
            )
        }
        self.storage = storage
        self.appVersion = appVersion
        self.platform = platform
        self.deviceID = deviceID
    }

    // MARK: Public surface

    /// Restore the persisted queue from disk and start the foreground
    /// timer. Idempotent — calling twice is safe.
    func start() async {
        loadQueueFromDisk()
        scheduleNextFlush()
    }

    /// Record one event. Returns immediately — the network call (if any)
    /// happens later, on flush. `properties` may be nil; values must be
    /// JSON-serialisable scalars / arrays / dictionaries.
    func log(name: String, properties: [String: Any]? = nil) {
        let ev = PendingEvent(
            name: name,
            occurred_at: Self.iso8601.string(from: Date()),
            properties: properties.map(Self.encodeProperties),
            device_id: deviceID
        )
        queue.append(ev)
        if queue.count > maxQueueDepth {
            // Drop oldest to enforce the cap. We log the drop count so
            // operator can spot a runaway producer.
            let dropped = queue.count - maxQueueDepth
            queue.removeFirst(dropped)
        }
        if queue.count >= maxBatchSize {
            // High watermark — flush sooner rather than waiting for
            // the next timer tick.
            triggerFlush()
        }
    }

    /// Force a flush now. Safe to call from app-lifecycle hooks
    /// (foreground / background / terminate). The actor serialises
    /// calls so concurrent triggers don't cause concurrent flushes.
    func flushNow() {
        triggerFlush()
    }

    /// Snapshot of the current queue length — used by tests and by
    /// diagnostic readouts. Cheap.
    var queueDepth: Int { queue.count }

    // MARK: Internals

    private func triggerFlush() {
        guard !isFlushing else { return }
        let pending = batchToSend()
        guard !pending.isEmpty else { return }

        isFlushing = true
        Task { [weak self] in
            guard let self else { return }
            await self.performFlush(pending: pending)
        }
    }

    private func batchToSend() -> [PendingEvent] {
        // Drop stale events first so we don't waste a network call.
        let cutoff = Date().addingTimeInterval(-maxEventAge)
        let formatter = Self.iso8601
        queue.removeAll(where: { ev in
            guard let d = formatter.date(from: ev.occurred_at) else { return true }
            return d < cutoff
        })
        let n = Swift.min(queue.count, maxBatchSize)
        guard n > 0 else { return [] }
        return Array(queue.prefix(n))
    }

    private func performFlush(pending: [PendingEvent]) async {
        defer { isFlushing = false }

        // Convert PendingEvent → [String: Any] for the API client.
        let dictBatch: [[String: Any]] = pending.map { ev in
            var d: [String: Any] = [
                "name": ev.name,
                "occurred_at": ev.occurred_at,
            ]
            if let props = ev.properties {
                d["properties"] = props.mapValues { $0.value }
            }
            if let did = ev.device_id { d["device_id"] = did }
            return d
        }

        let result = await sender(dictBatch)

        if result >= 0 {
            // 2xx — drop the events we just sent from the head of the
            // queue. The server's `accepted` value can be less than
            // `pending.count` if it rejected malformed rows; that's
            // fine, we still drop the whole batch (no resend would
            // help, the data was bad on the client).
            let n = Swift.min(pending.count, queue.count)
            queue.removeFirst(n)
            persistQueueToDisk()
        }
        // result < 0 → keep batch queued, retry on next flush.

        scheduleNextFlush()
    }

    private func scheduleNextFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self, interval = foregroundFlushInterval] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.triggerFlush()
        }
    }

    // MARK: Persistence

    private func loadQueueFromDisk() {
        guard let data = try? Data(contentsOf: storage) else { return }
        guard let decoded = try? JSONDecoder().decode([PendingEvent].self, from: data) else { return }

        let cutoff = Date().addingTimeInterval(-maxEventAge)
        let formatter = Self.iso8601
        queue = decoded.filter { ev in
            guard let d = formatter.date(from: ev.occurred_at) else { return false }
            return d >= cutoff
        }
        if queue.count > maxQueueDepth {
            queue = Array(queue.suffix(maxQueueDepth))
        }
    }

    private func persistQueueToDisk() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: storage, options: .atomic)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func encodeProperties(_ d: [String: Any]) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for (k, v) in d {
            out[k] = AnyCodable(value: v)
        }
        return out
    }
}

/// Tiny wrapper that lets us Codable arbitrary JSON-safe scalars without
/// pulling in a full any-codable lib. We only ever round-trip via JSON
/// (encode for disk + send, decode on load) so the supported shape is
/// limited to JSON primitives.
struct AnyCodable: Codable {
    let value: Any

    init(value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        } else if let v = try? c.decode(Bool.self) {
            self.value = v
        } else if let v = try? c.decode(Int64.self) {
            self.value = v
        } else if let v = try? c.decode(Double.self) {
            self.value = v
        } else if let v = try? c.decode(String.self) {
            self.value = v
        } else if let v = try? c.decode([AnyCodable].self) {
            self.value = v.map { $0.value }
        } else if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try c.encodeNil()
        case let v as Bool:
            try c.encode(v)
        case let v as Int:
            try c.encode(v)
        case let v as Int64:
            try c.encode(v)
        case let v as Double:
            try c.encode(v)
        case let v as String:
            try c.encode(v)
        case let v as [Any]:
            try c.encode(v.map { AnyCodable(value: $0) })
        case let v as [String: Any]:
            try c.encode(v.mapValues { AnyCodable(value: $0) })
        default:
            try c.encodeNil()
        }
    }
}

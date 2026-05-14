import Foundation

/// Pure decision core extracted from `PacketTunnel/RealTrafficStallDetector.swift`
/// so the branchy log-parsing + sliding-window + multi-criteria STALL
/// formula is unit-testable without the PacketTunnel extension target
/// (which the test target can't link). Every function/type here is a
/// behaviour-preserving extract: `RealTrafficStallDetector` keeps the
/// `DispatchQueue`, ring-buffer storage, cooldown/per-hour bookkeeping
/// and `onStall` callback, and just routes through these.
///
/// Detection formula (sliding window, applied per evaluation tick):
///
///     attempts        >= minAttempts
///     timeouts        >= minTimeouts
///     timeout_rate    >= minTimeoutRate
///     distinct_dests  >= minDistinctDestinations
///     no connection closed in window with downlink >= meaningfulDownloadBytes
///
/// All criteria must hold simultaneously.
enum RealTrafficStallLogic {

    // MARK: - Tunable thresholds

    /// The formula's numeric knobs. Mirrors the subset of
    /// `RealTrafficStallDetector.Config` the pure evaluation needs —
    /// cooldown / per-hour-cap / queue stay in the detector because they
    /// involve wall-clock side-state, not the per-tick decision.
    struct Thresholds: Equatable {
        var minAttempts: Int = 8
        var minTimeouts: Int = 5
        var minTimeoutRate: Double = 0.6
        var minDistinctDestinations: Int = 3
        var meaningfulDownloadBytes: Int64 = 4096
    }

    // MARK: - Parsed event

    /// One observation parsed from a sing-box log line. Primitive (no
    /// Libbox refs) so the detector's ring buffer doesn't pin Go memory.
    struct DialAttempt: Equatable {
        let timestamp: Date
        let outbound: String      // e.g. "de-direct-de"
        let destination: String   // host (port stripped)
        let isTimeout: Bool       // true = timeout / deadline / TLS handshake
    }

    /// A connection-close observation — only the downlink byte count
    /// matters for the meaningful-download suppressor.
    struct ConnectionClose: Equatable {
        let timestamp: Date
        let downloadBytes: Int64
    }

    // MARK: - Fast-path log classification

    /// Cheap substring test: does this message look like a real
    /// user-dial *failure* (timeout-bearing)? Mirrors the first
    /// `if` in `RealTrafficStallDetector.process`.
    static func isUserDialFailureLine(_ message: String) -> Bool {
        message.contains("connection: open connection to ") &&
            (message.contains(": i/o timeout") ||
             message.contains(": operation timed out") ||
             message.contains(": context deadline exceeded") ||
             message.contains(": TLS handshake timeout"))
    }

    /// Cheap substring test: does this message look like a successful
    /// outbound dial? Mirrors the second `if` in `process`.
    static func isDialSuccessLine(_ message: String) -> Bool {
        message.contains(": outbound connection to ")
    }

    // MARK: - Parsing

    /// Extract `(outbound, userDestination, isTimeout)` from a real
    /// user-dial-failure log message. Returns nil if the message isn't
    /// the right shape. Anchors on `using outbound/` and `open
    /// connection to ` string fragments — sing-box sprinkles ANSI
    /// escapes and connection-id markers with stray brackets, so the
    /// FIRST `[` is rarely the outbound tag's opening bracket.
    static func parseUserDialFailure(from message: String, at now: Date) -> DialAttempt? {
        guard let usingRange = message.range(of: "using outbound/") else { return nil }
        let afterUsing = message[usingRange.upperBound...]
        guard let bracketStart = afterUsing.firstIndex(of: "["),
              let bracketEnd = afterUsing[bracketStart...].firstIndex(of: "]"),
              bracketStart < bracketEnd else { return nil }
        let outbound = String(afterUsing[afterUsing.index(after: bracketStart)..<bracketEnd])

        var destination = ""
        if let toRange = message.range(of: "open connection to ") {
            let after = message[toRange.upperBound...]
            let hostPort = after.prefix { $0 != " " }
            if let lastColon = hostPort.lastIndex(of: ":") {
                destination = String(hostPort[..<lastColon])
            } else {
                destination = String(hostPort)
            }
        }

        let isTimeout = message.contains("i/o timeout") ||
            message.contains("operation timed out") ||
            message.contains("context deadline exceeded") ||
            message.contains("TLS handshake timeout")

        return DialAttempt(timestamp: now, outbound: outbound, destination: destination, isTimeout: isTimeout)
    }

    /// Extract `(outbound, destination)` from a successful dial log line.
    /// Marks `isTimeout = false`. Returns nil for `outbound/urltest[...]`
    /// lines — those are sing-box's own probe, not user traffic, and
    /// counting them would pad the failure-ratio denominator.
    static func parseDialSuccess(from message: String, at now: Date) -> DialAttempt? {
        guard let typeRange = message.range(of: "outbound/") else { return nil }
        let afterType = message[typeRange.upperBound...]
        guard let bracketStart = afterType.firstIndex(of: "["),
              let bracketEnd = afterType[bracketStart...].firstIndex(of: "]"),
              bracketStart < bracketEnd else { return nil }
        let outbound = String(afterType[afterType.index(after: bracketStart)..<bracketEnd])

        if message.contains("outbound/urltest[") {
            return nil
        }

        var destination = ""
        if let toRange = message.range(of: "outbound connection to ") {
            let after = message[toRange.upperBound...]
            let hostPort = after.prefix { $0 != " " && $0 != "\n" && $0 != "\t" }
            if let lastColon = hostPort.lastIndex(of: ":") {
                destination = String(hostPort[..<lastColon])
            } else {
                destination = String(hostPort)
            }
        }

        return DialAttempt(timestamp: now, outbound: outbound, destination: destination, isTimeout: false)
    }

    // MARK: - Sliding-window prune

    /// Drop events older than `windowSeconds` relative to `referenceDate`.
    /// Mirrors the `removeAll { $0.timestamp < cutoff }` the detector runs
    /// before every insert. Generic over the two event types via a
    /// timestamp accessor.
    static func pruned<T>(_ events: [T], windowSeconds: TimeInterval, referenceDate: Date, timestamp: (T) -> Date) -> [T] {
        let cutoff = referenceDate.addingTimeInterval(-windowSeconds)
        return events.filter { timestamp($0) >= cutoff }
    }

    // MARK: - Evaluation

    /// Why a STALL evaluation did or didn't fire — the exit reason of
    /// `RealTrafficStallDetector.evaluateIfDue`'s criteria chain.
    enum Decision: Equatable {
        case stall
        case notEnoughAttempts      // attempts < minAttempts
        case notEnoughTimeouts      // timeouts < minTimeouts
        case rateTooLow             // timeout_rate < minTimeoutRate
        case tooFewDistinctDests    // distinct dests < minDistinctDestinations
        case meaningfulDownload     // a close in window had downlink >= threshold
    }

    /// The per-tick STALL decision over an already-window-pruned event
    /// set. This is the exact criteria chain from `evaluateIfDue` after
    /// the cooldown / per-hour-cap guards (those stay in the detector —
    /// they mutate wall-clock side-state). Pure: same inputs → same
    /// `Decision`, every time.
    static func evaluate(
        recentDials: [DialAttempt],
        recentCloses: [ConnectionClose],
        thresholds: Thresholds
    ) -> Decision {
        let attempts = recentDials.count
        guard attempts >= thresholds.minAttempts else { return .notEnoughAttempts }

        let timeoutDials = recentDials.filter { $0.isTimeout }
        let timeouts = timeoutDials.count
        guard timeouts >= thresholds.minTimeouts else { return .notEnoughTimeouts }

        let rate = Double(timeouts) / Double(attempts)
        guard rate >= thresholds.minTimeoutRate else { return .rateTooLow }

        var distinctDests = Set<String>()
        for dial in timeoutDials where !dial.destination.isEmpty {
            distinctDests.insert(dial.destination)
        }
        guard distinctDests.count >= thresholds.minDistinctDestinations else { return .tooFewDistinctDests }

        let hasMeaningfulDownload = recentCloses.contains { $0.downloadBytes >= thresholds.meaningfulDownloadBytes }
        if hasMeaningfulDownload { return .meaningfulDownload }

        return .stall
    }
}

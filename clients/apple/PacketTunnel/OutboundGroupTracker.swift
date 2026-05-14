import Foundation
import Libbox

/// Long-lived LibboxCommandClient that subscribes to the outbound-group
/// feed (LibboxCommandGroup) and maintains a thread-safe snapshot of:
///
///   - which outbound is currently `selected` in each urltest/selector group
///   - the full member list per group (so the penalty-aware fallback can
///     pick an alternative without re-asking sing-box)
///
/// Phase 1.D (build 63+). The extension's previous fallback path used a
/// short-lived CommandClient that called `urlTest(group)` and disconnected
/// — it never received any `writeGroups` events because subscriptions
/// arrive asynchronously after `connect()`. The result was that on STALL
/// streak we'd re-probe every leaf equally; the throttled leaf passes
/// the small probe (DPI bulk-throttle signature only trips on real
/// flows) and gets re-elected within seconds.
///
/// With this tracker, the probe can:
///
///   1. Read the currently-active outbound for each group synchronously.
///   2. Mark it as penalised (OutboundPenaltyStore, 60 s window).
///   3. `selectOutbound(group, alternative)` to pin a non-penalised member,
///      bypassing urltest's small-probe re-election.
final class OutboundGroupTracker: @unchecked Sendable {

    /// Back-compat alias — the pure snapshot model now lives in
    /// `Shared/OutboundGroupLogic.swift` (so it's unit-testable without
    /// this PacketTunnel target).
    typealias Snapshot = OutboundGroupSnapshot.Group

    private let queue = DispatchQueue(label: "outbound.group.tracker", attributes: [])
    private var snapshot: OutboundGroupSnapshot = .empty    // groupTag → group

    private let handler: TrackerHandler
    private var client: LibboxCommandClient?

    init() {
        handler = TrackerHandler()
        handler.tracker = self
    }

    func start() {
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandGroup)
        // statusInterval is mandatory; we don't use the status stream but
        // setting it positive keeps the client happy. 5 s is the same as
        // the main app's CommandClientWrapper.
        options.statusInterval = Int64(NSEC_PER_SEC * 5)
        guard let c = LibboxNewCommandClient(handler, options) else {
            TunnelFileLogger.log("OutboundGroupTracker: LibboxNewCommandClient nil — fallback degrades to old nudge", category: "tunnel-probe")
            return
        }
        do {
            try c.connect()
            client = c
            TunnelFileLogger.log("OutboundGroupTracker: connected, subscribed to groups feed", category: "tunnel-probe")
        } catch {
            TunnelFileLogger.log("OutboundGroupTracker: connect failed (\(error.localizedDescription))", category: "tunnel-probe")
        }
    }

    func stop() {
        try? client?.disconnect()
        client = nil
        queue.sync { snapshot = .empty }
    }

    func selected(in groupTag: String) -> String? {
        queue.sync { snapshot.selected(in: groupTag) }
    }

    func members(in groupTag: String) -> [String] {
        queue.sync { snapshot.members(in: groupTag) }
    }

    /// Test/diagnostic accessor — full snapshot.
    func allGroups() -> [String: Snapshot] {
        queue.sync { snapshot.groups }
    }

    fileprivate func ingest(_ message: any LibboxOutboundGroupIteratorProtocol) {
        // Bridge the libbox iterator into plain primitives, then let the
        // pure `OutboundGroupSnapshot.build` do the transform.
        var rawGroups: [RawOutboundGroup] = []
        while message.hasNext() {
            guard let group = message.next() else { break }
            var members: [String] = []
            if let iter = group.getItems() {
                while iter.hasNext() {
                    if let item = iter.next() { members.append(item.tag) }
                }
            }
            rawGroups.append(RawOutboundGroup(tag: group.tag, selected: group.selected, members: members))
        }
        let fresh = OutboundGroupSnapshot.build(from: rawGroups)
        queue.sync { snapshot = fresh }
    }
}

// MARK: - LibboxCommandClient handler

private final class TrackerHandler: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
    weak var tracker: OutboundGroupTracker?

    // Only writeGroups is load-bearing — everything else is a stub.
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let message else { return }
        tracker?.ingest(message)
    }

    func connected() {}
    func disconnected(_ message: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func clearLogs() {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}
}

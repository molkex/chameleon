import Foundation
import Libbox

/// Nudges sing-box's urltest groups to re-probe immediately, on demand.
///
/// History: build-42 through build-44 grew this into a full periodic
/// stall-probe loop — a synthetic 32 KB GET to our own healthcheck
/// endpoint every 15 s, on its own ephemeral `URLSession`, meant to catch
/// RU LTE "handshake-OK-but-throttled" paths that sing-box's own
/// HEAD-based urltest missed. Build-44 already demoted it to a passive
/// diagnostic — `RealTrafficStallDetector` (parses real sing-box dial
/// timeouts) became the authoritative stall signal because the synthetic
/// probe gave false-OK readings while real user traffic was timing out.
///
/// MEM-01 (2026-07-15): the periodic loop is deleted outright. A device
/// log proved the extension gets jetsam-killed ~4 s after connect at
/// 41 MiB against the ~50 MiB NE hard limit — 8 MiB of headroom. The loop
/// created a brand-new ephemeral `URLSession` on every 15 s tick without
/// ever calling `finishTasksAndInvalidate`, so its native buffers
/// (invisible to the Go GC, fully counted in `phys_footprint`) grew
/// unbounded for as long as the tunnel stayed up — the prime "fine at
/// first, dies later" suspect. Nobody acted on its result once build-44
/// made it passive, so there was nothing left worth keeping.
///
/// What's left is the one thing that still matters:
/// `RealTrafficStallDetector.onStall` (wired in `ExtensionProvider`) wants
/// to force sing-box to re-probe every urltest group RIGHT NOW instead of
/// waiting for its next tick, so the new leg is live within 1-2 s even if
/// the main app is suspended. `nudgeNow()` is that call.
final class TunnelStallProbe {

    struct Config {
        /// Names of urltest groups to nudge via `LibboxCommandClient.urlTest`
        /// when a real stall fires. Sing-box's group tags are the
        /// human-facing labels we generate in
        /// `backend/internal/vpn/clientconfig.go`.
        ///
        /// Audit P1-1 (2026-05-26): "🇩🇪 Германия" hardcoded here used to be
        /// the leading entry; after DE retirement (2026-05-25) sing-box no
        /// longer emits that group, so `urlTest("🇩🇪 Германия")` returns a
        /// "group not found" error on every probe and pollutes the log. Now
        /// only "Auto" is always-present (top-level urltest).
        var urltestGroupTags: [String] = ["Auto"]
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// Build-49: called by RealTrafficStallDetector's onStall so the extension
    /// can switch outbounds without waiting for the suspended main app.
    func nudgeNow() {
        nudgeUrltestGroups()
    }

    /// Force sing-box to re-probe every urltest group immediately. Best
    /// effort: failures are logged but don't block the caller.
    /// Implementation intentionally creates a short-lived CommandClient
    /// each time — the connection lives <1s.
    private func nudgeUrltestGroups() {
        let handler = NudgeHandler()
        let options = LibboxCommandClientOptions()
        options.statusInterval = Int64(NSEC_PER_SEC)

        guard let client = LibboxNewCommandClient(handler, options) else {
            TunnelFileLogger.log("TunnelStallProbe: nudge skipped — LibboxNewCommandClient nil", category: "tunnel-probe")
            return
        }

        do {
            try client.connect()
        } catch {
            TunnelFileLogger.log("TunnelStallProbe: nudge connect failed (\(error.localizedDescription))", category: "tunnel-probe")
            return
        }

        defer { try? client.disconnect() }

        for group in config.urltestGroupTags {
            do {
                try client.urlTest(group)
                TunnelFileLogger.log("TunnelStallProbe: urlTest('\(group)') OK", category: "tunnel-probe")
            } catch {
                TunnelFileLogger.log("TunnelStallProbe: urlTest('\(group)') FAILED \(error.localizedDescription)", category: "tunnel-probe")
            }
        }

        // Build-42: removed `client.closeConnections()` here. Field log
        // 2026-04-27 12:20 showed it killed working NL traffic after the
        // build-41 outer urltest correctly fell back to `_nl_leaves`,
        // causing a self-inflicted ~53 s blackout. The build-40
        // `interrupt_exist_connections=true` flag on every urltest +
        // selector already does surgical cleanup whenever sing-box
        // re-elects an outbound, so the global close was redundant on
        // top of being destructive.
    }
}

// MARK: - LibboxCommandClient handler stub

/// Minimal LibboxCommandClientHandlerProtocol implementation — the nudge
/// flow only calls send-side commands (`urlTest`) and disconnects, so we
/// don't need to react to any server callbacks.
private final class NudgeHandler: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
    func connected() {}
    func disconnected(_ message: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func clearLogs() {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {}
}

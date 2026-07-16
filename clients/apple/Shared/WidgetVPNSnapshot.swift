import Foundation

/// launch-04: the VPN-status snapshot the Home/Lock-Screen widget reads.
///
/// The widget extension and the main app can't share live object state —
/// they're separate processes. They DO share the App Group container, and
/// `handleStatus()` already maintains the two keys we need there:
///   - vpnConnectedAtKey   — set on .connected, removed on .disconnected
///   - selectedServerTagKey — the user's chosen server / "Auto"
/// So the widget reads status with zero new write-path code; the app just
/// has to call `WidgetCenter.reloadAllTimelines()` on status change so the
/// timeline refreshes promptly.
///
/// This type is the single agreed reader, included in both the app target
/// (so a unit test can exercise it) and the widget target.
struct WidgetVPNSnapshot: Equatable {
    let connected: Bool
    /// WIDGET-CONNECTING (2026-07-16): true while a connect attempt is in
    /// flight — distinct from `connected` so the widget can show an honest
    /// "connecting…" state instead of silently doing nothing for however
    /// long the real connect takes. Never true when `connected` is true
    /// (see `read()`) — `connected` always wins, and this can NEVER be used
    /// to claim protection, only "something is happening."
    let connecting: Bool
    /// User-facing server label, e.g. "Auto" / "🇩🇪 Германия". nil when the
    /// user has never picked one (fresh install).
    let serverName: String?
    /// When the tunnel came up — the `vpnConnectedAtKey` timestamp. nil
    /// when disconnected. The widget renders this as a live-updating
    /// uptime via `Text(_, style: .timer)`, which ticks without any
    /// timeline reload.
    let connectedAt: Date?
    /// When the in-flight connect attempt was requested — the
    /// `vpnConnectingAtKey` timestamp. nil unless `connecting` is true.
    let connectingAt: Date?

    init(connected: Bool, serverName: String?, connectedAt: Date? = nil,
         connecting: Bool = false, connectingAt: Date? = nil) {
        self.connected = connected
        self.serverName = serverName
        self.connectedAt = connectedAt
        self.connecting = connecting
        self.connectingAt = connectingAt
    }

    /// Write the connected/disconnected signal into the App Group — the
    /// inverse of `read()`. Both `ExtensionProvider.publishWidgetState`
    /// (the source of truth) and `ToggleVPNIntent` (the optimistic
    /// instant-feedback write) go through here, so the key semantics —
    /// a timestamp on connect, key removed on disconnect — live in ONE
    /// place. No-op when the App Group is unreachable.
    static func write(connected: Bool, to defaults: UserDefaults?) {
        guard let defaults else { return }
        if connected {
            // Idempotent: keep the existing "session start" timestamp across
            // TRANSPARENT tunnel restarts (On-Demand reconnect, extension
            // jetsam-relaunch, a re-published .connected). publishWidgetState
            // runs inside startTunnel, which re-fires on those events — and the
            // old unconditional `set(now)` reset the widget's "Защищено X" back
            // to ~0 while the app's in-memory timer (guarded by `vpnConnectedAt
            // == nil`) kept the true value, so the app showed 19:27:21 and the
            // widget showed 0:12 (user-reported 2026-06-03). Only stamp on the
            // FIRST connect of a session; `false` (real disconnect) clears it,
            // so the next genuine connect stamps fresh.
            if defaults.double(forKey: AppConstants.vpnConnectedAtKey) <= 0 {
                defaults.set(Date().timeIntervalSince1970, forKey: AppConstants.vpnConnectedAtKey)
            }
        } else {
            defaults.removeObject(forKey: AppConstants.vpnConnectedAtKey)
        }
        // WIDGET-CONNECTING: every definitive outcome — connected OR really
        // disconnected — clears the in-flight flag. Both callers of write()
        // (ExtensionProvider.publishWidgetState, the optimistic-stop path)
        // now clear it for free; see AppState.handleStatus() for the third
        // writer that stamps vpnConnectedAtKey directly and clears this too.
        defaults.removeObject(forKey: AppConstants.vpnConnectingAtKey)
    }

    /// WIDGET-CONNECTING: stamp "a connect attempt is in flight right now."
    /// Called by the widget/Control-Center intent immediately before
    /// `session.startTunnel`, so the widget can show "connecting…" instead
    /// of dead air. Deliberately separate from `write(connected:)` — this
    /// never claims protection, only "something is happening," so it's safe
    /// to write from a process (the widget extension) that can't observe
    /// whether the attempt ultimately succeeds. See `read()` for the 30s
    /// self-expiry that makes this safe even if nothing ever clears it.
    static func writeConnecting(to defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: AppConstants.vpnConnectingAtKey)
    }

    /// Pure decision extracted for testability: is a "connecting" timestamp
    /// still within its 30s self-expiry window? `timestamp <= 0` means the
    /// key was never set (or was cleared) — never fresh. Matches
    /// `VPNManager.waitUntilConnected`'s in-app connect timeout.
    static func isConnectingFlagFresh(timestamp: Double, now: Date) -> Bool {
        guard timestamp > 0 else { return false }
        return now.timeIntervalSince1970 - timestamp < 30
    }

    /// Read the current snapshot from the App Group. Returns a
    /// disconnected snapshot if the App Group is unreachable — a widget
    /// must never crash, "disconnected" is the safe default to show.
    static func read() -> WidgetVPNSnapshot {
        guard let d = UserDefaults(suiteName: AppConstants.appGroupID) else {
            return WidgetVPNSnapshot(connected: false, serverName: nil)
        }
        // vpnConnectedAtKey is the connected/disconnected signal:
        // handleStatus() / ExtensionProvider.publishWidgetState() stamp
        // it on connect, clear it on disconnect. Presence + >0 == connected.
        let ts = d.double(forKey: AppConstants.vpnConnectedAtKey)
        let server = d.string(forKey: AppConstants.selectedServerTagKey)
        let connected = ts > 0

        // WIDGET-CONNECTING: honest "in flight" state, self-expiring at 30s
        // (matches VPNManager.waitUntilConnected's in-app connect timeout —
        // see CLAUDE.md: "если статус не connected за 30 секунд →
        // disconnect + показать ошибку"). The expiry lives HERE, in the
        // reader, not in whoever clears the key — a widget extension can't
        // run a background timer, so the flag must self-heal to "off" on
        // its own next render even if nothing ever clears it (extension
        // crash, jetsam kill mid-connect, etc.). `connected` always wins:
        // a stale connecting flag must never mask a real connected state.
        let connectingTs = d.double(forKey: AppConstants.vpnConnectingAtKey)
        let connecting = !connected && isConnectingFlagFresh(timestamp: connectingTs, now: Date())

        return WidgetVPNSnapshot(
            connected: connected,
            serverName: server,
            connectedAt: connected ? Date(timeIntervalSince1970: ts) : nil,
            connecting: connecting,
            connectingAt: connecting ? Date(timeIntervalSince1970: connectingTs) : nil
        )
    }

    /// Localised status line. The widget target doesn't carry the app's
    /// Localizable.strings (keeping the new target lean), so the two
    /// strings it needs are resolved here against the current locale.
    var statusText: String {
        let isRU = Locale.current.language.languageCode?.identifier == "ru"
        if connected {
            return isRU ? "Защищено" : "Protected"
        }
        if connecting {
            return isRU ? "Подключение…" : "Connecting…"
        }
        return isRU ? "Не защищено" : "Not protected"
    }

    /// Fallback server label when none is stored yet.
    var serverDisplay: String {
        if let serverName, !serverName.isEmpty { return serverName }
        let isRU = Locale.current.language.languageCode?.identifier == "ru"
        return isRU ? "Авто" : "Auto"
    }
}

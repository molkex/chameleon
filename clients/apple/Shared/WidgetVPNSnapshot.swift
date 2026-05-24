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
    /// User-facing server label, e.g. "Auto" / "🇩🇪 Германия". nil when the
    /// user has never picked one (fresh install).
    let serverName: String?
    /// When the tunnel came up — the `vpnConnectedAtKey` timestamp. nil
    /// when disconnected. The widget renders this as a live-updating
    /// uptime via `Text(_, style: .timer)`, which ticks without any
    /// timeline reload.
    let connectedAt: Date?

    init(connected: Bool, serverName: String?, connectedAt: Date? = nil) {
        self.connected = connected
        self.serverName = serverName
        self.connectedAt = connectedAt
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
            defaults.set(Date().timeIntervalSince1970, forKey: AppConstants.vpnConnectedAtKey)
        } else {
            defaults.removeObject(forKey: AppConstants.vpnConnectedAtKey)
        }
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
        return WidgetVPNSnapshot(
            connected: ts > 0,
            serverName: server,
            connectedAt: ts > 0 ? Date(timeIntervalSince1970: ts) : nil
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
        return isRU ? "Не защищено" : "Not protected"
    }

    /// Fallback server label when none is stored yet.
    var serverDisplay: String {
        if let serverName, !serverName.isEmpty { return serverName }
        let isRU = Locale.current.language.languageCode?.identifier == "ru"
        return isRU ? "Авто" : "Auto"
    }
}

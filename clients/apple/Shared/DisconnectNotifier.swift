import Foundation
import NetworkExtension
import UserNotifications

/// launch-07: tell the user when the VPN tunnel drops *unexpectedly*.
///
/// For a VPN a silent disconnect is a safety bug, not a UX nicety — the
/// user keeps browsing believing they're protected when they aren't.
///
/// Two sides, one file because the content/policy is shared:
///   - `requestAuthorizationIfNeeded()` — MAIN APP. Asks for notification
///     permission exactly once, after the first successful connect (not at
///     cold launch — asking before the user has seen any value is poor UX
///     and tanks the grant rate).
///   - `postUnexpectedDisconnect(reason:)` — EXTENSION. Called from
///     `stopTunnel(with:)`. Maps `NEProviderStopReason` to "was this an
///     unexpected loss of protection?" and posts a banner if so.
///
/// Until launch-07, the app never called `requestAuthorization` at all —
/// so even the pre-existing stall banner silently no-op'd. This fixes that
/// too.
enum DisconnectNotifier {

    // MARK: - Main app: permission

    /// Request notification authorization once. Idempotent via a
    /// UserDefaults guard — safe to call on every `.connected` transition.
    /// Best-effort: a denied prompt is fine, we just won't post banners.
    static func requestAuthorizationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppConstants.didRequestNotificationAuthKey) else {
            return
        }
        defaults.set(true, forKey: AppConstants.didRequestNotificationAuthKey)
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                TunnelFileLogger.log("DisconnectNotifier: auth request error — \(error.localizedDescription)", category: "ui")
            } else {
                TunnelFileLogger.log("DisconnectNotifier: notification auth granted=\(granted)", category: "ui")
            }
        }
    }

    // MARK: - Extension: posting

    /// Post an "unexpected disconnect" banner if `reason` represents a loss
    /// of protection the user did NOT ask for. No-op for user-initiated /
    /// expected stops. Called from `ExtensionProvider.stopTunnel(with:)`.
    ///
    /// Note: a hard jetsam SIGKILL never calls `stopTunnel`, so that path
    /// isn't covered here — the main app catching `.disconnected` on next
    /// foreground would be the place for it (separate follow-up).
    static func postUnexpectedDisconnect(reason: NEProviderStopReason) {
        guard let body = unexpectedBody(for: reason) else {
            // Expected stop (user tapped disconnect, config disabled, sleep,
            // app update, …) — say nothing.
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "MadFrog VPN"
        content.body = body
        content.sound = .default
        // .active: surface it promptly — the user is currently unprotected.
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: AppConstants.disconnectNotificationID,
            content: content,
            trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(
            withIdentifiers: [AppConstants.disconnectNotificationID]
        )
        center.add(request)
        TunnelFileLogger.log("DisconnectNotifier: posted unexpected-disconnect banner (reason=\(reason.rawValue))", category: "ui")
    }

    /// Returns the user-facing body for reasons that mean "you lost
    /// protection and didn't choose to", or nil for expected stops.
    ///
    /// Notify:
    ///   .providerFailed              — extension crashed / failed
    ///   .noNetworkAvailable          — network vanished under the tunnel
    ///   .unrecoverableNetworkChange  — network changed, tunnel can't follow
    ///   .connectionFailed            — couldn't (re)establish
    /// Stay silent:
    ///   .userInitiated, .providerDisabled, .configurationDisabled,
    ///   .configurationRemoved, .superceded, .userLogout, .userSwitch,
    ///   .idleTimeout, .authenticationCanceled, .sleep, .appUpdate, .none —
    ///   all either user/system-intended or self-resolving.
    static func unexpectedBody(for reason: NEProviderStopReason) -> String? {
        switch reason {
        case .providerFailed,
             .connectionFailed:
            return "VPN отключился — соединение потеряно. Трафик идёт напрямую."
        case .noNetworkAvailable,
             .unrecoverableNetworkChange:
            return "VPN отключился из-за смены сети. Трафик идёт напрямую."
        default:
            return nil
        }
    }
}

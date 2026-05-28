import Foundation
import NetworkExtension
import UserNotifications

/// LAUNCH-08 — local notification when the VPN drops without the user asking
/// for it. Lives next to `AppState` and is driven by `handleStatus()` calls
/// inside the `NEVPNStatusDidChange` observer.
///
/// Design contract:
///
/// 1. We only ever fire on the `.connected → (.disconnecting →)? .disconnected`
///    transition. `.connecting → .disconnected` (failed handshake) is silent —
///    the user just attempted a connect and `toggleVPN` already surfaces a
///    UI error for that path.
///
/// 2. The notification is suppressed when the disconnect was user-initiated.
///    `VPNManager.userInitiatedDisconnect` already tracks this: the flag is
///    set to `true` before `stopVPNTunnel()` and reset to `false` on the next
///    `connect()`. We snapshot it on `.disconnecting` (which fires before
///    `.disconnected`) so a race where `userInitiatedDisconnect` gets reset
///    by a quick reconnect can't make a server-side drop look user-initiated.
///
/// 3. Foreground = no notification. The home view shows the connection state
///    directly; a banner would be redundant and annoying.
///
/// 4. `.invalid` is treated as a no-op — that's the "the user uninstalled
///    the profile" path, not a tunnel drop.
///
/// The state-machine portion is pure (no UNUserNotificationCenter side
/// effects): `decide(...)` returns whether a notification should fire AND
/// the new previous-status snapshot. The orchestrating call site
/// (`record(status:userInitiatedDisconnect:)`) then schedules the actual
/// banner via `UNUserNotificationCenter.current()`. This split keeps the
/// transition logic unit-testable without standing up the notification
/// center.
@MainActor
final class DisconnectNotifier {

    /// Output of `decide(...)`: did we cross the "tunnel dropped" edge.
    enum Decision: Equatable {
        case noop
        case fireNotification
    }

    /// Snapshot of the previous `NEVPNStatus`, fed by `record(status:)`. Seed
    /// with `.invalid` so the first observed status is never seen as a drop
    /// from `.connected`.
    private(set) var previousStatus: NEVPNStatus = .invalid

    /// Snapshot of `userInitiatedDisconnect` captured on the first transition
    /// out of `.connected`. We can't read it directly at `.disconnected` time
    /// because `VPNManager.connect()` resets it the next time the user
    /// reconnects, and a fast reconnect could race that reset.
    private(set) var pendingDisconnectWasUserInitiated: Bool = false

    /// Whether the host scene is in the foreground. Caller pushes scene-phase
    /// changes via `setAppActive(_:)`. Default `true` so we only ever fire
    /// once a real background transition has been observed (avoids a stray
    /// notification on cold start if the system replays an old `.disconnected`
    /// event before the SwiftUI scene phase is propagated).
    private(set) var isAppActive: Bool = true

    init() {}

    /// Register the notification category + "Reconnect" action. Idempotent —
    /// safe to call on every launch. Should be called BEFORE any notification
    /// is scheduled, otherwise iOS shows the alert with no action button.
    func registerCategory() {
        let action = UNNotificationAction(
            identifier: AppConstants.disconnectNotificationReconnectActionID,
            title: "Reconnect",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: AppConstants.disconnectNotificationCategoryID,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Ask the user once for `[.alert, .sound]` authorisation. We persist a
    /// "we already asked" flag so we don't re-pester on every successful
    /// connect — if the user denied the first time, the notifier silently
    /// no-ops forever after.
    func requestAuthorizationIfNeeded() async {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupID)
        let alreadyAsked = defaults?.bool(forKey: AppConstants.disconnectNotifyAuthRequestedKey) ?? false
        guard !alreadyAsked else { return }
        defaults?.set(true, forKey: AppConstants.disconnectNotifyAuthRequestedKey)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Forwarded from `MadFrogVPNApp.onChange(of: scenePhase)`. We use this
    /// to suppress notifications while the user is already looking at the app.
    func setAppActive(_ active: Bool) {
        isAppActive = active
    }

    /// Record + react to a status transition. Always update `previousStatus`
    /// even when we don't fire so subsequent transitions can be reasoned about.
    /// `userInitiatedDisconnect` is the live VPNManager flag at the moment
    /// of the call.
    func record(status: NEVPNStatus, userInitiatedDisconnect: Bool) {
        let decision = Self.decide(
            previous: previousStatus,
            next: status,
            userInitiatedSnapshot: pendingDisconnectWasUserInitiated,
            userInitiatedLive: userInitiatedDisconnect,
            isAppActive: isAppActive
        )

        // Update bookkeeping based on the transition. Kept inline (not part
        // of the pure decide()) so decide stays a side-effect-free testable
        // function.
        switch (previousStatus, status) {
        case (.connected, .disconnecting):
            pendingDisconnectWasUserInitiated = userInitiatedDisconnect
        case (_, .connected), (.disconnecting, .disconnected), (.connected, .disconnected):
            pendingDisconnectWasUserInitiated = false
        default:
            break
        }
        previousStatus = status

        if decision == .fireNotification {
            scheduleDisconnectNotification()
        }
    }

    /// Drop the in-flight banner — used when the user opens the app and we
    /// know they've seen the state already, or after the action handler
    /// triggers a reconnect.
    func dismissDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [AppConstants.disconnectNotificationID]
        )
    }

    /// Pure transition function — given the previous + next status and the
    /// snapshot/live values of `userInitiatedDisconnect`, decide whether a
    /// notification should fire. No side effects. Used by `record(...)` and
    /// by unit tests to lock down the matrix without a UNUserNotificationCenter.
    ///
    /// Logic:
    ///   * `.connected → .disconnecting`: never fires; sets the snapshot.
    ///   * `.connected → .disconnected` (skipping disconnecting): use the LIVE
    ///     `userInitiatedDisconnect` — no snapshot was captured.
    ///   * `.disconnecting → .disconnected`: use the snapshot captured at
    ///     `.connected → .disconnecting`.
    ///   * `.connecting → .disconnected`: silent (failed handshake).
    ///   * Any other transition: silent.
    ///   * Foreground (`isAppActive == true`): always silent.
    nonisolated static func decide(
        previous: NEVPNStatus,
        next: NEVPNStatus,
        userInitiatedSnapshot: Bool,
        userInitiatedLive: Bool,
        isAppActive: Bool
    ) -> Decision {
        guard !isAppActive else { return .noop }

        switch (previous, next) {
        case (.connected, .disconnected):
            return userInitiatedLive ? .noop : .fireNotification
        case (.disconnecting, .disconnected):
            return userInitiatedSnapshot ? .noop : .fireNotification
        default:
            // .connected → .disconnecting: handled, but no banner yet
            // (we wait for .disconnected so the "Reconnect" action lands on
            // a fully-stopped tunnel).
            return .noop
        }
    }

    private func scheduleDisconnectNotification() {
        let content = UNMutableNotificationContent()
        content.title = "VPN disconnected"
        content.body = "Connection dropped — tap to reconnect"
        content.sound = .default
        content.categoryIdentifier = AppConstants.disconnectNotificationCategoryID

        let request = UNNotificationRequest(
            identifier: AppConstants.disconnectNotificationID,
            content: content,
            trigger: nil // deliver immediately
        )
        // Drop any in-flight banner first so a quick second drop doesn't
        // stack — iOS would collapse same-identifier requests but the visual
        // is cleaner if we explicitly remove first.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [AppConstants.disconnectNotificationID]
        )
        UNUserNotificationCenter.current().add(request)
    }
}

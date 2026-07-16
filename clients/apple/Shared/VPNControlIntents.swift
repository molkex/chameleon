import AppIntents
import Foundation
import NetworkExtension
import StoreKit
#if os(iOS)
import WidgetKit
#endif

/// launch-04b: the interactive half of widgets — a Control Center toggle
/// (iOS 18 `ControlWidget`) and an interactive Home-Screen button, both
/// driven by `ToggleVPNIntent`.
///
/// `perform()` runs in the *widget-extension* process — that's where
/// Control-Center and interactive-widget intents execute — so the
/// MadFrogWidget target carries the `packet-tunnel-provider` Network
/// Extension entitlement.
///
/// Connect uses `startTunnel(options: nil)`: the PacketTunnel extension
/// falls back to the config persisted in the App Group (see
/// ExtensionProvider.startTunnel — "Config source: persisted
/// UserDefaults"), so the warm path needs no backend round-trip and no
/// app launch. The one cold case — no VPN profile installed yet — can't
/// be handled head-less (it needs the one-time iOS permission prompt),
/// so it surfaces as an error telling the user to open the app.

// MARK: - Pure decision (the branch worth a unit test)

/// What `ToggleVPNIntent` should do, decided from its inputs with no
/// side effects.
enum VPNControlPlan: Equatable {
    case start
    case stop
    /// No VPN profile on the device yet — the toggle can't create one
    /// head-less (that needs the iOS permission prompt), so the app
    /// must be opened for first-time setup.
    case needsApp
}

/// Decide the toggle outcome. Kept free of NetworkExtension types so it
/// is trivially unit-testable.
func vpnControlPlan(desiredOn: Bool, hasManager: Bool) -> VPNControlPlan {
    guard hasManager else { return .needsApp }
    return desiredOn ? .start : .stop
}

// MARK: - Own-tunnel profile selection (CLIENT-VPN-PROFILE-SELECT)

/// `loadAllFromPreferences()` returns EVERY `NETunnelProviderManager` saved
/// on the device — including legacy/duplicate profiles left over from a
/// reinstall, a different NE-owning app, or a stale migration. Blindly
/// taking the first result could then observe/control the WRONG tunnel.
/// Pure predicate over an already-loaded list (rather than doing the
/// filtering inline) so it's unit-testable without any live NE calls: a
/// test can build a bare `NETunnelProviderManager()`, stamp a
/// `protocolConfiguration`, and assert the match.
///
/// `bundleID` is the exact discriminator `VPNManager.createManager()` sets
/// when it first saves OUR profile — see
/// `MadFrogVPN/Models/VPNManager.swift`: `proto.providerBundleIdentifier =
/// AppConstants.tunnelBundleID`. Matching on that (not index 0, not
/// `localizedDescription`, which a user could rename) is the one field the
/// app itself uses to identify its own tunnel.
func selectOurManager(from managers: [NETunnelProviderManager],
                      bundleID: String) -> NETunnelProviderManager? {
    managers.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
    }
}

/// Load every saved manager and narrow to the one (if any) that's ours.
/// Every intent entry point below goes through this instead of calling
/// `loadAllFromPreferences()` directly, so "index 0" can never happen
/// again by accident.
private func loadOurManagers() async throws -> [NETunnelProviderManager] {
    let all = try await NETunnelProviderManager.loadAllFromPreferences()
    guard let ours = selectOurManager(from: all, bundleID: AppConstants.tunnelBundleID) else {
        return []
    }
    return [ours]
}

// MARK: - Subscription gate (CLIENT-INTENT-GATE-BYPASS)

/// Headless mirror of `AppState.mayConnect(subscriptionExpire:isPremium:now:)`
/// / `AppState.ensureSubscriptionForConnect`. This is a deliberate
/// *duplicate*, not a call into `AppState` — `AppState.swift` lives in
/// `MadFrogVPN/Models` and is intentionally NOT part of the `MadFrogWidget`
/// target's sources (see project.yml: the widget stays lean and does not
/// link the rest of `Shared`'s Libbox/StoreKit-heavy app graph), so this
/// file — compiled into BOTH the app and the widget extension — cannot
/// reference `AppState` without breaking the widget build. Any change to
/// `AppState.mayConnect`'s semantics must be mirrored here.
///
/// Unlike `AppState.ensureSubscriptionForConnect`, there is no cross-device
/// reclaim network round-trip (no `APIClient`/`AppState` available inside a
/// headless intent) — just the pure decision plus the local StoreKit
/// fallback for the brief post-purchase window before the backend expiry
/// has synced.
enum VPNIntentSubscriptionGate {
    /// Pure decision — identical logic to `AppState.mayConnect`. Backend
    /// `subscription_expiry` is authoritative whenever known; `isPremium`
    /// is consulted only when it's nil (fresh purchase, not yet synced).
    static func mayConnect(subscriptionExpire: Date?, isPremium: Bool, now: Date) -> Bool {
        if let expiry = subscriptionExpire { return expiry > now }
        return isPremium
    }

    /// The backend-synced expiry, read straight out of the App Group.
    /// Mirrors `ConfigStore.subscriptionExpire`'s storage contract exactly
    /// (same suite, same key) — `ConfigStore` itself isn't linked into the
    /// widget target because it imports Libbox.
    static var persistedSubscriptionExpire: Date? {
        UserDefaults(suiteName: AppConstants.appGroupID)?
            .object(forKey: AppConstants.subscriptionExpireKey) as? Date
    }

    /// Mirrors `SubscriptionManager.allProductIDs` — duplicated (not
    /// imported) for the same lean-widget-target reason as above. Keep in
    /// sync with `MadFrogVPN/Models/SubscriptionManager.swift` if a product
    /// ID is ever added or removed.
    private static let productIDs: Set<String> = [
        "com.madfrog.vpn.sub.30days",
        "com.madfrog.vpn.sub.90days",
        "com.madfrog.vpn.sub.180days",
        "com.madfrog.vpn.sub.365days",
    ]

    /// Local StoreKit fallback, mirroring
    /// `SubscriptionManager.updatePremiumStatus` /
    /// `SubscriptionManager.isActiveEntitlement`. Bounded by `timeout` —
    /// per CLAUDE.md every async operation needs one — so a slow/hung
    /// StoreKit call can never leave a headless intent hanging.
    static func hasLocalActiveEntitlement(now: Date = Date(), timeout: Duration = .seconds(3)) async -> Bool {
        let raceResult = try? await withThrowingTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await entitlementResult in Transaction.currentEntitlements {
                    guard case .verified(let transaction) = entitlementResult,
                          productIDs.contains(transaction.productID),
                          transaction.revocationDate == nil
                    else { continue }
                    if let expiry = transaction.expirationDate, expiry <= now { continue }
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        return raceResult ?? false
    }

    /// The full headless connect-gate: true if the CONNECT action may
    /// proceed. Checked before every `.start` in `VPNControl.perform`.
    static func mayPerformConnect(now: Date = Date()) async -> Bool {
        let expiry = persistedSubscriptionExpire
        if mayConnect(subscriptionExpire: expiry, isPremium: false, now: now) {
            return true
        }
        let isPremium = await hasLocalActiveEntitlement(now: now)
        return mayConnect(subscriptionExpire: expiry, isPremium: isPremium, now: now)
    }
}

// MARK: - Errors

enum VPNControlError: Error, CustomLocalizedStringResourceConvertible {
    /// No NETunnelProviderManager exists — the user has never connected.
    case profileNotInstalled
    /// Manager exists but its connection isn't a tunnel-provider session.
    case noSession
    /// CLIENT-INTENT-GATE-BYPASS: the same subscription gate the in-app
    /// Connect button applies (`AppState.mayConnect`) failed. The app shows
    /// a paywall in this case; a headless intent can't present UI, so it
    /// fails with a localized message telling the user to open the app.
    case subscriptionInactive

    var localizedStringResource: LocalizedStringResource {
        let isRU = Locale.current.language.languageCode?.identifier == "ru"
        switch self {
        case .profileNotInstalled:
            return isRU
                ? "Откройте MadFrog VPN один раз, чтобы настроить подключение."
                : "Open MadFrog VPN once to set up the connection."
        case .noSession:
            return isRU
                ? "VPN-сессия недоступна. Откройте MadFrog VPN."
                : "VPN session unavailable. Open MadFrog VPN."
        case .subscriptionInactive:
            return isRU
                ? "Подписка неактивна — откройте приложение."
                : "Subscription inactive — open MadFrog VPN."
        }
    }
}

// MARK: - Shared VPN control (the extract-method core)

/// launch-05: the start/stop body, lifted verbatim out of
/// `ToggleVPNIntent.perform()` so all three intents — the toggle, and
/// the discrete `ConnectVPNIntent` / `DisconnectVPNIntent` Shortcuts
/// verbs — drive the VPN through ONE code path. Pure extract-method:
/// the toggle still does exactly what it did before, it just calls this.
///
/// `plan` is the already-decided outcome from `vpnControlPlan`, and
/// `managers` is the already-loaded `NETunnelProviderManager` list the
/// decision was made from. This helper performs the NetworkExtension
/// side effects for `.start` / `.stop` and throws `VPNControlError` for
/// `.needsApp` — identical to the original `ToggleVPNIntent` switch.
enum VPNControl {
    /// build-84 testability seam: encodes the invariant that `.start` must
    /// NOT optimistically write `connected=true` into the App Group. The
    /// optimistic-connected path can never be reverted from the widget
    /// process (it can't observe whether the tunnel actually came up), so
    /// the widget would lie forever about protection state on any failed
    /// start. Asserted by VPNControlIntentsBehaviorTests so a regression
    /// flips the constant visibly. `.stop` IS optimistic (kernel teardown
    /// is essentially immediate) — see `publishOptimisticState` call below.
    static let publishesOptimisticOnStart: Bool = false

    /// Drive `NETunnelProviderManager` to satisfy `plan`. Callers load
    /// the managers (to compute the plan) and hand the same array in,
    /// so this stays a pure extract — no extra `loadAllFromPreferences`.
    static func perform(_ plan: VPNControlPlan,
                        managers: [NETunnelProviderManager]) async throws {
        switch plan {
        case .needsApp:
            throw VPNControlError.profileNotInstalled

        case .start:
            // CLIENT-INTENT-GATE-BYPASS: mirror the in-app connect gate
            // (AppState.mayConnect) before starting the tunnel. Without
            // this, an expired user's widget tap / Shortcut bypassed the
            // paywall entirely and connected anyway.
            guard await VPNIntentSubscriptionGate.mayPerformConnect() else {
                throw VPNControlError.subscriptionInactive
            }
            // managers is non-empty here (vpnControlPlan guaranteed it),
            // and — CLIENT-VPN-PROFILE-SELECT — is always OUR tunnel's
            // manager, never an arbitrary index 0 (see loadOurManagers()).
            let manager = managers[0]
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw VPNControlError.noSession
            }
            // WIDGET-CONNECTING (2026-07-16): stamp BEFORE startTunnel so the
            // widget shows an honest "connecting…" the instant iOS queues the
            // start, instead of dead air. This does NOT claim protection —
            // see WidgetVPNSnapshot.writeConnecting's doc comment — so it's
            // safe from a process that can't observe the eventual outcome;
            // the reader's own 30s expiry self-heals if nothing clears it.
            let sharedDefaults = UserDefaults(suiteName: AppConstants.appGroupID)
            WidgetVPNSnapshot.writeConnecting(to: sharedDefaults)
            #if os(iOS)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            do {
                // options: nil — the extension uses the App-Group-persisted
                // config; no backend fetch, no app launch on the warm path.
                try session.startTunnel(options: nil)
            } catch {
                // Queueing itself failed — clear the connecting flag right
                // away instead of waiting out the 30s self-expiry.
                WidgetVPNSnapshot.write(connected: false, to: sharedDefaults)
                #if os(iOS)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
                throw error
            }
            // Build-84: NO optimistic .connected write. startTunnel() is
            // async — it returns without throwing as long as iOS QUEUED
            // the start, but the actual tunnel may fail to come up
            // (another VPN holding the device, On-Demand reclaim, config
            // error, etc.). The widget process doesn't observe the
            // outcome, so an optimistic .connected write here could
            // never be reverted and the widget would lie forever about
            // protection state. Defer to ExtensionProvider.publishWidget
            // State, which fires from the one process that knows — it'll
            // clear the connecting flag too (see WidgetVPNSnapshot.write).

        case .stop:
            managers[0].connection.stopVPNTunnel()
            // Stop IS essentially immediate at the kernel level — the
            // tunnel comes down within ~100ms. Optimistic-disconnected
            // is safe: if it somehow stays up, ExtensionProvider re-asserts.
            publishOptimisticState(connected: false)
        }
    }

    /// Write the just-requested state into the App Group and nudge the
    /// widgets, so the UI flips the instant the user taps — before the
    /// tunnel has actually finished coming up / down. The PacketTunnel
    /// extension remains the source of truth and corrects this if the
    /// real outcome differs.
    ///
    /// Goes through `WidgetVPNSnapshot.write` — the same key-write the
    /// extension uses — so the optimistic and authoritative writes can't
    /// drift apart.
    static func publishOptimisticState(connected: Bool) {
        WidgetVPNSnapshot.write(connected: connected,
                                to: UserDefaults(suiteName: AppConstants.appGroupID))
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// MARK: - Toggle intent

/// Connect / disconnect the VPN. `SetValueIntent` so it can back an
/// iOS-18 `ControlWidgetToggle`; the Home-Screen button instantiates it
/// with `ToggleVPNIntent(value: !current)`.
struct ToggleVPNIntent: SetValueIntent {
    static let title: LocalizedStringResource = "MadFrog VPN"
    static let description = IntentDescription("Connect or disconnect MadFrog VPN.")

    /// The desired connection state. For a `ControlWidgetToggle` the
    /// system sets this to the state the user is switching *to*.
    @Parameter(title: "Connected")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        let managers = try await loadOurManagers()
        let plan = vpnControlPlan(desiredOn: value, hasManager: !managers.isEmpty)
        try await VPNControl.perform(plan, managers: managers)
        return .result()
    }
}

// MARK: - Discrete Shortcuts verbs (launch-05)

/// Connect MadFrog VPN. A plain `AppIntent` (not a toggle) — Shortcuts
/// and Spotlight users expect a discrete "Connect" verb. Routes through
/// the same `VPNControl.perform` core as `ToggleVPNIntent`.
struct ConnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect MadFrog VPN"
    static let description = IntentDescription("Turn on the MadFrog VPN connection.")
    /// Headless: the warm path needs no UI. The shared core throws a
    /// localized error if no profile exists yet, prompting the user to
    /// open the app for the one-time setup.
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        let managers = try await loadOurManagers()
        let plan = vpnControlPlan(desiredOn: true, hasManager: !managers.isEmpty)
        try await VPNControl.perform(plan, managers: managers)
        return .result()
    }
}

/// Disconnect MadFrog VPN. Plain `AppIntent` discrete verb, shares the
/// `VPNControl.perform` core.
struct DisconnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect MadFrog VPN"
    static let description = IntentDescription("Turn off the MadFrog VPN connection.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        let managers = try await loadOurManagers()
        let plan = vpnControlPlan(desiredOn: false, hasManager: !managers.isEmpty)
        try await VPNControl.perform(plan, managers: managers)
        return .result()
    }
}

// MARK: - Read-only status verb (launch-05)

/// Report whether the VPN is connected and which server is selected.
/// Read-only — no NetworkExtension side effects — so it reads straight
/// from the App-Group snapshot the extension maintains.
///
/// launch-05b: this is the third Shortcuts action. A "Switch server"
/// intent was evaluated and deferred — server switching lives on the
/// `@MainActor`/`@Observable` `AppState` (chain resolution, cascade
/// state, a live `CommandClient`), none of which a headless intent can
/// reconstruct cleanly, and shipping a half-working switch is worse
/// than none (same call as the launch-04b split). A status read is a
/// genuinely clean, useful third verb.
struct VPNStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "MadFrog VPN Status"
    static let description = IntentDescription("Check whether MadFrog VPN is connected.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let snapshot = WidgetVPNSnapshot.read()
        return .result(value: snapshot.connected,
                       dialog: IntentDialog(vpnStatusDialog(for: snapshot)))
    }
}

/// The spoken / displayed status line for `VPNStatusIntent`. Pulled out
/// as a pure function over the snapshot so it's unit-testable without
/// touching AppIntents machinery.
func vpnStatusDialog(for snapshot: WidgetVPNSnapshot) -> LocalizedStringResource {
    let isRU = Locale.current.language.languageCode?.identifier == "ru"
    if snapshot.connected {
        let server = snapshot.serverDisplay
        return isRU
            ? "MadFrog VPN подключён — \(server)."
            : "MadFrog VPN is connected — \(server)."
    }
    return isRU
        ? "MadFrog VPN отключён."
        : "MadFrog VPN is disconnected."
}

import AppIntents
import Foundation
import NetworkExtension
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

// MARK: - Errors

enum VPNControlError: Error, CustomLocalizedStringResourceConvertible {
    /// No NETunnelProviderManager exists — the user has never connected.
    case profileNotInstalled
    /// Manager exists but its connection isn't a tunnel-provider session.
    case noSession

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
    /// Drive `NETunnelProviderManager` to satisfy `plan`. Callers load
    /// the managers (to compute the plan) and hand the same array in,
    /// so this stays a pure extract — no extra `loadAllFromPreferences`.
    static func perform(_ plan: VPNControlPlan,
                        managers: [NETunnelProviderManager]) async throws {
        switch plan {
        case .needsApp:
            throw VPNControlError.profileNotInstalled

        case .start:
            // managers is non-empty here (vpnControlPlan guaranteed it).
            let manager = managers[0]
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw VPNControlError.noSession
            }
            // options: nil — the extension uses the App-Group-persisted
            // config; no backend fetch, no app launch on the warm path.
            try session.startTunnel(options: nil)
            // Optimistic: startTunnel() didn't throw, so the tunnel is
            // coming up. Stamp the App Group NOW so the timeline reload
            // WidgetKit fires right after this intent shows the new
            // state immediately — instead of waiting for the extension
            // (whose own reloadAllTimelines() is iOS-budget-throttled).
            // ExtensionProvider.publishWidgetState() then confirms it,
            // or clears it if the connection actually fails.
            publishOptimisticState(connected: true)

        case .stop:
            managers[0].connection.stopVPNTunnel()
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
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
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
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
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
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
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

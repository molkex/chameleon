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
        switch vpnControlPlan(desiredOn: value, hasManager: !managers.isEmpty) {
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
            Self.publishOptimisticState(connected: true)

        case .stop:
            managers[0].connection.stopVPNTunnel()
            Self.publishOptimisticState(connected: false)
        }
        return .result()
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
    private static func publishOptimisticState(connected: Bool) {
        WidgetVPNSnapshot.write(connected: connected,
                                to: UserDefaults(suiteName: AppConstants.appGroupID))
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

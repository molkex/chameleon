import AppIntents
import SwiftUI
import WidgetKit

/// launch-04b: Control Center toggle (iOS 18+).
///
/// The current state is read from the App Group via `WidgetVPNSnapshot`
/// (same source the read-only `StatusWidget` uses). The toggle action is
/// `ToggleVPNIntent`, which runs in this extension's process and drives
/// `NETunnelProviderManager` directly — so flipping the control connects
/// or disconnects without ever opening the app.
@available(iOS 18.0, *)
struct MadFrogControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.madfrog.vpn.control.toggle",
            provider: VPNControlValueProvider()
        ) { isConnected in
            ControlWidgetToggle(
                Self.controlTitle,
                isOn: isConnected,
                action: ToggleVPNIntent()
            ) { connected in
                Label(Self.stateLabel(connected: connected),
                      systemImage: connected ? "checkmark.shield.fill" : "shield.slash")
            }
            .tint(.green)
        }
        .displayName(LocalizedStringResource(stringLiteral: Self.controlTitle))
        .description(LocalizedStringResource(stringLiteral: Self.controlDescription))
    }

    // The widget target deliberately carries no Localizable.strings
    // (kept lean — see project.yml). The two visible strings are
    // resolved against the current locale, mirroring StatusWidget.
    private static var isRU: Bool {
        Locale.current.language.languageCode?.identifier == "ru"
    }
    static var controlTitle: String { "MadFrog VPN" }
    static var controlDescription: String {
        isRU ? "Подключить или отключить MadFrog VPN" : "Connect or disconnect MadFrog VPN"
    }
    static func stateLabel(connected: Bool) -> String {
        if isRU { return connected ? "Защищено" : "Выкл" }
        return connected ? "Protected" : "Off"
    }
}

/// Supplies the control's current on/off value from the App Group.
@available(iOS 18.0, *)
struct VPNControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        WidgetVPNSnapshot.read().connected
    }
}

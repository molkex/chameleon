import AppIntents

/// launch-05: exposes the VPN verbs to the Shortcuts app and Spotlight.
///
/// An `AppShortcutsProvider` is app-level discovery — the system scans
/// the *main app* bundle for it, so this type lives in the MadFrogVPN
/// target only (the widget extension can't host it). The intents it
/// references — `ConnectVPNIntent`, `DisconnectVPNIntent`,
/// `VPNStatusIntent` — live in `Shared/VPNControlIntents.swift` so the
/// widget extension keeps compiling them too.
///
/// Three actions ship: Connect, Disconnect, Status. "Switch server" was
/// deferred — see the `launch-05b` note in `VPNStatusIntent`.
///
/// Phrases are bilingual (en + ru, matching the app's localizations).
/// `\(.applicationName)` is required by AppIntents in every phrase — the
/// system substitutes the app's display name.
struct VPNAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Turn on \(.applicationName)",
                "Start \(.applicationName)",
                "Включи \(.applicationName)",
                "Подключи \(.applicationName)",
                "Включить \(.applicationName)"
            ],
            shortTitle: "Connect VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Turn off \(.applicationName)",
                "Stop \(.applicationName)",
                "Выключи \(.applicationName)",
                "Отключи \(.applicationName)",
                "Выключить \(.applicationName)"
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "lock.open"
        )
        AppShortcut(
            intent: VPNStatusIntent(),
            phrases: [
                "Is \(.applicationName) connected",
                "\(.applicationName) status",
                "Check \(.applicationName)",
                "Статус \(.applicationName)",
                "Проверь \(.applicationName)",
                "\(.applicationName) подключён"
            ],
            shortTitle: "VPN Status",
            systemImageName: "shield.lefthalf.filled"
        )
    }
}

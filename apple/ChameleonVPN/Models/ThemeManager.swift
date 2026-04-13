import Foundation
import Observation

/// Owns the currently selected `Theme` and its persistence.
///
/// First-launch contract: if `hasSelected == false`, the app shows
/// `ThemePickerView` before onboarding/main content. Once the user picks,
/// the choice is written to UserDefaults (source of truth) and best-effort
/// PATCHed to the backend for analytics/cross-device hint.
@Observable
final class ThemeManager {
    private static let themeIDKey = "com.madfrog.vpn.ui_theme"
    private static let hasSelectedKey = "com.madfrog.vpn.ui_theme.selected"

    private(set) var current: Theme
    private(set) var hasSelected: Bool

    private let defaults: UserDefaults

    /// Injected server-sync hook. Called on `select(_:)` with the new theme id.
    /// Left nil for unit tests / early app startup before auth is wired up.
    var remoteSync: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: Self.themeIDKey) ?? Theme.calm.id
        self.current = Theme.byID(id)
        self.hasSelected = defaults.bool(forKey: Self.hasSelectedKey)
    }

    /// Marks the theme as selected by the user and persists both locally
    /// and (best-effort) remotely. Call from the picker and from Settings.
    func select(_ theme: Theme) {
        current = theme
        defaults.set(theme.id, forKey: Self.themeIDKey)
        defaults.set(true, forKey: Self.hasSelectedKey)
        hasSelected = true
        remoteSync?(theme.id)
    }
}

import SwiftUI

/// Visual theme tokens for the app. MadFrog (neon: deep blue + neon green +
/// magenta) is the only theme — a second variant (`.calm`) existed through
/// build 123 and was removed 2026-07-11 (~700 lines of duplicated home-screen
/// logic across two near-identical views for a picker almost nobody used).
struct Theme: Equatable {
    let id: String
    let displayName: String
    let tagline: String

    // Core palette
    let background: Color
    let surface: Color        // cards
    let surfaceElevated: Color
    let accent: Color
    let accentSecondary: Color
    let textPrimary: Color
    let textSecondary: Color
    let success: Color
    let danger: Color

    // Shape language
    let cornerRadius: CGFloat
    let cardCornerRadius: CGFloat

    // Typography family names (use `font(size:weight:)` to apply)
    let displayFontName: String?
    let bodyFontName: String?

    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if let name = bodyFontName {
            return .custom(name, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: design)
    }

    func displayFont(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if let name = displayFontName {
            return .custom(name, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }
}

extension Theme {
    /// Neon Swamp — dark blue, neon green + magenta, bold street-art energy.
    static let neon = Theme(
        id: "neon",
        displayName: "MadFrog",
        tagline: "Signature neon, bold and loud.",
        background: Color(red: 0.039, green: 0.055, blue: 0.102),       // #0a0e1a
        surface: Color(red: 0.071, green: 0.094, blue: 0.153),          // #121827
        surfaceElevated: Color(red: 0.11, green: 0.14, blue: 0.2),      // #1C2433
        accent: Color(red: 0.549, green: 1.0, blue: 0.31),              // #8CFF4F neon green
        accentSecondary: Color(red: 1.0, green: 0.239, blue: 0.604),    // #FF3D9A magenta
        textPrimary: Color(red: 0.953, green: 0.98, blue: 1.0),         // #F3FAFF
        textSecondary: Color(red: 0.518, green: 0.588, blue: 0.706),    // #8496B4
        success: Color(red: 0.549, green: 1.0, blue: 0.31),
        danger: Color(red: 1.0, green: 0.239, blue: 0.604),
        cornerRadius: 12,
        cardCornerRadius: 18,
        displayFontName: nil,   // Syne Black fallback for now
        bodyFontName: nil
    )

    /// The app's one and only theme. Kept as a name (rather than inlining
    /// `.neon` everywhere) so a future re-theme is a one-line change.
    static let current = neon
}

import SwiftUI

/// Visual theme for the app. Two variants: `.calm` (charcoal + warm yellow,
/// soft rounded cards) and `.neon` (deep blue + neon green + magenta, bold).
///
/// The device is the source of truth — `ThemeManager` persists the selection
/// to UserDefaults and best-effort syncs it to the backend for analytics.
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
    /// Calm — charcoal background, warm lime-yellow accent, rounded cards,
    /// plenty of whitespace. Reference: soil-monitor app (dark + #E8FF4B).
    static let calm = Theme(
        id: "calm",
        displayName: "Classic",
        tagline: "Minimal. Comfortable. Quiet.",
        background: Color(red: 0.055, green: 0.055, blue: 0.055),       // #0E0E0E
        surface: Color(red: 0.102, green: 0.102, blue: 0.102),          // #1A1A1A
        surfaceElevated: Color(red: 0.14, green: 0.14, blue: 0.14),     // #242424
        accent: Color(red: 0.91, green: 1.0, blue: 0.294),              // #E8FF4B
        accentSecondary: Color(red: 0.98, green: 0.98, blue: 0.98),     // near-white
        textPrimary: Color(red: 0.98, green: 0.98, blue: 0.98),         // #FAFAFA
        textSecondary: Color(red: 0.541, green: 0.541, blue: 0.541),    // #8A8A8A
        success: Color(red: 0.91, green: 1.0, blue: 0.294),
        danger: Color(red: 1.0, green: 0.42, blue: 0.42),
        cornerRadius: 16,
        cardCornerRadius: 26,
        displayFontName: nil,   // SF Pro Rounded fallback for now
        bodyFontName: nil
    )

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

    static let all: [Theme] = [.calm, .neon]

    static func byID(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .neon
    }
}

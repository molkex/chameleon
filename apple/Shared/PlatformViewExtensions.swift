import SwiftUI

/// Platform-specific SwiftUI view modifiers. iOS-only APIs (navigation bar
/// titles, keyboard autocapitalization, iOS toolbar placements, inset grouped
/// lists) become no-ops on macOS, where they don't exist or behave differently.
/// This keeps the shared view code compiling for both platforms without a
/// forest of `#if os(iOS)` blocks in every file.
extension View {
    /// iOS: `.navigationBarTitleDisplayMode(.inline)`. No-op on macOS.
    @ViewBuilder
    func iosInlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// iOS: `.listStyle(.insetGrouped)`. macOS: `.listStyle(.inset)`.
    @ViewBuilder
    func platformInsetGroupedList() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    /// iOS: `.textInputAutocapitalization(.never)`. No-op on macOS (no keyboard).
    @ViewBuilder
    func iosNoAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// iOS: `.textContentType(.emailAddress)`. No-op on macOS.
    @ViewBuilder
    func iosEmailContentType() -> some View {
        #if os(iOS)
        self.textContentType(.emailAddress)
        #else
        self
        #endif
    }

    /// iOS: `.keyboardType(.emailAddress)`. No-op on macOS (no on-screen keyboard).
    @ViewBuilder
    func iosEmailKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress)
        #else
        self
        #endif
    }

    /// iOS: `.toolbarBackground(color, for: .navigationBar)` with `.visible`.
    /// No-op on macOS (no navigation bar — title is in window chrome).
    @ViewBuilder
    func iosToolbarBackground<S: ShapeStyle>(_ style: S) -> some View {
        #if os(iOS)
        self
            .toolbarBackground(style, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    /// On macOS gives sheet content a sensible modal size (iPhone-shaped) so
    /// it doesn't render as a tiny floating popover. No-op on iOS where
    /// sheets expand to the scene automatically.
    @ViewBuilder
    func macSheetSize(width: CGFloat = 480, height: CGFloat = 700) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// On macOS overlays a top-trailing close button that dismisses the sheet
    /// (iOS sheets can be swiped down; macOS sheets can't — they need a
    /// visible close control). Also maps the Escape key to the same action.
    /// No-op on iOS where the existing toolbar "Done" already handles it.
    @ViewBuilder
    func macCloseButton(action: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.overlay(alignment: .topTrailing) {
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
        #else
        self
        #endif
    }
}

/// Toolbar placement that maps iOS `.topBarLeading` / `.topBarTrailing` to
/// sensible macOS equivalents without polluting every call site.
enum PlatformToolbarPlacement {
    case leading
    case trailing

    var resolved: ToolbarItemPlacement {
        #if os(iOS)
        switch self {
        case .leading: return .topBarLeading
        case .trailing: return .topBarTrailing
        }
        #else
        switch self {
        case .leading: return .cancellationAction
        case .trailing: return .primaryAction
        }
        #endif
    }
}

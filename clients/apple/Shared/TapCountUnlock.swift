import SwiftUI

/// Reusable "N consecutive taps reveals a hidden feature" gesture. The
/// server picker's power-mode unlock and Settings' diagnostics unlock used
/// to duplicate this counter+threshold logic independently. Extracted
/// 2026-07-11 (L1, Fable code review).
private struct TapCountUnlock: ViewModifier {
    let threshold: Int
    let onUnlock: () -> Void
    @State private var count = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                count += 1
                if count >= threshold {
                    onUnlock()
                }
            }
    }
}

extension View {
    /// Fires `onUnlock` on every tap once the running count has reached
    /// `threshold` (5 by default) — it does not reset or debounce, so a
    /// caller that only wants a one-time reveal should gate `onUnlock`'s
    /// body on its own "already unlocked" flag (as the power-mode call site
    /// does; the diagnostics call site re-fires harmlessly on every tap past
    /// the 5th, matching its pre-extraction behavior).
    func tapCountUnlock(threshold: Int = 5, onUnlock: @escaping () -> Void) -> some View {
        modifier(TapCountUnlock(threshold: threshold, onUnlock: onUnlock))
    }
}

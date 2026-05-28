import Foundation

/// Per-server probe lifecycle as surfaced to the UI.
///
/// `PingService` owns the existing best-of-N background sweep that populates
/// `results[tag] = ms`; LAUNCH-11 layers a manual, user-driven re-measure on
/// top. The user can tap a "Ping" button next to any server in the picker —
/// the row's status moves `idle → measuring → success(ms)` (or `failed`) and
/// the UI binds to it directly via `@Observable`.
///
/// We deliberately keep this separate from `results`. `results` is the
/// "best-known-value" cache (persisted to UserDefaults, used by the country
/// list to render best-of-country pings, survives picker open/close). The
/// `statuses` map is the *live* state of an in-flight manual probe — it
/// flips back to `.idle` on the next manual ping, and on success also writes
/// the value through to `results` so the cached badge updates.
enum PingStatus: Equatable, Sendable {
    /// No manual probe in flight. The cached `results[tag]` (if any) is what
    /// the UI shows. This is the initial state for every server.
    case idle

    /// User tapped the manual ping button; a fresh measurement is running.
    /// UI shows a small `ProgressView()` instead of the latency badge.
    case measuring

    /// Most recent manual probe succeeded with this RTT in ms. Mirrored into
    /// `results[tag]` so the country-list "best-of" calculation picks it up.
    case success(ms: Int)

    /// Most recent manual probe timed out or returned an error. UI shows
    /// "—" with a red dot. Tapping the button again moves back to `.measuring`.
    case failed
}

import Foundation
import Libbox

/// Pure formatting for the home-screen live traffic strip (HOME-STATS,
/// 2026-07-14). Wraps `LibboxFormatBytes` — the same helper
/// `CommandClientWrapper.formattedUploadTotal`/`formattedDownloadTotal`
/// already use — behind a placeholder rule that also accounts for the
/// tunnel's connection state.
///
/// Why not just read `CommandClientWrapper.formattedUploadTotal` directly:
/// that guard only checks `statsAvailable` (true by default, and NOT reset
/// by `CommandClientWrapper.disconnect()`), so right after a disconnect it
/// would render "0 B" instead of the required "—" placeholder. Keeping the
/// connection-state check here — as a pure, tested function — avoids a
/// silent regression if that reset behavior ever changes.
enum ConnectionStatsFormatter {
    /// - Parameters:
    ///   - bytes: raw total from `LibboxStatusMessage.uplinkTotal` /
    ///     `.downlinkTotal`, pushed ~1×/s by the existing CommandClient
    ///     status stream while connected.
    ///   - isConnected: current VPN tunnel state.
    ///   - statsAvailable: whether the CommandClient's gRPC/unix-socket
    ///     stream to the extension is actually up.
    static func totalText(bytes: Int64, isConnected: Bool, statsAvailable: Bool) -> String {
        guard isConnected, statsAvailable else { return "—" }
        return LibboxFormatBytes(bytes)
    }
}

import Foundation

/// CLIENT-EXT-RACE (P1): thread-safe generation/epoch guard for the
/// `startTunnel` / `stopTunnel` race in `ExtensionProvider`.
///
/// `ExtensionProvider.startTunnel` moves the actual sing-box bring-up onto
/// an untracked `DispatchQueue.global().async` block and returns
/// immediately; `stopTunnel` runs synchronously with no cancellation of
/// that in-flight work. A fast connect→disconnect can let the late start
/// block publish a 'connected' side effect (widget state, watchdogs,
/// `completionHandler(nil)`) AFTER stop has already torn the tunnel down
/// and reported 'disconnected' — a stale/zombie tunnel signal.
///
/// Usage: `startTunnel` calls `beginGeneration()` synchronously (before
/// dispatching the background start work) and captures the returned
/// token. Once that work finishes — success or failure — it calls
/// `isCurrent(token)` right before publishing any 'connected' side
/// effect. If `stopTunnel` already called `invalidate()` in the meantime,
/// the token is stale and the late start must tear itself down quietly
/// instead of resurrecting a 'connected' signal.
///
/// Pure counter, no NetworkExtension/Libbox dependency — safe to unit test.
final class TunnelStartGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    /// Call at the very start of `startTunnel`, before dispatching the
    /// background start work. Returns a token identifying this specific
    /// start attempt.
    func beginGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    /// Call at the very start of `stopTunnel`. Invalidates any start whose
    /// token was captured before this call (and any generation older than
    /// the one this returns).
    @discardableResult
    func invalidate() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    /// True if `token` is still the most recent generation — i.e. neither
    /// `invalidate()` nor a newer `beginGeneration()` has happened since
    /// `token` was issued.
    func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }
}

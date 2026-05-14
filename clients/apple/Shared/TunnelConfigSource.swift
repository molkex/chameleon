import Foundation

/// Where the PacketTunnel extension's sing-box config came from. The
/// extension's `startTunnel` prefers the freshest source available.
enum TunnelConfigSource: String, Equatable {
    /// Passed in by the app via `startTunnel(options:)` — the fresh,
    /// just-fetched config (the app's explicit Connect).
    case options
    /// Read from App-Group UserDefaults — the warm path: a widget /
    /// Control-Center toggle or an On-Demand restart, when the app
    /// isn't running to hand a config in.
    case persisted
    /// On-disk fallback — last resort if neither of the above exists.
    case file
}

/// The resolved config + where it came from.
struct ResolvedTunnelConfig: Equatable {
    let json: String
    let source: TunnelConfigSource
}

/// Pick the sing-box config for a tunnel start, in precedence order:
/// `startTunnel` options → App-Group-persisted → on-disk file. Returns
/// `nil` when no source has a config — the caller then fails the start
/// with "No VPN config".
///
/// `file` is an `@autoclosure` so the on-disk read only happens when the
/// two faster sources both miss — the warm path (persisted hit) does no
/// extra I/O, matching the original inline `else if` chain.
///
/// Pure: the inputs are read by the caller (ExtensionProvider); this
/// just encodes the precedence so it's unit-testable without
/// NetworkExtension.
func resolveTunnelConfig(
    options: String?,
    persisted: String?,
    file: @autoclosure () -> String?
) -> ResolvedTunnelConfig? {
    if let options {
        return ResolvedTunnelConfig(json: options, source: .options)
    }
    if let persisted {
        return ResolvedTunnelConfig(json: persisted, source: .persisted)
    }
    if let file = file() {
        return ResolvedTunnelConfig(json: file, source: .file)
    }
    return nil
}

import Foundation
import Network
#if os(iOS)
import NetworkExtension
#endif

/// Coarse fingerprint of the current network, used as a key for "which
/// VPN leg worked here last time?" memory. Stable across app launches but
/// changes when the user moves between networks (home WiFi → office WiFi
/// → cellular), which is exactly when the cached leg picks need to be
/// re-validated.
///
/// Sources:
/// - WiFi: SSID via `NEHotspotNetwork.fetchCurrent` (iOS only — macOS
///   requires Location permission and CoreWLAN).
/// - Cellular: generic "cellular" bucket. iOS 16+ deprecated MCC/MNC
///   access for privacy.
/// - Other / unknown: nil — caller treats as a never-seen network.
enum NetworkFingerprint {
    /// Returns a fingerprint string for the current network, or nil if
    /// nothing identifiable is available.
    static func current() async -> String? {
        guard let path = await snapshotPath() else { return nil }
        let usesWifi = path.usesInterfaceType(NWInterface.InterfaceType.wifi)
        // SSID lookup is the one async leg — only do it on a WiFi path,
        // matching the original short-circuit.
        let ssid = usesWifi ? await wifiSSID() : nil
        return NetworkFingerprintLogic.fingerprint(
            usesWifi: usesWifi,
            wifiSSID: ssid,
            usesCellular: path.usesInterfaceType(NWInterface.InterfaceType.cellular),
            usesWiredEthernet: path.usesInterfaceType(NWInterface.InterfaceType.wiredEthernet)
        )
    }

    /// One-shot NWPath snapshot. NWPathMonitor delivers continuously; we
    /// just need the current state.
    private static func snapshotPath() async -> Network.NWPath? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "NetworkFingerprint.snapshot")
            let store = OneShot()
            monitor.pathUpdateHandler = { path in
                guard store.tryResume() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }

    private static func wifiSSID() async -> String? {
#if os(iOS)
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
#else
        return nil
#endif
    }

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

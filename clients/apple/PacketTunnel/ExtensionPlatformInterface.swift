import Foundation
import NetworkExtension
import Network
import Libbox

/// Implements LibboxPlatformInterfaceProtocol + LibboxCommandServerHandlerProtocol.
/// Bridges sing-box Go engine ↔ iOS NetworkExtension.
/// Based on SFI (sing-box-for-apple) reference implementation.
final class ExtensionPlatformInterface: NSObject, @unchecked Sendable {

    /// Build-44: real-traffic stall detector receives every sing-box
    /// log line via `writeLogs` below. Set by `ExtensionProvider`
    /// when the tunnel starts; cleared on stop. Optional because the
    /// detector only exists while sing-box is alive — no point
    /// retaining 30 s of stale events across reconnects.
    weak var realStallDetector: RealTrafficStallDetector?
    weak var tunnel: NEPacketTunnelProvider?
    private var pathMonitor: NWPathMonitor?
    private var interfaceListener: LibboxInterfaceUpdateListenerProtocol?
    private let interfaceLock = NSLock()
    private var _lastInterfaceName: String = ""
    // neighborListener removed in libbox 1.13

    /// Build-38: thread-safe read of the current default interface name
    /// (`en0` for Wi-Fi, `pdp_ip0` for cellular, etc.). Mutated on the
    /// NWPathMonitor's background queue from `handlePathUpdate`; the memory
    /// watchdog on its own utility queue reads this to label diagnostics so
    /// we can correlate growth curves with the active uplink.
    var currentInterfaceName: String {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        return _lastInterfaceName
    }

    init(tunnel: NEPacketTunnelProvider) {
        self.tunnel = tunnel
        super.init()
    }

    deinit {
        pathMonitor?.cancel()
    }
}

// MARK: - LibboxPlatformInterfaceProtocol

extension ExtensionPlatformInterface: LibboxPlatformInterfaceProtocol {

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        return nil
    }

    func usePlatformAutoDetectControl() -> Bool {
        return true
    }

    func autoDetectControl(_ fd: Int32) throws {
        TunnelFileLogger.log("autoDetectControl fd=\(fd)", category: "platform")
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_ ret0: UnsafeMutablePointer<Int32>?) throws {
        TunnelFileLogger.log("openTun called", category: "platform")
        try runBlocking { [self] in
            try await openTunAsync(options, ret0)
        }
    }

    private func openTunAsync(_ options: (any LibboxTunOptionsProtocol)?,
                               _ ret0: UnsafeMutablePointer<Int32>?) async throws {
        guard let tunnel = tunnel, let options = options, let ret0 = ret0 else {
            TunnelFileLogger.log("ERROR: openTunAsync — no tunnel/options/ret0", category: "platform")
            throw NSError(domain: "Chameleon", code: 1, userInfo: [NSLocalizedDescriptionKey: "No tunnel provider"])
        }

        TunnelFileLogger.log("openTunAsync: MTU=\(options.getMTU()), building settings...", category: "platform")
        let settings = try buildTunnelSettings(from: options)

        TunnelFileLogger.log("setTunnelNetworkSettings: calling...", category: "platform")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tunnel.setTunnelNetworkSettings(settings) { error in
                if let error {
                    TunnelFileLogger.log("ERROR: setTunnelNetworkSettings failed: \(error)", category: "platform")
                    continuation.resume(throwing: error)
                } else {
                    TunnelFileLogger.log("setTunnelNetworkSettings: OK", category: "platform")
                    continuation.resume()
                }
            }
        }

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            TunnelFileLogger.log("TUN fd from packetFlow: \(tunFd)", category: "platform")
            ret0.pointee = tunFd
            return
        }

        let tunFd = LibboxGetTunnelFileDescriptor()
        TunnelFileLogger.log("TUN fd from LibboxGetTunnelFileDescriptor: \(tunFd)", category: "platform")
        if tunFd != -1 {
            ret0.pointee = tunFd
        } else {
            TunnelFileLogger.log("ERROR: Missing TUN file descriptor", category: "platform")
            throw NSError(domain: "Chameleon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing TUN file descriptor"])
        }
    }

    func useProcFS() -> Bool {
        return false
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        return LibboxConnectionOwner()
    }

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        self.interfaceListener = listener
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: .global(qos: .utility))
        self.pathMonitor = monitor
    }

    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
        interfaceListener = nil
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor = pathMonitor else {
            return NetworkInterfaceArray([])
        }
        let path = monitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for iface in path.availableInterfaces {
            let ni = LibboxNetworkInterface()
            ni.name = iface.name
            ni.index = Int32(iface.index)
            switch iface.type {
            case .wifi: ni.type = LibboxInterfaceTypeWIFI
            case .cellular: ni.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: ni.type = LibboxInterfaceTypeEthernet
            default: ni.type = LibboxInterfaceTypeOther
            }
            interfaces.append(ni)
        }
        return NetworkInterfaceArray(interfaces)
    }

    func underNetworkExtension() -> Bool {
        return true
    }

    /// VPN-KILLSWITCH (truth audit 2026-07-14): this used to hardcode
    /// `false`, which meant `NEVPNProtocol.includeAllNetworks` on the saved
    /// profile was cosmetic — libbox's own platform layer told the system
    /// "no" regardless of what the profile said. Read the App Group default
    /// directly: this extension process has no visibility into the host
    /// app's in-memory ConfigStore, and libbox calls this once per tunnel
    /// start, so a fresh read here is exactly "whatever the user's Settings
    /// toggle says as of THIS connect" — see VPNManager.applyKillSwitchSettings
    /// for what includeAllNetworks does and does not guarantee.
    func includeAllNetworks() -> Bool {
        UserDefaults(suiteName: AppConstants.appGroupID)?
            .bool(forKey: AppConstants.killSwitchEnabledKey) ?? false
    }

    func readWIFIState() -> LibboxWIFIState? {
        return nil
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        return nil
    }

    func clearDNSCache() {
        // Audit MED-007 (2026-05-26): Apple docs require NEPacketTunnelProvider
        // KVO-observable properties (reasserting, protocolConfiguration, etc.)
        // to be mutated on the main thread. libbox calls this from its own
        // background goroutine on every DNS-purge event, so without hopping
        // we'd race NEVPNStatusDidChange observers in the main app.
        guard let tunnel = tunnel else { return }
        DispatchQueue.main.async {
            tunnel.reasserting = true
            tunnel.reasserting = false
        }
    }

    func send(_ notification: LibboxNotification?) throws {
        // Not implemented for MVP
    }

    // startNeighborMonitor/closeNeighborMonitor removed in libbox 1.13

    func registerMyInterface(_ name: String?) {
        // Used by sing-box to register TUN interface name
    }

    // MARK: - Network Settings Builder

    private func buildTunnelSettings(from options: any LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        // IPv4
        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        if let iter = options.getInet4Address() {
            while iter.hasNext() {
                guard let prefix = iter.next() else { break }
                ipv4Addresses.append(prefix.address())
                ipv4Masks.append(prefix.mask())
            }
        }
        if ipv4Addresses.isEmpty {
            ipv4Addresses = ["172.19.0.1"]
            ipv4Masks = ["255.255.255.252"]
        }

        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)

        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        // Exclude APNs (17.0.0.0/8) to prevent push notification issues
        ipv4Settings.excludedRoutes = [NEIPv4Route(destinationAddress: "17.0.0.0", subnetMask: "255.0.0.0")]
        settings.ipv4Settings = ipv4Settings

        // IPv6
        var ipv6Addresses: [String] = []
        var ipv6Prefixes: [NSNumber] = []
        if let iter = options.getInet6Address() {
            while iter.hasNext() {
                guard let prefix = iter.next() else { break }
                ipv6Addresses.append(prefix.address())
                ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
        }
        if !ipv6Addresses.isEmpty {
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6Settings
        } else {
            // Build-56 leak-plug: capture all v6 routes INTO the tunnel even
            // when sing-box has no v6 outbound. Without this, dual-stack apps
            // (Safari, Gemini, Maps) do happy-eyeballs v6-first → packets go
            // natively → Google sees the real IP and geo-gates features. ULA
            // (RFC 4193) gives iOS a v6 source to route to; sing-box drops the
            // packet on the outbound side (no v6 exit), happy-eyeballs falls
            // back to v4 within ~250ms, v4 goes through the VPN as expected.
            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [NSNumber(value: 128)])
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6Settings
        }

        // DNS
        let dnsAddress = (try? options.getDNSServerAddress())?.value ?? "1.1.1.1"
        let dnsSettings = NEDNSSettings(servers: [dnsAddress])
        dnsSettings.matchDomains = [""]  // Route all DNS through tunnel
        settings.dnsSettings = dnsSettings

        return settings
    }

    private func prefixToMask(_ prefix: Int) -> String {
        let mask = prefix > 0 ? UInt32.max << (32 - prefix) : 0
        return "\(mask >> 24 & 0xFF).\(mask >> 16 & 0xFF).\(mask >> 8 & 0xFF).\(mask & 0xFF)"
    }

    // MARK: - Network Path Monitoring

    private func handlePathUpdate(_ path: Network.NWPath) {
        guard let listener = interfaceListener else { return }

        var interfaceName = ""
        var interfaceIndex: Int32 = 0

        if let iface = path.availableInterfaces.first {
            interfaceName = iface.name
            interfaceIndex = Int32(iface.index)
        }

        interfaceLock.lock()
        let prevInterfaceName = _lastInterfaceName
        _lastInterfaceName = interfaceName
        interfaceLock.unlock()
        let networkChanged = !prevInterfaceName.isEmpty && interfaceName != prevInterfaceName

        TunnelFileLogger.log("pathUpdate: status=\(path.status), iface=\(interfaceName)(\(interfaceIndex)), expensive=\(path.isExpensive)\(networkChanged ? " [NETWORK CHANGED]" : "")", category: "network")

        // Notify sing-box of interface change
        listener.updateDefaultInterface(
            interfaceName,
            interfaceIndex: interfaceIndex,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )

        // Force iOS to re-evaluate tunnel on network change (WiFi↔LTE)
        // Only reassert when switching between interfaces with connectivity,
        // not when going offline (unsatisfied) — avoids unnecessary restart.
        // reasserting must be mutated on the main thread (Apple docs);
        // this callback fires on NWPathMonitor's background queue. ROADMAP iOS-14.
        if networkChanged && path.status == .satisfied {
            TunnelFileLogger.log("Network switch detected, triggering reassert + DNS flush", category: "network")
            clearDNSCache()
            DispatchQueue.main.async { [weak self] in
                self?.tunnel?.reasserting = true
                self?.tunnel?.reasserting = false
            }
        }
    }
}

// MARK: - NetworkInterfaceArray Iterator

private class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ array: [LibboxNetworkInterface]) {
        iterator = array.makeIterator()
    }

    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? {
        nextValue
    }
}

// MARK: - LibboxCommandServerHandlerProtocol

extension ExtensionPlatformInterface: LibboxCommandServerHandlerProtocol {

    func serviceStop() throws {
        tunnel?.cancelTunnelWithError(nil)
    }

    func serviceReload() throws {
        TunnelFileLogger.log("serviceReload called", category: "singbox")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        return LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        // Not applicable on iOS
    }

    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        guard let messageList else { return }
        while messageList.hasNext() {
            guard let entry = messageList.next() else { continue }
            // Build-44: feed EVERY line to the stall detector (it fast-paths
            // non-dial events), regardless of the file-sink filter below.
            realStallDetector?.ingest(level: entry.level, message: entry.message)
            // NE-LOG-SINK-FIX (2026-07-15): raised INFO(2)→WARN(3). On-device
            // crash reports proved the file-sink volume at INFO was itself
            // enough to trip iOS's diskwrites_resource + cpu_resource limits
            // under load (a whoer.net connection storm killed the extension
            // in ~4s) — config log.level never gates this callback (fork
            // log/observable.go:140 delivers every line once a platform
            // writer exists), so only a Swift-side threshold can cut it.
            guard entry.level >= 3 else { continue }
            let levelStr: String
            switch entry.level {
            case 2: levelStr = "INFO"
            case 3: levelStr = "WARN"
            case 4: levelStr = "ERROR"
            case 5: levelStr = "FATAL"
            default: levelStr = "L\(entry.level)"
            }
            TunnelFileLogger.log("[\(levelStr)] \(entry.message)", category: "singbox")
        }
    }

    func writeMessage(_ level: Int32, message: String?) {
        guard let message else { return }
        realStallDetector?.ingest(level: level, message: message)
        // NE-LOG-SINK-FIX: keep WARN+ only out of the file sink (see writeLogs).
        guard level >= 3 else { return }
        TunnelFileLogger.log("[L\(level)] \(message)", category: "singbox")
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        // Build-44: most singbox dial-event lines arrive here (stderr-formatted
        // INFO/DEBUG/ERROR strings), so feed the detector FIRST — it must see
        // dial events even at DEBUG level. Its fast-path filter ignores anything
        // that's not a dial pattern.
        realStallDetector?.ingest(level: 2, message: message)
        // NE-LOG-SINK-FIX (2026-07-15): raised TRACE/DEBUG→also-drop-INFO
        // (isVerboseSingboxLine → isBelowWarnSingboxLine), matching the
        // writeLogs/writeMessage threshold. This callback carries the bulk of
        // sing-box's stderr-formatted stream and was confirmed the top
        // contributor to the on-device diskwrites_resource + cpu_resource
        // kills (a whoer.net storm killed the extension in ~4s at INFO).
        // config log.level cannot gate this (fork log/observable.go:140).
        guard !TunnelFileLogger.isBelowWarnSingboxLine(message) else { return }
        // Forward sing-box messages to our file logger too. libbox calls this
        // from arbitrary background threads — funnel writes through a serial
        // queue so concurrent emissions don't interleave (which used to corrupt
        // singbox.log because FileHandle has no internal locking).
        TunnelFileLogger.log(message, category: "singbox")
        Self.singboxLogQueue.async {
            let logURL = AppConstants.sharedContainerURL.appendingPathComponent("singbox.log")
            let line = "\(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            // LOG-01: bound singbox.log. libbox's DEBUG/TRACE firehose lands here
            // (config log.level is ignored by libbox), and an uncapped file grew
            // to 565 MB in the field. Truncate-to-half once over the cap, reading
            // ONLY the kept tail via seek — never load the (possibly huge) whole
            // file into the NE's ~50 MB budget.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? Int,
               let offset = TunnelFileLogger.truncationKeepOffset(fileSize: size, maxSize: TunnelFileLogger.singboxLogMaxSize) {
                if let rh = try? FileHandle(forReadingFrom: logURL) {
                    defer { try? rh.close() }
                    _ = try? rh.seek(toOffset: offset)
                    let tail = (try? rh.readToEnd()) ?? Data()
                    try? (Data("--- log truncated ---\n".utf8) + tail).write(to: logURL)
                }
            }

            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private static let singboxLogQueue = DispatchQueue(label: "vpn.madfrog.singbox-log", qos: .utility)
}

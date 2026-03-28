import Foundation
import NetworkExtension
import Network
import Libbox

/// Implements LibboxPlatformInterfaceProtocol + LibboxCommandServerHandlerProtocol.
/// Bridges sing-box Go engine ↔ iOS NetworkExtension.
/// Based on SFI (sing-box-for-apple) reference implementation.
final class ExtensionPlatformInterface: NSObject, @unchecked Sendable {
    weak var tunnel: NEPacketTunnelProvider?
    private var pathMonitor: NWPathMonitor?
    private var interfaceListener: LibboxInterfaceUpdateListenerProtocol?
    private var neighborListener: LibboxNeighborUpdateListenerProtocol?

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
        // On iOS the system handles interface binding for VPN sockets
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_ ret0: UnsafeMutablePointer<Int32>?) throws {
        // Use Task.detached via runBlocking to avoid deadlocking the provider queue.
        // SFI pattern: async/await setTunnelNetworkSettings in a detached task.
        try runBlocking { [self] in
            try await openTunAsync(options, ret0)
        }
    }

    private func openTunAsync(_ options: (any LibboxTunOptionsProtocol)?,
                               _ ret0: UnsafeMutablePointer<Int32>?) async throws {
        guard let tunnel = tunnel, let options = options, let ret0 = ret0 else {
            throw NSError(domain: "MadFrog", code: 1, userInfo: [NSLocalizedDescriptionKey: "No tunnel provider"])
        }

        let settings = try buildTunnelSettings(from: options)

        // Use withCheckedThrowingContinuation to wrap callback-based API.
        // This runs in a Task.detached context (via runBlocking),
        // so the completion handler can dispatch freely without deadlock.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tunnel.setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0.pointee = tunFd
            return
        }

        let tunFd = LibboxGetTunnelFileDescriptor()
        if tunFd != -1 {
            ret0.pointee = tunFd
        } else {
            throw NSError(domain: "MadFrog", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing TUN file descriptor"])
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

    func includeAllNetworks() -> Bool {
        return false
    }

    func readWIFIState() -> LibboxWIFIState? {
        return nil
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        return nil
    }

    func clearDNSCache() {
        // Toggle tunnel settings to flush iOS DNS cache
        guard let tunnel = tunnel else { return }
        tunnel.reasserting = true
        tunnel.reasserting = false
    }

    func send(_ notification: LibboxNotification?) throws {
        // Not implemented for MVP
    }

    func startNeighborMonitor(_ listener: (any LibboxNeighborUpdateListenerProtocol)?) throws {
        self.neighborListener = listener
    }

    func closeNeighborMonitor(_ listener: (any LibboxNeighborUpdateListenerProtocol)?) throws {
        self.neighborListener = nil
    }

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
                let prefix = iter.next()!
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
                let prefix = iter.next()!
                ipv6Addresses.append(prefix.address())
                ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
        }
        if ipv6Addresses.isEmpty {
            ipv6Addresses = ["fdfe:dcba:9876::1"]
            ipv6Prefixes = [126]
        }

        let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
        ipv6Settings.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6Settings

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

        listener.updateDefaultInterface(
            interfaceName,
            interfaceIndex: interfaceIndex,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
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
        // Reload handled by ExtensionProvider
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        return LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        // Not applicable on iOS
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        // Write to file so we can pull logs from device
        let logURL = AppConstants.sharedContainerURL.appendingPathComponent("singbox.log")
        let line = "\(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

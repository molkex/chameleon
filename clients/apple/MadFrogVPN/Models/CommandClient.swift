import Foundation
import Libbox

/// Connects to CommandServer running in the PacketTunnel extension via Unix socket.
/// Receives live traffic stats, outbound groups, and log entries.
///
/// The CommandClient finds the socket at `basePath/command.sock` where basePath
/// is set by `LibboxSetup()` in MadFrogVPNApp.init (main app side).
/// The extension's CommandServer creates the socket at the same path via its
/// own LibboxSetup call in ExtensionProvider.startSingBox().
/// Both sides MUST use the same sharedContainerURL from AppConstants.
@MainActor
@Observable
final class CommandClientWrapper {
    var uploadSpeed: Int64 = 0
    var downloadSpeed: Int64 = 0
    var uploadTotal: Int64 = 0
    var downloadTotal: Int64 = 0
    var connectionsIn: Int32 = 0
    var connectionsOut: Int32 = 0
    var isConnected = false

    /// Whether live stats are available. False when gRPC connection failed.
    var statsAvailable = true

    var groups: [ServerGroup] = []

    /// Called once after connection when the first group update is received.
    /// AppState uses this to apply the saved server preference.
    var onGroupsReceived: (([ServerGroup]) -> Void)?
    fileprivate var didDeliverGroups = false

    private var client: LibboxCommandClient?
    private let handler: ClientHandler

    /// Token-based cancellation: incremented on each connect/disconnect call.
    /// Prevents stale callbacks from old connections from updating state.
    /// nonisolated(unsafe) because ClientHandler reads this from libbox callbacks on arbitrary threads.
    fileprivate nonisolated(unsafe) var connectionToken: UInt64 = 0
    private var connectTask: Task<Void, Never>?

    init() {
        handler = ClientHandler()
        handler.wrapper = self
    }

    func connect() {
        // Disconnect any existing client first
        if let existingClient = client {
            try? existingClient.disconnect()
            client = nil
        }

        // Increment token to invalidate any in-flight callbacks
        connectionToken &+= 1
        let token = connectionToken

        // Cancel any pending connect task
        connectTask?.cancel()

        handler.connectionToken = token

        connectTask = Task { [weak self] in
            await self?.performConnection(token: token)
        }
    }

    private func performConnection(token: UInt64) async {
        // Small delay to let the extension's CommandServer start the gRPC listener.
        // The extension starts the server on a background queue, so it may not be
        // ready immediately when VPN status transitions to .connected.
        try? await Task.sleep(for: .seconds(0.5))

        guard !Task.isCancelled else { return }

        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandGroup)
        options.statusInterval = Int64(NSEC_PER_SEC) // 1 second

        guard let newClient = LibboxNewCommandClient(handler, options) else {
            AppLogger.app.error("LibboxNewCommandClient returned nil")
            await MainActor.run {
                statsAvailable = false
            }
            return
        }

        do {
            try newClient.connect()
            AppLogger.app.info("CommandClient connected successfully")
            TunnelFileLogger.log("CommandClient: connected", category: "ui")
            await MainActor.run { [weak self] in
                guard let self, self.connectionToken == token else {
                    try? newClient.disconnect()
                    return
                }
                self.client = newClient
                self.statsAvailable = true
            }
        } catch {
            AppLogger.app.error("CommandClient connect failed: \(error.localizedDescription)")

            // Retry once after a longer delay — the extension may still be starting
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            do {
                try newClient.connect()
                AppLogger.app.info("CommandClient connected on retry")
                await MainActor.run { [weak self] in
                    guard let self, self.connectionToken == token else {
                        try? newClient.disconnect()
                        return
                    }
                    self.client = newClient
                    self.statsAvailable = true
                }
            } catch {
                AppLogger.app.error("CommandClient retry failed: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self, self.connectionToken == token else { return }
                    self.statsAvailable = false
                }
            }
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        connectionToken &+= 1

        if let client {
            do {
                try client.disconnect()
            } catch {
                AppLogger.app.error("CommandClient disconnect failed: \(error)")
            }
        }
        client = nil
        isConnected = false
        didDeliverGroups = false
        // Reset stats on disconnect
        uploadSpeed = 0
        downloadSpeed = 0
        uploadTotal = 0
        downloadTotal = 0
        connectionsIn = 0
        connectionsOut = 0
        groups = []
    }

    var formattedUploadSpeed: String {
        guard statsAvailable else { return "—" }
        return LibboxFormatBytes(uploadSpeed) + "/s"
    }

    var formattedDownloadSpeed: String {
        guard statsAvailable else { return "—" }
        return LibboxFormatBytes(downloadSpeed) + "/s"
    }

    var formattedUploadTotal: String {
        guard statsAvailable else { return "—" }
        return LibboxFormatBytes(uploadTotal)
    }

    var formattedDownloadTotal: String {
        guard statsAvailable else { return "—" }
        return LibboxFormatBytes(downloadTotal)
    }

    /// Trigger URL test (ping) for a group.
    func urlTest(groupTag: String) {
        do {
            try client?.urlTest(groupTag)
        } catch {
            AppLogger.app.error("urlTest failed: \(error)")
        }
    }

    /// Manually select an outbound in a group.
    /// Also closes all existing connections so they reconnect through the new outbound —
    /// without this, in-flight TCP streams keep using the previously selected server.
    func selectOutbound(groupTag: String, outboundTag: String) {
        TunnelFileLogger.log("selectOutbound: begin group='\(groupTag)' outbound='\(outboundTag)'", category: "ui")
        do {
            try client?.selectOutbound(groupTag, outboundTag: outboundTag)
            TunnelFileLogger.log("selectOutbound: OK", category: "ui")
        } catch {
            AppLogger.app.error("selectOutbound failed: \(error)")
            TunnelFileLogger.log("selectOutbound: FAILED \(error)", category: "ui")
            return
        }
        do {
            try client?.closeConnections()
            TunnelFileLogger.log("closeConnections: OK", category: "ui")
        } catch {
            AppLogger.app.error("closeConnections failed: \(error)")
            TunnelFileLogger.log("closeConnections: FAILED \(error)", category: "ui")
        }
    }

}

// MARK: - LibboxCommandClientHandlerProtocol

private final class ClientHandler: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
    weak var wrapper: CommandClientWrapper?
    var connectionToken: UInt64 = 0

    private func isActive() -> Bool {
        wrapper?.connectionToken == connectionToken
    }

    func connected() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive() else { return }
            self.wrapper?.isConnected = true
            self.wrapper?.statsAvailable = true
            AppLogger.app.info("CommandClient handler: connected")
        }
    }

    func disconnected(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive() else { return }
            self.wrapper?.isConnected = false
            if let message {
                AppLogger.app.info("CommandClient handler: disconnected — \(message)")
            }
        }
    }

    func setDefaultLogLevel(_ level: Int32) {}
    func clearLogs() {}

    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else { return }
        let uplink = message.uplink
        let downlink = message.downlink
        let uplinkTotal = message.uplinkTotal
        let downlinkTotal = message.downlinkTotal
        let connIn = message.connectionsIn
        let connOut = message.connectionsOut
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive() else { return }
            self.wrapper?.uploadSpeed = uplink
            self.wrapper?.downloadSpeed = downlink
            self.wrapper?.uploadTotal = uplinkTotal
            self.wrapper?.downloadTotal = downlinkTotal
            self.wrapper?.connectionsIn = connIn
            self.wrapper?.connectionsOut = connOut
        }
    }

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let message else { return }
        var newGroups: [ServerGroup] = []
        while message.hasNext() {
            guard let group = message.next() else { break }
            var items: [ServerItem] = []
            if let itemIter = group.getItems() {
                while itemIter.hasNext() {
                    guard let item = itemIter.next() else { break }
                    items.append(ServerItem(
                        id: item.tag,
                        tag: item.tag,
                        type: item.type,
                        delay: item.urlTestDelay,
                        delayTime: item.urlTestTime
                    ))
                }
            }
            newGroups.append(ServerGroup(
                id: group.tag,
                tag: group.tag,
                type: group.type,
                selected: group.selected,
                items: items,
                selectable: group.selectable
            ))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive() else { return }
            guard let wrapper = self.wrapper else { return }
            wrapper.groups = newGroups
            if !wrapper.didDeliverGroups && !newGroups.isEmpty {
                wrapper.didDeliverGroups = true
                wrapper.onGroupsReceived?(newGroups)
            }
        }
    }

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}

    func write(_ events: LibboxConnectionEvents?) {}
}

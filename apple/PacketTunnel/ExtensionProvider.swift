import NetworkExtension
import Libbox

/// Base class for PacketTunnelProvider. Implements sing-box lifecycle
/// using CommandServer API (modern approach, same as SFI).
///
/// Architecture:
/// - VPN engine runs via CommandServer.startOrReloadService() — always works
/// - gRPC listener (server.start()) is non-fatal — provides live stats to main app
/// - If gRPC fails, VPN works; app sees stats as unavailable via shared UserDefaults
/// - handleAppMessage() serves as backup IPC channel for commands
open class ExtensionProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var platformInterface: ExtensionPlatformInterface?
    private var isGrpcRunning = false

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AppConstants.appGroupID)
    }

    // MARK: - Tunnel Lifecycle

    override open func startTunnel(options: [String: NSObject]?,
                                   completionHandler: @escaping (Error?) -> Void) {
        // Load config — prefer tunnel options, fallback to shared file
        let configJSON: String
        if let optionsConfig = options?["configContent"] as? String {
            configJSON = optionsConfig
            persistStartOptions(configJSON)
        } else if let persisted = loadPersistedConfig() {
            configJSON = persisted
        } else if let fileConfig = try? String(contentsOf: AppConstants.configFileURL, encoding: .utf8) {
            configJSON = fileConfig
        } else {
            completionHandler(NSError(domain: "Chameleon", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "No VPN config. Open app first."]))
            return
        }

        // MUST dispatch to background — startOrReloadService blocks the calling thread,
        // and setTunnelNetworkSettings needs the provider queue to be free.
        // Task.detached in runBlocking handles the async bridge inside openTun.
        let sanitizedConfig = ConfigSanitizer.sanitizeForIOS(configJSON)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.startSingBox(config: sanitizedConfig)
                AppLogger.tunnel.info("sing-box started successfully")
                completionHandler(nil)
            } catch {
                AppLogger.tunnel.error("sing-box start failed: \(error)")
                self.setGrpcState(false)
                completionHandler(error)
            }
        }
    }

    override open func stopTunnel(with reason: NEProviderStopReason,
                                  completionHandler: @escaping () -> Void) {
        AppLogger.tunnel.info("Stopping tunnel, reason: \(reason.rawValue)")
        stopSingBox()
        setGrpcState(false)
        completionHandler()
    }

    override open func handleAppMessage(_ messageData: Data,
                                        completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        switch command {
        case "reload":
            if let config = try? String(contentsOf: AppConstants.configFileURL, encoding: .utf8) {
                reloadService(config: config)
            }
            completionHandler?(nil)

        case "status":
            // Return extension status as JSON — backup channel when gRPC is down
            let status: [String: Any] = [
                "grpcAvailable": isGrpcRunning,
                "running": commandServer != nil
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: status))

        default:
            completionHandler?(nil)
        }
    }

    override open func sleep() async {
        commandServer?.pause()
    }

    override open func wake() {
        commandServer?.wake()
    }

    // MARK: - sing-box Engine

    private func startSingBox(config: String) throws {
        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = AppConstants.sharedContainerURL.path
        setupOptions.workingPath = AppConstants.workingDirectory.path
        setupOptions.tempPath = AppConstants.tempDirectory.path

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError { throw setupError }

        LibboxSetMemoryLimit(true)

        let logPath = AppConstants.sharedContainerURL.appendingPathComponent("stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(logPath, &stderrError)

        let platform = ExtensionPlatformInterface(tunnel: self)
        self.platformInterface = platform

        var cmdError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &cmdError) else {
            throw cmdError ?? NSError(domain: "Chameleon", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Failed to create CommandServer"])
        }
        self.commandServer = server

        do {
            try server.start()
            setGrpcState(true)
        } catch {
            setGrpcState(false)
            AppLogger.tunnel.warning("gRPC server failed (non-fatal): \(error.localizedDescription)")
        }

        #if DEBUG
        // Save sanitized config for debugging (only in debug builds)
        let debugConfigURL = AppConstants.sharedContainerURL.appendingPathComponent("sanitized-config.json")
        try? config.write(to: debugConfigURL, atomically: true, encoding: .utf8)
        #endif

        try server.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    private func stopSingBox() {
        if let server = commandServer {
            do {
                try server.closeService()
            } catch {
                AppLogger.tunnel.error("Failed to close service: \(error)")
            }
            server.close()
        }
        commandServer = nil
        platformInterface = nil
    }

    private func reloadService(config: String) {
        guard let server = commandServer else { return }
        reasserting = true
        do {
            let sanitized = ConfigSanitizer.sanitizeForIOS(config)
            try server.startOrReloadService(sanitized, options: LibboxOverrideOptions())
            AppLogger.tunnel.info("Config reloaded successfully")
        } catch {
            AppLogger.tunnel.error("Config reload failed: \(error)")
        }
        reasserting = false
    }

    // MARK: - Shared State

    private func setGrpcState(_ available: Bool) {
        isGrpcRunning = available
        sharedDefaults?.set(available, forKey: AppConstants.grpcAvailableKey)
    }

    // MARK: - Config Persistence (for on-demand reconnect)

    private func persistStartOptions(_ config: String) {
        sharedDefaults?.set(config, forKey: AppConstants.startOptionsKey)
    }

    private func loadPersistedConfig() -> String? {
        sharedDefaults?.string(forKey: AppConstants.startOptionsKey)
    }

}

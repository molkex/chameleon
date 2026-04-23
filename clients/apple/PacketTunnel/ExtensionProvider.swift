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
        // Do NOT clear log here — we lose all UI-side logs written before tunnel starts
        // (toggleVPN, connect button taps). Log rotation happens at 512KB anyway.
        TunnelFileLogger.log("========== TUNNEL START ==========")
        TunnelFileLogger.log("libbox version: \(LibboxVersion())")
        TunnelFileLogger.log("options keys: \(options?.keys.joined(separator: ", ") ?? "nil")")

        // If user just stopped VPN from iOS Settings, On Demand will try to restart immediately.
        // Refuse to start so the disconnect actually takes effect.
        if sharedDefaults?.bool(forKey: AppConstants.userStoppedVPNKey) == true {
            sharedDefaults?.removeObject(forKey: AppConstants.userStoppedVPNKey)
            TunnelFileLogger.log("Blocked On Demand restart after user-initiated stop")
            completionHandler(NSError(domain: "Chameleon", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "User stopped VPN"]))
            return
        }

        // Load config — prefer tunnel options, fallback to shared file
        let configJSON: String
        if let optionsConfig = options?["configContent"] as? String {
            configJSON = optionsConfig
            persistStartOptions(configJSON)
            TunnelFileLogger.log("Config source: tunnel options (\(optionsConfig.count) chars)")
        } else if let persisted = loadPersistedConfig() {
            configJSON = persisted
            TunnelFileLogger.log("Config source: persisted UserDefaults (\(persisted.count) chars)")
        } else if let fileConfig = try? String(contentsOf: AppConstants.configFileURL, encoding: .utf8) {
            configJSON = fileConfig
            TunnelFileLogger.log("Config source: file (\(fileConfig.count) chars)")
        } else {
            TunnelFileLogger.log("ERROR: No config found anywhere")
            completionHandler(NSError(domain: "Chameleon", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "No VPN config. Open app first."]))
            return
        }

        let sanitizedConfig = ConfigSanitizer.sanitizeForIOS(configJSON)
        TunnelFileLogger.log("Config sanitized, length: \(sanitizedConfig.count)")

        // MUST dispatch to background — startOrReloadService blocks the calling thread,
        // and setTunnelNetworkSettings needs the provider queue to be free.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completionHandler(NSError(domain: "Chameleon", code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Tunnel provider deallocated"]))
                return
            }
            do {
                try self.startSingBox(config: sanitizedConfig)
                TunnelFileLogger.log("sing-box started successfully")
                AppLogger.tunnel.info("sing-box started successfully")
                completionHandler(nil)
            } catch {
                TunnelFileLogger.log("ERROR: sing-box start failed: \(error)")
                AppLogger.tunnel.error("sing-box start failed: \(error)")
                self.setGrpcState(false)
                completionHandler(error)
            }
        }
    }

    override open func stopTunnel(with reason: NEProviderStopReason,
                                  completionHandler: @escaping () -> Void) {
        TunnelFileLogger.log("Stopping tunnel, reason: \(reason.rawValue)")
        AppLogger.tunnel.info("Stopping tunnel, reason: \(reason.rawValue)")

        // Signal to main app that user explicitly stopped VPN from iOS Settings.
        // Main app reads this in handleStatus() to disable On Demand.
        if reason == .userInitiated {
            sharedDefaults?.set(true, forKey: AppConstants.userStoppedVPNKey)
            TunnelFileLogger.log("User-initiated stop — signaled to main app")
        }

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
            let status: [String: Any] = [
                "grpcAvailable": isGrpcRunning,
                "running": commandServer != nil
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: status))

        case "diagnostics":
            let diag: [String: Any] = [
                "libboxVersion": LibboxVersion(),
                "engineRunning": commandServer != nil,
                "grpcRunning": isGrpcRunning,
                "configFileExists": FileManager.default.fileExists(atPath: AppConstants.configFileURL.path),
                "debugLogSize": (try? FileManager.default.attributesOfItem(atPath: TunnelFileLogger.logFileURL.path)[.size] as? Int) ?? 0,
                "stderrLogSize": (try? FileManager.default.attributesOfItem(atPath: TunnelFileLogger.stderrLogURL.path)[.size] as? Int) ?? 0,
                "sharedContainerPath": AppConstants.sharedContainerURL.path
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: diag))

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
        TunnelFileLogger.log("startSingBox: begin setup")

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = AppConstants.sharedContainerURL.path
        setupOptions.workingPath = AppConstants.workingDirectory.path
        setupOptions.tempPath = AppConstants.tempDirectory.path
        setupOptions.debug = true
        setupOptions.logMaxLines = 500
        TunnelFileLogger.log("Paths — base: \(setupOptions.basePath), work: \(setupOptions.workingPath)")

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            TunnelFileLogger.log("ERROR: LibboxSetup failed: \(setupError)")
            throw setupError
        }
        TunnelFileLogger.log("LibboxSetup OK")

        LibboxSetMemoryLimit(true)

        let logPath = AppConstants.sharedContainerURL.appendingPathComponent("stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(logPath, &stderrError)
        if let stderrError {
            TunnelFileLogger.log("WARNING: RedirectStderr failed: \(stderrError)")
        }
        TunnelFileLogger.log("stderr redirected to: \(logPath)")

        let platform = ExtensionPlatformInterface(tunnel: self)
        self.platformInterface = platform
        TunnelFileLogger.log("PlatformInterface created")

        var cmdError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &cmdError) else {
            let err = cmdError ?? NSError(domain: "Chameleon", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Failed to create CommandServer"])
            TunnelFileLogger.log("ERROR: CommandServer creation failed: \(err)")
            throw err
        }
        self.commandServer = server
        TunnelFileLogger.log("CommandServer created")

        do {
            try server.start()
            setGrpcState(true)
            TunnelFileLogger.log("gRPC server started OK")
        } catch {
            setGrpcState(false)
            TunnelFileLogger.log("WARNING: gRPC server failed (non-fatal): \(error.localizedDescription)")
            AppLogger.tunnel.warning("gRPC server failed (non-fatal): \(error.localizedDescription)")
        }

        // Save sanitized config for debugging — DEBUG only.
        // The file contains the user's UUID and full server list; not safe
        // to leave on disk in App Store builds.
        #if DEBUG
        let debugConfigURL = AppConstants.sharedContainerURL.appendingPathComponent("sanitized-config.json")
        try? config.write(to: debugConfigURL, atomically: true, encoding: .utf8)
        #endif

        TunnelFileLogger.log("Calling startOrReloadService (this blocks)...")
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
        TunnelFileLogger.log("startOrReloadService returned OK")
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

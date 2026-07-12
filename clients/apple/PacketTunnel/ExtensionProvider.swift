import NetworkExtension
import Libbox
import UserNotifications
#if os(iOS)
import WidgetKit
#endif

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
    private var memoryWatchdog: DispatchSourceTimer?

    /// CLIENT-EXT-RACE (P1) guard: invalidates a late `startTunnel`
    /// completion that races a fast `stopTunnel` (see TunnelStartGuard doc).
    private let startGuard = TunnelStartGuard()

    /// Build-39 stall detector. Lives only while sing-box is running.
    /// Catches the dead-leaf scenario the main-app TrafficHealthMonitor
    /// can't reach when the user is in Safari and MadFrog is suspended.
    /// Build-44: kept as a passive diagnostic only — `RealTrafficStallDetector`
    /// below is the new authoritative source for stall signals because
    /// synthetic probes (which is what TunnelStallProbe does) gave
    /// false-OK readings while real user traffic was timing out.
    private var stallProbe: TunnelStallProbe?

    /// Build-44 real-traffic stall detector. Subscribes to every
    /// sing-box log line via `ExtensionPlatformInterface.writeLogs`,
    /// counts dial timeouts in a 30 s sliding window, fires STALL when
    /// the formula matches against actual user-traffic outcomes.
    private var realStallDetector: RealTrafficStallDetector?

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AppConstants.appGroupID)
    }

    /// Extension is the single source of truth for the widget's
    /// connected/disconnected state: the main app's handleStatus() also
    /// maintains vpnConnectedAtKey but isn't running when the VPN is
    /// toggled from the Control Center widget / interactive button / iOS
    /// Settings. Writing the key here + reloading widget timelines keeps
    /// the widget honest regardless of who flipped the VPN. Key semantics
    /// (timestamp on connect, key removed on disconnect) live in
    /// WidgetVPNSnapshot.write — shared with the optimistic write in
    /// ToggleVPNIntent so the two never drift.
    private func publishWidgetState(connected: Bool) {
        #if os(iOS)
        WidgetVPNSnapshot.write(connected: connected, to: sharedDefaults)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Memory diagnostics

    /// Build-38: detailed memory snapshot for jetsam-correlation diagnostics.
    /// All values in MB. `phys` is what jetsam tracks; the rest help localize
    /// growth between Swift heap, Go heap, and mmap'd regions.
    fileprivate struct MemorySnapshot {
        let phys: Int        // phys_footprint — the jetsam metric
        let resident: Int    // resident_size — RSS, uncompressed pages in RAM
        let virt: Int        // virtual_size — total VM mapping (incl. file-backed)
        let compressed: Int  // pages currently in compressed memory
        let intern: Int      // process-internal pages (heaps, stacks)
        let external: Int    // mmap'd files + shared regions
        let avail: Int       // os_proc_available_memory — left before jetsam
    }

    fileprivate func memorySnapshot() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb: (UInt64) -> Int = { Int($0 / (1024 * 1024)) }
        let avail = availableMemoryMB()
        guard kr == KERN_SUCCESS else {
            return MemorySnapshot(phys: -1, resident: -1, virt: -1, compressed: -1,
                                  intern: -1, external: -1, avail: avail)
        }
        return MemorySnapshot(
            phys: mb(info.phys_footprint),
            resident: mb(info.resident_size),
            virt: mb(info.virtual_size),
            compressed: mb(info.compressed),
            intern: mb(info.`internal`),
            external: mb(info.external),
            avail: avail
        )
    }

    /// Current resident memory footprint of this process in MB. Kept for
    /// callers that just want the headline number (logSync at start/stop).
    fileprivate func currentMemoryFootprintMB() -> Int {
        memorySnapshot().phys
    }

    /// Remaining memory before jetsam fires (iOS 13+), in MB.
    fileprivate func availableMemoryMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory() / (1024 * 1024))
        #else
        // os_proc_available_memory() is iOS-only (jetsam budget). macOS NE
        // extensions have no equivalent hard memory cap — report -1 ("n/a").
        return -1
        #endif
    }

    /// Start a timer that logs memory every 15s. Gives us breadcrumbs so post-kill
    /// debug reports show the growth curve leading up to jetsam.
    ///
    /// Build-38: log full breakdown + active interface name (en0 vs pdp_ip0)
    /// so we can correlate the WiFi-only memory pressure observed in build 37
    /// field tests (44MB on Wi-Fi → jetsam in ~60s vs 37–39MB plateau on LTE).
    private func startMemoryWatchdog() {
        memoryWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let s = self.memorySnapshot()
            let iface = self.platformInterface?.currentInterfaceName ?? "?"
            TunnelFileLogger.log(
                "memory: phys=\(s.phys)MB resident=\(s.resident)MB virt=\(s.virt)MB "
                + "compressed=\(s.compressed)MB internal=\(s.intern)MB external=\(s.external)MB "
                + "avail=\(s.avail)MB iface=\(iface)",
                category: "memory"
            )
            // Proactive GC hint when we're close to the limit. Libbox is Go —
            // setting GOMEMLIMIT already presses the runtime but an explicit
            // hint from Swift can't hurt. (We call Swift's malloc_zone_pressure
            // equivalent; the Go side reacts via signal handler.)
            if s.avail < 8 {
                TunnelFileLogger.logSync("memory pressure — \(s.avail)MB left iface=\(iface)", category: "memory")
            }
        }
        timer.resume()
        memoryWatchdog = timer
    }

    private func stopMemoryWatchdog() {
        memoryWatchdog?.cancel()
        memoryWatchdog = nil
    }

    // MARK: - Tunnel Lifecycle

    override open func startTunnel(options: [String: NSObject]?,
                                   completionHandler: @escaping (Error?) -> Void) {
        // CLIENT-EXT-RACE (P1): claim a generation token for this start
        // attempt before doing anything else. The background block below
        // re-checks this token right before publishing a 'connected' side
        // effect; if stopTunnel() invalidates it first (fast connect→
        // disconnect), the late start tears itself down instead of
        // resurrecting a stale 'connected' signal. See TunnelStartGuard.
        let startToken = startGuard.beginGeneration()

        // iOS NE extension 50 MB hard cap — jetsam SIGKILLs us past that. Pin Go
        // runtime so GC runs aggressively before we hit the wall.
        // GOMEMLIMIT is a soft target (Go 1.19+); GOGC=25 makes GC run 4× more
        // often than default (100). These MUST be set before libbox init loads
        // the Go runtime. Matches practice of Hiddify/sfi.
        //
        // 2026-06-21 (PRODUCT-MATURITY-LOOP): lowered 42MiB → 38MiB. Real device
        // logs show the libbox oom-killer (LibboxSetMemoryLimit) resetting the
        // network at 40 MiB. The old 42MiB GOMEMLIMIT sat ABOVE that trip, so Go
        // never pressed before the fork reset — it was inert. 38MiB is below the
        // trip, so the runtime GCs/releases under 40 first. This can only free
        // more memory (worst case = a little extra GC CPU); verify resets drop via
        // the on-device memory watchdog log before tuning further.
        setenv("GOMEMLIMIT", "38MiB", 1)
        setenv("GOGC", "25", 1)
        setenv("GODEBUG", "madvdontneed=1", 1)

        // Do NOT clear log here — we lose all UI-side logs written before tunnel starts
        // (toggleVPN, connect button taps). Log rotation happens at 512KB anyway.
        // Sync flush for the boot markers: if jetsam kills us in the first few
        // seconds these lines are the only diagnostic the user can surface.
        TunnelFileLogger.logSync("========== TUNNEL START ==========")
        TunnelFileLogger.logSync("libbox version: \(LibboxVersion())")
        TunnelFileLogger.logSync("GOMEMLIMIT=38MiB GOGC=25 — below the 40MiB oom-killer trip", category: "memory")
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
                TunnelFileLogger.logSync("sing-box started successfully (memory: \(self.currentMemoryFootprintMB())MB/\(self.availableMemoryMB())MB avail)", category: "memory")
                AppLogger.tunnel.info("sing-box started successfully")

                // CLIENT-EXT-RACE (P1): if stopTunnel already fired while we
                // were starting, this success is stale — the tunnel has
                // already been commanded to stop. Tear down what we just
                // brought up and report failure instead of publishing a
                // 'connected' widget/watchdog/completionHandler signal after
                // the user already disconnected.
                guard self.startGuard.isCurrent(startToken) else {
                    TunnelFileLogger.logSync("startTunnel: stale generation after start success — stopTunnel raced us, tearing down zombie start")
                    self.stopSingBox()
                    self.setGrpcState(false)
                    completionHandler(NSError(domain: "Chameleon", code: 3,
                                              userInfo: [NSLocalizedDescriptionKey: "Tunnel was stopped before start completed"]))
                    return
                }

                self.startMemoryWatchdog()
                self.startStallProbe()
                self.publishWidgetState(connected: true)
                completionHandler(nil)
            } catch {
                TunnelFileLogger.logSync("ERROR: sing-box start failed: \(error)")
                AppLogger.tunnel.error("sing-box start failed: \(error)")
                // Audit MED-008 (2026-05-26): explicitly tear down the
                // CommandServer + any partially-started service. The previous
                // code only flipped grpcRunning=false and returned the error,
                // leaving any sockets/file descriptors opened during
                // startSingBox() dangling until the extension itself
                // terminates. stopSingBox is idempotent — safe to call even
                // if no listener was bound.
                self.stopSingBox()
                self.setGrpcState(false)
                // CLIENT-EXT-RACE (P1): teardown above is unconditional
                // (idempotent, and this is a failure/disconnected signal —
                // never a stale 'connected' one), but skip re-publishing the
                // widget as disconnected if stopTunnel already did it, purely
                // to keep the log/diagnostic trail honest about which path
                // ran.
                if self.startGuard.isCurrent(startToken) {
                    self.publishWidgetState(connected: false)
                } else {
                    TunnelFileLogger.log("startTunnel: stale generation after start failure — stopTunnel already handled teardown/widget state")
                }
                completionHandler(error)
            }
        }
    }

    override open func stopTunnel(with reason: NEProviderStopReason,
                                  completionHandler: @escaping () -> Void) {
        // CLIENT-EXT-RACE (P1): invalidate any in-flight startTunnel first,
        // before anything else runs. Closes the race window as tightly as
        // possible — a start whose token was captured before this line will
        // see isCurrent() == false and refuse to publish 'connected'.
        startGuard.invalidate()

        // Sync flush — reason=2 (providerFailed) typically means jetsam is
        // about to SIGKILL us, queue won't drain in time.
        TunnelFileLogger.logSync("Stopping tunnel, reason: \(reason.rawValue)")
        TunnelFileLogger.logSync("memory at stop: \(currentMemoryFootprintMB())MB of \(availableMemoryMB())MB", category: "memory")
        AppLogger.tunnel.info("Stopping tunnel, reason: \(reason.rawValue)")

        // Signal to main app that user explicitly stopped VPN from iOS Settings.
        // Main app reads this in handleStatus() to disable On Demand.
        if reason == .userInitiated {
            sharedDefaults?.set(true, forKey: AppConstants.userStoppedVPNKey)
            TunnelFileLogger.log("User-initiated stop — signaled to main app")
        }

        stopStallProbe()
        stopMemoryWatchdog()
        stopSingBox()
        setGrpcState(false)
        publishWidgetState(connected: false)
        completionHandler()
    }

    // MARK: - Stall probe lifecycle

    private func startStallProbe() {
        guard stallProbe == nil else { return }

        // Build-44: real-traffic detector takes authority for fallback
        // signals. The synthetic probe stays only as an idle health
        // ping with `onStall` set to no-op (its FAIL counter still logs
        // for diagnostics, but it does NOT cross-process-signal the
        // main app on its own — only RealTrafficStallDetector does).
        let detector = RealTrafficStallDetector(onStall: { [weak self] reason, now in
            guard let self else { return }
            self.sharedDefaults?.set(now.timeIntervalSince1970,
                                     forKey: AppConstants.tunnelStallRequestedAtKey)
            TunnelFileLogger.log("RealTrafficStallDetector: signalled main app via shared defaults reason=\(reason)", category: "real-stall")

            // Build-49: force sing-box to re-probe all urltest groups RIGHT NOW
            // from inside the extension — don't wait for the suspended main app.
            // After re-probe OVH shows timeout, NL wins; interrupt_exist_connections
            // kills stalled streams and they reconnect through NL automatically.
            // This recovers traffic without any user action.
            self.stallProbe?.nudgeNow()

            // Also wake the main app if it is backgrounded (not suspended) so
            // AppState.handleExtensionStallSignalIfAny() can update UI and persist
            // the new server selection.
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(AppConstants.tunnelStallDarwinNotification as CFString),
                nil, nil, true
            )

            // OOM-SELF-HEAL: a memory-pressure reset recovers SILENTLY — the
            // re-elect above is enough, and the oom-killer fires every few
            // minutes under load, so a banner each time would be spam. Only a
            // genuine leg-stall (dns/dial) shows the "switching server" banner.
            guard reason != .oomReset else { return }

            // For the suspended-app case: passive banner so user can tap to open.
            let content = UNMutableNotificationContent()
            content.title = "MadFrog VPN"
            content.body = "Переключаемся на резервный сервер…"
            content.sound = .none
            content.interruptionLevel = .passive
            let request = UNNotificationRequest(
                identifier: AppConstants.tunnelStallNotificationID,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [AppConstants.tunnelStallNotificationID]
            )
            UNUserNotificationCenter.current().add(request)
        })
        realStallDetector = detector
        platformInterface?.realStallDetector = detector

        let probe = TunnelStallProbe()
        stallProbe = probe
        probe.start()
    }

    private func stopStallProbe() {
        stallProbe?.stop()
        stallProbe = nil
        platformInterface?.realStallDetector = nil
        realStallDetector = nil
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
        // Build-48: always enable libbox debug log forwarding so
        // RealTrafficStallDetector receives ERROR-level dial-timeout lines
        // in production builds. Earlier builds set debug=false in Release
        // which caused writeDebugMessage to never fire (0 sing-box log lines
        // in TestFlight), making the stall detector completely blind.
        // logMaxLines=500 caps the Go-side ring buffer so memory stays
        // bounded even at ~30 lines/sec with sing-box config level="info".
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

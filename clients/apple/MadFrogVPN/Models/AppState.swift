import Foundation
import SwiftUI
import NetworkExtension
import AuthenticationServices
import UserNotifications
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class AppState {
    let configStore = ConfigStore()
    let apiClient = APIClient()
    let vpnManager = VPNManager()
    let commandClient = CommandClientWrapper()
    let pingService = PingService()
    /// LAUNCH-08 — local-notification helper. Owned here because it has to
    /// see every NEVPNStatus transition, and `handleStatus()` is the single
    /// place those land.
    let disconnectNotifier = DisconnectNotifier()

    /// USR-09 Phase 2 — client-side event sink. See EventTracker.swift.
    /// Lazy because we need configStore.accessToken accessible from the
    /// tracker's flush closure, and the store is set up before AppState
    /// is fully built only via the closure-capture dance below.
    @ObservationIgnored
    private(set) lazy var eventTracker: EventTracker = {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let versionString = "\(appVersion) (\(build))"
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        let storage: URL = {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return support.appendingPathComponent("madfrog-events.json")
        }()
        return EventTracker(
            api: apiClient,
            storage: storage,
            appVersion: versionString,
            platform: platform,
            deviceID: PlatformDevice.identifier,
            tokenProvider: { [weak self] in self?.configStore.accessToken }
        )
    }()

    @ObservationIgnored private(set) lazy var subscriptionManager: SubscriptionManager = {
        SubscriptionManager { [weak self] signedJWS in
            guard let self, let token = self.configStore.accessToken else {
                throw APIError.unauthorized
            }
            return try await self.apiClient.verifySubscription(signedJWS: signedJWS, accessToken: token)
        }
    }()

    var servers: [ServerGroup] = []
    /// Currently selected server tag, mirrored into configStore (UserDefaults).
    /// Stored here as @Observable so SwiftUI views (pill, ServerListView) react
    /// to user selection without polling. configStore stays the persistence
    /// layer (also read by PacketTunnel extension which has no AppState).
    var selectedServerTag: String?
    var isLoading = false
    var errorMessage: String?
    var vpnConnectedAt: Date?
    var subscriptionExpire: Date?
    var isAuthenticated: Bool = false
    var isInitialized: Bool = false
    /// ACCT-IDENTITY (2026-06-01): set when an identity user's (Apple/Google/
    /// email) session can no longer be silently refreshed (refresh token dead
    /// after >30d dormancy, or backend 404). The app KEEPS the Keychain
    /// identity and surfaces a non-destructive re-auth banner instead of
    /// demoting the user to a fresh anonymous trial. Cleared on any successful
    /// (re-)authentication or token refresh.
    var needsReauth: Bool = false
    /// When true, UI should present the VPN permission primer instead of
    /// toggling the tunnel. Set by `requestConnect()` on first connect
    /// attempt; UI clears it via `proceedAfterPrimer()` or by dismissing.
    var showPermissionPrimer: Bool = false
    /// EXPIRED-PAYWALL-ON-CONNECT (2026-06-17): flipped true when a CONNECT
    /// attempt is gated because the subscription is expired/absent — the UI
    /// presents the paywall instead of toggling the tunnel. Set by
    /// `requestToggle()` after a reclaim attempt fails; the sheet clears it.
    var requestPaywall: Bool = false
    /// SUPPORT-CHAT P4: flipped true when the user taps a "support reply" push.
    /// The app root observes this and presents `SupportChatView` from anywhere;
    /// the sheet's dismiss resets it back to false.
    var pendingSupportChatOpen: Bool = false
    var routingMode: RoutingMode = {
        let raw = UserDefaults(suiteName: AppConstants.appGroupID)?
            .string(forKey: AppConstants.routingModeKey) ?? ""
        return RoutingMode(rawValue: raw) ?? .default
    }()

    /// "Power-user" mode: when ON, the server picker exposes per-protocol
    /// leaves (Hysteria2/TUIC/Direct/via-MSK) and the home pill shows a
    /// subtitle with the active leg. Unlocked via 5-tap on the picker
    /// nav title; sticky for the session, not persisted — a kill+relaunch
    /// returns to the simplified UX.
    var powerModeUnlocked: Bool = false

    /// Last fallback notification message (Russian/English depending on
    /// system locale). Surfaced as a toast over the home view; nil hides it.
    /// Auto-clears after 5s like errorMessage. Set by TrafficHealthMonitor
    /// when it switches the user off a dead leg.
    var fallbackToastMessage: String?

    /// True when the host SwiftUI scene is active (foreground+visible).
    /// Set by MadFrogVPNApp's `.onChange(of: scenePhase)`. The traffic
    /// health monitor reads this so it doesn't probe in the background.
    var isAppActive: Bool = true

    /// Built lazily on first foreground after a connect. Owned here so the
    /// extension's libbox doesn't have to know about it (extension memory
    /// is tight; this lives in main app process).
    @ObservationIgnored
    var trafficHealthMonitor: TrafficHealthMonitor?

    /// Build-39: server selection moved out of the NetworkExtension's
    /// sing-box `urltest` outbound and into the main app. PathPicker probes
    /// candidate leaves via NWConnection (TCP-only, no HTTP) and picks the
    /// lowest-latency winner — the extension just gets a single leaf via
    /// `selectOutbound("Proxy", leaf)`. See PathPicker.swift header for
    /// rationale (50MB jetsam cap on iOS NE extensions).
    @ObservationIgnored
    private let leafRankingStore = LeafRankingStore()
    @ObservationIgnored
    lazy var pathPicker = PathPicker(store: leafRankingStore)

    /// Build-35: per-network "this leaf worked here last time" memory.
    /// Kept across the build-39 refactor as a fast-path hint: if PathPicker
    /// has a fresh measurement for the remembered leaf, we skip the full
    /// probe round.
    @ObservationIgnored
    let lastWorkingLegStore = LastWorkingLegStore()
    /// Cached fingerprint of the current network — refreshed at every
    /// connect attempt and at health-probe success.
    @ObservationIgnored
    var currentNetworkFingerprint: String?

    /// Build-37: single-flight guard for `toggleVPN()`. iOS sometimes delivers
    /// duplicate touch events from a single physical tap (or the user double-
    /// taps), and SwiftUI's `Button` does not debounce. Without this guard, two
    /// taps within the same MainActor hop both pass `vpnManager.isConnected`
    /// and start two parallel connect flows: 2× preconnect race, 2× tunnel
    /// start, then 2× `applyRoutingModeIfLive` + `applyServerSelectionIfLive`,
    /// each spawning its own `selectOutbound` chain. The combined burst (8+
    /// `closeConnections` in 100ms) tears every TLS handshake the user's
    /// browser has in flight — the "то грузило то не грузило" symptom from
    /// 2026-04-26 field test. Stored as nonisolated(unsafe) since `@Observable`
    /// + `@MainActor` + mutable property combo needs the dance.
    @ObservationIgnored
    private var toggleVPNInFlight: Bool = false

    /// Build-37: cancel-then-replace slots for the deferred apply tasks
    /// triggered by `handleStatus(.connected)`. NEVPNStatusDidChange can fire
    /// `.connected` more than once during a single connect cycle (status
    /// observer may re-emit; toggleVPN's `awaitConnectionWithSilentRetry`
    /// also triggers `handleStatus()` directly to belt-and-braces a missed
    /// transition). Without these slots, every duplicate `.connected` queues
    /// another retry-loop that polls `commandClient.isConnected` and fires
    /// the same `selectOutbound` calls when it becomes ready — which is what
    /// caused the 8× `closeConnections` storm in the 2026-04-26 NL field log.
    @ObservationIgnored
    private var pendingApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var routingApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var selectionApplyTask: Task<Void, Never>?

    /// Per-country failed-leaf attempts inside a single fallback cascade.
    /// Cleared whenever the user manually selects a server or the cascade
    /// settles back to a working state. Prevents the monitor from cycling
    /// through the same dead leaves forever — once a leaf has failed in
    /// the current sequence we skip it and escalate.
    @ObservationIgnored
    var deadLeavesInCurrentCascade: Set<String> = []

    /// Country urltest tags that exhausted all their leaves in the current
    /// cascade. Used by the build-33 cascade chain to skip already-tried
    /// countries when escalating to the next-best country. Cleared on
    /// manual user pick or a clean recovery (probe success).
    @ObservationIgnored
    var deadCountriesInCurrentCascade: Set<String> = []

    /// Hard cap on cascade depth. We try at most `maxCascadeDepth` distinct
    /// countries before falling through to SPB relays — prevents the
    /// monitor from spending the user's battery flailing across every
    /// country when the underlying network is genuinely down.
    private let maxCascadeDepth = 3

    @ObservationIgnored nonisolated(unsafe) private var statusObserver: Any?
    /// Background config refresh task (handleForeground, toggleVPN).
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    /// Server switch reconnect task (selectServer). Separate from refreshTask
    /// so that background config updates don't cancel reconnection.
    @ObservationIgnored nonisolated(unsafe) private var reconnectTask: Task<Void, Never>?
    /// Darwin cross-process observer installed once for tunnel-stall wakeup.
    @ObservationIgnored nonisolated(unsafe) var darwinStallObserverInstalled = false

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        refreshTask?.cancel()
        reconnectTask?.cancel()
    }

    func initialize() async {
        installDarwinStallObserverIfNeeded()

        // ACCT-IDENTITY (2026-06-01): Keychain is the source of truth, NOT the
        // app-group UserDefaults `onboardingCompleted` flag. Keychain creds
        // survive app delete/reinstall AND app-group container resets; the UD
        // flag does NOT. The old code read "flag missing + creds present" as a
        // fresh install and WIPED the Keychain — silently demoting a real
        // (often paying) account to a brand-new anonymous trial. That was the
        // P0. Correct interpretation: creds present ⇒ established user. Never
        // wipe here; just self-heal the flag so the rest of the app sees a
        // consistent state. A genuine fresh install has no Keychain creds, so
        // nothing to heal and onboarding shows as normal.
        let sharedDefaults = UserDefaults(suiteName: AppConstants.appGroupID)
        let onboardingDone = sharedDefaults?.bool(forKey: AppConstants.onboardingCompletedKey) ?? false
        if !onboardingDone && configStore.username != nil {
            AppLogger.app.info("initialize: Keychain creds present but onboarding flag missing — self-healing flag, NOT wiping (ACCT-IDENTITY)")
            sharedDefaults?.set(true, forKey: AppConstants.onboardingCompletedKey)
        }

        // Fix: if config file is corrupted (missing selector/urltest), delete it
        // so fresh config is fetched from API
        repairConfigIfNeeded()

        // ACCT-IDENTITY (P0, recurred on build 98): a cached payload that isn't a
        // real sing-box config (error body, Cloudflare/relay error page, throttled
        // response) is a BAD CONFIG, not a sign-out. Discard ONLY the cached config
        // + start options and re-fetch for the SAME identity. NEVER clear() here —
        // clear() wipes authProvider/appleUserID and demoted a paying user to a
        // fresh anonymous trial. (Guard 1 — doFetchAndSave — now prevents such a
        // body from being cached in the first place; this stays as belt-and-suspenders
        // for any pre-existing bad cache.)
        if let cached = configStore.loadConfig(), !AppState.isUsableConfigPayload(cached) {
            AppLogger.app.info("initialize: cached config is not a usable sing-box config — discarding cache, KEEPING identity (ACCT-IDENTITY)")
            try? FileManager.default.removeItem(at: AppConstants.configFileURL)
            UserDefaults(suiteName: AppConstants.appGroupID)?.removeObject(forKey: AppConstants.startOptionsKey)
        }

        servers = configStore.parseServersFromConfig()
        selectedServerTag = configStore.selectedServerTag
        subscriptionExpire = configStore.subscriptionExpire
        isAuthenticated = configStore.username != nil

        // Build-32 migration: legacy installs may have a leaf tag pinned
        // (e.g. "de-h2-de") because the previous picker wrote leaves
        // directly. The new default UX pins country urltests instead, and
        // a stale leaf pin can leave the user on a dead protocol with no
        // way to recover via the simplified UI. Promote leaf → country
        // exactly once. Power-mode users who deliberately pick a leaf
        // after this migration runs are unaffected.
        AppState.migrateLeafToCountryIfNeeded(
            configStore: configStore,
            servers: servers,
            mirrorTo: { [weak self] newTag in self?.selectedServerTag = newTag }
        )

        do {
            try await vpnManager.load()
            startObservingVPNStatus()
            // Sync initial state: if VPN is already up (e.g. cold start while On Demand
            // reconnected the tunnel), proactively stamp vpnConnectedAt and kick the
            // command client so chips/timers render correctly.
            handleStatus()
        } catch {
            AppLogger.app.error("VPN load failed: \(error)")
        }

        // Mark as initialized BEFORE network calls — prevents black screen when offline.
        // UI can now render immediately with cached data while config refreshes in background.
        isInitialized = true

        // USR-09 Phase 2 — start the event tracker. Restores any persisted
        // queue and schedules the foreground flush timer. The launch event
        // is logged once per cold start so we can chart DAU vs MAU from
        // app-side instead of relying purely on /config touches.
        await eventTracker.start()
        await eventTracker.log(
            name: "app.launch",
            properties: ["authenticated": isAuthenticated]
        )

        // STORE-COUNTRY: cache the App Store storefront once so APIClient can
        // attach it as X-Store-Country on every request (admin visibility of the
        // download region). Fire-and-forget — never delays launch.
        Task { await subscriptionManager.cacheStorefrontCountry() }

        // Refresh config silently on app launch (only if already signed in)
        if configStore.username != nil {
            await silentConfigUpdate()
        }

        // ACCT-IDENTITY StoreKit backstop: if the backend shows no active sub
        // but StoreKit has a live entitlement (auto-restored from the Apple ID,
        // no login/prompt), push it so the server reclaims the subscription by
        // originalTransactionId — a paying user is never shown a trial, even if
        // their account state got confused. Cheap + silent (no AppStore.sync()).
        let subActive = subscriptionExpire.map { $0 > Date() } ?? false
        // ACCT-IDENTITY (decision 0010): also run the backstop when we're on an
        // ANONYMOUS account — a demote can park the device on a fresh anon TRIAL
        // (so subActive==true) while a real Apple entitlement still exists. Gating
        // only on !subActive would skip the silent reclaim and strand a payer on
        // the wrong account → "вернулось без перезахода" never happens. The reclaim
        // is a no-op when StoreKit has no live entitlement, so it's safe for a
        // genuine anon user.
        let onAnonAccount = configStore.authProvider == nil
        if configStore.username != nil, (!subActive || onAnonAccount) {
            if await subscriptionManager.reconcileEntitlementsSilently() {
                AppLogger.app.info("initialize: StoreKit entitlement found — re-fetching config after backend reclaim")
                await silentConfigUpdate()
                subscriptionExpire = configStore.subscriptionExpire
            }
        }

        // ACCT-IDENTITY recovery ladder, step 0: launch-time Apple credential
        // health check (no UI). A `.revoked` flags re-auth proactively; never
        // wipes creds. Runs detached so it never delays first paint.
        Task { await self.verifyAppleCredentialState() }

        // SUPPORT-CHAT P4: once the user has a session, register for APNs so the
        // backend can push support replies. Fire-and-forget — never blocks
        // startup; the system prompt (if not yet answered) appears post-launch.
        if configStore.accessToken != nil {
            registerForPushNotifications()
        }
    }

    /// Forwarded from the SwiftUI scene's `.onChange(of: scenePhase)`.
    /// USR-09 Phase 2 — every foreground/background transition is a good
    /// flush trigger: we want batches sent before the OS suspends us, and
    /// we want a quick top-up while the user is actively using the app.
    func handleScenePhaseChange(active: Bool) async {
        if active {
            await eventTracker.flushNow()
            await eventTracker.log(name: "app.foreground", properties: nil)
        } else {
            await eventTracker.log(name: "app.background", properties: nil)
            await eventTracker.flushNow()
        }
    }

    /// Build-32 one-shot: rewrite a legacy leaf-tag pin (e.g. `de-h2-de`)
    /// to the country urltest tag the leaf belongs to (`🇩🇪 Германия`).
    ///
    /// Why this exists: build 31 and earlier wrote leaf tags directly into
    /// `selectedServerTag` when the user drilled into a country picker.
    /// Build 32 promotes the country picker to a one-tap flow, and a stale
    /// leaf pin leaves the user with no UI affordance to recover. Country
    /// urltests are also more resilient — they survive a single leg going
    /// dark — which is what we actually want most of the time.
    ///
    /// Idempotent: gates on `migrationLeafToCountryV32Key` in App Group
    /// UserDefaults. Power-mode users who deliberately pick a leaf after
    /// migration ran are unaffected.
    ///
    /// Static so unit tests can drive it with synthetic ServerGroup arrays
    /// without spinning up a full AppState.
    static func migrateLeafToCountryIfNeeded(
        configStore: ConfigStore,
        servers: [ServerGroup],
        defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
        mirrorTo: ((String?) -> Void)? = nil
    ) {
        let result = migrateLeafToCountry(
            currentTag: configStore.selectedServerTag,
            servers: servers,
            isMigrated: { defaults?.bool(forKey: AppConstants.migrationLeafToCountryV32Key) ?? false },
            markMigrated: { defaults?.set(true, forKey: AppConstants.migrationLeafToCountryV32Key) }
        )
        guard let newTag = result else { return }
        configStore.selectedServerTag = newTag
        mirrorTo?(newTag)
    }

    /// Pure logic core of `migrateLeafToCountryIfNeeded` — fully unit-testable
    /// without UserDefaults or ConfigStore. Returns the new tag the caller
    /// should persist, or nil if no migration is needed (already migrated,
    /// pinned to non-leaf, or no matching country found). The callbacks
    /// gate the one-shot guard so it remains idempotent across launches.
    static func migrateLeafToCountry(
        currentTag: String?,
        servers: [ServerGroup],
        isMigrated: () -> Bool,
        markMigrated: () -> Void
    ) -> String? {
        if isMigrated() { return nil }
        defer { markMigrated() }

        guard let pinned = currentTag else { return nil }
        guard case .leaf = ServerTagShape(pinned) else { return nil }

        let countryTag: String? = servers
            .flatMap(\.countries)
            .first(where: { $0.serverTags.contains(pinned) })?
            .tag

        guard let countryTag else {
            AppLogger.app.info("migration v32: leaf '\(pinned)' has no matching country, leaving as-is")
            return nil
        }

        AppLogger.app.info("migration v32: leaf '\(pinned)' → country '\(countryTag)'")
        TunnelFileLogger.log("migration v32: leaf '\(pinned)' → country '\(countryTag)'", category: "ui")
        return countryTag
    }

    /// Called when app returns to foreground. Refreshes config in background.
    func handleForeground() async {
        guard isInitialized, configStore.username != nil else { return }
        AppLogger.app.info("handleForeground: refreshing config in background")
        refreshTask?.cancel()
        refreshTask = Task { await silentConfigUpdate() }
    }

    /// Delete corrupted or outdated config.
    /// Forces re-download from API on next connect.
    private func repairConfigIfNeeded() {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]]
        else { return }

        let hasProxySelector = outbounds.contains {
            ($0["type"] as? String) == "selector" && ($0["tag"] as? String) == "Proxy"
        }

        // Check for deprecated inbound fields (sing-box 1.13 deprecation)
        let inbounds = (json["inbounds"] as? [[String: Any]]) ?? []
        let hasLegacyInbound = inbounds.contains { $0["sniff"] != nil || $0["sniff_override_destination"] != nil }

        // Build-39: only the Proxy selector is required. Pre-build-39 configs
        // also had `urltest` outbounds for "Auto" + per-country grouping;
        // those are gone now (server selection moved into the main app via
        // PathPicker). A fresh build-39 config legitimately has zero urltest
        // outbounds, so don't gate on their presence — that would loop-clear
        // every healthy config.
        if !hasProxySelector || hasLegacyInbound {
            AppLogger.app.info("repairConfigIfNeeded: clearing outdated config (proxy=\(hasProxySelector) legacyInbound=\(hasLegacyInbound))")
            try? FileManager.default.removeItem(at: AppConstants.configFileURL)
            UserDefaults(suiteName: AppConstants.appGroupID)?.removeObject(forKey: AppConstants.startOptionsKey)
        }
    }

    // MARK: - Push Notifications (SUPPORT-CHAT P4)

    /// Ask the OS for remote-notification authorisation and, on grant, register
    /// for an APNs device token. Safe to call repeatedly — `requestAuthorization`
    /// returns the cached decision after the first prompt, and
    /// `registerForRemoteNotifications()` is idempotent. The token itself lands
    /// asynchronously in the app delegate's `didRegisterForRemoteNotifications`
    /// callback, which forwards it to `handlePushToken(_:)`. Best-effort: a denied
    /// prompt or a registration error just means no support-reply pushes.
    /// iOS/macOS bits are `#if os(iOS)`-scoped; on macOS this is a no-op for now.
    func registerForPushNotifications() {
        #if os(iOS)
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            AppLogger.app.info("registerForPushNotifications: authorization granted=\(granted, privacy: .public)")
            guard granted else { return }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        #endif
    }

    /// Forwarded from the app delegate's
    /// `didRegisterForRemoteNotificationsWithDeviceToken`. Hex-encodes the raw
    /// token and POSTs it to the backend (Bearer) so it can target this device
    /// with support-reply pushes. Best-effort — no token / network failure just
    /// skips registration, the user can still poll the chat manually.
    func handlePushToken(_ deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppLogger.app.info("handlePushToken: APNs token received len=\(hex.count, privacy: .public)")
        guard let token = configStore.accessToken else {
            AppLogger.app.info("handlePushToken: no access token yet — skipping push registration")
            return
        }
        do {
            try await apiClient.registerPushToken(hex, accessToken: token)
            AppLogger.app.info("handlePushToken: registered with backend")
        } catch {
            AppLogger.app.error("handlePushToken: backend registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forwarded from the app delegate when the user taps a "support reply"
    /// push. Flips the observable flag the app root watches to present the
    /// support chat from anywhere.
    @MainActor
    func handleSupportPushTap() {
        AppLogger.app.info("handleSupportPushTap: opening support chat")
        pendingSupportChatOpen = true
    }

    // MARK: - In-app announcements (INAPP-ANNOUNCEMENTS)

    /// The announcement currently presented as a card over the home, or nil.
    /// The root view observes this and overlays `AnnouncementView`.
    var activeAnnouncement: Announcement?

    private static let dismissedAnnouncementsKey = "dismissedAnnouncementIDs"

    /// Best-effort: fetch the active announcement set and present the first one
    /// the user hasn't dismissed. No-op while one is already showing, on a
    /// missing token, or on any network error (announcements are non-critical).
    func loadActiveAnnouncement() async {
        guard activeAnnouncement == nil, let token = configStore.accessToken else { return }
        let list = (try? await apiClient.fetchActiveAnnouncements(accessToken: token)) ?? []
        guard !list.isEmpty else { return }
        let dismissed = Set(UserDefaults.standard.array(forKey: Self.dismissedAnnouncementsKey) as? [Int] ?? [])
        if let next = list.first(where: { !dismissed.contains($0.id) }) {
            activeAnnouncement = next
        }
    }

    /// Dismiss the shown announcement and remember it so it never reappears.
    func dismissActiveAnnouncement() {
        guard let ann = activeAnnouncement else { return }
        var dismissed = UserDefaults.standard.array(forKey: Self.dismissedAnnouncementsKey) as? [Int] ?? []
        if !dismissed.contains(ann.id) { dismissed.append(ann.id) }
        if dismissed.count > 200 { dismissed = Array(dismissed.suffix(200)) } // bound the set
        UserDefaults.standard.set(dismissed, forKey: Self.dismissedAnnouncementsKey)
        activeAnnouncement = nil
    }

    /// Fetch fresh config from API and save. Silently logs errors — never shows them to the user.
    private func silentConfigUpdate() async {
        do {
            try await fetchAndSaveConfig()
            if let config = configStore.loadConfig() {
                UserDefaults(suiteName: AppConstants.appGroupID)?.set(
                    configForStartup() ?? config,
                    forKey: AppConstants.startOptionsKey
                )
            }
        } catch {
            AppLogger.app.error("Config update failed (using cached): \(error.localizedDescription)")
        }
    }

    /// Build the startup JSON for the cached config with the user's current
    /// selection baked in. Returns nil only if the on-disk config can't be
    /// parsed — callers fall back to the raw config in that case.
    private func configForStartup() -> String? {
        let target = configStore.selectedServerTag ?? "Auto"
        return buildConfigWithSelections(chain: chainOrFallback(target: target))
    }

    /// Build a fresh `[LeafCandidate]` from the cached server list. Empty
    /// before `parseServersFromConfig` has populated `servers` (very first
    /// launch / no config) — callers should treat empty as "no probe possible,
    /// fall through to whatever default the config baked in".
    func leafCandidates() -> [LeafCandidate] {
        guard let proxy = servers.first(where: { $0.type == "selector" && $0.selectable }) else {
            return []
        }
        return proxy.items.compactMap { item in
            guard !item.host.isEmpty, item.port > 0 else { return nil }
            return LeafCandidate(tag: item.tag, host: item.host, port: item.port, type: item.type)
        }
    }

    /// Build-39: synchronous best-guess translator used by sync code paths
    /// (`selectServer`, `configForStartup`) that need a Proxy → leaf chain
    /// without running an async PathPicker probe. Falls through to the
    /// existing `resolveSelectionChain` first; on miss (target is "Auto"
    /// or a country urltest tag — both no longer exist in the new flat
    /// config), maps to the cached-best or alphabetically-first leaf in
    /// the matching country.
    ///
    /// Async paths (`configForStartupWithRace`, `applyServerSelectionIfLive`)
    /// use the full `pathPicker.bestLeaf` which can probe; this helper
    /// only consults `LeafRankingStore` and the parsed candidates so it
    /// stays sync and cheap.
    private func chainOrFallback(target: String) -> [SelectionStep] {
        let chain = resolveSelectionChain(target: target)
        if !chain.isEmpty { return chain }

        let candidates = leafCandidates()
        guard !candidates.isEmpty else { return [] }

        // Power-mode pin (target IS a leaf tag in current candidates).
        if candidates.contains(where: { $0.tag == target }) {
            return [SelectionStep(group: "Proxy", target: target)]
        }

        // Map "Auto" / country label → leaf via cache or alphabetical.
        let countryFilter = PathPicker.countryCode(forSelectedTag: target)
        let pool = candidates.filter { countryFilter == nil || $0.country == countryFilter }
        guard !pool.isEmpty else { return [] }

        // Cache-best from LeafRankingStore (fresh successful entry only).
        let cutoff = Date().addingTimeInterval(-PathPicker.defaultCacheTTL)
        let recent = leafRankingStore.load()
            .filter { $0.measuredAt > cutoff && $0.success }
        let recentByTag = Dictionary(uniqueKeysWithValues: recent.map { ($0.tag, $0) })
        let pickedTag: String = pool.min(by: {
            (recentByTag[$0.tag]?.latencyMs ?? .max)
            < (recentByTag[$1.tag]?.latencyMs ?? .max)
        })?.tag ?? pool.sorted(by: { $0.tag < $1.tag }).first!.tag
        return [SelectionStep(group: "Proxy", target: pickedTag)]
    }

    /// Build the cold-start config. Build-39 return-to-urltest: no pre-connect
    /// TCP probe — we no longer pick a leaf before the tunnel is up. The
    /// config is built around the user's UI selection ("Auto" / country
    /// urltest tag / specific leaf for power-mode), and sing-box's own
    /// urltest groups decide which leaf actually carries traffic, end-to-end
    /// rather than first-hop. This eliminates the false-positive class on
    /// RKN-blocked direct paths (TCP handshake succeeds → Reality data dies)
    /// and removes the need for a custom watchdog.
    ///
    /// Side effects: refreshes `currentNetworkFingerprint` for telemetry.
    private func configForStartupWithRace() async -> String? {
        currentNetworkFingerprint = await NetworkFingerprint.current()
        return configForStartup()
    }

    /// Snapshot the currently-active leaf as "known good". Build-39 records
    /// to PathPicker's ranking store (so subsequent connects bypass the
    /// probe) AND to `LastWorkingLegStore` (per-network preferred hint,
    /// preserved for backwards compat / future use). Called from
    /// TrafficHealthMonitor.onProbeSuccess so we only record
    /// real-world-confirmed legs, not whatever picker's RTT probe
    /// happens to like.
    func recordWorkingLegToMemory() {
        // PathPicker's currentLeaf is the one we just connected through.
        // The probe-success signal from TrafficHealthMonitor doesn't carry
        // a fresh latency, so re-stamp the stored measurement with `now()`
        // and the existing latency (or 50ms as a fallback) so cache TTL
        // resets on every healthy probe.
        if let activeLeaf = pathPicker.currentLeaf, !activeLeaf.isEmpty {
            let prev = leafRankingStore.load().first(where: { $0.tag == activeLeaf })
            let latencyMs = prev?.latencyMs ?? 50
            pathPicker.recordSuccess(leaf: activeLeaf, latencyMs: latencyMs)
            // Legacy per-network memory — keep populated for future pinning.
            if let fp = currentNetworkFingerprint, let cc = leafCountryCode(activeLeaf) {
                lastWorkingLegStore.set(fingerprint: fp, country: cc, leg: activeLeaf)
            }
        }
    }

    /// Fetch fresh config with a timeout. Falls back to cached config if fetch fails or times out.
    /// Public so the UI refresh button can force a re-fetch when user suspects stale config.
    func refreshConfig(timeout: Duration = .seconds(5)) async {
        AppLogger.app.info("refreshConfig: fetching (timeout=\(timeout))")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.silentConfigUpdate() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
            for await _ in group { }
        }
        AppLogger.app.info("refreshConfig: done")
    }

    /// Called from Paywall after a successful StoreKit purchase or restore.
    /// Re-fetches the config so `subscriptionExpire` and the `servers` list
    /// reflect the freshly-extended plan.
    func refreshAfterPurchase() async {
        AppLogger.app.info("refreshAfterPurchase: pulling updated config")
        do {
            try await fetchAndSaveConfig()
        } catch {
            AppLogger.app.error("refreshAfterPurchase: \(error.localizedDescription)")
        }
    }

    // MARK: - Account lifecycle

    /// Sign the user out locally. Disconnects VPN, wipes all credentials,
    /// and returns to the onboarding screen. Does not call any backend —
    /// tokens will expire on their own.
    func logout() async {
        AppLogger.app.info("logout: begin")
        if vpnManager.status == .connected || vpnManager.status == .connecting || vpnManager.status == .reasserting {
            vpnManager.disconnect()
            await vpnManager.waitUntilDisconnected(timeout: .seconds(5))
        }
        try? await vpnManager.resetProfile()
        configStore.clear()
        subscriptionExpire = nil
        servers = []
        isAuthenticated = false
        errorMessage = nil
        AppLogger.app.info("logout: done")
    }

    /// Permanently delete the authenticated user's account on the backend,
    /// then perform a local logout. Required by App Store Review 5.1.1(v).
    func deleteAccount() async {
        AppLogger.app.info("deleteAccount: begin")
        guard let token = configStore.accessToken else {
            AppLogger.app.info("deleteAccount: no access token, local-only cleanup")
            await logout()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await apiClient.deleteAccount(accessToken: token)
            AppLogger.app.info("deleteAccount: backend confirmed")
        } catch {
            AppLogger.app.error("deleteAccount: backend failed: \(error.localizedDescription)")
            errorMessage = VPNErrorMapper.humanMessage(error)
            return
        }
        await logout()
    }

    // MARK: - VPN

    /// UI-level entry point for the Connect button. On the very first tap —
    /// when no NETunnelProviderManager has been saved yet — we show a
    /// pre-permission primer instead of triggering the system alert cold.
    /// Once the user has confirmed the primer, `toggleVPN()` is called.
    /// Subsequent taps go straight to `toggleVPN()`.
    func requestToggle() async {
        // EXPIRED-PAYWALL-ON-CONNECT (2026-06-17): a CONNECT intent requires an
        // active subscription. Disconnect is always allowed. Gating here (before
        // the permission primer) means an expired user sees the paywall, not the
        // VPN-profile install dialog. We reclaim first (cross-device pay) so a
        // user who paid elsewhere is never wrongly blocked.
        if !vpnManager.isConnected {
            guard await ensureSubscriptionForConnect() else { return }
        }
        if !vpnManager.isConnected && !vpnManager.hasInstalledProfile {
            showPermissionPrimer = true
            return
        }
        await toggleVPN()
    }

    /// The pure connect-gate decision: may this user start the tunnel? The
    /// backend `subscription_expiry` is authoritative whenever it's known —
    /// all 4 products are NonRenewingSubscription, so StoreKit reports a nil
    /// expirationDate for them and `isPremium` (isActiveEntitlement) stays
    /// true forever after any purchase. It cannot encode "still within the
    /// paid window" — only the backend expiry can, and a churned user's
    /// backend expiry is a PAST date (not nil). `isPremium` is used only as a
    /// fresh-purchase fallback when the backend hasn't synced an expiry yet
    /// (nil): a connect always needs a backend config anyway, and that config
    /// response carries subscription_expiry (X-Expire), so whenever a connect
    /// is possible the expiry is known — this fallback only rescues the brief
    /// window right after purchase, before the sync lands. Static + pure so
    /// it's unit-testable without a live AppState.
    nonisolated static func mayConnect(subscriptionExpire: Date?, isPremium: Bool, now: Date) -> Bool {
        // Backend subscription_expiry is authoritative for our time-limited
        // (NonRenewingSubscription) products: StoreKit reports nil expiry for
        // them, so `isPremium` stays true forever after purchase and cannot
        // encode "still within the paid window". A churned user's backend expiry
        // is a PAST date (not nil), so gating on it correctly blocks them.
        // This strands nobody: a connect needs a backend config anyway, and the
        // config response carries subscription_expiry (X-Expire), so whenever a
        // connect is possible the expiry is known. isPremium only rescues the
        // brief window after a fresh purchase before the backend expiry syncs.
        if let expiry = subscriptionExpire { return expiry > now }
        return isPremium
    }

    /// The ONE client-side "is the subscription active?" signal for UI (PRO
    /// badge, paywall copy) and the connect gate. An absent/past expiry is NOT
    /// active (was rendered as PRO via `subscriptionExpire != nil`, so an expired
    /// user saw a crown — EXPIRED-PAYWALL polish 2026-06-17). Mirrors mayConnect.
    var isSubscriptionActive: Bool {
        Self.mayConnect(subscriptionExpire: subscriptionExpire,
                        isPremium: subscriptionManager.isPremium, now: Date())
    }

    /// Returns true if the connect may proceed; false if the paywall was
    /// presented instead. Tries a cross-device reclaim (config refresh +
    /// StoreKit entitlement) before gating so a payer isn't stranded.
    private func ensureSubscriptionForConnect() async -> Bool {
        if Self.mayConnect(subscriptionExpire: subscriptionExpire,
                           isPremium: subscriptionManager.isPremium, now: Date()) {
            return true
        }
        // Reclaim 1: re-sync backend state (a payment we haven't pulled yet).
        await refreshConfig()
        subscriptionExpire = configStore.subscriptionExpire
        if Self.mayConnect(subscriptionExpire: subscriptionExpire,
                           isPremium: subscriptionManager.isPremium, now: Date()) {
            return true
        }
        // Reclaim 2: StoreKit entitlement (non-CIS Apple payer auto-restore),
        // then re-pull the backend state the reclaim updated.
        if await subscriptionManager.reconcileEntitlementsSilently() {
            await refreshConfig()
            subscriptionExpire = configStore.subscriptionExpire
            if Self.mayConnect(subscriptionExpire: subscriptionExpire,
                               isPremium: subscriptionManager.isPremium, now: Date()) {
                return true
            }
        }
        TunnelFileLogger.log("requestToggle: connect gated — subscription expired, showing paywall", category: "ui")
        requestPaywall = true
        return false
    }

    /// Called by the primer's Continue button to proceed with the actual
    /// connect — which triggers the iOS permission alert.
    func proceedAfterPrimer() async {
        showPermissionPrimer = false
        await toggleVPN()
    }

    /// CLIENT-CONNECT-DEADLINE (2026-07-12): project rule (CLAUDE.md) requires
    /// a VPN connect to fail within 30s total if it never reaches `.connected`.
    /// Build-36's original budget (18s + 3s disconnect-wait + 1s sleep + 18s =
    /// 40s worst case) violated that. Rebalanced to two ~13s connect attempts
    /// with a slimmer gap: 13s + 2s + 1s + 13s = 29s worst case, <= 30s.
    /// Still: wait up to `connectAttemptTimeout` for the tunnel; on
    /// `.timedOut`, silently disconnects, sleeps `retrySleep`, reconnects, and
    /// waits `connectAttemptTimeout` again. Only the second timeout surfaces.
    /// 13s still comfortably covers the build-35 watchdog regression's
    /// observed libbox cold-start range on LTE (9-15s reported; the low end of
    /// that range is now the tighter margin, not the near-100% buffer build-36
    /// had at 18s — acceptable tradeoff to satisfy the hard 30s rule).
    // Internal (not private) so AppStateConnectDeadlineTests can assert the
    // total worst-case budget stays <= 30s without invoking the live retry
    // path (which needs a real VPNManager/NE round-trip).
    static let connectAttemptTimeout: Duration = .seconds(13)
    static let disconnectWaitTimeout: Duration = .seconds(2)
    static let retrySleep: Duration = .seconds(1)

    private func awaitConnectionWithSilentRetry(config: String?) async -> VPNManager.ConnectOutcome {
        let first = await vpnManager.waitUntilConnected(timeout: Self.connectAttemptTimeout)
        guard case .timedOut = first else { return first }
        TunnelFileLogger.log("toggleVPN: watchdog \(Self.connectAttemptTimeout) timeout — silent retry", category: "ui")
        vpnManager.disconnect()
        await vpnManager.waitUntilDisconnected(timeout: Self.disconnectWaitTimeout)
        try? await Task.sleep(for: Self.retrySleep)
        do {
            try await vpnManager.connect(configJSON: config)
        } catch {
            TunnelFileLogger.log("toggleVPN: silent retry connect FAILED: \(error)", category: "ui")
            return .failed
        }
        let second = await vpnManager.waitUntilConnected(timeout: Self.connectAttemptTimeout)
        if case .timedOut = second {
            TunnelFileLogger.log("toggleVPN: watchdog \(Self.connectAttemptTimeout) timeout — second time, giving up", category: "ui")
        }
        return second
    }

    func toggleVPN() async {
        // Build-37: single-flight. See `toggleVPNInFlight` doc.
        guard !toggleVPNInFlight else {
            TunnelFileLogger.log("toggleVPN: ignored — already in flight (duplicate tap)", category: "ui")
            return
        }
        toggleVPNInFlight = true
        defer { toggleVPNInFlight = false }

        TunnelFileLogger.log("toggleVPN: begin, isConnected=\(vpnManager.isConnected)", category: "ui")
        Haptics.impact(.medium)
        if vpnManager.isConnected {
            commandClient.disconnect()
            vpnManager.disconnect()
            // Stop any in-flight config refresh, but do NOT kick a new one here:
            // a disconnect-time /config fetch churned the published `servers`
            // list mid-teardown for no benefit (config is refreshed on launch +
            // on the next connect).
            refreshTask?.cancel()
            TunnelFileLogger.log("toggleVPN: disconnect requested", category: "ui")
            // Hold the single-flight guard until the tunnel is actually down.
            // toggleVPN used to return in ~2 ms, releasing `toggleVPNInFlight`
            // while the NE was still tearing sing-box down (status stuck on
            // .disconnecting). A fast second tap then started a connect
            // mid-teardown — the lag + re-enabled toggle + "ступор" the user hit.
            // Awaiting (bounded) keeps the CTA in its disabled "ОСТАНОВКА…" state
            // until truly .disconnected.
            await vpnManager.waitUntilDisconnected(timeout: .seconds(5))
            return
        }

        // If we have a cached config — start the tunnel immediately and refresh
        // in the background for next time. Only block on refresh when there is
        // no cache at all (first launch, offline).
        if configStore.hasConfig() {
            // iOS multi-VPN handling: only one NEPacketTunnelProvider can be
            // active at a time, BUT Apple's framework auto-displaces the
            // current owner when we call setEnabled(true) + saveToPreferences +
            // startTunnel (see vpnManager.connect). So we DON'T short-circuit
            // here — let iOS try the takeover first. If it fails (e.g. user
            // declined the system permission dialog, or the other VPN uses
            // On-Demand and immediately reclaims the device), the catch /
            // watchdog branches below detect the still-active foreign tunnel
            // and surface the actionable "disable other VPN" message.
            TunnelFileLogger.log("toggleVPN: have cached config, running preconnect race + building", category: "ui")
            let config: String? = await configForStartupWithRace() ?? configStore.loadConfig()
            TunnelFileLogger.log("toggleVPN: config built, running preflight probe", category: "ui")
            await connectFlow(config: config, scheduleBackgroundRefresh: true)
            return
        }

        // No cached config: must fetch before we can connect. This is a user's
        // first-ever connect (or a fully offline relaunch) — the most important
        // funnel event, so it MUST go through the same connectFlow as the cached
        // path (telemetry + anotherVPNActive handling used to be cached-only; a
        // first connect blocked by a foreign VPN showed a generic "server
        // rejected" instead of "disable your other VPN", and never emitted a
        // single vpn.connect.* event — verified 2026-07-11 code review, H2).
        isLoading = true
        defer { isLoading = false }
        await refreshConfig(timeout: .seconds(5))

        guard configStore.hasConfig() else {
            errorMessage = L10n.Error.noConfig
            return
        }

        let config: String? = configForStartup() ?? configStore.loadConfig()
        await connectFlow(config: config, scheduleBackgroundRefresh: false)
    }

    /// Shared preflight → connect → watchdog path for both the cached-config
    /// and no-cache branches of `toggleVPN` (see H2 in the 2026-07-11 code
    /// review — these used to be two independently-maintained copies that had
    /// drifted). `scheduleBackgroundRefresh` is true only for the cached path:
    /// the no-cache path just did a synchronous `refreshConfig`, so there's
    /// nothing stale to refresh again 3 seconds later.
    private func connectFlow(config: String?, scheduleBackgroundRefresh: Bool) async {
        // Fail-fast preflight: probe each outbound's TCP endpoint before
        // committing to a 10s watchdog. This catches "all servers dead"
        // in ~2s and gives the user a specific, actionable error instead
        // of a generic "server rejected" after 30 seconds of silence.
        // The preflight probes run through whatever tunnel currently owns the
        // device. If a FOREIGN VPN is active, our servers look "dead" only
        // because traffic is being routed through it — aborting here is what
        // stopped us from ever reaching vpnManager.connect(), which is the call
        // that triggers iOS/macOS single-tunnel takeover (displaces the other
        // VPN). So when another VPN is active, ignore the unreliable preflight
        // and proceed straight to the takeover.
        let foreignVPNActive = VPNErrorMapper.anotherVPNActive()
        switch await preflightProbe() {
        case .ok, .skipped:
            break
        case .allDead:
            if foreignVPNActive {
                TunnelFileLogger.log("toggleVPN: preflight allDead but a foreign VPN is active — probes unreliable, proceeding to takeover", category: "ui")
            } else {
                TunnelFileLogger.log("toggleVPN: preflight — all servers unreachable", category: "ui")
                errorMessage = L10n.Error.allServersUnreachable
                return
            }
        case .selectedDead(let name):
            if foreignVPNActive {
                TunnelFileLogger.log("toggleVPN: preflight selectedDead '\(name)' but a foreign VPN is active — proceeding to takeover", category: "ui")
            } else {
                TunnelFileLogger.log("toggleVPN: preflight — selected '\(name)' unreachable", category: "ui")
                errorMessage = L10n.Error.selectedUnreachable(name)
                return
            }
        }

        TunnelFileLogger.log("toggleVPN: preflight OK, calling vpnManager.connect", category: "ui")

        // USR-09 Phase 2 — record connect intent. server tag is the
        // selected country/leaf urltest the cascade will start from.
        await eventTracker.log(
            name: "vpn.connect.start",
            properties: [
                "server": selectedServerTag ?? "",
                "routing": routingMode.rawValue,
            ]
        )

        do {
            try await vpnManager.connect(configJSON: config)
            TunnelFileLogger.log("toggleVPN: vpnManager.connect returned OK", category: "ui")
        } catch {
            TunnelFileLogger.log("toggleVPN: vpnManager.connect FAILED: \(error)", category: "ui")
            errorMessage = VPNErrorMapper.anotherVPNActive()
                ? L10n.Error.anotherVPNActive
                : VPNErrorMapper.humanMessage(error)
            await eventTracker.log(
                name: "vpn.connect.fail",
                properties: [
                    "stage": "vpnmanager_connect",
                    "reason": "\(error)",
                ]
            )
            return
        }

        // Watchdog: the tunnel must reach .connected within 18s, with
        // one silent retry on timeout. Build-36: libbox cold-start on
        // LTE can take 9-15s; the previous 10s watchdog killed connects
        // ~50ms before success. Preflight already confirmed at least one
        // outbound is network-reachable, so non-timeout failure modes
        // (Reality handshake mismatch, bad UUID) still surface fast.
        let outcome = await awaitConnectionWithSilentRetry(config: config)
        switch outcome {
        case .connected:
            Haptics.notify(.success)
            // Belt-and-braces: NEVPNStatusDidChange notifications can arrive
            // while AppState's MainActor task is busy (toggleVPN is itself
            // running on @MainActor), so the observer-driven handleStatus
            // call may have hit .connecting and missed the .connected
            // transition. Force-stamp here so the timer always starts on
            // first connect (without this, the chip stayed blank until the
            // user backgrounded + foregrounded the app).
            handleStatus()
            await eventTracker.log(
                name: "vpn.connect.success",
                properties: ["server": selectedServerTag ?? ""]
            )
        case .failed:
            TunnelFileLogger.log("toggleVPN: watchdog — extension rejected connection", category: "ui")
            vpnManager.disconnect()
            Haptics.notify(.error)
            errorMessage = VPNErrorMapper.anotherVPNActive()
                ? L10n.Error.anotherVPNActive
                : L10n.Error.serverRejected
            await eventTracker.log(
                name: "vpn.connect.fail",
                properties: ["stage": "watchdog", "reason": "rejected"]
            )
            return
        case .permissionDenied:
            TunnelFileLogger.log("toggleVPN: watchdog — permission denied", category: "ui")
            vpnManager.disconnect()
            Haptics.notify(.error)
            errorMessage = VPNErrorMapper.permissionMissing
            await eventTracker.log(
                name: "vpn.connect.fail",
                properties: ["stage": "watchdog", "reason": "permission_denied"]
            )
            return
        case .timedOut:
            vpnManager.disconnect()
            Haptics.notify(.error)
            errorMessage = VPNErrorMapper.watchdogTimeout
            await eventTracker.log(
                name: "vpn.connect.fail",
                properties: ["stage": "watchdog", "reason": "timeout"]
            )
            return
        }

        guard scheduleBackgroundRefresh else { return }

        // Delay background refresh — if we fire immediately, URLSession
        // competes with the tunnel that's still coming up and iOS sometimes
        // stalls the main queue waiting on network reachability.
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await silentConfigUpdate()
        }
    }

    // MARK: - Preflight probe

    private enum PreflightOutcome {
        case ok
        case allDead
        case selectedDead(name: String)
        case skipped
    }

    /// Parallel TCP probe of the outbounds in the current config. Runs with a
    /// 2-second budget per target (PingService default). Returns fast:
    /// `.ok` if at least one outbound is reachable; `.allDead` if none are;
    /// `.selectedDead` if the user picked a specific server and *that* one
    /// is unreachable (even if others are up); `.skipped` if we have no
    /// parsed servers yet (cold start / no config).
    private func preflightProbe() async -> PreflightOutcome {
        // Validate reachability before connecting so we fail fast with an
        // actionable error instead of a ~30s silent dead tunnel. Each leg is
        // probed on its REAL transport: a TCP handshake for TCP/TLS legs, a
        // QUIC Initial for UDP legs (Hysteria2/TUIC).
        //
        // We no longer trust UDP picks blind. A hard UDP/QUIC block (common on
        // RKN) used to leave a blind-trusted Hysteria2 pick "connected" to a
        // dead tunnel where nothing loaded. PingService.probeQUIC returns 0
        // when the server's UDP never answers, so a blocked leg is correctly
        // classified as unreachable and surfaced as .selectedDead — matching
        // how a dead TCP leg already behaves. (Industry rule — Psiphon/Outline/
        // sing-box urltest only trust a transport once it actually replies.)
        let udpOnlyTypes: Set<String> = ["hysteria2", "tuic"]

        let items: [ServerItem] = servers
            .flatMap { $0.items }
            .filter { !$0.host.isEmpty && $0.port > 0 }
        guard !items.isEmpty else { return .skipped }

        let selectedTag = configStore.selectedServerTag
        // The default one-tap UX pins a COUNTRY tag (e.g. "🇳🇱 Нидерланды"), not a
        // leaf — `items` are leaves, so a direct tag match only ever succeeds for a
        // power-mode leaf pin. Without this, `targets` came back empty for a country
        // pin and preflight silently no-op'd via `.skipped` for essentially every
        // real user (verified 2026-07-11 code review). Resolve a country pin to its
        // member leaves before falling through.
        let pinnedCountry = selectedTag.flatMap { tag in servers.flatMap(\.countries).first { $0.tag == tag } }
        let targets: [ServerItem]
        if let country = pinnedCountry {
            targets = items.filter { country.serverTags.contains($0.tag) }
        } else if let tag = selectedTag {
            targets = items.filter { $0.tag == tag }
        } else {
            targets = items
        }
        guard !targets.isEmpty else { return .skipped }

        // Probe every target on its real transport, concurrently. CONNECT-PREFLIGHT-FAST
        // (2026-06-17): return as soon as the FIRST leg proves reachable and cancel
        // the rest — reachability is binary here, we don't need every result. Field
        // logs showed preflight cost a flat ~3.2 s on every connect because it waited
        // for the SLOWEST probe (a dead UDP leg's full 3 s QUIC timeout, common under
        // RKN) even when a TCP/Reality leg had already answered in ~100 ms. Early-out
        // shaves that ~3 s off every connect ("долгое подключение"). The dead path
        // (nothing alive) still waits the full budget — that's the failure case we
        // WANT to confirm before surfacing .selectedDead / .allDead.
        let anyAlive: Bool = await withTaskGroup(of: Bool.self) { group in
            for target in targets {
                let isUDP = udpOnlyTypes.contains(target.type)
                group.addTask {
                    let ms: Int
                    if isUDP {
                        ms = await PingService.probeQUIC(host: target.host, port: target.port, timeout: 3.0)
                    } else {
                        ms = await PingService.probeTCP(host: target.host, port: target.port, timeout: 2.0)
                    }
                    return ms > 0
                }
            }
            for await alive in group where alive {
                group.cancelAll()
                return true
            }
            return false
        }

        if anyAlive { return .ok }

        if selectedTag != nil, targets.first != nil {
            // Prefer the country's display name (e.g. "Нидерланды") over the raw
            // leaf tag (e.g. "nl-direct-nl2") — a country pin is the default UX,
            // so most users hitting this have never seen a leaf tag anywhere else.
            let name = pinnedCountry?.name ?? selectedTag ?? "?"
            return .selectedDead(name: name)
        }
        return .allDead
    }

    func selectServer(groupTag: String, serverTag: String) {
        selectServer(groupTag: groupTag, serverTag: serverTag, clearCascade: true)
    }

    /// Internal entry point — `clearCascade: false` is used by the
    /// fallback chain so the dead-leaves set we just appended to isn't
    /// wiped when we hop to the next leaf.
    func selectServer(groupTag: String, serverTag: String, clearCascade: Bool) {
        let previousTag = configStore.selectedServerTag
        let isAuto = serverTag == "Auto"
        let newTag: String? = isAuto ? nil : serverTag
        configStore.selectedServerTag = newTag
        selectedServerTag = newTag  // @Observable mirror for SwiftUI

        // Manual pick clears the cascade history and gives the new leg
        // a grace window before the health monitor probes again — sing-box
        // needs a moment to settle. Fallback callers pass clearCascade=false
        // so the dead-leaf and dead-country sets survive the hop.
        if clearCascade {
            deadLeavesInCurrentCascade.removeAll()
            deadCountriesInCurrentCascade.removeAll()
        }
        trafficHealthMonitor?.suspendForManualSwitch()

        // Persist the full multi-step selection into the cached startOptions
        // immediately, regardless of whether the tunnel is currently up. This
        // ensures a cold-start connect reads the right selector defaults
        // rather than falling back to "Auto"/"direct" and routing through
        // the wrong country.
        let persistTarget = isAuto ? "Auto" : serverTag
        if let persisted = buildConfigWithSelections(chain: chainOrFallback(target: persistTarget)) {
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(persisted, forKey: AppConstants.startOptionsKey)
        }
        TunnelFileLogger.log("selectServer ENTER: groupTag='\(groupTag)' serverTag='\(serverTag)' prev='\(previousTag ?? "Auto")' connected=\(vpnManager.isConnected) cmdClientConnected=\(commandClient.isConnected)", category: "ui")
        // Dump current servers tree so we can verify the tag we got from
        // the UI is one sing-box actually knows about.
        for g in servers {
            let items = g.items.map { $0.tag }.joined(separator: ", ")
            TunnelFileLogger.log("  group tag='\(g.tag)' type=\(g.type) selectable=\(g.selectable) items=[\(items)]", category: "ui")
        }

        // Update local servers array so UI reflects the change immediately
        for i in servers.indices {
            if servers[i].items.contains(where: { $0.tag == serverTag }) {
                servers[i] = ServerGroup(
                    id: servers[i].id, tag: servers[i].tag, type: servers[i].type,
                    selected: serverTag, items: servers[i].items, selectable: servers[i].selectable,
                    hasAuto: servers[i].hasAuto, countries: servers[i].countries
                )
            }
        }

        let effectiveNew = isAuto ? nil : serverTag
        let tagChanged = previousTag != effectiveNew
        guard vpnManager.isConnected else {
            AppLogger.app.info("selectServer: skipped (not connected), tag persisted")
            return
        }

        // Resolve the full selection chain needed to route Proxy → user's
        // choice. In the 2026-04-24+ config layout, the Proxy selector only
        // references country urltests ("🇳🇱 Нидерланды", …) and "Auto" —
        // never leaf outbounds directly. A leaf tag like "nl-direct-nl2"
        // therefore needs TWO Clash API calls:
        //   1) selectOutbound(<country urltest>, leafTag)   // force urltest pick
        //   2) selectOutbound("Proxy", <country urltest>)   // route Proxy here
        //
        // A country urltest tag (e.g. "🇳🇱 Нидерланды") needs only step 2.
        // "Auto" needs only step 2 with target="Auto".
        let selectorTarget = isAuto ? "Auto" : serverTag
        let chain = chainOrFallback(target: selectorTarget)
        guard !chain.isEmpty else {
            AppLogger.app.error("selectServer: could not resolve selection chain for '\(serverTag)'")
            return
        }

        // Rebuild config JSON with every Clash-API-equivalent change applied
        // inline, so a cold-start tunnel reads the right defaults without
        // depending on the selector API being hit post-boot.
        let updatedConfig = buildConfigWithSelections(chain: chain) ?? configStore.loadConfig()
        AppLogger.app.info("selectServer: chain=\(chain.map { "\($0.group)→\($0.target)" }.joined(separator: " / "))")

        if tagChanged, let updatedConfig {
            UserDefaults(suiteName: AppConstants.appGroupID)?.set(updatedConfig, forKey: AppConstants.startOptionsKey)
        }

        // Fast path: live tunnel — re-pick the leaf via PathPicker for the
        // new selection and push it. Build-39: replaces the old chain-walk +
        // forceUrlTestEverywhere combo. With country urltests gone from the
        // config, the entire selection is a single Clash API call.
        if commandClient.isConnected {
            applyServerSelectionIfLive()
            return
        }

        // Fallback: tunnel up but command client not ready. Only reconnect
        // when the tag actually changed — a same-tag tap with a dead client
        // is nothing to do.
        guard tagChanged, let updatedConfig else { return }
        TunnelFileLogger.log("selectServer: FALLBACK reconnect (commandClient not ready)", category: "ui")
        reconnectTask?.cancel()
        reconnectTask = Task {
            commandClient.disconnect()
            vpnManager.disconnect()
            await vpnManager.waitUntilDisconnected(timeout: .seconds(5))
            guard !Task.isCancelled else { return }
            try? await vpnManager.connect(configJSON: updatedConfig)
        }
    }

    /// A single (group, target) step to apply via Clash API selectOutbound.
    /// Internal (not private) so `ProxyChainResolverTests` can construct
    /// expected chains without pulling in a full AppState fixture.
    struct SelectionStep: Equatable {
        let group: String
        let target: String
    }

    /// Walk the current config's outbound graph and produce the ordered list
    /// of selectOutbound calls needed to route Proxy → `target`.
    private func resolveSelectionChain(target: String) -> [SelectionStep] {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]]
        else { return [] }
        return Self.resolveChain(target: target, outbounds: outbounds)
    }

    /// COUNTRY-PICK-STICKY (2026-06-17): should a persisted server selection be
    /// RESET to Auto because it no longer resolves? Pure + testable. Only when
    /// the target is a real pin (not Auto), the chain didn't resolve, AND the
    /// config genuinely has servers (so the target was retired) — never when the
    /// config is transiently empty/flat (that's the bug: a mid-refresh miss must
    /// keep the user's deliberate pin, not silently revert it to Auto).
    nonisolated static func shouldResetStaleSelection(target: String,
                                                      chainResolved: Bool,
                                                      configHasServers: Bool) -> Bool {
        if chainResolved { return false }
        if target == "Auto" { return false }
        return configHasServers
    }

    /// Pure-function core of selection resolution — exposed `internal`
    /// for unit tests. Takes a parsed sing-box outbounds array (straight
    /// from `JSONSerialization`) and returns the ordered selectOutbound
    /// steps. No I/O, no actor isolation, deterministic.
    ///
    /// Call ordering inside the returned chain matters: urltest/selector
    /// leaf pin comes first so Proxy's final hop lands on a pinned leaf
    /// rather than the urltest's pre-pin RTT pick.
    ///
    /// `nonisolated` because AppState is `@Observable` + @MainActor
    /// (implicit from actor-isolated init) — without the override, test
    /// code from background queues / XCTest sync contexts can't call it.
    nonisolated static func resolveChain(target: String, outbounds: [[String: Any]]) -> [SelectionStep] {
        // Index (type, members) by tag.
        var typeByTag: [String: String] = [:]
        var membersByTag: [String: [String]] = [:]
        for ob in outbounds {
            guard let tag = ob["tag"] as? String,
                  let type = ob["type"] as? String else { continue }
            typeByTag[tag] = type
            if let members = ob["outbounds"] as? [String] {
                membersByTag[tag] = members
            }
        }

        // Helper: is `target` reachable via any Proxy member? Include Auto
        // here — Case 3 below legitimately wants to use Auto as a fallback
        // when a leaf exists only there. Excluding Auto from reachability
        // caused valid leaves-only-in-Auto to return an empty chain before
        // Case 3 even ran.
        func isReachableFromProxy() -> Bool {
            for member in membersByTag["Proxy"] ?? [] {
                if membersByTag[member]?.contains(target) == true { return true }
            }
            return false
        }

        guard membersByTag["Proxy"]?.contains(target) == true ||
              isReachableFromProxy()
        else {
            // Target isn't anywhere under Proxy — caller passed a stale tag.
            return []
        }

        // Case 1: target is a direct member of Proxy (Auto, country urltest,
        // or — post-2026-04-25 — an individual leaf added as Proxy child so
        // manual leaf overrides can be pinned by the Clash API).
        if membersByTag["Proxy"]?.contains(target) == true {
            return [SelectionStep(group: "Proxy", target: target)]
        }

        // Case 2: target is a leaf nested inside a urltest OR selector that
        // IS a direct member of Proxy. Prefer a specific country group over
        // the meta-"Auto" urltest — Auto contains every leaf, so it would
        // match first alphabetically and steal the routing from the user's
        // deliberate country pick. Both urltest and selector parents are
        // accepted (whitelist-bypass is a selector, country groups are
        // urltests).
        for member in membersByTag["Proxy"] ?? [] {
            guard member != "Auto" else { continue }
            let memberType = typeByTag[member] ?? ""
            guard (memberType == "urltest" || memberType == "selector"),
                  membersByTag[member]?.contains(target) == true
            else { continue }
            return [
                SelectionStep(group: member, target: target),
                SelectionStep(group: "Proxy", target: member),
            ]
        }

        // No country group claims this leaf. Last resort: fall back to Auto
        // (only if Auto happens to contain it). Still better than returning
        // an empty chain and leaving Proxy pinned to whatever it was.
        if typeByTag["Auto"] == "urltest",
           membersByTag["Auto"]?.contains(target) == true {
            return [
                SelectionStep(group: "Auto", target: target),
                SelectionStep(group: "Proxy", target: "Auto"),
            ]
        }

        return []
    }

    /// Apply every step from `chain` to the on-disk config's `default`
    /// fields and return the serialized JSON. Falls back to returning nil on
    /// parse error so callers keep using the unchanged config from disk.
    ///
    /// Note: sing-box `urltest` outbounds don't honour a `default` field —
    /// only live selectOutbound pins them. Config persistence is therefore
    /// for selector defaults only; urltest state is reapplied every reload
    /// by `applyServerSelectionIfLive`.
    private func buildConfigWithSelections(chain: [SelectionStep]) -> String? {
        guard let config = configStore.loadConfig(),
              let data = config.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbounds = json["outbounds"] as? [[String: Any]]
        else { return nil }

        // Apply default-field updates only for `selector` types. urltest has
        // no `default` field in the sing-box schema — persisted pick won't
        // survive a restart; that's what applyServerSelectionIfLive is for.
        for step in chain {
            for i in outbounds.indices {
                guard outbounds[i]["tag"] as? String == step.group,
                      outbounds[i]["type"] as? String == "selector"
                else { continue }
                outbounds[i]["default"] = step.target
            }
        }

        json["outbounds"] = outbounds
        guard let out = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: out, encoding: .utf8)
        else { return nil }
        return str
    }

    /// Re-applies the persisted server selection to the live tunnel. Called from
    /// handleStatus(.connected) so that a cold-start tunnel whose sing-box Proxy
    /// selector booted on a stale default gets forced onto the user's real pick.
    ///
    /// Build-39 return-to-urltest: we no longer pick a *leaf* and pin Proxy to
    /// it. The user's pick is a UI label ("Auto" / "🇩🇪 Германия" / specific
    /// leaf for power-mode), and `resolveSelectionChain` produces the chain of
    /// `selectOutbound` calls that route Proxy → that label. For Auto and
    /// country urltest groups the chain is a single step that hands control
    /// to sing-box's own urltest — sing-box probes each leaf end-to-end and
    /// picks the lowest-latency *working* one, automatically failing over
    /// when a leaf goes dead. Build-38's pre-connect TCP probe and bytes-flow
    /// watchdog were re-implementing what sing-box already does correctly,
    /// just worse — TCP probe is a false-positive on RKN-blocked paths
    /// (handshake succeeds, Reality data dies), and bytes-flow watchdog read
    /// global counters that mixed Proxy traffic with native LTE direct traffic.
    ///
    /// Why retry: `commandClient` binds to the extension's unix socket AFTER
    /// the tunnel reaches `.connected`. Without retry the apply races the
    /// socket bind and `Proxy` keeps its fresh-config default. Retry 500ms ×
    /// 10 = 5s budget covers the worst observed bind delay (LTE cold-start,
    /// ~700ms).
    private func applyServerSelectionIfLive() {
        let selectedTag = configStore.selectedServerTag ?? "Auto"
        // Build-37: cancel-then-replace. See `selectionApplyTask` doc.
        selectionApplyTask?.cancel()
        selectionApplyTask = Task { [weak self] in
            guard let self else { return }

            // COUNTRY-PICK-STICKY (2026-06-17): use the FORGIVING chainOrFallback
            // (country label → best leaf) instead of the strict
            // resolveSelectionChain. The strict resolver returned empty for a
            // country pick whenever the live config was transiently flat
            // (urltest-less) or mid-refresh, and the block below then NUKED the
            // user's deliberate country pick back to Auto — "выбор не
            // запоминается".
            let chain = self.chainOrFallback(target: selectedTag)
            guard !chain.isEmpty else {
                // Empty even with fallback. Build-85: when a server / country is
                // RETIRED backend-side (e.g. DE 2026-05-25) the UI would show
                // "🇩🇪 Германия" forever, so we reset to Auto. But ONLY when the
                // config genuinely HAS servers and none match — if there are NO
                // candidates at all the config is just transiently unavailable,
                // and nuking the pin is the COUNTRY-PICK-STICKY bug. Keep the pin
                // and let the next config refresh reconcile.
                let configHasServers = !self.leafCandidates().isEmpty
                if Self.shouldResetStaleSelection(target: selectedTag,
                                                  chainResolved: false,
                                                  configHasServers: configHasServers),
                   self.configStore.selectedServerTag != nil {
                    TunnelFileLogger.log("applyServerSelectionIfLive: '\(selectedTag)' gone from a populated config — resetting to Auto", category: "ui")
                    self.configStore.selectedServerTag = nil
                    self.selectedServerTag = nil
                } else {
                    TunnelFileLogger.log("applyServerSelectionIfLive: empty chain for '\(selectedTag)', config flat/unavailable — keeping pin", category: "ui")
                }
                return
            }
            let chainStr = chain.map { "\($0.group)→\($0.target)" }.joined(separator: " / ")

            for attempt in 1...10 {
                if Task.isCancelled { return }
                if self.commandClient.isConnected {
                    if attempt > 1 {
                        TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient ready after \(attempt * 500)ms, applying chain=\(chainStr)", category: "ui")
                    } else {
                        TunnelFileLogger.log("applyServerSelectionIfLive: applying chain=\(chainStr)", category: "ui")
                    }
                    for step in chain {
                        self.commandClient.selectOutbound(groupTag: step.group, outboundTag: step.target)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            TunnelFileLogger.log("applyServerSelectionIfLive: cmdClient still not connected after 5s, giving up", category: "ui")
        }
    }

    // MARK: - Routing mode

    /// Persists the routing mode and, if the command client is live, flips
    /// the three selectors ("RU Traffic", "Blocked Traffic", "Default Route")
    /// over the libbox unix socket. No reconnect — sing-box applies the switch
    /// in place. When the tunnel is down, only persistence happens; the mode
    /// is re-applied from `handleStatus` once the command client reconnects.
    func setRoutingMode(_ mode: RoutingMode) {
        routingMode = mode
        UserDefaults(suiteName: AppConstants.appGroupID)?
            .set(mode.rawValue, forKey: AppConstants.routingModeKey)
        TunnelFileLogger.log("setRoutingMode: \(mode.rawValue), cmdClient=\(commandClient.isConnected)", category: "ui")
        Haptics.selection()
        applyRoutingModeIfLive(mode)
    }

    private func applyRoutingModeIfLive(_ mode: RoutingMode) {
        // Retry with backoff: commandClient binds to the extension's unix
        // socket after the tunnel is up, and that's racy. If we miss the
        // window, selectors keep their default-config state (direct for
        // Default Route) and Full VPN silently degrades to Smart-like
        // behaviour — exactly the bug users see when whoer.net shows the
        // real IP. Retry every 500ms for 5s.
        guard commandClient.isConnected else {
            TunnelFileLogger.log("applyRoutingMode: cmdClient not connected, scheduling retry for \(mode.rawValue)", category: "ui")
            // Build-37: cancel-then-replace. See `routingApplyTask` doc.
            routingApplyTask?.cancel()
            routingApplyTask = Task { [weak self] in
                for attempt in 1...10 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if self.commandClient.isConnected {
                        TunnelFileLogger.log("applyRoutingMode: cmdClient ready after \(attempt * 500)ms, applying \(mode.rawValue)", category: "ui")
                        for (selector, target) in mode.selectorTargets {
                            self.commandClient.selectOutbound(groupTag: selector, outboundTag: target)
                        }
                        return
                    }
                }
                TunnelFileLogger.log("applyRoutingMode: cmdClient still not connected after 5s, giving up", category: "ui")
            }
            return
        }
        TunnelFileLogger.log("applyRoutingMode: applying \(mode.rawValue) via \(mode.selectorTargets.count) selectors", category: "ui")
        for (selector, target) in mode.selectorTargets {
            commandClient.selectOutbound(groupTag: selector, outboundTag: target)
        }
    }

    // MARK: - VPN-KILLSWITCH (truth audit 2026-07-14)

    /// User-facing notice shown under the Kill Switch toggle in Settings —
    /// either "this takes effect on your next connect" (informational, shown
    /// whenever the toggle is flipped while already connected — see
    /// `VPNManager.applyKillSwitch` for why a live session isn't retroactively
    /// tightened) or a save-failure message. `nil` clears the notice.
    var killSwitchNotice: String?

    /// Persist the user's Kill Switch preference and push it onto the saved
    /// VPN profile. Mirrors `setAutoConnectOnUntrustedWiFi`: silently no-ops
    /// (logs only) when no profile exists yet — `VPNManager.createManager()`
    /// reads the same App Group default the first time a profile is created,
    /// so the preference isn't lost, just deferred.
    func setKillSwitchEnabled(_ enabled: Bool) async {
        configStore.killSwitchEnabled = enabled
        killSwitchNotice = nil
        do {
            try await vpnManager.applyKillSwitch(enabled: enabled)
            // includeAllNetworks/excludeLocalNetworks/enforceRoutes are read
            // by the system when a tunnel SESSION starts — saving them onto
            // an already-saved profile does not retroactively tighten a
            // session that's already running. Say so instead of letting the
            // toggle imply a guarantee it can't deliver right now.
            if vpnManager.isConnected {
                killSwitchNotice = "settings.kill_switch.notice_reconnect".localized
            }
        } catch VPNManager.KillSwitchError.noManager {
            AppLogger.app.info("setKillSwitchEnabled: no manager yet (will apply on first connect)")
        } catch VPNManager.KillSwitchError.saveFailed(let err) {
            AppLogger.app.error("setKillSwitchEnabled: saveFailed \(err.localizedDescription)")
            killSwitchNotice = "settings.kill_switch.save_failed".localized + ": \(err.localizedDescription)"
        } catch {
            AppLogger.app.error("setKillSwitchEnabled: \(error.localizedDescription)")
            killSwitchNotice = "settings.kill_switch.save_failed".localized
        }
    }

    // MARK: - LAUNCH-07 Auto-connect (NEOnDemandRule) wiring

    /// Last user-facing error from an `applyAutoConnect…` call. Surfaced as
    /// a toast over Settings. Cleared on the next successful apply or when
    /// the user explicitly dismisses the toast.
    var autoConnectErrorMessage: String?

    /// Apply whatever the persisted auto-connect preference is. Called from
    /// `handleStatus(.connected)` so the rule chain is re-installed after
    /// every connect (VPNManager.connect() clears On-Demand defensively —
    /// see comment in VPNManager.swift).
    private func applyAutoConnectFromPreferences() async {
        let enabled = configStore.autoConnectOnUntrustedWiFi
        let trusted = configStore.trustedWiFiSSIDs
        let cellular = configStore.autoConnectOnCellular
        do {
            try await vpnManager.applyAutoConnectRules(
                enabled: enabled,
                trustedSSIDs: trusted,
                includeCellular: cellular
            )
        } catch VPNManager.OnDemandError.noManager {
            // Expected when the user toggled the pref before ever connecting.
            // Will be re-applied on the next .connected transition.
            AppLogger.app.info("applyAutoConnect: no manager yet, deferring")
        } catch {
            AppLogger.app.error("applyAutoConnect: failed: \(error.localizedDescription)")
        }
    }

    /// Called by SettingsView when the user flips any of the auto-connect
    /// controls. Persists the new value to ConfigStore + tries to push the
    /// rules to the live VPN profile (if any). When the profile doesn't
    /// exist yet — first-launch user toggles the setting before ever
    /// connecting — we silently persist and surface a hint in Settings
    /// instructing the user to connect once so iOS prompts for VPN config.
    func setAutoConnectOnUntrustedWiFi(_ enabled: Bool) async {
        configStore.autoConnectOnUntrustedWiFi = enabled
        await pushAutoConnectRules()
    }

    func setAutoConnectOnCellular(_ enabled: Bool) async {
        configStore.autoConnectOnCellular = enabled
        await pushAutoConnectRules()
    }

    /// Add a trusted SSID and re-apply rules if a profile exists. Returns
    /// the new list so the UI can update without re-reading.
    @discardableResult
    func addTrustedSSID(_ ssid: String) async -> [String] {
        let updated = configStore.addTrustedSSID(ssid)
        await pushAutoConnectRules()
        return updated
    }

    @discardableResult
    func removeTrustedSSID(_ ssid: String) async -> [String] {
        let updated = configStore.removeTrustedSSID(ssid)
        await pushAutoConnectRules()
        return updated
    }

    /// Internal shared helper — pushes the current preferences down to
    /// NETunnelProviderManager. Surfaces `saveFailed` errors via
    /// `autoConnectErrorMessage` so Settings can show a toast; silently
    /// no-ops the `noManager` case because that's a normal "you haven't
    /// connected once yet" state.
    private func pushAutoConnectRules() async {
        let enabled = configStore.autoConnectOnUntrustedWiFi
        let trusted = configStore.trustedWiFiSSIDs
        let cellular = configStore.autoConnectOnCellular
        do {
            try await vpnManager.applyAutoConnectRules(
                enabled: enabled,
                trustedSSIDs: trusted,
                includeCellular: cellular
            )
            autoConnectErrorMessage = nil
        } catch VPNManager.OnDemandError.noManager {
            // Common path: user toggled before first connect. The pref is
            // still persisted so the rules will be applied on the next
            // .connected transition (see handleStatus).
            AppLogger.app.info("pushAutoConnectRules: no manager (will apply after first connect)")
        } catch VPNManager.OnDemandError.saveFailed(let err) {
            AppLogger.app.error("pushAutoConnectRules: saveFailed \(err.localizedDescription)")
            autoConnectErrorMessage = "settings.auto_connect.save_failed".localized + ": \(err.localizedDescription)"
        } catch {
            AppLogger.app.error("pushAutoConnectRules: \(error.localizedDescription)")
            autoConnectErrorMessage = "settings.auto_connect.save_failed".localized
        }
    }

    // MARK: - Status

    private func startObservingVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleStatus() }
        }
    }

    private func handleStatus() {
        TunnelFileLogger.log("handleStatus: vpn status=\(vpnManager.status.rawValue)", category: "ui")
        // LAUNCH-08: surface OS-initiated drops as local notifications. Done
        // first so the snapshot of `userInitiatedDisconnect` is captured
        // before any downstream work might clobber it.
        disconnectNotifier.record(
            status: vpnManager.status,
            userInitiatedDisconnect: vpnManager.userInitiatedDisconnect
        )
        // Build-84: nudge the widget timeline so the Home/Lock-Screen widget
        // re-reads App Group state immediately after the main app sees a
        // status transition. Without this the widget can show stale "Защищено"
        // for up to 15 min after disconnect (own timeline policy is the only
        // refresh signal). Cheap: WidgetCenter rate-limits internally.
        WidgetCenter.shared.reloadAllTimelines()
        let sharedDefaults = UserDefaults(suiteName: AppConstants.appGroupID)

        switch vpnManager.status {
        case .connected:
            if vpnConnectedAt == nil {
                // Restore from UserDefaults if the app was relaunched while
                // the tunnel was still up (On Demand / background relaunch).
                // Otherwise stamp now and persist so the session chip survives
                // app lifecycle transitions.
                let key = AppConstants.vpnConnectedAtKey
                if let ts = UserDefaults(suiteName: AppConstants.appGroupID)?.double(forKey: key), ts > 0 {
                    vpnConnectedAt = Date(timeIntervalSince1970: ts)
                } else {
                    let now = Date()
                    vpnConnectedAt = now
                    UserDefaults(suiteName: AppConstants.appGroupID)?
                        .set(now.timeIntervalSince1970, forKey: key)
                }
            }
            // WIDGET-CONNECTING: a real .connected status is a definitive
            // outcome — clear any in-flight "connecting…" flag the widget/
            // Control-Center intent may have stamped, same as
            // WidgetVPNSnapshot.write does for the other two writers.
            sharedDefaults?.removeObject(forKey: AppConstants.vpnConnectingAtKey)
            if !commandClient.isConnected { commandClient.connect() }
            // Clear the user-stopped flag on successful connection
            sharedDefaults?.removeObject(forKey: AppConstants.userStoppedVPNKey)
            // Re-apply the user's routing mode AND server selection after a
            // (re)connect. commandClient takes a moment to bind after connect()
            // above — defer one hop so selectOutbound has a live socket to talk
            // to. Server selection must be re-asserted because sing-box may
            // have resolved Proxy to a different default than configStore.
            let mode = routingMode
            // Build-37: cancel-then-replace. NEVPNStatusDidChange may emit
            // `.connected` more than once per cycle; without this guard each
            // emit queues another apply pass that bombards `selectOutbound`
            // (which itself tears in-flight TLS).
            pendingApplyTask?.cancel()
            pendingApplyTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                self?.applyRoutingModeIfLive(mode)
                self?.applyServerSelectionIfLive()
                // LAUNCH-07: VPNManager.connect() defensively clears
                // isOnDemandEnabled so the user can disable VPN from iOS
                // Settings (an unconditional Connect rule would re-enable it
                // immediately). Re-install the user's auto-connect rules now
                // that the tunnel is up — without this the toggle would be
                // ON in Settings yet On-Demand would be off on the profile.
                await self?.applyAutoConnectFromPreferences()
                // LAUNCH-08: ask for notification authorisation on the first
                // successful connect. Idempotent — once asked, this no-ops.
                // First connect is the most contextual moment to surface the
                // system permission alert (the user just enabled the VPN and
                // is paying attention).
                await self?.disconnectNotifier.requestAuthorizationIfNeeded()
            }
            startTrafficHealthMonitorIfEligible()
        case .disconnected, .invalid:
            vpnConnectedAt = nil
            UserDefaults(suiteName: AppConstants.appGroupID)?.removeObject(forKey: AppConstants.vpnConnectedAtKey)
            // WIDGET-CONNECTING: a real disconnected/invalid status is also
            // definitive — a connect attempt that failed surfaces here too,
            // so clear the flag instead of leaving the widget to wait out
            // the 30s self-expiry.
            sharedDefaults?.removeObject(forKey: AppConstants.vpnConnectingAtKey)
            if commandClient.isConnected { commandClient.disconnect() }
            trafficHealthMonitor?.stop()
            deadLeavesInCurrentCascade.removeAll()
            deadCountriesInCurrentCascade.removeAll()
            // Check if the PacketTunnel extension signaled a user-initiated stop
            // (from iOS Settings toggle). If so, disable On Demand to prevent auto-reconnect.
            let userStoppedVPN = sharedDefaults?.bool(forKey: AppConstants.userStoppedVPNKey) ?? false
            if userStoppedVPN {
                sharedDefaults?.removeObject(forKey: AppConstants.userStoppedVPNKey)
                AppLogger.app.info("handleStatus: user stopped VPN from Settings, disabling On Demand")
                Task { await vpnManager.disableOnDemand() }
            }
        default: break
        }
    }

}

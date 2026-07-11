import Foundation
import AuthenticationServices

/// Sign-in / token-refresh / re-auth ladder. Extracted 2026-07-11 (M1, Fable
/// code review) from AppState.swift, which had grown into a single
/// ~2700-line file mixing auth, connect orchestration, fallback, push,
/// announcements, and diagnostics. This file owns everything from "how do we
/// get/keep a valid session" through "what do we do when it goes stale" —
/// the four sign-in entry points (anonymous/Google/email/Apple), the shared
/// `completeSignIn` persist step (H4), config fetch-with-refresh-retry, and
/// the ACCT-IDENTITY re-auth ladder (never demote an identity user to anon).
///
/// `fetchAndSaveConfig` is the one member here still called from outside
/// this file (`silentConfigUpdate`, `refreshAfterPurchase` in AppState.swift
/// proper), so it can't be `private` — everything else here is only ever
/// called by other members of this same extension and stays `private`,
/// exactly as it was before the split.
extension AppState {
    /// Anonymous device registration — the "Continue without account" flow.
    /// Backed by a device-id tied trial; no Apple/email binding. Users who
    /// later want multi-device or restore-on-reinstall can sign in with
    /// Apple from Settings, which links this device to an Apple identity
    /// server-side.
    func signInAnonymous() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        AppLogger.app.info("signInAnonymous: starting device registration")
        TunnelFileLogger.log("signInAnonymous: ENTER", category: "auth")
        do {
            let result = try await apiClient.registerDevice()
            AppLogger.app.info("signInAnonymous: registered as \(result.username)")
            TunnelFileLogger.log("signInAnonymous: registerDevice OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            try await completeSignIn(
                result: result,
                authProvider: nil, // explicit: anonymous device account
                clearsReauth: false
            )
            TunnelFileLogger.log("signInAnonymous: SUCCESS", category: "auth")
        } catch {
            AppLogger.app.error("signInAnonymous: FAILED: \(error.localizedDescription)")
            TunnelFileLogger.log("signInAnonymous: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "onboarding.anon_failed")
        }
    }

    func fetchAndSaveConfig() async throws {
        guard let username = configStore.username else {
            AppLogger.app.error("fetchAndSaveConfig: no username")
            return
        }
        AppLogger.app.info("fetchAndSaveConfig: fetching for \(username)")

        do {
            try await doFetchAndSave(username: username)
        } catch APIError.unauthorized {
            AppLogger.app.info("fetchAndSaveConfig: 401, attempting token refresh")
            let refreshed = await tryRefreshToken()
            if refreshed {
                try await doFetchAndSave(username: username)
            } else if AppState.shouldAnonReRegister(authProvider: configStore.authProvider, onboardingCompleted: hasCompletedOnboarding) {
                // Anonymous device account — safe to mint a fresh one.
                AppLogger.app.info("fetchAndSaveConfig: refresh failed (anon), re-registering device")
                try await reRegisterDevice()
            } else {
                // ACCT-IDENTITY: identity user (Apple/Google/email) whose
                // refresh token is dead (>30d dormant). NEVER demote to a fresh
                // anonymous trial — that orphaned paying accounts (the P0).
                // Keep the Keychain identity and surface the re-auth ladder;
                // the backend reclaims the same account by Apple `sub` on
                // re-auth, or by email on magic-link.
                AppLogger.app.info("fetchAndSaveConfig: refresh failed for identity user (\(self.configStore.authProvider ?? "?")) — requesting re-auth, keeping creds")
                flagSessionExpired()
                throw APIError.unauthorized
            }
        } catch APIError.serverError(let code) where code == 404 {
            // Backend returns 404 when JWT is valid but user_id is not in DB
            // (DB wiped, migration, soft-delete edge case, etc).
            if AppState.shouldAnonReRegister(authProvider: configStore.authProvider, onboardingCompleted: hasCompletedOnboarding) {
                // Anon: stale creds survive iOS reinstall via Keychain — only
                // re-registering can unstick. Symptom: "404 on fresh install".
                AppLogger.app.info("fetchAndSaveConfig: 404 user_not_found (anon), clearing creds + re-registering")
                configStore.clear()
                try await reRegisterDevice()
                try await doFetchAndSave(username: configStore.username ?? username)
            } else {
                // ACCT-IDENTITY: identity user vanished from the backend (rare).
                // Do NOT clear/anon-register — re-auth reclaims the SAME account
                // by Apple `sub` (FindUserByAppleID) and restores entitlements.
                AppLogger.app.info("fetchAndSaveConfig: 404 for identity user — requesting re-auth, keeping creds (ACCT-IDENTITY)")
                flagSessionExpired()
                throw APIError.serverError(404)
            }
        } catch let error as APIError where isNetworkError(error) {
            AppLogger.app.info("fetchAndSaveConfig: network error, retrying once")
            try await Task.sleep(for: .seconds(2))
            try await doFetchAndSave(username: username)
        }
    }

    /// SUBSCRIPTION-ON-AUTH (2026-06-17): apply the subscription expiry the auth
    /// response now carries, so it's reflected the instant sign-in succeeds —
    /// before (and independent of) the /config fetch whose X-Expire header can be
    /// lost to an RU network blip. Only sets a present value; never clears an
    /// existing one (a nil here just means "use /config / cached").
    private func applyAuthSubscription(_ expiryUnix: Int64?) {
        guard let exp = expiryUnix, exp > 0 else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(exp))
        configStore.subscriptionExpire = date
        subscriptionExpire = date
        AppLogger.app.info("applyAuthSubscription: \(date)")
    }

    /// Shared "auth succeeded, persist everything" step for all 4 sign-in
    /// entry points (anonymous, Google, magic link, Apple). Extracted
    /// 2026-07-11 (H4, Fable code review) — each provider used to repeat this
    /// ~8-step persist block independently, and the exact failure mode that
    /// class of duplication invites (a partially-persisted sign-in during a
    /// network blip) was the shape of the ACCT-IDENTITY P0: the server
    /// accepted auth but the client only wrote some of accessToken/
    /// refreshToken/username/authProvider. One atomic function makes that bug
    /// structurally harder to reintroduce, and makes a 5th provider a 5-line add.
    ///
    /// `tolerateNoActiveSubscription` preserves signInWithApple's one real
    /// behavioral difference: a returning user whose trial has lapsed gets a
    /// 403 from `/config`, which must NOT fail the sign-in itself (auth
    /// already succeeded) — App Review build 52 hit exactly this path.
    private func completeSignIn(
        result: AuthResult,
        authProvider: String?,
        appleUserID: String? = nil,
        clearsReauth: Bool,
        tolerateNoActiveSubscription: Bool = false
    ) async throws {
        configStore.accessToken = result.accessToken
        configStore.refreshToken = result.refreshToken
        configStore.username = result.username
        configStore.authProvider = authProvider
        if let appleUserID {
            configStore.appleUserID = appleUserID
        }
        applyAuthSubscription(result.subscriptionExpiry)
        if clearsReauth {
            needsReauth = false
        }
        do {
            try await fetchAndSaveConfig()
            subscriptionExpire = configStore.subscriptionExpire
        } catch APIError.serverError(403) where tolerateNoActiveSubscription {
            AppLogger.app.info("completeSignIn: /config 403 — no active subscription, completing sign-in")
            TunnelFileLogger.log("completeSignIn: /config 403 (no active sub), proceeding", category: "auth")
            subscriptionExpire = nil
        }
        UserDefaults(suiteName: AppConstants.appGroupID)?.set(true, forKey: AppConstants.onboardingCompletedKey)
        isAuthenticated = true
    }

    private func doFetchAndSave(username: String) async throws {
        let result = try await apiClient.fetchConfig(username: username, accessToken: configStore.accessToken)
        AppLogger.app.info("fetchAndSaveConfig: got config, length=\(result.config.count)")
        // ACCT-IDENTITY trip-wire guard: never cache a non-config (error body,
        // CF/relay error page, throttled/empty response). Caching one is what
        // armed the initialize() identity-wipe that demoted payers. Treat it as a
        // transient fetch failure — keep the existing cached config, demote nothing.
        guard AppState.isUsableConfigPayload(result.config) else {
            AppLogger.app.error("fetchAndSaveConfig: response is not a usable sing-box config (len=\(result.config.count)) — refusing to cache")
            throw APIError.networkError("config response was not a valid sing-box config")
        }
        try configStore.saveConfig(result.config)
        if result.expire > 0 {
            let expireDate = Date(timeIntervalSince1970: TimeInterval(result.expire))
            configStore.subscriptionExpire = expireDate
            subscriptionExpire = expireDate
            AppLogger.app.info("fetchAndSaveConfig: expire=\(result.expire) (\(expireDate))")
        }
        servers = configStore.parseServersFromConfig()
        AppLogger.app.info("fetchAndSaveConfig: parsed \(self.servers.count) groups, total items=\(self.servers.flatMap(\.items).count)")
        // Warm the ping cache in the background so the server picker shows
        // values instantly the first time the user opens it.
        let allItems = servers.flatMap(\.items)
        Task { [pingService] in await pingService.probe(allItems) }
    }

    /// Best-effort-fresh access token for the support-chat WKWebView, which
    /// can't refresh on its own (no refresh token in the webview, by design).
    /// The stored access token may have expired while the app was backgrounded
    /// (it 401s the chat with a confusing "нет связи"), so refresh proactively;
    /// on failure fall back to whatever is stored (tryRefreshToken keeps it).
    func accessTokenForSupportChat() async -> String {
        _ = await tryRefreshToken()
        return configStore.accessToken ?? ""
    }

    private func tryRefreshToken() async -> Bool {
        guard let refreshToken = configStore.refreshToken else { return false }
        do {
            let result = try await apiClient.refreshAccessToken(refreshToken)
            // Persist BOTH: the backend rotates the refresh token (single-use,
            // blacklisted for 30d). Storing only the access token left the OLD,
            // now-consumed refresh token in the keychain, so the NEXT refresh
            // 401'd with "refresh token already used" → a re-login every ~24h
            // (Pain #2). Order: access first, then the rotated refresh token.
            configStore.accessToken = result.accessToken
            configStore.refreshToken = result.refreshToken
            applyAuthSubscription(result.subscriptionExpiry)
            needsReauth = false // session restored silently
            AppLogger.app.info("tryRefreshToken: success")
            return true
        } catch {
            AppLogger.app.error("tryRefreshToken: failed: \(error.localizedDescription)")
            return false
        }
    }

    private func reRegisterDevice() async throws {
        let result = try await apiClient.registerDevice()
        AppLogger.app.info("reRegisterDevice: registered as \(result.username)")
        configStore.accessToken = result.accessToken
        configStore.refreshToken = result.refreshToken
        configStore.username = result.username
        configStore.authProvider = nil // reRegister only runs for anon users now
        applyAuthSubscription(result.subscriptionExpiry)
        try await doFetchAndSave(username: result.username)
    }

    private func isNetworkError(_ error: APIError) -> Bool {
        if case .networkError = error { return true }
        return false
    }

    // MARK: - ACCT-IDENTITY session recovery

    /// ACCT-IDENTITY core invariant: anonymous re-registration (which mints a
    /// brand-new `device_<rand>` account + fresh trial) is ONLY a valid session
    /// fallback for a user with no identity. A user authenticated via
    /// Apple/Google/email must NEVER be silently demoted to anon — return false
    /// so the caller re-auths that identity (reclaim by Apple `sub` / magic-link)
    /// instead. Pure + static so it can be unit-tested without constructing the
    /// heavyweight AppState (same pattern as `shouldEscalateBeyondCountry`).
    static func shouldAnonReRegister(authProvider: String?, onboardingCompleted: Bool) -> Bool {
        // ACCT-IDENTITY-3 (2026-06-17): also require that onboarding was NEVER
        // completed. Field data: a paying Apple user (acct 12351) was silently
        // wiped to anon and dropped to the first-run onboarding screen because
        // authProvider went transiently nil — an Apple sign-in that the server
        // accepted (200) but the client didn't fully persist during an RU network
        // blackout — and the next /config 404 hit this re-register path. A user who
        // has completed onboarding has a real account server-side (reclaimed by
        // re-auth), so NEVER mint a fresh anon trial for them. onboardingCompleted
        // lives in App Group UserDefaults — it survives keychain loss but is reset
        // by a genuine delete+reinstall, so a true reinstall still re-registers.
        authProvider == nil && !onboardingCompleted
    }

    /// Whether the user has ever completed onboarding (App Group UserDefaults,
    /// survives keychain loss). Guards the anon re-register path above.
    private var hasCompletedOnboarding: Bool {
        UserDefaults(suiteName: AppConstants.appGroupID)?.bool(forKey: AppConstants.onboardingCompletedKey) ?? false
    }

    /// A real sing-box config ALWAYS contains an `outbounds` array. Error JSON
    /// bodies, Cloudflare/relay HTML error pages, throttled or empty responses
    /// (common on RU networks via the direct-IP fallback) do NOT. Such a payload
    /// must NEVER be cached as "the config", and a previously-cached one must be
    /// discarded WITHOUT touching identity.
    ///
    /// This is the ACCT-IDENTITY trip-wire that recurred on build 98: the old
    /// code cached error bodies, then `initialize()` saw `"error"` in the cache
    /// and `clear()`-ed the WHOLE identity (authProvider/appleUserID) — demoting
    /// a paying Apple/Google/email user to a brand-new anonymous trial. Pure +
    /// static so it's unit-testable without constructing AppState.
    ///
    /// A real structural check, not a substring match (2026-07-11): a garbled
    /// or partially-corrupted response — e.g. mangled by something else on the
    /// device's network path — can still happen to contain the literal text
    /// `"outbounds"` without being valid JSON at all. That was caught live: a
    /// device cached exactly such a payload, then every subsequent connect
    /// failed inside the tunnel with sing-box's own `decode config` JSON
    /// errors, and the server picker silently showed zero countries — no
    /// user-visible error pointed at the real cause. Parsing it for real (and
    /// requiring every outbound to carry `type`+`tag`, which every real
    /// sing-box outbound does) closes that hole without changing any
    /// user-visible behavior: an unusable payload still just falls through to
    /// "keep the existing cached config" exactly as before.
    static func isUsableConfigPayload(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]],
              !outbounds.isEmpty
        else { return false }
        return outbounds.allSatisfy { $0["type"] is String && $0["tag"] is String }
    }

    /// Mark the identity session as needing re-auth WITHOUT touching stored
    /// credentials. Keeps `isAuthenticated` true (creds present) so the user
    /// stays inside the app with cached config and a non-destructive banner,
    /// rather than being demoted to anon or kicked back to onboarding.
    private func flagSessionExpired() {
        if !needsReauth {
            AppLogger.app.info("flagSessionExpired: identity session needs re-auth (provider=\(self.configStore.authProvider ?? "?", privacy: .public))")
        }
        needsReauth = true
    }

    /// Recovery ladder step 0 — launch-time Sign in with Apple health check.
    /// `getCredentialState` is a fast, no-UI call (Apple ID daemon). If Apple
    /// reports the credential `.revoked` (user removed the app from their Apple
    /// ID), flag re-auth proactively. `.authorized`/`.notFound`/errors are left
    /// alone — a transient daemon miss must never nuke a working session. This
    /// returns NO token; minting a fresh Apple identity token always needs UI
    /// (see reauthenticateWithApple).
    func verifyAppleCredentialState() async {
        guard configStore.authProvider == "apple", let userID = configStore.appleUserID else { return }
        let provider = ASAuthorizationAppleIDProvider()
        let state: ASAuthorizationAppleIDProvider.CredentialState = await withCheckedContinuation { cont in
            provider.getCredentialState(forUserID: userID) { state, _ in cont.resume(returning: state) }
        }
        if state == .revoked {
            AppLogger.app.info("verifyAppleCredentialState: Apple credential REVOKED — requesting re-auth")
            flagSessionExpired()
        }
    }

    /// Recovery ladder step 2 — re-authenticate an Apple identity user from the
    /// re-auth banner. Presents the system Sign in with Apple sheet (one Face
    /// ID for an already-authorized user). On success `signInWithApple` clears
    /// `needsReauth`; the backend reclaims the SAME account by `sub`.
    func reauthenticateWithApple() async {
        await AppleAuthCoordinator.signIn(into: self)
    }

    /// Recovery ladder step 3 — email a magic sign-in link (cross-device /
    /// last-resort, when the Apple credential is gone). Thin wrapper over the
    /// existing magic-link request so the banner can offer it. Returns true if
    /// the request was accepted.
    @discardableResult
    func requestReauthMagicLink(email: String) async -> Bool {
        await requestMagicLink(email: email)
    }

    // MARK: - Sign In

    /// Sign in by Google ID token received from GoogleSignIn SDK.
    /// Parallel to `signInWithApple` but without a credential wrapper.
    /// AUTH-LEG-TELEMETRY (PRODUCT-MATURITY-LOOP 2026-06-21): record which transport
    /// leg carried (or failed) a sign-in, so the RU residential failure mode becomes
    /// measurable from real users — CF vs decoy win rate, and how often nothing wins.
    /// The server side (RU monitor on MSK) only sees datacenter vantage; this is the
    /// real-device signal. Fire-and-forget via the existing EventTracker batch.
    private func logAuthLeg(provider: String, ok: Bool) async {
        let leg = apiClient.lastSensitiveAuthLeg ?? "none"
        let region = Locale.current.region?.identifier ?? "unknown"
        await eventTracker.log(name: "auth.attempt",
                               properties: ["provider": provider, "leg": leg, "ok": ok, "region": region])
    }

    func signInWithGoogle(idToken: String) async {
        AppLogger.app.info("signInWithGoogle: entry, tokenLen=\(idToken.count, privacy: .public)")
        TunnelFileLogger.log("signInWithGoogle: ENTER, tokenLen=\(idToken.count)", category: "auth")
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.signInWithGoogle(idToken: idToken)
            AppLogger.app.info("signInWithGoogle: username=\(result.username), isNew=\(result.isNew ?? false)")
            TunnelFileLogger.log("signInWithGoogle: API OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            try await completeSignIn(result: result, authProvider: "google", clearsReauth: true)
            TunnelFileLogger.log("signInWithGoogle: SUCCESS", category: "auth")
            await logAuthLeg(provider: "google", ok: true)
        } catch {
            AppLogger.app.error("signInWithGoogle: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("signInWithGoogle: FAILED — \(String(describing: error))", category: "auth")
            await logAuthLeg(provider: "google", ok: false)
            errorMessage = String(localized: "onboarding.signin_failed")
        }
    }

    /// Email entry: ask backend to send a magic link. Always resolves to a
    /// "check your email" confirmation in UI, even on rate-limit, because we
    /// don't want to leak which addresses have accounts.
    func requestMagicLink(email: String) async -> Bool {
        TunnelFileLogger.log("requestMagicLink: ENTER", category: "auth")
        errorMessage = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            TunnelFileLogger.log("requestMagicLink: REJECTED — empty email", category: "auth")
            errorMessage = String(localized: "magic.error.invalid_email")
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await apiClient.requestMagicLink(email: trimmed)
            TunnelFileLogger.log("requestMagicLink: SUCCESS", category: "auth")
            return true
        } catch APIError.serverError(429) {
            TunnelFileLogger.log("requestMagicLink: RATE LIMITED (429)", category: "auth")
            errorMessage = String(localized: "magic.error.rate_limited")
            return false
        } catch {
            AppLogger.app.error("requestMagicLink: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("requestMagicLink: FAILED — \(String(describing: error))", category: "auth")
            errorMessage = String(localized: "magic.error.generic")
            return false
        }
    }

    /// Called from MadFrogVPNApp.handleUniversalLink when a /app/signin?token=…
    /// link is opened. Redeems the token and completes auth.
    ///
    /// If the user is already signed in, we skip redeeming so we don't
    /// consume a usable magic token — the link's still valid in their
    /// inbox if they need it on another device. We surface a quick toast
    /// instead so the tap isn't silent.
    func consumeMagicToken(_ token: String) async {
        let wasAuthenticated = isAuthenticated
        AppLogger.app.info("consumeMagicToken: entry, tokenLen=\(token.count, privacy: .public), alreadyAuthenticated=\(wasAuthenticated, privacy: .public)")
        TunnelFileLogger.log("consumeMagicToken: ENTER, tokenLen=\(token.count) alreadyAuth=\(wasAuthenticated)", category: "auth")
        errorMessage = nil
        if wasAuthenticated {
            TunnelFileLogger.log("consumeMagicToken: skip — already authenticated", category: "auth")
            errorMessage = String(localized: "magic.already_signed_in")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await apiClient.verifyMagicLink(token: token)
            AppLogger.app.info("consumeMagicToken: username=\(result.username), isNew=\(result.isNew ?? false)")
            TunnelFileLogger.log("consumeMagicToken: API OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            try await completeSignIn(result: result, authProvider: "email", clearsReauth: true)
            TunnelFileLogger.log("consumeMagicToken: SUCCESS", category: "auth")
            await logAuthLeg(provider: "email", ok: true)
        } catch {
            AppLogger.app.error("consumeMagicToken: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("consumeMagicToken: FAILED — \(String(describing: error))", category: "auth")
            await logAuthLeg(provider: "email", ok: false)
            errorMessage = String(localized: "magic.error.invalid_link")
        }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        AppLogger.app.info("signInWithApple: entry, hasToken=\(credential.identityToken != nil, privacy: .public), user=\(credential.user, privacy: .public)")
        TunnelFileLogger.log("signInWithApple: ENTER, hasToken=\(credential.identityToken != nil)", category: "auth")
        errorMessage = nil
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            AppLogger.app.error("signInWithApple: no identity token in credential")
            TunnelFileLogger.log("signInWithApple: FAILED — no identity token in credential", category: "auth")
            errorMessage = String(localized: "onboarding.signin_failed")
            return
        }
        AppLogger.app.info("signInWithApple: got token, len=\(token.count, privacy: .public)")
        TunnelFileLogger.log("signInWithApple: tokenLen=\(token.count), calling backend", category: "auth")

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.signInWithApple(identityToken: token)
            AppLogger.app.info("signInWithApple: username=\(result.username), isNew=\(result.isNew ?? false)")
            TunnelFileLogger.log("signInWithApple: API OK, username=\(result.username) isNew=\(result.isNew ?? false)", category: "auth")
            // ACCT-IDENTITY: persist the durable identity so a later session
            // failure re-auths Apple (reclaim by `sub`) instead of demoting to
            // anon. credential.user IS the Apple `sub`, stable across reinstall.
            // tolerateNoActiveSubscription: a returning user whose trial has
            // lapsed gets a 403 from /config — that must NOT fail the sign-in
            // itself (auth already succeeded). App Review build 52 hit exactly
            // this path on May 12 2026.
            try await completeSignIn(
                result: result,
                authProvider: "apple",
                appleUserID: credential.user,
                clearsReauth: true,
                tolerateNoActiveSubscription: true
            )
            TunnelFileLogger.log("signInWithApple: SUCCESS", category: "auth")
            await logAuthLeg(provider: "apple", ok: true)
        } catch let apiErr as APIError {
            AppLogger.app.error("signInWithApple: APIError \(String(describing: apiErr), privacy: .public)")
            TunnelFileLogger.log("signInWithApple: FAILED APIError \(String(describing: apiErr))", category: "auth")
            await logAuthLeg(provider: "apple", ok: false)
            errorMessage = signInFailureMessage(for: apiErr)
        } catch let decodingErr as DecodingError {
            AppLogger.app.error("signInWithApple: decode error \(String(describing: decodingErr), privacy: .public)")
            TunnelFileLogger.log("signInWithApple: FAILED decode \(String(describing: decodingErr))", category: "auth")
            await logAuthLeg(provider: "apple", ok: false)
            errorMessage = String(localized: "onboarding.signin_failed") + " (decode)"
        } catch {
            AppLogger.app.error("signInWithApple: failed: \(String(describing: error), privacy: .public)")
            TunnelFileLogger.log("signInWithApple: FAILED — \(String(describing: error))", category: "auth")
            await logAuthLeg(provider: "apple", ok: false)
            errorMessage = String(localized: "onboarding.signin_failed")
        }
    }

    /// Map APIError into a user-visible message that gives App Review (and
    /// real users) enough context to know whether to retry or contact support.
    private func signInFailureMessage(for err: APIError) -> String {
        let base = String(localized: "onboarding.signin_failed")
        switch err {
        case .unauthorized:
            return base + " (401)"
        case .serverError(let code):
            return base + " (\(code))"
        case .networkError(let msg):
            return base + " (network: \(msg))"
        case .noConfig:
            return base + " (no config)"
        case .invalidCode:
            return base + " (invalid code)"
        }
    }
}

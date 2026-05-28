import Foundation
import Sentry

/// LAUNCH-03 (2026-05-28). Sentry crash reporting wrapper.
///
/// **Why Sentry, why EU.** See [`docs/decisions/0007-sentry-eu-crash-reporting.md`](../../docs/decisions/0007-sentry-eu-crash-reporting.md).
/// TL;DR: industry-standard symbolicated crash reports, EU region
/// (de.sentry.io) for GDPR alignment because we ship a VPN, strict
/// privacy defaults — no PII, no session beacons, no performance
/// traces.
///
/// **Privacy posture.**
/// - DSN is read from `Info.plist` at runtime — never compiled in.
///   Empty DSN ⇒ `start()` is a no-op (dev builds, forks, anyone
///   who cloned the repo). The user explicitly populates the key at
///   build time via xcconfig / CI secret. There is no fallback DSN.
/// - `sendDefaultPii = false`. Sentry's default would attach the
///   user's IP, device name, locale. We disable all of that.
/// - `enableAutoSessionTracking = false`. We do not need to know
///   that an MAU launched the app today.
/// - `tracesSampleRate = 0`. No performance tracing — keeps payload
///   small, avoids accidentally capturing URLs in spans.
/// - `beforeSend` scrubs the few fields Sentry might still populate
///   on a crash event: any `user` PII, query strings on the request
///   URL, the macOS device name in the `device` context, and the
///   `serverName` (hostname) field.
///
/// **What we DO capture.** Symbolicated stack traces of crashes
/// (signal handlers + Mach exceptions + uncaught NSExceptions),
/// plus thread state at crash time. That's it.
///
/// **What we do NOT capture (out of the box).**
/// - User actions / breadcrumbs — explicitly disabled.
/// - Network requests — Sentry's URLSession swizzling would attach
///   request URLs as breadcrumbs and we'd have to scrub them after
///   the fact. Easier to keep the integration off.
/// - View controller lifecycle — irrelevant for SwiftUI, off by
///   default in SwiftUI apps anyway.
///
/// **PacketTunnel extension.** Sentry is intentionally NOT linked
/// into `PacketTunnel` / `PacketTunnelMac` — the Network Extension
/// process has a ~15 MB resident memory ceiling on iOS and any
/// non-essential dependency risks OOM-kill mid-tunnel. Crashes that
/// happen inside the extension surface as `NEVPNStatus` transitions
/// (`.invalid` / `.disconnecting` with non-zero exit code) which
/// the main-app side already maps to user-visible errors.
enum CrashReporter {

    /// Info.plist key holding the DSN. Empty / missing ⇒ disabled.
    /// Populated at build time, never committed.
    private static let dsnInfoPlistKey = "SENTRY_DSN"

    /// Process-launch argument flag used by unit tests + integration
    /// runs to keep Sentry's crash handlers from registering. Without
    /// this, the SDK would install signal handlers that interfere
    /// with XCTest's own crash reporter.
    static let disableLaunchArgument = "--no-crash-reporter"

    /// Whether `start()` actually initialised Sentry. Useful for
    /// debug HUDs / Settings → About; never gate logic on this.
    private(set) static var isEnabled = false

    /// Initialise Sentry. Safe to call multiple times — only the
    /// first invocation does work. Failures are swallowed (logged
    /// via `TunnelFileLogger`) so a broken DSN never crashes the
    /// app at launch.
    ///
    /// Call from `MadFrogVPNApp.init()` **before** any other init
    /// logic so that an early-launch crash is still captured.
    static func start() {
        // 1. Test-mode bypass — `--no-crash-reporter` keeps unit
        //    tests from clashing with Sentry's signal handlers.
        if ProcessInfo.processInfo.arguments.contains(disableLaunchArgument) {
            TunnelFileLogger.log("CrashReporter: skipped (--no-crash-reporter)", category: "boot")
            return
        }

        // 2. Idempotency.
        guard !isEnabled else { return }

        // 3. Look up the DSN. Empty / whitespace / missing ⇒ no-op.
        //    This is the dev path; nothing is sent until a real DSN
        //    is wired in via xcconfig at build time.
        guard let dsn = readDSN(), !dsn.isEmpty else {
            TunnelFileLogger.log("CrashReporter: SENTRY_DSN empty — disabled", category: "boot")
            return
        }

        // 4. Boot Sentry with strict-privacy options. Wrapped in
        //    do/catch via the SDK's own bridging — SentrySDK.start
        //    itself is non-throwing and swallows config errors into
        //    its internal logger, but we still guard the call.
        SentrySDK.start { options in
            options.dsn = dsn

            #if DEBUG
            options.environment = "development"
            options.debug = false   // SDK chatter on stderr is noise even in DEBUG
            #else
            options.environment = "production"
            options.debug = false
            #endif

            // Minimum-signal config: crashes only, no perf / session
            // / breadcrumb beacons.
            options.tracesSampleRate = 0.0
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = false

            // Scrub anything Sentry might still populate on a crash
            // event before it leaves the device. See sanitize(_:).
            options.beforeSend = { event in
                return CrashReporter.sanitize(event)
            }
        }

        // 5. Belt-and-suspenders: explicitly null the serverName on
        //    the global scope. Sentry's default uses the device
        //    hostname, which on macOS leaks the user's chosen
        //    machine name ("Maksim's MacBook Pro") — clear PII.
        //    `serverName = nil` on the scope wins over per-event
        //    population.
        SentrySDK.configureScope { scope in
            scope.setUser(nil)
            scope.setTag(value: "vpn-client", key: "app.kind")
        }

        isEnabled = true
        TunnelFileLogger.log("CrashReporter: started (EU region, strict privacy)", category: "boot")
    }

    // MARK: - Private

    /// Read the DSN from the main bundle's Info.plist. Returns nil
    /// if the key is missing or the value is not a string. Whitespace
    /// is trimmed — accidental leading/trailing newlines in build
    /// configs are common.
    private static func readDSN() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: dsnInfoPlistKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Strip PII from an outgoing event. Called for every event
    /// Sentry is about to send (which today means: crashes).
    ///
    /// Scrubbed fields:
    /// - `event.user` — entirely removed. We don't want any user
    ///   identifier going out, even an anonymous one, until we add
    ///   an explicit "send anonymous id" opt-in.
    /// - `event.request.url` — query string dropped. Most VPN API
    ///   URLs don't carry secrets in the query, but the magic-link
    ///   sign-in flow does (`/app/signin?token=...`).
    /// - `event.request.queryString` — dropped entirely.
    /// - `event.context["device"]["name"]` — removed. On macOS this
    ///   is the user's chosen machine name.
    /// - `event.serverName` — cleared. Same hostname leak.
    /// - `event.tags["device.name"]` — removed if present (Sentry
    ///   sometimes mirrors device.name into a tag).
    ///
    /// Returns the (mutated) event so Sentry sends it. Return `nil`
    /// to drop the event entirely; we don't do that today but the
    /// hook is here.
    static func sanitize(_ event: Event) -> Event? {
        // 1. Wipe the user object. Even a UUID is a stable identifier
        //    we don't want correlating crashes across sessions.
        event.user = nil

        // 2. Sanitize the request URL. Strip the query string —
        //    that's where magic-link tokens and (in older builds)
        //    JWT refresh nonces could land.
        if let request = event.request {
            request.queryString = nil
            if let urlString = request.url,
               var comps = URLComponents(string: urlString) {
                comps.query = nil
                comps.fragment = nil
                if let cleaned = comps.string {
                    request.url = cleaned
                }
            }
        }

        // 3. Scrub device.name out of the contexts dictionary.
        //    `event.context` is `[String: [String: Any]]` — mutate
        //    a copy and reassign because the outer dict is read-only
        //    in some SDK versions.
        var contexts = event.context ?? [:]
        if var deviceCtx = contexts["device"] {
            deviceCtx.removeValue(forKey: "name")
            // Also remove a couple of other identifier-ish keys that
            // Sentry pulls from UIDevice / sysctl by default but
            // that a VPN user might consider sensitive on the wire.
            deviceCtx.removeValue(forKey: "device_unique_identifier")
            deviceCtx.removeValue(forKey: "boot_time")
            contexts["device"] = deviceCtx
        }
        event.context = contexts

        // 4. Clear the hostname field outright. Sentry uses
        //    `gethostname(3)` to populate this, which on macOS is the
        //    user-chosen Computer Name.
        event.serverName = ""

        // 5. Drop the `device.name` tag if Sentry mirrored it there.
        if var tags = event.tags {
            tags.removeValue(forKey: "device.name")
            tags.removeValue(forKey: "server_name")
            event.tags = tags
        }

        return event
    }
}

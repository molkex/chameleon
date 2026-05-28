import XCTest
import Sentry
@testable import MadFrogVPN

/// LAUNCH-03. Verifies `CrashReporter.sanitize(_:)` actually strips
/// every field listed in the ADR
/// (`docs/decisions/0007-sentry-eu-crash-reporting.md`).
///
/// We don't boot the SDK here — we just exercise the pure-function
/// `sanitize(_:)` against a hand-built `Event`. That's enough to
/// catch regressions where someone disables one of the scrubs.
final class CrashReporterSanitizeTests: XCTestCase {

    // MARK: - User scrubbing

    func testSanitizeDropsUser() {
        let event = Event(level: .error)
        let user = User()
        user.userId = "user-1234"
        user.email = "leak@example.com"
        user.ipAddress = "203.0.113.42"
        user.username = "shouldnotleak"
        event.user = user

        _ = CrashReporter.sanitize(event)

        XCTAssertNil(event.user, "User block must be wiped before send")
    }

    // MARK: - Request URL scrubbing

    func testSanitizeStripsQueryStringFromRequestURL() {
        let event = Event(level: .error)
        let req = SentryRequest()
        req.url = "https://api.madfrog.online/app/signin?token=secret-magic-token&debug=1"
        req.queryString = "token=secret-magic-token&debug=1"
        event.request = req

        _ = CrashReporter.sanitize(event)

        XCTAssertEqual(event.request?.url, "https://api.madfrog.online/app/signin",
                       "Query string must be dropped from request URL")
        XCTAssertNil(event.request?.queryString,
                     "Request.queryString must be cleared")
    }

    func testSanitizeStripsFragmentFromRequestURL() {
        let event = Event(level: .error)
        let req = SentryRequest()
        req.url = "https://api.madfrog.online/x#access_token=AAAA.BBBB.CCCC"
        event.request = req

        _ = CrashReporter.sanitize(event)

        XCTAssertEqual(event.request?.url, "https://api.madfrog.online/x",
                       "URL fragment must be dropped — could carry implicit-flow tokens")
    }

    func testSanitizePreservesPathWhenNoQuery() {
        let event = Event(level: .error)
        let req = SentryRequest()
        req.url = "https://api.madfrog.online/api/v1/mobile/healthcheck"
        event.request = req

        _ = CrashReporter.sanitize(event)

        XCTAssertEqual(event.request?.url,
                       "https://api.madfrog.online/api/v1/mobile/healthcheck",
                       "Clean URLs must round-trip unchanged")
    }

    // MARK: - Device context scrubbing

    func testSanitizeRemovesDeviceNameFromContext() {
        let event = Event(level: .error)
        event.context = [
            "device": [
                "name": "Maksim's MacBook Pro",
                "model": "MacBookPro18,2",
                "boot_time": "2026-05-28T08:00:00Z",
                "device_unique_identifier": "ABCDEF12-1234-5678-9ABC-DEF012345678"
            ],
            "os": [
                "name": "macOS",
                "version": "14.4"
            ]
        ]

        _ = CrashReporter.sanitize(event)

        let device = event.context?["device"]
        XCTAssertNil(device?["name"], "device.name leaks the user-chosen machine name")
        XCTAssertNil(device?["boot_time"], "device.boot_time is a fingerprint")
        XCTAssertNil(device?["device_unique_identifier"],
                     "device_unique_identifier is a stable fingerprint")
        // model + os.* are NOT PII — must survive so crashes stay actionable.
        XCTAssertEqual(device?["model"] as? String, "MacBookPro18,2",
                       "Hardware model is needed for symbolication context")
        XCTAssertEqual(event.context?["os"]?["name"] as? String, "macOS",
                       "OS context must survive — not PII")
    }

    // MARK: - serverName / tags

    func testSanitizeClearsServerName() {
        let event = Event(level: .error)
        event.serverName = "Maksims-MacBook-Pro.local"

        _ = CrashReporter.sanitize(event)

        XCTAssertEqual(event.serverName, "",
                       "serverName (hostname) leaks the user's machine name")
    }

    func testSanitizeDropsDeviceNameTag() {
        let event = Event(level: .error)
        event.tags = [
            "device.name": "Maksim's iPhone",
            "server_name": "Maksims-iPhone.local",
            "app.kind": "vpn-client"   // keeper — set by configureScope
        ]

        _ = CrashReporter.sanitize(event)

        XCTAssertNil(event.tags?["device.name"])
        XCTAssertNil(event.tags?["server_name"])
        XCTAssertEqual(event.tags?["app.kind"], "vpn-client",
                       "Non-PII tags must survive — only PII keys are dropped")
    }

    // MARK: - Returns event (never drops by default)

    func testSanitizeReturnsTheEventByDefault() {
        let event = Event(level: .error)
        let result = CrashReporter.sanitize(event)
        XCTAssertNotNil(result,
                        "sanitize must not drop crashes — only scrub fields")
    }
}

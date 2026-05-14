import XCTest
import NetworkExtension
@testable import MadFrogVPN

/// test-coverage (ios-vpn-error-mapper): pins `VPNErrorMapper.humanMessage`
/// — the pure raw-error → short-user-message mapping. The invariant under
/// test: every branch yields a non-empty string and no case silently
/// falls through to "".
final class VPNErrorMapperTests: XCTestCase {

    private func nevpnError(_ code: NEVPNError.Code) -> NSError {
        NSError(domain: NEVPNErrorDomain, code: code.rawValue)
    }

    // MARK: - NEVPNError domain cases

    func testEveryNEVPNErrorCodeMapsToNonEmpty() {
        let codes: [NEVPNError.Code] = [
            .configurationInvalid,
            .configurationDisabled,
            .connectionFailed,
            .configurationStale,
            .configurationReadWriteFailed,
            .configurationUnknown,
        ]
        for code in codes {
            let msg = VPNErrorMapper.humanMessage(nevpnError(code))
            XCTAssertFalse(msg.isEmpty, "NEVPNError.\(code) mapped to an empty string")
        }
    }

    func testConfigurationUnknownReusesConfigInvalidMessage() {
        // configurationUnknown intentionally falls through to the same
        // message as configurationInvalid — assert they agree.
        let unknown = VPNErrorMapper.humanMessage(nevpnError(.configurationUnknown))
        let invalid = VPNErrorMapper.humanMessage(nevpnError(.configurationInvalid))
        XCTAssertEqual(unknown, invalid)
    }

    // MARK: - keyword-matched generic NSErrors

    /// Builds an NSError whose `localizedDescription` carries `desc`.
    private func describedError(_ desc: String) -> NSError {
        NSError(domain: "TestDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: desc])
    }

    func testPermissionKeywordsMapToPermissionMessage() {
        for desc in ["Operation not permitted", "Permission denied", "access denied"] {
            let msg = VPNErrorMapper.humanMessage(describedError(desc))
            XCTAssertEqual(msg, L10n.Error.permission, "‘\(desc)’ should map to the permission message")
            XCTAssertFalse(msg.isEmpty)
        }
    }

    func testNetworkKeywordsMapToOfflineMessage() {
        for desc in ["The Internet connection appears to be offline",
                     "A network error occurred",
                     "Could not find host"] {
            let msg = VPNErrorMapper.humanMessage(describedError(desc))
            XCTAssertEqual(msg, L10n.Error.offline, "‘\(desc)’ should map to the offline message")
            XCTAssertFalse(msg.isEmpty)
        }
    }

    func testTimeoutKeywordsMapToServerTimeoutMessage() {
        for desc in ["The request timed out", "connection timeout"] {
            let msg = VPNErrorMapper.humanMessage(describedError(desc))
            XCTAssertEqual(msg, L10n.Error.serverTimeout, "‘\(desc)’ should map to the server-timeout message")
            XCTAssertFalse(msg.isEmpty)
        }
    }

    // MARK: - generic fallback

    func testNoiseCocoaPrefixIsReplacedWithGenericMessage() {
        let msg = VPNErrorMapper.humanMessage(describedError("The operation couldn't be completed."))
        XCTAssertEqual(msg, L10n.Error.generic,
                       "the bare Cocoa noise prefix must be swapped for the friendly generic message")
        XCTAssertFalse(msg.isEmpty)
    }

    func testUnrecognisedErrorIsPassedThroughVerbatim() {
        // A descriptive error we have no rule for is kept as-is (better
        // than a vague generic) — still must be non-empty.
        let msg = VPNErrorMapper.humanMessage(describedError("Server returned malformed JWS chain"))
        XCTAssertEqual(msg, "Server returned malformed JWS chain")
        XCTAssertFalse(msg.isEmpty)
    }

    // MARK: - keyword precedence

    func testPermissionIsCheckedBeforeNetwork() {
        // A description carrying both keywords resolves to permission —
        // permission is checked first in the branch ladder.
        let msg = VPNErrorMapper.humanMessage(describedError("network access denied"))
        XCTAssertEqual(msg, L10n.Error.permission)
    }

    func testNetworkIsCheckedBeforeTimeout() {
        let msg = VPNErrorMapper.humanMessage(describedError("network request timed out"))
        XCTAssertEqual(msg, L10n.Error.offline)
    }

    // MARK: - static convenience messages

    func testStaticMessagesAreNonEmpty() {
        XCTAssertFalse(VPNErrorMapper.watchdogTimeout.isEmpty)
        XCTAssertFalse(VPNErrorMapper.permissionMissing.isEmpty)
        XCTAssertEqual(VPNErrorMapper.permissionMissing, L10n.Error.permission)
    }
}

import XCTest
@testable import MadFrogVPN

/// Regression guard for audit MED-006 (build-88): the timeout race that
/// wraps every `NETunnelProviderSession.sendProviderMessage` call.
///
/// The real `sendMessage` cannot be unit-tested directly — it needs an
/// `NETunnelProviderManager` whose `connection` is bound to a live
/// `NETunnelProviderSession`, neither of which can be constructed in a
/// unit-test environment (the system creates them out-of-process when
/// the user accepts the VPN profile). Build-88 lifts the race itself
/// into the pure helper `VPNManager.raceWithTimeout(timeout:operation:)`
/// so the timeout-vs-completion semantics can be exercised here without
/// touching NetworkExtension.
///
/// The invariants we pin:
///   * Fast operation → the operation's return value bubbles up unchanged.
///   * Slow operation → the timeout wins and throws
///     `NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)` so
///     existing callers that key on `URLError(.timedOut)` keep matching.
///   * Operation that itself throws → its error propagates (the timeout
///     isn't masking real errors).
@MainActor
final class VPNManagerTimeoutTests: XCTestCase {

    func testFastOperationReturnsValue() async throws {
        let result = try await VPNManager.raceWithTimeout(timeout: .seconds(1)) {
            return "ok"
        }
        XCTAssertEqual(result, "ok")
    }

    func testSlowOperationThrowsTimedOut() async {
        do {
            _ = try await VPNManager.raceWithTimeout(timeout: .milliseconds(100)) {
                try await Task.sleep(for: .seconds(10))
                return "late"
            }
            XCTFail("expected timeout to fire before the 10s sleep completes")
        } catch let nsError as NSError {
            XCTAssertEqual(nsError.domain, NSURLErrorDomain,
                           "MED-006: timeout MUST be NSURLErrorDomain so callers keying on URLError match")
            XCTAssertEqual(nsError.code, NSURLErrorTimedOut,
                           "MED-006: code must be NSURLErrorTimedOut")
        } catch {
            XCTFail("expected NSError(NSURLErrorDomain, NSURLErrorTimedOut), got \(error)")
        }
    }

    func testSlowOperationThrowsURLErrorTimedOutBridged() async {
        // The thrown NSError bridges to URLError(.timedOut) — verify the
        // Swift-native pattern callers may use also matches.
        do {
            _ = try await VPNManager.raceWithTimeout(timeout: .milliseconds(50)) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
            XCTFail("expected timeout")
        } catch let urlError as URLError {
            XCTAssertEqual(urlError.code, .timedOut)
        } catch let nsError as NSError {
            // Accept the un-bridged NSError too — Swift's error bridging
            // chooses which face you see based on the catch pattern order.
            XCTAssertEqual(nsError.code, NSURLErrorTimedOut)
        }
    }

    func testOperationErrorPropagates() async {
        struct Boom: Error, Equatable {}
        do {
            _ = try await VPNManager.raceWithTimeout(timeout: .seconds(5)) {
                throw Boom()
            }
            XCTFail("expected Boom to propagate")
        } catch let boom as Boom {
            XCTAssertEqual(boom, Boom())
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    func testSendMessageReturnsNilWhenNoManagerLoaded() async throws {
        // Sanity: with no manager loaded the guard at the top of
        // sendMessage returns nil before any timeout/race work runs.
        // This ensures the extract didn't change that early-return path.
        let manager = VPNManager()
        let response = try await manager.sendMessage(Data())
        XCTAssertNil(response, "no NETunnelProviderManager → nil, no timeout")
    }
}

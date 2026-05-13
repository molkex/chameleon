import XCTest
@testable import MadFrogVPN
import Libbox

/// Pin the vendored Libbox.xcframework to a known-good sing-box base. If
/// someone rebuilds libbox against a newer upstream tag and the new tag
/// has a memory regression (build 56-58 = sing-box v1.13.6 OOM-killer loop
/// on iOS NE, field log 2026-05-13 19:43) this test fails BEFORE the build
/// ships to TestFlight. Bump the expected version alongside any deliberate
/// libbox upgrade after running the full memory bench.
///
/// History:
///   - 1.13.5 — production-stable through builds 39-55, ~32-35 MB RSS on
///     iOS NE during normal use, well under the 50 MB jetsam cap.
///   - 1.13.6 — fork HEAD used in builds 56-58. Memory regression: phys
///     hit 47 MB within 60 s of Telegram traffic; singbox internal
///     oom-killer fired ~500x/sec resetting the network, killing every TG
///     connection on each reset. Build 60 reverted to 1.13.5 + our
///     first-write callback patch cherry-picked.
final class LibboxVersionGuardTests: XCTestCase {

    /// Update this prefix only after verifying the new libbox version
    /// keeps PacketTunnel RSS under ~35 MB during a realistic Telegram /
    /// browser load on a real iPhone (not the simulator — simulator memory
    /// behaviour differs from device).
    ///
    /// We match by prefix because gomobile bakes the git commit suffix
    /// into the version string (e.g. "1.13.5-f087cc8b"). The base "1.13.5"
    /// is the part we're pinning to; the suffix changes with each rebuild
    /// and isn't load-bearing.
    static let expectedSingboxBase = "1.13.5"

    func testLibboxIsPinnedToExpectedVersion() {
        let actual = LibboxVersion()
        XCTAssertTrue(
            actual.hasPrefix(Self.expectedSingboxBase),
            """
            Libbox.xcframework reports sing-box \(actual) but this build \
            pins to \(Self.expectedSingboxBase).x. If the upgrade is \
            intentional, run a memory benchmark on a real device and \
            bump `expectedSingboxBase` only if RSS stays under ~35 MB. \
            Builds 56-58 shipped 1.13.6 and triggered an oom-killer reset \
            loop on iOS NE within 60 s of TG traffic — see commit 2a63451 \
            for the revert rationale.
            """
        )
    }

    /// Defensive: Libbox version must not be empty. An empty string means
    /// the framework loaded but `LibboxVersion()` returned a zero value,
    /// which typically signals a stripped-symbols build or a wiring bug
    /// in gomobile bind — both of which break runtime feature detection
    /// elsewhere in the app.
    func testLibboxVersionIsNotEmpty() {
        XCTAssertFalse(LibboxVersion().isEmpty, "LibboxVersion() returned empty — framework load probably broken")
    }
}

import XCTest
@testable import MadFrogVPN

/// COUNTRY-PICK-STICKY (2026-06-17). A deliberate country pick must survive a
/// transient/flat live config — it was silently reverted to Auto when
/// applyServerSelectionIfLive's strict resolver returned empty and the block
/// nuked the persisted tag. The reset is now gated by shouldResetStaleSelection:
/// only a genuinely-retired target (config populated, no match) resets; an
/// unavailable config keeps the pin.
final class CountryPickStickyTests: XCTestCase {

    func testKeepsPinWhenConfigUnavailable() {
        // Mid-refresh / flat config: no servers parsed → keep the pin, DON'T reset.
        XCTAssertFalse(AppState.shouldResetStaleSelection(target: "🇫🇷 Франция",
                                                          chainResolved: false,
                                                          configHasServers: false))
    }

    func testResetsWhenTargetRetiredFromPopulatedConfig() {
        // Build-85: config HAS servers but the picked country is gone (DE retired).
        XCTAssertTrue(AppState.shouldResetStaleSelection(target: "🇩🇪 Германия",
                                                         chainResolved: false,
                                                         configHasServers: true))
    }

    func testKeepsResolvedSelection() {
        // Chain resolved → never reset, regardless of anything else.
        XCTAssertFalse(AppState.shouldResetStaleSelection(target: "🇫🇷 Франция",
                                                          chainResolved: true,
                                                          configHasServers: true))
    }

    func testAutoNeverResets() {
        XCTAssertFalse(AppState.shouldResetStaleSelection(target: "Auto",
                                                          chainResolved: false,
                                                          configHasServers: true))
    }
}

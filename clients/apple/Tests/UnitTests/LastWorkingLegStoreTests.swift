import XCTest
@testable import MadFrogVPN

final class LastWorkingLegStoreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "LastWorkingLegStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testSetThenGetRoundtrip() {
        let store = LastWorkingLegStore(defaults: freshDefaults())
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-via-msk")
        XCTAssertEqual(store.get(fingerprint: "wifi:Home", country: "DE"), "de-via-msk")
    }

    func testGetMissReturnsNil() {
        let store = LastWorkingLegStore(defaults: freshDefaults())
        XCTAssertNil(store.get(fingerprint: "wifi:Home", country: "DE"))
    }

    func testFingerprintAndCountryArePartOfKey() {
        let store = LastWorkingLegStore(defaults: freshDefaults())
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-via-msk")
        store.set(fingerprint: "cellular", country: "DE", leg: "de-direct-de")
        XCTAssertEqual(store.get(fingerprint: "wifi:Home", country: "DE"), "de-via-msk")
        XCTAssertEqual(store.get(fingerprint: "cellular", country: "DE"), "de-direct-de")
        XCTAssertNil(store.get(fingerprint: "wifi:Home", country: "NL"))
    }

    func testForgetClearsEntry() {
        let store = LastWorkingLegStore(defaults: freshDefaults())
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-via-msk")
        store.forget(fingerprint: "wifi:Home", country: "DE")
        XCTAssertNil(store.get(fingerprint: "wifi:Home", country: "DE"))
    }

    func testOverwriteSameLegIsIdempotent() {
        let defaults = freshDefaults()
        let store = LastWorkingLegStore(defaults: defaults)
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-via-msk")
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-via-msk")
        XCTAssertEqual(store.get(fingerprint: "wifi:Home", country: "DE"), "de-via-msk")
    }

    func testOverwriteDifferentLegReplaces() {
        let store = LastWorkingLegStore(defaults: freshDefaults())
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-direct-de")
        store.set(fingerprint: "wifi:Home", country: "DE", leg: "de-via-msk")
        XCTAssertEqual(store.get(fingerprint: "wifi:Home", country: "DE"), "de-via-msk")
    }
}

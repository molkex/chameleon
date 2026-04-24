import XCTest
@testable import MadFrogVPN

/// Keychain in iOS Simulator returns errSecMissingEntitlement (-34018) for
/// generic-password items unless the test bundle is signed with a real
/// keychain-access-group entitlement, which would require a paid signing
/// identity in this XCTest target. Per the test brief: "Если Keychain в
/// Simulator работает иначе — пропусти на real device tests."
///
/// We therefore probe the Keychain once at setUp and `XCTSkip` the suite
/// when running in Simulator. On a real device these tests are expected
/// to pass without modification.
final class KeychainHelperTests: XCTestCase {

    private var writtenKeys: Set<String> = []
    private static let probeKey = "test.keychain.probe"

    override func setUpWithError() throws {
        try Self.skipIfKeychainUnavailable()
    }

    override func tearDown() {
        for key in writtenKeys {
            KeychainHelper.delete(key: key)
        }
        writtenKeys.removeAll()
        super.tearDown()
    }

    /// Returns successfully if Keychain reads/writes work. Throws
    /// `XCTSkip` if Keychain is sandboxed off (errSecMissingEntitlement
    /// in Simulator unit-test bundles).
    private static func skipIfKeychainUnavailable() throws {
        KeychainHelper.delete(key: probeKey)
        KeychainHelper.save(key: probeKey, value: "probe")
        let loaded = KeychainHelper.load(key: probeKey)
        KeychainHelper.delete(key: probeKey)
        if loaded != "probe" {
            throw XCTSkip("Keychain unavailable in this test environment (likely Simulator unit-test bundle without keychain-access-group entitlement). Run on a real device to exercise these tests.")
        }
    }

    private func uniqueKey(_ name: String = #function) -> String {
        let base = name.replacingOccurrences(of: "()", with: "")
        let key = "test.\(base).\(UUID().uuidString)"
        writtenKeys.insert(key)
        return key
    }

    // MARK: - Roundtrip

    func testSaveLoadRoundtripASCII() {
        let key = uniqueKey()
        KeychainHelper.save(key: key, value: "hello-world")
        XCTAssertEqual(KeychainHelper.load(key: key), "hello-world")
    }

    func testSaveLoadRoundtripUnicode() {
        let key = uniqueKey()
        let value = "Привет мир — 你好 — 🦊🔐"
        KeychainHelper.save(key: key, value: value)
        XCTAssertEqual(KeychainHelper.load(key: key), value)
    }

    func testSaveLoadRoundtripLongValue() {
        let key = uniqueKey()
        let value = String(repeating: "X", count: 4096)
        KeychainHelper.save(key: key, value: value)
        XCTAssertEqual(KeychainHelper.load(key: key), value)
    }

    // MARK: - Idempotent overwrite

    func testSaveOverwritesExistingValue() {
        let key = uniqueKey()
        KeychainHelper.save(key: key, value: "first")
        XCTAssertEqual(KeychainHelper.load(key: key), "first")

        KeychainHelper.save(key: key, value: "second")
        XCTAssertEqual(KeychainHelper.load(key: key), "second")

        KeychainHelper.save(key: key, value: "third")
        XCTAssertEqual(KeychainHelper.load(key: key), "third")
    }

    // MARK: - Delete

    func testDeleteRemovesValue() {
        let key = uniqueKey()
        KeychainHelper.save(key: key, value: "to-be-deleted")
        XCTAssertNotNil(KeychainHelper.load(key: key))

        KeychainHelper.delete(key: key)
        XCTAssertNil(KeychainHelper.load(key: key))
    }

    func testDeleteUnknownKeyDoesNotCrash() {
        let key = uniqueKey()
        // Never saved — must be a no-op.
        KeychainHelper.delete(key: key)
        XCTAssertNil(KeychainHelper.load(key: key))
    }

    func testLoadMissingKeyReturnsNil() {
        let key = uniqueKey()
        XCTAssertNil(KeychainHelper.load(key: key))
    }
}

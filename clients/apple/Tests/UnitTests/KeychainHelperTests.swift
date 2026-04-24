import XCTest
@testable import MadFrogVPN

/// Keychain works in iOS Simulator but is process-scoped per simulator
/// device, so values can leak across tests if not cleaned up. Each test
/// uses a unique key prefix and tearDown deletes everything it wrote.
final class KeychainHelperTests: XCTestCase {

    private var writtenKeys: Set<String> = []

    override func tearDown() {
        for key in writtenKeys {
            KeychainHelper.delete(key: key)
        }
        writtenKeys.removeAll()
        super.tearDown()
    }

    private func uniqueKey(_ name: String = #function) -> String {
        // Sanitize function name (e.g. "testFoo()") into a stable identifier
        // and add a UUID so parallel runs don't collide.
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

    func testSaveLoadRoundtripEmptyString() {
        let key = uniqueKey()
        KeychainHelper.save(key: key, value: "")
        // Note: kSecValueData with zero-length Data may behave platform-
        // dependently. We just assert load returns "" (round-trip), not
        // anything stronger.
        let loaded = KeychainHelper.load(key: key)
        XCTAssertEqual(loaded, "")
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

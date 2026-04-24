import XCTest
@testable import MadFrogVPN

/// Russian noun pluralisation: 1 → singular, 2-4 → "few", 5-20 → "many",
/// then the cycle repeats every 10 except 11-19 are always "many".
/// Source: StringUtils.dayNoun / serverNoun.
final class StringUtilsTests: XCTestCase {

    // MARK: - dayNoun

    func testDayNounSingular() {
        XCTAssertEqual(StringUtils.dayNoun(1), "день")
        XCTAssertEqual(StringUtils.dayNoun(21), "день")
        XCTAssertEqual(StringUtils.dayNoun(101), "день")
        XCTAssertEqual(StringUtils.dayNoun(1001), "день")
    }

    func testDayNounFew() {
        XCTAssertEqual(StringUtils.dayNoun(2), "дня")
        XCTAssertEqual(StringUtils.dayNoun(3), "дня")
        XCTAssertEqual(StringUtils.dayNoun(4), "дня")
        XCTAssertEqual(StringUtils.dayNoun(22), "дня")
        XCTAssertEqual(StringUtils.dayNoun(33), "дня")
        XCTAssertEqual(StringUtils.dayNoun(104), "дня")
    }

    func testDayNounMany() {
        XCTAssertEqual(StringUtils.dayNoun(5), "дней")
        XCTAssertEqual(StringUtils.dayNoun(6), "дней")
        XCTAssertEqual(StringUtils.dayNoun(20), "дней")
        XCTAssertEqual(StringUtils.dayNoun(25), "дней")
        XCTAssertEqual(StringUtils.dayNoun(100), "дней")
    }

    func testDayNounTeenSpecialCase() {
        // 11..19 are "many" regardless of last digit (11, 12, 13, 14 must NOT
        // become "день" / "дня" — that's the whole point of the rule).
        for n in 11...19 {
            XCTAssertEqual(
                StringUtils.dayNoun(n),
                "дней",
                "n=\(n) must be 'дней' (teen rule)"
            )
        }
        // 111..119 — same teen rule applies via mod 100.
        for n in 111...119 {
            XCTAssertEqual(
                StringUtils.dayNoun(n),
                "дней",
                "n=\(n) must be 'дней' (teen rule via mod 100)"
            )
        }
    }

    func testDayNounZero() {
        // 0 % 10 == 0 → "many"; this is the conventional Russian form
        // ("0 дней").
        XCTAssertEqual(StringUtils.dayNoun(0), "дней")
    }

    // MARK: - serverNoun

    func testServerNounSingular() {
        XCTAssertEqual(StringUtils.serverNoun(1), "сервер")
        XCTAssertEqual(StringUtils.serverNoun(21), "сервер")
        XCTAssertEqual(StringUtils.serverNoun(101), "сервер")
    }

    func testServerNounFew() {
        XCTAssertEqual(StringUtils.serverNoun(2), "сервера")
        XCTAssertEqual(StringUtils.serverNoun(3), "сервера")
        XCTAssertEqual(StringUtils.serverNoun(4), "сервера")
        XCTAssertEqual(StringUtils.serverNoun(22), "сервера")
        XCTAssertEqual(StringUtils.serverNoun(104), "сервера")
    }

    func testServerNounMany() {
        XCTAssertEqual(StringUtils.serverNoun(5), "серверов")
        XCTAssertEqual(StringUtils.serverNoun(10), "серверов")
        XCTAssertEqual(StringUtils.serverNoun(20), "серверов")
        XCTAssertEqual(StringUtils.serverNoun(25), "серверов")
    }

    func testServerNounTeenSpecialCase() {
        for n in 11...19 {
            XCTAssertEqual(
                StringUtils.serverNoun(n),
                "серверов",
                "n=\(n) must be 'серверов' (teen rule)"
            )
        }
    }

    func testServerNounZero() {
        XCTAssertEqual(StringUtils.serverNoun(0), "серверов")
    }
}

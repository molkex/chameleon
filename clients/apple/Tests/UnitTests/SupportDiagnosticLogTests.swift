import XCTest
@testable import MadFrogVPN

/// SUPPORT-CHAT "Отправить лог" (2026-06-04) — guards for the singbox.log tail
/// that the diagnostic button attaches.
///
/// `tailLogText` is the pure half of `readSingboxLogTail` (the file half needs
/// the App Group container, sandboxed off in unit-test bundles). It turns a
/// raw byte slice — which, when cut from a multi-GB log, can start mid-line and
/// even mid-UTF-8-character — into a clean string support can read.
@MainActor
final class SupportDiagnosticLogTests: XCTestCase {

    func testWholeFileIsReturnedVerbatim() {
        let body = "line one\nline two\nline three\n"
        let out = AppState.tailLogText(Data(body.utf8), truncated: false)
        XCTAssertEqual(out, body, "an untruncated log must pass through unchanged")
    }

    func testTruncatedDropsLeadingPartialLineAndMarks() {
        // Simulate a cut in the middle of the first line.
        let slice = "ne one\nline two\nline three\n"
        let out = AppState.tailLogText(Data(slice.utf8), truncated: true)
        XCTAssertTrue(out.hasPrefix("…(обрезано"), "a truncated tail must be marked as such")
        XCTAssertFalse(out.contains("ne one"), "the partial first line must be dropped")
        XCTAssertTrue(out.contains("line two"), "the first WHOLE line must survive")
        XCTAssertTrue(out.contains("line three"), "the rest of the tail must survive")
    }

    func testTruncatedWithNoNewlineKeepsContent() {
        // A single huge line with no newline in the slice: nothing to drop, but
        // it must still be marked truncated.
        let out = AppState.tailLogText(Data("blobblobblob".utf8), truncated: true)
        XCTAssertTrue(out.hasPrefix("…(обрезано"))
        XCTAssertTrue(out.contains("blobblobblob"))
    }

    func testTruncatedMidUTF8DoesNotCrashAndDropsPartialLine() {
        // Cut in the middle of a multi-byte character ("я" = D1 8F): keep only
        // the trailing byte 0x8F, then a newline + a clean line. Decoding must
        // not crash, and the partial first line is dropped.
        var data = Data([0x8F]) // dangling UTF-8 continuation byte
        data.append(Data("\nчисто\n".utf8))
        let out = AppState.tailLogText(data, truncated: true)
        XCTAssertTrue(out.hasPrefix("…(обрезано"))
        XCTAssertTrue(out.contains("чисто"))
    }

    func testEmptyUntruncatedIsEmpty() {
        XCTAssertEqual(AppState.tailLogText(Data(), truncated: false), "")
    }

    func testDiagnosticLogFilenameIsBrandedUniqueAndHidesEngine() {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 4; c.hour = 14; c.minute = 34; c.second = 12
        let d = Calendar.current.date(from: c)!
        let name = AppState.diagnosticLogFilename(date: d)
        XCTAssertEqual(name, "madfrog-log-20260604-143412.log", "branded + timestamped name")
        XCTAssertFalse(name.lowercased().contains("singbox"), "must not leak the engine name")
    }
}

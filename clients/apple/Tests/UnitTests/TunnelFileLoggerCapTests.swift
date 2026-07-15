import XCTest
@testable import MadFrogVPN

/// LOG-01 (2026-06-06) — guard for the singbox.log size cap that bounds
/// libbox's DEBUG/TRACE firehose. The raw file grew to 565 MB in the field
/// (wasted disk + a memory spike when naively truncated, feeding the NE
/// oom-killer's "resetting network" tunnel drops). `truncationKeepOffset` is
/// the pure half: ExtensionPlatformInterface.writeDebugMessage seeks to this
/// offset and rewrites ONLY the tail, so a multi-hundred-MB file is never
/// loaded into the extension's ~50 MB budget to truncate it.
final class TunnelFileLoggerCapTests: XCTestCase {

    func testNoTruncationUnderOrAtCap() {
        XCTAssertNil(TunnelFileLogger.truncationKeepOffset(fileSize: 100, maxSize: 200))
        XCTAssertNil(TunnelFileLogger.truncationKeepOffset(fileSize: 200, maxSize: 200),
                     "equal to the cap must not truncate")
    }

    func testTruncationKeepsLastHalf() {
        // Over the cap → keep the last maxSize/2 bytes; offset = fileSize - keep.
        XCTAssertEqual(TunnelFileLogger.truncationKeepOffset(fileSize: 1000, maxSize: 400), 800)
        // A 565 MB file still only reads back maxSize/2 (2 MB) — memory-safe.
        XCTAssertEqual(
            TunnelFileLogger.truncationKeepOffset(fileSize: 565_000_000, maxSize: 4_000_000),
            563_000_000)
    }

    func testGuardsInvalidMax() {
        XCTAssertNil(TunnelFileLogger.truncationKeepOffset(fileSize: 1000, maxSize: 0))
        XCTAssertNil(TunnelFileLogger.truncationKeepOffset(fileSize: 1000, maxSize: -5))
    }

    // MARK: - isVerboseSingboxLine (drop TRACE/DEBUG from the file sinks)

    /// Real ANSI-colored lines as libbox emits them to writeDebugMessage.
    private static let esc = "\u{1b}"

    func testVerboseLevelsDropped() {
        // \u{1b}[37mDEBUG\u{1b}[0m[4731] … and the TRACE variant.
        XCTAssertTrue(TunnelFileLogger.isVerboseSingboxLine(
            "\(Self.esc)[37mDEBUG\(Self.esc)[0m[4731] dns: exchange strm.yandex.ru. IN A"))
        XCTAssertTrue(TunnelFileLogger.isVerboseSingboxLine(
            "\(Self.esc)[37mTRACE\(Self.esc)[0m[0001] service: start"))
        // Plain (no ANSI) DEBUG also dropped.
        XCTAssertTrue(TunnelFileLogger.isVerboseSingboxLine("DEBUG[4731] router: match"))
    }

    func testInfoAndAboveKept() {
        XCTAssertFalse(TunnelFileLogger.isVerboseSingboxLine(
            "\(Self.esc)[36mINFO\(Self.esc)[0m[4731] outbound/vless[nl-direct-nl2]: outbound connection"))
        XCTAssertFalse(TunnelFileLogger.isVerboseSingboxLine(
            "\(Self.esc)[31mERROR\(Self.esc)[0m[4731] service/oom-killer: resetting network"))
        XCTAssertFalse(TunnelFileLogger.isVerboseSingboxLine("WARN something"))
        XCTAssertFalse(TunnelFileLogger.isVerboseSingboxLine(""))
        // A domain containing "debug" must NOT be misread as a DEBUG line.
        XCTAssertFalse(TunnelFileLogger.isVerboseSingboxLine(
            "\(Self.esc)[36mINFO\(Self.esc)[0m[1] dns: exchange debug.example.com. IN A"))
    }

    // MARK: - isBelowWarnSingboxLine (NE-LOG-SINK-FIX: drop TRACE/DEBUG/INFO)

    func testBelowWarnLevelsDropped() {
        XCTAssertTrue(TunnelFileLogger.isBelowWarnSingboxLine(
            "\(Self.esc)[37mDEBUG\(Self.esc)[0m[4731] dns: exchange strm.yandex.ru. IN A"))
        XCTAssertTrue(TunnelFileLogger.isBelowWarnSingboxLine(
            "\(Self.esc)[37mTRACE\(Self.esc)[0m[0001] service: start"))
        XCTAssertTrue(TunnelFileLogger.isBelowWarnSingboxLine("DEBUG[4731] router: match"))
        // INFO is the delta vs isVerboseSingboxLine — now also dropped.
        XCTAssertTrue(TunnelFileLogger.isBelowWarnSingboxLine(
            "\(Self.esc)[36mINFO\(Self.esc)[0m[4731] outbound/vless[nl-direct-nl2]: outbound connection"))
    }

    func testWarnAndAboveKeptByBelowWarn() {
        XCTAssertFalse(TunnelFileLogger.isBelowWarnSingboxLine(
            "\(Self.esc)[33mWARN\(Self.esc)[0m[4731] service/oom-killer: memory pressure"))
        XCTAssertFalse(TunnelFileLogger.isBelowWarnSingboxLine(
            "\(Self.esc)[31mERROR\(Self.esc)[0m[4731] service/oom-killer: resetting network"))
        XCTAssertFalse(TunnelFileLogger.isBelowWarnSingboxLine("WARN something"))
        XCTAssertFalse(TunnelFileLogger.isBelowWarnSingboxLine(""))
        // A domain containing "info" must NOT be misread as an INFO line.
        XCTAssertFalse(TunnelFileLogger.isBelowWarnSingboxLine(
            "\(Self.esc)[33mWARN\(Self.esc)[0m[1] dns: exchange info.example.com. IN A"))
    }
}

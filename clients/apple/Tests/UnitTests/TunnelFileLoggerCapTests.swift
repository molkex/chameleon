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
}

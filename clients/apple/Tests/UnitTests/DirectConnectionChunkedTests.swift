import XCTest
@testable import MadFrogVPN

/// 2026-07-11 field bug: nginx serves `/api/v1/mobile/config` (and likely
/// other dynamically-sized JSON responses) with `Transfer-Encoding: chunked`
/// and no `Content-Length` (confirmed live via `curl -D-`). `DirectConnection`
/// — the raw HTTP/1.1 client used for the decoy and direct-IP race legs —
/// took everything after the header terminator as the body verbatim, so
/// every response that won the race via a non-primary leg had literal hex
/// chunk-size lines spliced into the JSON. That produced exactly the two
/// `decode config` errors seen on-device: a line starting with a hex a-f
/// digit ("invalid character 'd' ... row 1, column 1") or an all-decimal
/// chunk size that a JSON decoder reads as a bare top-level number ("cannot
/// unmarshal number into Go value of type option._Options"). These tests pin
/// `DirectConnection.dechunk` so that regression can't silently return.
final class DirectConnectionChunkedTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testSingleChunk() {
        let raw = data("5\r\nhello\r\n0\r\n\r\n")
        XCTAssertEqual(String(data: DirectConnection.dechunk(raw), encoding: .utf8), "hello")
    }

    func testMultipleChunks() {
        let raw = data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n")
        XCTAssertEqual(String(data: DirectConnection.dechunk(raw), encoding: .utf8), "Wikipedia")
    }

    func testChunkSizeExtensionIsIgnored() {
        // RFC 7230 allows `chunk-ext` after the size, delimited by ';'.
        let raw = data("5;ignored-extension=1\r\nhello\r\n0\r\n\r\n")
        XCTAssertEqual(String(data: DirectConnection.dechunk(raw), encoding: .utf8), "hello")
    }

    func testTrailerHeadersAfterTerminatorAreIgnored() {
        let raw = data("5\r\nhello\r\n0\r\nX-Trailer: ignored\r\n\r\n")
        XCTAssertEqual(String(data: DirectConnection.dechunk(raw), encoding: .utf8), "hello")
    }

    func testEmptyChunkedBody() {
        let raw = data("0\r\n\r\n")
        XCTAssertEqual(DirectConnection.dechunk(raw), Data())
    }

    /// The exact failure shape: a JSON config split across chunk boundaries
    /// must reassemble byte-for-byte, including a hex chunk-size that starts
    /// with a letter (a-f) — the "invalid character" trigger — to prove the
    /// hex parse itself (not just decimal-looking sizes) works.
    func testRealisticJSONAcrossChunkBoundaries() {
        let json = #"{"outbounds":[{"type":"vless","tag":"nl-direct-nl2"}]}"#
        let mid = json.index(json.startIndex, offsetBy: 20)
        let part1 = String(json[..<mid])
        let part2 = String(json[mid...])
        // part1 is 20 bytes = 0x14 (starts with digit); size the raw chunked
        // stream so the SECOND chunk's size is chosen to start with a hex
        // letter to also exercise the 'a'-'f' path.
        let raw = data("\(String(part1.utf8.count, radix: 16))\r\n\(part1)\r\n" +
                        "\(String(part2.utf8.count, radix: 16))\r\n\(part2)\r\n0\r\n\r\n")
        XCTAssertEqual(String(data: DirectConnection.dechunk(raw), encoding: .utf8), json)
    }

    func testMalformedChunkHeaderDoesNotCrashAndReturnsPartialData() {
        // Truncated / non-hex chunk-size line — must degrade gracefully
        // (return what was already decoded), never throw or crash.
        let raw = data("5\r\nhello\r\nNOT-HEX\r\ngarbage")
        XCTAssertEqual(String(data: DirectConnection.dechunk(raw), encoding: .utf8), "hello")
    }

    func testTruncatedStreamDoesNotCrash() {
        // Chunk header claims more bytes than are actually present.
        let raw = data("A\r\nshort")
        XCTAssertNoThrow(DirectConnection.dechunk(raw))
    }
}

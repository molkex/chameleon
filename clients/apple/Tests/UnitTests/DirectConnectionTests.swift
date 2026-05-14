import XCTest
@testable import MadFrogVPN

/// test-coverage-hardening: pins the pure HTTP framing of
/// `DirectConnection` — the SNI-spoofing direct-IP dialer used to bypass
/// Cloudflare throttling in RU. `buildRequest` and `parseHTTPResponse`
/// hand-roll HTTP/1.1 because URLSession can't override the SNI for a
/// resolved IP; this pins that framing without a live socket.
///
/// What this guards:
///  - request framing: request line, mandatory Host/Connection/encoding
///    headers, caller-header passthrough with host/connection dedup,
///    Content-Length + body append.
///  - response parsing: status-line extraction, header splitting, the
///    malformed-response throws.
///
/// The NWConnection TLS dial / read loop stays on-device-verified.
final class DirectConnectionTests: XCTestCase {

    private func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<non-utf8>"
    }

    // MARK: - buildRequest

    func testBuildRequest_getNoBody() {
        let req = DirectConnection.buildRequest(
            method: "GET", path: "/api/ping", host: "madfrog.online",
            headers: [:], body: nil
        )
        let s = text(req)
        XCTAssertTrue(s.hasPrefix("GET /api/ping HTTP/1.1\r\n"), "request line first")
        XCTAssertTrue(s.contains("\r\nHost: madfrog.online\r\n"))
        XCTAssertTrue(s.contains("\r\nConnection: close\r\n"), "direct dial is always one-shot")
        XCTAssertTrue(s.contains("\r\nAccept-Encoding: identity\r\n"), "identity — the manual reader can't gunzip")
        XCTAssertTrue(s.hasSuffix("\r\n\r\n"), "headers terminated by blank line, no body")
        XCTAssertFalse(s.contains("Content-Length"), "no body → no Content-Length")
    }

    func testBuildRequest_postWithBodyAddsContentLengthAndAppendsBody() {
        let body = Data("{\"k\":1}".utf8)
        let req = DirectConnection.buildRequest(
            method: "POST", path: "/api/register", host: "madfrog.online",
            headers: ["Content-Type": "application/json"], body: body
        )
        let s = text(req)
        XCTAssertTrue(s.hasPrefix("POST /api/register HTTP/1.1\r\n"))
        XCTAssertTrue(s.contains("\r\nContent-Type: application/json\r\n"))
        XCTAssertTrue(s.contains("\r\nContent-Length: \(body.count)\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n{\"k\":1}"), "body appended verbatim after the header terminator")
    }

    func testBuildRequest_dropsCallerHostAndConnectionHeaders() {
        // The caller must not be able to override Host (SNI integrity) or
        // Connection (one-shot semantics) — those are filtered out.
        let req = DirectConnection.buildRequest(
            method: "GET", path: "/", host: "madfrog.online",
            headers: ["Host": "evil.com", "Connection": "keep-alive", "connection": "upgrade"],
            body: nil
        )
        let s = text(req)
        XCTAssertFalse(s.contains("evil.com"), "caller Host header must be dropped")
        XCTAssertFalse(s.contains("keep-alive"))
        XCTAssertFalse(s.contains("upgrade"))
        XCTAssertEqual(s.components(separatedBy: "Host:").count - 1, 1, "exactly one Host header")
        XCTAssertEqual(s.components(separatedBy: "Connection:").count - 1, 1, "exactly one Connection header")
    }

    func testBuildRequest_passesThroughCustomHeaders() {
        let req = DirectConnection.buildRequest(
            method: "GET", path: "/", host: "h",
            headers: ["Authorization": "Bearer xyz", "X-Device-Id": "abc"],
            body: nil
        )
        let s = text(req)
        XCTAssertTrue(s.contains("\r\nAuthorization: Bearer xyz\r\n"))
        XCTAssertTrue(s.contains("\r\nX-Device-Id: abc\r\n"))
    }

    func testBuildRequest_bodyAppendedEvenWhenNonUTF8Header() {
        // Body is appended as raw bytes regardless — verify exact length.
        let body = Data([0x00, 0xFF, 0x10])
        let req = DirectConnection.buildRequest(method: "POST", path: "/", host: "h", headers: [:], body: body)
        XCTAssertEqual(Array(req.suffix(3)), [0x00, 0xFF, 0x10])
    }

    // MARK: - parseHTTPResponse

    func testParseResponse_okWithBody() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"ok\":1}".utf8)
        let (body, meta) = try DirectConnection.parseHTTPResponse(raw)
        XCTAssertEqual(meta.status, 200)
        XCTAssertEqual(meta.headers["Content-Type"], "application/json")
        XCTAssertEqual(text(body), "{\"ok\":1}")
        XCTAssertEqual(meta.body, body)
    }

    func testParseResponse_errorStatus() throws {
        let raw = Data("HTTP/1.1 503 Service Unavailable\r\n\r\nupstream down".utf8)
        let (body, meta) = try DirectConnection.parseHTTPResponse(raw)
        XCTAssertEqual(meta.status, 503)
        XCTAssertEqual(text(body), "upstream down")
    }

    func testParseResponse_emptyBody() throws {
        let raw = Data("HTTP/1.1 204 No Content\r\nX-Trace: abc\r\n\r\n".utf8)
        let (body, meta) = try DirectConnection.parseHTTPResponse(raw)
        XCTAssertEqual(meta.status, 204)
        XCTAssertEqual(body.count, 0)
        XCTAssertEqual(meta.headers["X-Trace"], "abc")
    }

    func testParseResponse_headerValueWithColon() throws {
        // maxSplits: 1 — a value containing ':' (e.g. a Date) is kept whole.
        let raw = Data("HTTP/1.1 200 OK\r\nDate: Mon, 01 Jan 2026 12:30:00 GMT\r\n\r\n".utf8)
        let (_, meta) = try DirectConnection.parseHTTPResponse(raw)
        XCTAssertEqual(meta.headers["Date"], "Mon, 01 Jan 2026 12:30:00 GMT")
    }

    func testParseResponse_throwsOnMissingHeaderTerminator() {
        // No "\r\n\r\n" — not a complete response.
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain".utf8)
        XCTAssertThrowsError(try DirectConnection.parseHTTPResponse(raw)) { error in
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testParseResponse_throwsOnMalformedStatusLine() {
        // Status line with no parseable code.
        let raw = Data("GARBAGE\r\n\r\n".utf8)
        XCTAssertThrowsError(try DirectConnection.parseHTTPResponse(raw)) { error in
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testParseResponse_throwsOnNonNumericStatusCode() {
        let raw = Data("HTTP/1.1 OK fine\r\n\r\n".utf8)
        XCTAssertThrowsError(try DirectConnection.parseHTTPResponse(raw)) { error in
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testParseResponse_bodyContainingCRLFCRLFNotResplit() throws {
        // Only the FIRST "\r\n\r\n" splits headers from body — a body that
        // itself contains the sequence must come through intact.
        let raw = Data("HTTP/1.1 200 OK\r\n\r\nline1\r\n\r\nline2".utf8)
        let (body, _) = try DirectConnection.parseHTTPResponse(raw)
        XCTAssertEqual(text(body), "line1\r\n\r\nline2")
    }
}

import Foundation
import Network
import Security
import CryptoKit
import os.log

/// Direct TLS dial to a hardcoded IP while presenting a chosen SNI —
/// the technique used by Signal, Psiphon, Tor, and Cloudflare Warp to
/// bypass SNI-based filtering (Cloudflare is increasingly throttled in
/// Russia as of 2026-04). Because TCP connects to the IP and the TLS
/// ClientHello carries the real hostname, nginx accepts the handshake
/// exactly as if the user had resolved DNS normally.
///
/// We build HTTP/1.1 manually over the tls-wrapped NWConnection because
/// URLSession has no public API to override the SNI for a resolved IP.
/// Thread-safe one-shot latch so stateUpdateHandler (which can fire
/// multiple times) resumes its continuation exactly once.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Thread-safe storage for a one-shot checked continuation.
final class ReadyContinuationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func set(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func take() -> CheckedContinuation<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}

enum DirectConnection {

    /// Perform a single HTTP request against `ip` with the given `sni`
    /// (placed into both TLS ClientHello and HTTP Host header). Returns
    /// body + status. Throws on transport/TLS failure or timeout.
    /// `pinnedCertSHA256` — when non-nil, the server cert is validated by
    /// pinning its leaf DER SHA-256 (lowercase hex) instead of chain-vs-SNI.
    /// Used by the RU-DECOY-SNI leg: it presents a clean SNI (ads.adfox.ru)
    /// the SNI-filter won't RST, to our MSK relay which serves a self-signed
    /// cert (no CA chain to validate). Pinning also means a network that
    /// SNI-hijacks ads.adfox.ru to the REAL adfox gets rejected here — we
    /// never hand credentials to a server we didn't provision.
    static func request(
        ip: String,
        port: UInt16 = 443,
        sni: String,
        method: String,
        path: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        pinnedCertSHA256: String? = nil
    ) async throws -> (Data, HTTPResponseMeta) {
        let start = DispatchTime.now()
        return try await withThrowingTaskGroup(of: (Data, HTTPResponseMeta).self) { group in
            group.addTask {
                try await performRequest(
                    ip: ip, port: port, sni: sni,
                    method: method, path: path,
                    headers: headers, body: body,
                    start: start, pinnedCertSHA256: pinnedCertSHA256
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                let ms = elapsedMs(from: start)
                AppLogger.network.error("direct.timeout ip=\(ip, privacy: .public) port=\(port, privacy: .public) elapsed=\(ms, privacy: .public)ms")
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw URLError(.cannotConnectToHost)
            }
            return first
        }
    }

    private static func elapsedMs(from start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func performRequest(
        ip: String, port: UInt16, sni: String,
        method: String, path: String,
        headers: [String: String], body: Data?,
        start: DispatchTime, pinnedCertSHA256: String? = nil
    ) async throws -> (Data, HTTPResponseMeta) {

        // Build TLS options with the SNI we want to present. The server
        // sees sni (e.g. "api.madfrog.online"), TCP goes to `ip`.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)

        // RU-DECOY-SNI (2026-06-17): when a pin is supplied, validate by
        // leaf-cert SHA-256 instead of chain-vs-SNI. The decoy leg presents
        // SNI=ads.adfox.ru to our MSK relay (self-signed cert), so a
        // SecPolicy(ads.adfox.ru) chain check would always fail. Pinning is
        // strictly *stronger* than name validation here: only the exact cert
        // we provisioned on MSK is accepted; a hijack to the real adfox (valid
        // GlobalSign cert) is rejected, so credentials never leak.
        if let pin = pinnedCertSHA256?.lowercased() {
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, sec_trust, complete in
                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                          let leaf = chain.first else {
                        AppLogger.network.error("direct.pin no-leaf sni=\(sni, privacy: .public)")
                        complete(false)
                        return
                    }
                    let der = SecCertificateCopyData(leaf) as Data
                    let got = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                    if got != pin {
                        AppLogger.network.error("direct.pin mismatch sni=\(sni, privacy: .public) got=\(got, privacy: .public)")
                    }
                    complete(got == pin)
                },
                .global()
            )
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 5
            return try await runWith(
                params: NWParameters(tls: tlsOptions, tcp: tcpOptions),
                ip: ip, port: port, sni: sni,
                method: method, path: path,
                headers: headers, body: body, start: start
            )
        }

        // Audit H-002b (2026-05-27): validate the cert chain against `sni`.
        // The platform's default verifier uses the *hostname* in the URL,
        // but we connect to a hardcoded IP — so the default validation
        // would either be skipped or check the cert against the IP, neither
        // of which proves we are actually talking to api.madfrog.online.
        //
        // Instead, build an explicit SecPolicy bound to `sni` and evaluate
        // the server-presented trust against it. This catches every MitM
        // scenario the IP-dial opens (DNS-poisoned IPs, hijacked RU
        // exit-relay terminating TLS with its own cert, etc.) — exactly
        // what URLSession would do for a regular HTTPS dial, just bound
        // to the SNI we chose instead of the URL host.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, sec_trust, complete in
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, sni as CFString)
                let policyStatus = SecTrustSetPolicies(trust, policy)
                guard policyStatus == errSecSuccess else {
                    AppLogger.network.error("direct.cert SetPolicies failed status=\(policyStatus, privacy: .public) sni=\(sni, privacy: .public)")
                    complete(false)
                    return
                }
                var error: CFError?
                let valid = SecTrustEvaluateWithError(trust, &error)
                if !valid, let error {
                    AppLogger.network.error("direct.cert reject sni=\(sni, privacy: .public) err=\(CFErrorCopyDescription(error) as String, privacy: .public)")
                }
                complete(valid)
            },
            .global()
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 5

        return try await runWith(
            params: NWParameters(tls: tlsOptions, tcp: tcpOptions),
            ip: ip, port: port, sni: sni,
            method: method, path: path,
            headers: headers, body: body, start: start
        )
    }

    /// Run a single HTTP/1.1 request over a fully-configured NWParameters
    /// (TLS options + verify block already applied). Shared by the pinned and
    /// chain-validated paths of `performRequest`.
    private static func runWith(
        params: NWParameters, ip: String, port: UInt16, sni: String,
        method: String, path: String,
        headers: [String: String], body: Data?, start: DispatchTime
    ) async throws -> (Data, HTTPResponseMeta) {
        let host = NWEndpoint.Host(ip)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: host, port: nwPort, using: params)

        defer { connection.cancel() }

        AppLogger.network.info("direct.dial ip=\(ip, privacy: .public) port=\(port, privacy: .public) sni=\(sni, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms")

        // Wait for ready state.
        try await waitReady(connection, ip: ip, port: port, start: start)

        // Send request.
        let requestData = buildRequest(
            method: method, path: path, host: sni,
            headers: headers, body: body
        )
        try await send(connection, data: requestData)
        AppLogger.network.info("direct.sent ip=\(ip, privacy: .public) port=\(port, privacy: .public) bytes=\(requestData.count, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms")

        // Read response until socket close or Content-Length satisfied.
        let raw = try await readAll(connection, ip: ip, port: port, start: start)
        let parsed = try parseHTTPResponse(raw)
        AppLogger.network.info("direct.done ip=\(ip, privacy: .public) port=\(port, privacy: .public) status=\(parsed.1.status, privacy: .public) bytes=\(raw.count, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms")
        if parsed.1.status < 200 || parsed.1.status >= 300 {
            let rawPreview = String(data: raw.prefix(800), encoding: .utf8) ?? "<non-utf8>"
            let reqPreview = String(data: requestData.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            AppLogger.network.error("direct.raw ip=\(ip, privacy: .public) status=\(parsed.1.status, privacy: .public) req=[\(reqPreview, privacy: .public)] resp=[\(rawPreview, privacy: .public)]")
        }
        return parsed
    }

    // MARK: - Connection helpers

    private static func waitReady(_ conn: NWConnection, ip: String, port: UInt16, start: DispatchTime) async throws {
        let guardBox = ResumeGuard()
        let store = ReadyContinuationStore()
        let finish: @Sendable (Result<Void, Error>) -> Void = { result in
            guard guardBox.tryResume() else { return }
            conn.stateUpdateHandler = nil
            guard let cont = store.take() else { return }
            switch result {
            case .success:
                cont.resume()
            case .failure(let error):
                cont.resume(throwing: error)
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                store.set(cont)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        AppLogger.network.info("direct.ready ip=\(ip, privacy: .public) port=\(port, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms")
                        finish(.success(()))
                    case .failed(let err):
                        AppLogger.network.error("direct.failed ip=\(ip, privacy: .public) port=\(port, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms error=\(err.localizedDescription, privacy: .public)")
                        finish(.failure(err))
                    case .waiting(let err):
                        AppLogger.network.error("direct.waiting ip=\(ip, privacy: .public) port=\(port, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms error=\(err.localizedDescription, privacy: .public)")
                        finish(.failure(err))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    case .setup, .preparing:
                        break
                    @unknown default:
                        AppLogger.network.error("direct.unknownState ip=\(ip, privacy: .public) port=\(port, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms")
                        finish(.failure(URLError(.cannotConnectToHost)))
                    }
                }
                if Task.isCancelled {
                    conn.cancel()
                    finish(.failure(CancellationError()))
                    return
                }
                conn.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            conn.cancel()
            finish(.failure(CancellationError()))
        }
    }

    private static func send(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    private static func readAll(_ conn: NWConnection, ip: String, port: UInt16, start: DispatchTime) async throws -> Data {
        var accumulated = Data()
        var loggedFirstByte = false
        while true {
            let (chunk, isComplete) = try await receiveChunk(conn)
            if let chunk {
                if !loggedFirstByte && !chunk.isEmpty {
                    loggedFirstByte = true
                    AppLogger.network.info("direct.firstByte ip=\(ip, privacy: .public) port=\(port, privacy: .public) bytes=\(chunk.count, privacy: .public) elapsed=\(elapsedMs(from: start), privacy: .public)ms")
                }
                accumulated.append(chunk)
            }
            if isComplete { break }
            // Stop early if we've received complete response.
            if let meta = peekHeaders(accumulated),
               let bodyStart = meta.bodyStartOffset,
               let length = meta.contentLength,
               accumulated.count >= bodyStart + length {
                break
            }
        }
        return accumulated
    }

    private static func receiveChunk(_ conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (data, isComplete))
            }
        }
    }

    // MARK: - HTTP framing

    private static func buildRequest(
        method: String, path: String, host: String,
        headers: [String: String], body: Data?
    ) -> Data {
        var lines: [String] = []
        lines.append("\(method) \(path) HTTP/1.1")
        lines.append("Host: \(host)")
        lines.append("Connection: close")
        lines.append("Accept-Encoding: identity")
        for (k, v) in headers where k.lowercased() != "host" && k.lowercased() != "connection" {
            lines.append("\(k): \(v)")
        }
        if let body {
            lines.append("Content-Length: \(body.count)")
        }
        var request = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) ?? Data()
        if let body { request.append(body) }
        return request
    }

    struct HTTPResponseMeta {
        let status: Int
        let headers: [String: String]
        let body: Data

        var asURLResponse: HTTPURLResponse? {
            HTTPURLResponse(
                url: URL(string: "https://\(headers["Host"] ?? "")")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        }
    }

    private struct HeaderPeek {
        let bodyStartOffset: Int?
        let contentLength: Int?
    }

    private static func peekHeaders(_ buf: Data) -> HeaderPeek? {
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerBytes = buf.subdata(in: 0..<range.lowerBound)
        guard let text = String(data: headerBytes, encoding: .utf8) else { return nil }
        var length: Int? = nil
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) }
        }
        return HeaderPeek(bodyStartOffset: range.upperBound, contentLength: length)
    }

    private static func parseHTTPResponse(_ raw: Data) throws -> (Data, HTTPResponseMeta) {
        guard let splitRange = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw URLError(.badServerResponse)
        }
        let headerData = raw.subdata(in: 0..<splitRange.lowerBound)
        var body = raw.subdata(in: splitRange.upperBound..<raw.count)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw URLError(.badServerResponse)
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        // 2026-07-11 field bug: nginx serves /api/v1/mobile/config (and
        // presumably other dynamically-sized JSON responses) with
        // `Transfer-Encoding: chunked` and NO `Content-Length` — confirmed
        // live (curl -D-). This raw HTTP/1.1 client took everything after the
        // header terminator as the body VERBATIM, so every response routed
        // through a DirectConnection leg (decoy or direct-IP) had literal hex
        // chunk-size lines ("d34\r\n", "0\r\n\r\n", ...) spliced into the
        // JSON. That is EXACTLY the shape of the two errors sing-box reported
        // on-device: "invalid character 'd' looking for beginning of value:
        // row 1, column 1" (a chunk-size line starting with a hex a-f digit)
        // and "cannot unmarshal number into Go value of type option._Options"
        // (a chunk-size line that happens to be all decimal digits, which the
        // JSON decoder reads as a bare top-level number). The primary leg
        // (URLSession) was never affected — Foundation de-chunks
        // transparently — which is why the race kept "succeeding" (decoy won
        // with a real 200) while the cached config stayed corrupt/empty.
        if let te = headers.first(where: { $0.key.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame })?.value,
           te.lowercased().contains("chunked") {
            body = dechunk(body)
        }
        let meta = HTTPResponseMeta(status: code, headers: headers, body: body)
        return (body, meta)
    }

    /// Decodes an HTTP/1.1 chunked-transfer-encoded body into its plain
    /// bytes. Each chunk is `<hex-size>[;ext]\r\n<size bytes>\r\n`; a
    /// zero-size chunk (optionally followed by trailer headers) ends the
    /// stream. Malformed/truncated input just stops decoding at the point it
    /// can no longer parse a chunk header — returns whatever was
    /// successfully decoded so far rather than throwing, since a partial
    /// body is strictly more useful for diagnosing the failure than none.
    static func dechunk(_ data: Data) -> Data {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeLine = data.subdata(in: index..<lineEnd.lowerBound)
            guard let sizeText = String(data: sizeLine, encoding: .utf8) else { break }
            let hex = sizeText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { break }  // terminating chunk — ignore any trailer headers after it
            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex) else { break }
            result.append(data.subdata(in: chunkStart..<chunkEnd))
            guard let next = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) else { break }
            index = next
        }
        return result
    }
}

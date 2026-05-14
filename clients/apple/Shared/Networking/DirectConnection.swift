import Foundation
import Network
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
    static func request(
        ip: String,
        port: UInt16 = 443,
        sni: String,
        method: String,
        path: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPResponseMeta) {
        let start = DispatchTime.now()
        return try await withThrowingTaskGroup(of: (Data, HTTPResponseMeta).self) { group in
            group.addTask {
                try await performRequest(
                    ip: ip, port: port, sni: sni,
                    method: method, path: path,
                    headers: headers, body: body,
                    start: start
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
        start: DispatchTime
    ) async throws -> (Data, HTTPResponseMeta) {

        // Build TLS options with the SNI we want to present. The server
        // sees sni (e.g. "madfrog.online"), TCP goes to `ip`.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)

        // Accept the server cert unconditionally — validation has no
        // meaning when we dial a hardcoded IP with a spoofed SNI. The
        // VPN tunnel itself uses VLESS Reality for real E2E security;
        // this endpoint is only used for API bootstrapping.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, complete in complete(true) },
            .global()
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 5

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
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

    /// Build a raw HTTP/1.1 request. Pure (no I/O) — `internal` so the
    /// unit-test target can pin the framing (Host/Connection/encoding
    /// header handling, body length, header dedup) without a socket.
    static func buildRequest(
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

    /// Parse a raw HTTP/1.1 response buffer into `(body, meta)`. Pure
    /// (no I/O) — `internal` so the unit-test target can pin status-line
    /// parsing, header splitting and the malformed-response throws.
    static func parseHTTPResponse(_ raw: Data) throws -> (Data, HTTPResponseMeta) {
        guard let splitRange = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw URLError(.badServerResponse)
        }
        let headerData = raw.subdata(in: 0..<splitRange.lowerBound)
        let body = raw.subdata(in: splitRange.upperBound..<raw.count)
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
        let meta = HTTPResponseMeta(status: code, headers: headers, body: body)
        return (body, meta)
    }
}

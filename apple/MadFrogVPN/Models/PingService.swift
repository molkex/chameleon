import Foundation
import Network

/// Measures TCP connect latency to VPN servers without requiring VPN connection.
/// Uses NWConnection (Network.framework) for accurate TCP handshake timing.
@Observable
final class PingService {
    /// Latency results: server tag → milliseconds (0 = not measured, -1 = failed)
    var results: [String: Int32] = [:]
    var isPinging = false

    /// Ping all servers from the given groups by performing TCP handshakes.
    func pingAll(groups: [ServerGroup]) {
        guard !isPinging else { return }
        isPinging = true

        let items = groups
            .filter { $0.type == "urltest" }
            .flatMap(\.items)

        let serverEndpoints = extractEndpoints(from: items)
        guard !serverEndpoints.isEmpty else {
            isPinging = false
            return
        }

        Task {
            await withTaskGroup(of: (String, Int32).self) { group in
                for (tag, host, port) in serverEndpoints {
                    group.addTask {
                        let latency = await Self.measureTCPLatency(host: host, port: port)
                        return (tag, latency)
                    }
                }

                for await (tag, latency) in group {
                    await MainActor.run {
                        self.results[tag] = latency
                    }
                }
            }

            await MainActor.run {
                self.isPinging = false
            }
        }
    }

    /// Extract (tag, host, port) tuples from server items.
    /// Parses the server address from the sing-box config data stored in ConfigStore.
    private func extractEndpoints(from items: [ServerItem]) -> [(String, String, UInt16)] {
        // Parse the actual sing-box config to get server addresses
        guard let jsonString = ConfigStore().loadConfig(),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]] else {
            return []
        }

        var tagToEndpoint: [String: (String, UInt16)] = [:]
        for ob in outbounds {
            guard let tag = ob["tag"] as? String,
                  let server = ob["server"] as? String,
                  let port = ob["server_port"] as? Int else { continue }
            tagToEndpoint[tag] = (server, UInt16(port))
        }

        return items.compactMap { item in
            guard let (host, port) = tagToEndpoint[item.tag] else { return nil }
            return (item.tag, host, port)
        }
    }

    /// Measure TCP handshake time to a host:port. Returns ms or -1 on failure.
    private static func measureTCPLatency(host: String, port: UInt16, timeout: TimeInterval = 5) async -> Int32 {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let params = NWParameters.tcp

            let connection = NWConnection(to: endpoint, using: params)
            let start = CFAbsoluteTimeGetCurrent()
            var didComplete = false

            let timeoutWork = DispatchWorkItem {
                guard !didComplete else { return }
                didComplete = true
                connection.cancel()
                continuation.resume(returning: -1)
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWork
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didComplete else { return }
                    didComplete = true
                    timeoutWork.cancel()
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    let ms = Int32(elapsed * 1000)
                    connection.cancel()
                    continuation.resume(returning: max(ms, 1))

                case .failed, .cancelled:
                    guard !didComplete else { return }
                    didComplete = true
                    timeoutWork.cancel()
                    connection.cancel()
                    continuation.resume(returning: -1)

                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}

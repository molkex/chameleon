import Foundation

/// File-based logger for PacketTunnel extension debugging.
/// Writes timestamped entries to tunnel-debug.log in the App Group container.
/// Readable from both the extension and the main app.
enum TunnelFileLogger {
    static let fileName = "tunnel-debug.log"
    static let maxFileSize = 512 * 1024 // 512 KB — auto-truncate

    static var logFileURL: URL {
        AppConstants.sharedContainerURL.appendingPathComponent(fileName)
    }

    static var stderrLogURL: URL {
        AppConstants.sharedContainerURL.appendingPathComponent("stderr.log")
    }

    private static let queue = DispatchQueue(label: "com.madfrog.vpn.filelogger")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Log a message with timestamp and category tag.
    static func log(_ message: String, category: String = "tunnel") {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"

        queue.async {
            writeToFile(line)
        }
    }

    /// Clear the debug log file.
    static func clear() {
        queue.async {
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Read the full debug log.
    static func readLog() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "(empty)"
    }

    /// Read the stderr log from libbox.
    static func readStderrLog() -> String {
        (try? String(contentsOf: stderrLogURL, encoding: .utf8)) ?? "(empty)"
    }

    private static func writeToFile(_ line: String) {
        let url = logFileURL
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            // Truncate if too large
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxFileSize {
                // Keep last half
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let halfIndex = content.index(content.startIndex, offsetBy: content.count / 2)
                    let trimmed = "--- log truncated ---\n" + String(content[halfIndex...])
                    try? trimmed.write(to: url, atomically: true, encoding: .utf8)
                }
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: url)
            }
        } else {
            try? data.write(to: url)
        }
    }
}

import Foundation

/// File-based logger for PacketTunnel extension debugging.
/// Writes timestamped entries to tunnel-debug.log in the App Group container.
/// Readable from both the extension and the main app.
///
/// **Durability note:** the iOS PacketTunnel extension has a 50 MB hard memory
/// cap. When jetsam kills the extension with SIGKILL, any log lines still sitting
/// in the async dispatch queue are lost. To survive those kills we flush early
/// lines synchronously and pre-create the file so the first entry is on disk
/// before startOrReloadService even begins.
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

    /// Log a message with timestamp and category tag. Normal async path.
    static func log(_ message: String, category: String = "tunnel") {
        let line = formatLine(message, category: category)
        queue.async { writeToFile(line) }
    }

    /// Log AND flush synchronously. Use for critical early-boot lines (TUNNEL
    /// START, crash-adjacent ERRORs) so they survive even if the extension gets
    /// SIGKILL'd moments later before the async queue drains.
    static func logSync(_ message: String, category: String = "tunnel") {
        let line = formatLine(message, category: category)
        queue.sync { writeToFile(line) }
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

    private static func formatLine(_ message: String, category: String) -> String {
        let timestamp = dateFormatter.string(from: Date())
        return "[\(timestamp)] [\(category)] \(message)\n"
    }

    private static func writeToFile(_ line: String) {
        let url = logFileURL
        let data = Data(line.utf8)

        // Ensure the file exists up-front. The parent directory is the App Group
        // container which iOS creates; the file itself may not exist on first run.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }

        // Truncate-to-half if we crossed the cap.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let halfIndex = content.index(content.startIndex, offsetBy: content.count / 2)
                let trimmed = "--- log truncated ---\n" + String(content[halfIndex...])
                try? trimmed.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.synchronize() // fsync — survive SIGKILL
            handle.closeFile()
        }
    }
}

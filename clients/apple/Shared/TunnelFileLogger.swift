import Foundation
import OSLog

/// File-based logger for PacketTunnel extension debugging.
/// Writes timestamped entries to tunnel-debug.log at the App Group
/// container root. Readable from both the extension and the main app.
///
/// **Reader robustness:** `readLog()` tries multiple historical paths
/// (root, then Library/Caches as a 26.x experimental fallback) so logs
/// remain visible across path migrations.
///
/// **Durability note:** the iOS PacketTunnel extension has a 50 MB hard memory
/// cap. When jetsam kills the extension with SIGKILL, any log lines still sitting
/// in the async dispatch queue are lost. To survive those kills we flush early
/// lines synchronously and pre-create the file so the first entry is on disk
/// before startOrReloadService even begins.
enum TunnelFileLogger {
    static let fileName = "tunnel-debug.log"
    // Build-43: bumped 512 KB → 2 MB. Sing-box at default verbosity emits
    // ~5 MB of logs in 5 minutes on busy LTE traffic; the old 512 KB cap
    // truncated the start of the session including TunnelStallProbe boot
    // events and the first 2-3 probe ticks, making it impossible to
    // diagnose stall-detection behaviour from a field-test log.
    static let maxFileSize = 2 * 1024 * 1024 // 2 MB — auto-truncate

    /// Primary write path: App Group container root. Confirmed writable
    /// across iOS versions including 26.x (extension reports debugLogSize
    /// > 0 there). Reverting here after a Library/Caches detour caused
    /// reader/writer mismatch when old extension binaries kept writing
    /// to root while the new main app code looked elsewhere.
    static var logFileURL: URL {
        AppConstants.sharedContainerURL.appendingPathComponent(fileName)
    }

    static var stderrLogURL: URL {
        AppConstants.sharedContainerURL.appendingPathComponent("stderr.log")
    }

    /// Mirror of every log line to os_log so they show up in
    /// `idevicesyslog` / `log stream` even if the file write fails.
    /// Subsystem matches AppLogger so existing predicates work.
    private static let osLogger = Logger(subsystem: "com.madfrog.vpn", category: "tunnelfile")

    private static let queue = DispatchQueue(label: "com.madfrog.vpn.filelogger")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Log a message with timestamp and category tag. Normal async path.
    static func log(_ message: String, category: String = "tunnel") {
        osLogger.log("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = formatLine(message, category: category)
        queue.async { writeToFile(line) }
    }

    /// Log AND flush synchronously. Use for critical early-boot lines (TUNNEL
    /// START, crash-adjacent ERRORs) so they survive even if the extension gets
    /// SIGKILL'd moments later before the async queue drains.
    static func logSync(_ message: String, category: String = "tunnel") {
        osLogger.log("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = formatLine(message, category: category)
        queue.sync { writeToFile(line) }
    }

    /// Clear the debug log file.
    static func clear() {
        queue.async {
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Read the full debug log. Tries the primary path, then the
    /// Library/Caches fallback (left over from a 38d build that used a
    /// different write path). On any read error, returns a diagnostic
    /// string with the underlying reason instead of silent "(empty)".
    static func readLog() -> String {
        readWithFallback(filename: fileName)
    }

    /// Read the stderr log from libbox.
    static func readStderrLog() -> String {
        readWithFallback(filename: "stderr.log")
    }

    private static func readWithFallback(filename: String) -> String {
        let primary = AppConstants.sharedContainerURL.appendingPathComponent(filename)
        let fallback = AppConstants.sharedContainerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(filename)

        for url in [primary, fallback] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            // Lossy UTF-8 decode — replaces invalid byte sequences with
            // U+FFFD. Concurrent writes from main app and extension can
            // tear in the middle of a multi-byte codepoint, producing
            // a few invalid bytes; strict `String(data:encoding:.utf8)`
            // returns nil for the entire file in that case (one bad byte
            // = whole log unreadable). Lossy keeps everything legible.
            return String(decoding: data, as: UTF8.self)
        }
        return "(empty)"
    }

    private static func formatLine(_ message: String, category: String) -> String {
        let timestamp = dateFormatter.string(from: Date())
        return "[\(timestamp)] [\(category)] \(message)\n"
    }

    private static func writeToFile(_ line: String) {
        let url = logFileURL
        let data = Data(line.utf8)

        // Ensure the file exists. createFile returns Bool — log failures so
        // we know if root is somehow not writable on this iOS version.
        if !FileManager.default.fileExists(atPath: url.path) {
            let ok = FileManager.default.createFile(atPath: url.path, contents: data, attributes: nil)
            if !ok {
                osLogger.error("createFile failed at \(url.path, privacy: .public)")
            } else {
                // First write went via createFile contents — done.
                return
            }
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

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: handle.seekToEndOfFile())
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            osLogger.error("writeToFile failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

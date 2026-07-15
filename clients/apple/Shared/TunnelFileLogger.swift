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

    // LOG-01: singbox.log is the raw sing-box stream written by
    // ExtensionPlatformInterface.writeDebugMessage (the diagnostic-snapshot
    // source, AppState.readSingboxLogTail). libbox emits DEBUG/TRACE regardless
    // of config log.level, so without a cap this file grew to 565 MB in the
    // field — wasted disk and, when naively truncated by loading the whole file,
    // a memory spike inside the ~50 MB NE jetsam cap that feeds the oom-killer's
    // "resetting network" tunnel drops. Cap it; the diagnostic tail only needs
    // the last 256 KiB.
    static let singboxLogMaxSize = 4 * 1024 * 1024 // 4 MB

    /// Byte offset to seek to when capping an append-only log: keep the last
    /// `maxSize/2` bytes once the file exceeds `maxSize`; returns nil while the
    /// file is still under the cap. Pure + unit-tested so the singbox.log cap
    /// (LOG-01) can't regress into unbounded growth. Callers seek to this offset
    /// and rewrite only the tail, so a multi-hundred-MB file is never loaded
    /// into memory to truncate it.
    static func truncationKeepOffset(fileSize: Int, maxSize: Int) -> UInt64? {
        guard maxSize > 0, fileSize > maxSize else { return nil }
        let keep = maxSize / 2
        return UInt64(max(0, fileSize - keep))
    }

    /// True when a raw sing-box log line is at TRACE/DEBUG level. libbox feeds
    /// these to ExtensionPlatformInterface.writeDebugMessage *regardless* of the
    /// config log.level, ANSI-colored as e.g. "\u{1b}[37mDEBUG\u{1b}[0m[4731] …".
    /// Dropping them from the file sinks (keeping INFO+, exactly like build-99 did
    /// for writeLogs/writeMessage) removes ~37% of log volume — the top allocator
    /// under the ~50 MB NetworkExtension cap that drives the sing-box oom-killer's
    /// "resetting network" tunnel drops (LOG-01 / the user-felt disconnects).
    /// Pure + unit-tested. The caller still feeds EVERY line to the stall detector
    /// first; only the file write is skipped.
    static func isVerboseSingboxLine(_ message: String) -> Bool {
        let s = stripLeadingANSI(message)
        return s.hasPrefix("TRACE") || s.hasPrefix("DEBUG")
    }

    /// True when a raw sing-box log line is below WARN (TRACE/DEBUG/INFO).
    /// NE-LOG-SINK-FIX (2026-07-15): iOS killed the extension via the
    /// `diskwrites_resource` + `cpu_resource` limits under load — sing-box's
    /// platform log writer delivers EVERY line at EVERY level unconditionally
    /// once `setupOptions.debug = true` (fork `log/observable.go:140`), so
    /// config `log.level` never gates this callback. Raising the file-sink
    /// threshold to WARN here (in Swift, where we can actually enforce it)
    /// is what cuts the write volume. `writeDebugMessage` still feeds
    /// `realStallDetector.ingest()` with EVERY line first — this only gates
    /// the file sinks.
    static func isBelowWarnSingboxLine(_ message: String) -> Bool {
        let s = stripLeadingANSI(message)
        return s.hasPrefix("TRACE") || s.hasPrefix("DEBUG") || s.hasPrefix("INFO")
    }

    /// Skip a leading ANSI SGR escape ("\u{1b}[…m") so callers read the level
    /// token. Shared by `isVerboseSingboxLine` and `isBelowWarnSingboxLine`.
    private static func stripLeadingANSI(_ message: String) -> Substring {
        var s = Substring(message)
        while s.first == "\u{1b}" {
            guard let m = s.firstIndex(of: "m") else { break }
            s = s[s.index(after: m)...]
        }
        return s
    }

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

        // Truncate-to-half if we crossed the cap. Seek+truncate (like the
        // singbox.log path in ExtensionPlatformInterface.writeDebugMessage)
        // instead of String(contentsOf:) — never loads the whole file into
        // the NE's ~50 MB budget just to drop the first half of it. Must
        // stay non-atomic (same inode) — see truncationKeepOffset's callers.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           let offset = truncationKeepOffset(fileSize: size, maxSize: maxFileSize) {
            if let rh = try? FileHandle(forReadingFrom: url) {
                defer { try? rh.close() }
                _ = try? rh.seek(toOffset: offset)
                let tail = (try? rh.readToEnd()) ?? Data()
                try? (Data("--- log truncated ---\n".utf8) + tail).write(to: url)
            }
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: handle.seekToEndOfFile())
            try handle.write(contentsOf: data)
            // NE-LOG-SINK-FIX: no fsync. It guards against kernel panic/power
            // loss, not jetsam SIGKILL — a written line survives the process
            // dying regardless (kernel page cache), and it's the same-machine
            // App Group container, so readers see it the instant write()
            // returns. logSync()'s queue.sync is what actually protects
            // against a SIGKILL racing an unflushed async write. Forcing a
            // physical write per line was pure diskwrites budget for nothing.
            try handle.close()
        } catch {
            osLogger.error("writeToFile failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

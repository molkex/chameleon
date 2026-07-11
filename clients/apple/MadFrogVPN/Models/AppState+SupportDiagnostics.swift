import Foundation

/// "Send log to support" diagnostic snapshot + singbox.log attachment.
/// Extracted 2026-07-11 (M1, Fable code review) from AppState.swift.
extension AppState {
    /// Outcome of the one-tap "Отправить лог" action so the chat view can give
    /// the user feedback (it used to fail completely silently).
    /// SENDLOG-NO-SILENT-LOSS (2026-06-17): `.sentWithoutLog` distinguishes
    /// "the snapshot went but the singbox.log attachment FAILED" from a clean
    /// `.sent`. Previously the attachment-fail path silently fell back to
    /// text-only and reported `.sent`, so the user thought the log was attached
    /// when only the text snapshot went ("думаешь отправил лог, а ушёл текст").
    enum SupportDiagnosticResult { case sent, sentWithoutLog, failed }

    /// One-tap diagnostic for the support chat ("Отправить лог" button). Ships
    /// the app/device/VPN snapshot (state the webview can't see) AS the message
    /// body, plus the tail of the tunnel's singbox.log as a text/plain
    /// attachment so support sees the real connection log. The open chat renders
    /// it via SSE/history.
    ///
    /// Uses a FRESHLY refreshed token — the cached `accessToken` may have expired
    /// while the app was backgrounded, which 401'd this into a silent no-op (the
    /// reported "лог не отправляется"; same root cause the webview's
    /// `accessTokenForSupportChat()` already fixed). Falls back to a text-only
    /// snapshot when there's no log yet (VPN never connected) or attachments are
    /// unavailable (B2 down → presign 503), so support always gets *something*.
    func sendSupportDiagnostic() async -> SupportDiagnosticResult {
        let token = await accessTokenForSupportChat()
        guard !token.isEmpty else { return .failed }
        let snapshot = buildDiagnosticSnapshot()
        if let logData = Self.readSingboxLogTail() {
            do {
                try await apiClient.sendSupportAttachment(
                    text: snapshot, fileData: logData,
                    filename: Self.diagnosticLogFilename(), mime: "text/plain",
                    accessToken: token)
                return .sent
            } catch {
                AppLogger.app.error("sendSupportDiagnostic (with log) failed: \(error.localizedDescription) — retrying text-only")
                // A log EXISTED but couldn't be attached. Still send the text
                // snapshot so support gets something, but report .sentWithoutLog
                // — the caller must NOT claim the log was attached.
                do {
                    try await apiClient.sendSupportMessage(text: snapshot, accessToken: token)
                    return .sentWithoutLog
                } catch {
                    AppLogger.app.error("sendSupportDiagnostic text-only fallback failed: \(error.localizedDescription)")
                    return .failed
                }
            }
        }
        // No log on disk yet (VPN never connected) — text-only IS the complete
        // result here, nothing was lost.
        do {
            try await apiClient.sendSupportMessage(text: snapshot, accessToken: token)
            return .sent
        } catch {
            AppLogger.app.error("sendSupportDiagnostic failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// A branded, unique filename for the attached diagnostic log. Avoids
    /// leaking the underlying engine name ("singbox.log") into the support
    /// thread and lets an operator tell multiple uploads apart by timestamp,
    /// e.g. "madfrog-log-20260604-143412.log". The on-disk file stays singbox.log;
    /// this only names the upload.
    static func diagnosticLogFilename(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "madfrog-log-\(f.string(from: date)).log"
    }

    /// Read the tail of the tunnel's singbox.log from the shared App Group
    /// container, capped so a huge log never blows past the 10 MiB attachment
    /// limit (the file has historically grown to GBs before the sink-level
    /// TRACE/DEBUG drop — see LOG-01). Returns nil when the log doesn't exist
    /// yet (VPN never connected) or can't be read.
    static func readSingboxLogTail(maxBytes: Int = 256 * 1024) -> Data? {
        let logURL = AppConstants.sharedContainerURL.appendingPathComponent("singbox.log")
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let truncated = size > UInt64(maxBytes)
        let offset = truncated ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return Self.tailLogText(data, truncated: truncated).data(using: .utf8)
    }

    /// Decode a (possibly mid-UTF-8 / mid-line) tail slice into a clean log
    /// string: when the slice was cut from a larger file, drop the leading
    /// partial line and prepend a truncation marker. Pure → unit-tested.
    static func tailLogText(_ data: Data, truncated: Bool) -> String {
        var text = String(decoding: data, as: UTF8.self)
        guard truncated else { return text }
        if let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return "…(обрезано, показан хвост журнала)\n" + text
    }

    private func buildDiagnosticSnapshot() -> String {
        let appV = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let provider = configStore.authProvider ?? "anon"
        return """
        📋 Диагностика
        • App: \(appV) (\(build))
        • Device: \(PlatformDevice.hardwareModel), iOS \(PlatformDevice.systemVersion)
        • Server: \(VPNStateHelper.selectedServerName(self))
        • VPN: \(vpnStatusLabel)
        • Account: \(provider)
        • Last error: \(errorMessage ?? "—")
        """
    }

    private var vpnStatusLabel: String {
        switch vpnManager.status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .reasserting: return "reasserting"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
        }
    }
}

import Foundation
import MetricKit

/// launch-03: production crash / hang observability via Apple's MetricKit.
///
/// Why MetricKit and not Sentry/Crashlytics:
///   - 0 third-party SDK. For a VPN app the App Privacy section is
///     load-bearing — adding a crash-reporter SDK that phones home would
///     force new disclosures and erode the "we don't collect your data"
///     stance. MetricKit data flows: OS → our app → our backend, nothing
///     in between.
///   - Covers the PacketTunnel extension's crashes too. MetricKit
///     aggregates diagnostics for the whole app bundle (main app +
///     extensions), so a NetworkExtension SIGSEGV still surfaces.
///   - Tradeoff: payloads are batched by the OS and delivered roughly
///     once every 24 h, not real-time. Acceptable — we want crash
///     *trends per build*, not a live pager.
///
/// We send a SUMMARY, never the full call-stack tree:
///   - crash type + signal/exception, termination reason
///   - build / OS / device — so ops can answer "which build regressed"
///   - top ~8 call-stack frames as "binaryName+offset" (privacy-safe:
///     offsets carry no user data; symbolicate later against the dSYM)
/// The summary is small enough to ride the existing
/// POST /api/v1/mobile/diagnostic endpoint as a structured log line —
/// no DB table, no new endpoint, no ops complexity.
///
/// Register once from `MadFrogVPNApp.init`. MetricKit retains a weak
/// reference to the subscriber, so the reporter is held by a static.
final class CrashDiagnosticReporter: NSObject, MXMetricManagerSubscriber {

    /// Held for the process lifetime — MetricKit keeps only a weak ref.
    static let shared = CrashDiagnosticReporter()

    /// UserDefaults key for the newest payload timestamp we've already
    /// processed. MetricKit normally only hands us un-seen payloads, but
    /// a double `add(_:)` (e.g. main app + extension both registering)
    /// could replay — this guard keeps us idempotent.
    private static let lastProcessedKey = "crashReporter.lastProcessedEnd"

    private let diagnosticURL = URL(string: AppConstants.baseURL + "/api/v1/mobile/diagnostic")!

    /// Call once at app launch. Idempotent — MetricKit dedups subscribers.
    static func register() {
        MXMetricManager.shared.add(shared)
        TunnelFileLogger.log("CrashDiagnosticReporter: registered with MXMetricManager", category: "boot")
    }

    // MARK: - MXMetricManagerSubscriber

    /// Performance metrics — we don't act on these (launch-08 might add a
    /// sparkline from them later). Required by the protocol; no-op.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    /// Diagnostic payloads: crashes, hangs, CPU/disk exceptions. Delivered
    /// by the OS in a background batch (~daily). We extract a summary from
    /// each diagnostic and POST it best-effort.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let defaults = UserDefaults.standard
        let lastProcessed = defaults.double(forKey: Self.lastProcessedKey)
        var newestEnd = lastProcessed

        var summaries: [CrashSummary] = []
        for payload in payloads {
            let end = payload.timeStampEnd.timeIntervalSince1970
            // Skip a payload window we've already drained.
            if end <= lastProcessed { continue }
            newestEnd = max(newestEnd, end)

            for d in payload.crashDiagnostics ?? [] {
                summaries.append(Self.summarise(crash: d))
            }
            for d in payload.hangDiagnostics ?? [] {
                summaries.append(Self.summarise(hang: d))
            }
            for d in payload.cpuExceptionDiagnostics ?? [] {
                summaries.append(Self.summarise(cpu: d))
            }
            for d in payload.diskWriteExceptionDiagnostics ?? [] {
                summaries.append(Self.summarise(disk: d))
            }
        }

        guard !summaries.isEmpty else { return }
        TunnelFileLogger.log("CrashDiagnosticReporter: \(summaries.count) diagnostic(s) in batch — reporting", category: "boot")

        // Advance the watermark BEFORE the network calls — if the POSTs
        // fail we'd rather drop a report than spam it on every launch.
        // MetricKit won't redeliver the same payload anyway.
        defaults.set(newestEnd, forKey: Self.lastProcessedKey)

        Task.detached(priority: .utility) { [summaries, diagnosticURL] in
            for s in summaries {
                await Self.send(s, to: diagnosticURL)
            }
        }
    }

    // MARK: - Summary extraction

    struct CrashSummary {
        var event: String           // "crash" | "hang" | "cpu" | "disk"
        var signal: String          // SIGSEGV / EXC_BAD_ACCESS / hang-2400ms / cpu-time / ...
        var termination: String     // MXCrashDiagnostic.terminationReason, else ""
        var appBuild: String
        var osVersion: String
        var deviceType: String
        var callStackTop: [String]  // "binaryName+offset"
    }

    private static func meta(_ m: MXMetaData) -> (build: String, os: String, device: String) {
        (m.applicationBuildVersion, m.osVersion, m.deviceType)
    }

    private static func summarise(crash d: MXCrashDiagnostic) -> CrashSummary {
        let m = meta(d.metaData)
        var signal = ""
        if let exc = d.exceptionType {
            signal = "exc=\(exc)"
            if let code = d.exceptionCode { signal += " code=\(code)" }
        }
        if let sig = d.signal {
            signal += signal.isEmpty ? "sig=\(sig)" : " sig=\(sig)"
        }
        if signal.isEmpty { signal = "unknown" }
        return CrashSummary(
            event: "crash",
            signal: signal,
            termination: d.terminationReason ?? "",
            appBuild: m.build, osVersion: m.os, deviceType: m.device,
            callStackTop: topFrames(d.callStackTree)
        )
    }

    private static func summarise(hang d: MXHangDiagnostic) -> CrashSummary {
        let m = meta(d.metaData)
        return CrashSummary(
            event: "hang",
            signal: "hang-\(d.hangDuration)",
            termination: "",
            appBuild: m.build, osVersion: m.os, deviceType: m.device,
            callStackTop: topFrames(d.callStackTree)
        )
    }

    private static func summarise(cpu d: MXCPUExceptionDiagnostic) -> CrashSummary {
        let m = meta(d.metaData)
        return CrashSummary(
            event: "cpu",
            signal: "cpu-\(d.totalCPUTime) sampled-\(d.totalSampledTime)",
            termination: "",
            appBuild: m.build, osVersion: m.os, deviceType: m.device,
            callStackTop: topFrames(d.callStackTree)
        )
    }

    private static func summarise(disk d: MXDiskWriteExceptionDiagnostic) -> CrashSummary {
        let m = meta(d.metaData)
        return CrashSummary(
            event: "disk",
            signal: "disk-\(d.totalWritesCaused)",
            termination: "",
            appBuild: m.build, osVersion: m.os, deviceType: m.device,
            callStackTop: topFrames(d.callStackTree)
        )
    }

    /// Walk MXCallStackTree's JSON down the first thread's frames,
    /// collecting up to 8 "binaryName+offset" strings. We don't symbolicate
    /// on-device — offsets + the dSYM (kept from each archive) symbolicate
    /// later. Privacy-safe: an offset into a text segment carries no user
    /// data.
    private static func topFrames(_ tree: MXCallStackTree, limit: Int = 8) -> [String] {
        guard
            let obj = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
            let stacks = obj["callStacks"] as? [[String: Any]],
            let first = stacks.first,
            let roots = first["callStackRootFrames"] as? [[String: Any]]
        else { return [] }

        var frames: [String] = []
        func descend(_ frame: [String: Any]) {
            if frames.count >= limit { return }
            let binary = (frame["binaryName"] as? String) ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int)
                ?? (frame["address"] as? Int) ?? 0
            frames.append("\(binary)+\(offset)")
            if let subs = frame["subFrames"] as? [[String: Any]] {
                for sub in subs { descend(sub) }
            }
        }
        for root in roots { descend(root) }
        return Array(frames.prefix(limit))
    }

    // MARK: - Transport

    /// Best-effort POST to the existing diagnostic endpoint. Any failure
    /// is swallowed — a crash report that doesn't land is not worth a
    /// retry storm, and MetricKit won't redeliver.
    private static func send(_ s: CrashSummary, to url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "event": s.event,
            "crash_signal": s.signal,
            "crash_termination": s.termination,
            "app_build": s.appBuild,
            "os_version": s.osVersion,
            "device_type": s.deviceType,
            "call_stack_top": s.callStackTop,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}

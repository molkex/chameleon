import XCTest
@testable import MadFrogVPN

/// launch-03 / ADR-006: the crash reporter must ship a privacy-safe
/// SUMMARY — never the raw MetricKit tree, never paths or user data.
/// These pin the two pure cores extracted for testability:
///   - parseTopFrames(fromCallStackJSON:) — call-stack -> [binary+offset]
///   - diagnosticBody(for:now:)            — the exact POST payload shape
/// The MetricKit-typed paths (summarise(crash:) etc.) need real
/// MXDiagnostic payloads — those have no public initializer, so they're
/// verified on-device, not here.
final class CrashDiagnosticReporterTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - parseTopFrames

    func testParseTopFrames_extractsBinaryAndOffset() {
        let data = json("""
        {"callStacks":[{"callStackRootFrames":[
          {"binaryName":"MadFrogVPN","offsetIntoBinaryTextSegment":4096,
           "subFrames":[
             {"binaryName":"libsystem","offsetIntoBinaryTextSegment":128}
           ]}
        ]}]}
        """)
        let frames = CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: data)
        XCTAssertEqual(frames, ["MadFrogVPN+4096", "libsystem+128"],
                       "frames must be parent-then-child, formatted binaryName+offset")
    }

    func testParseTopFrames_respectsLimit() {
        let data = json("""
        {"callStacks":[{"callStackRootFrames":[
          {"binaryName":"a","offsetIntoBinaryTextSegment":1},
          {"binaryName":"b","offsetIntoBinaryTextSegment":2},
          {"binaryName":"c","offsetIntoBinaryTextSegment":3}
        ]}]}
        """)
        XCTAssertEqual(CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: data, limit: 2),
                       ["a+1", "b+2"])
    }

    func testParseTopFrames_defaultLimitIsEight() {
        var roots: [String] = []
        for i in 0..<20 { roots.append("{\"binaryName\":\"f\(i)\",\"offsetIntoBinaryTextSegment\":\(i)}") }
        let data = json("{\"callStacks\":[{\"callStackRootFrames\":[\(roots.joined(separator: ","))]}]}")
        XCTAssertEqual(CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: data).count, 8)
    }

    func testParseTopFrames_addressFallbackAndZero() {
        let data = json("""
        {"callStacks":[{"callStackRootFrames":[
          {"binaryName":"hasAddress","address":777},
          {"binaryName":"hasNeither"}
        ]}]}
        """)
        let frames = CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: data)
        XCTAssertEqual(frames, ["hasAddress+777", "hasNeither+0"],
                       "offsetIntoBinaryTextSegment -> address -> 0 fallback chain")
    }

    func testParseTopFrames_missingBinaryNameBecomesQuestionMark() {
        let data = json(#"{"callStacks":[{"callStackRootFrames":[{"offsetIntoBinaryTextSegment":9}]}]}"#)
        XCTAssertEqual(CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: data), ["?+9"])
    }

    func testParseTopFrames_malformedOrEmptyReturnsEmpty() {
        let bad = [
            "",                                            // not JSON
            "{not json",                                   // broken
            "{}",                                          // no callStacks
            #"{"callStacks":[]}"#,                         // empty stacks
            #"{"callStacks":[{"callStackRootFrames":[]}]}"#,// empty roots
            #"{"callStacks":[{}]}"#,                        // stack w/o roots
        ]
        for s in bad {
            XCTAssertEqual(CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: json(s)), [],
                           "malformed/empty input must yield [], got non-empty for \(s)")
        }
    }

    func testParseTopFrames_leaksNoPathsOrExtraFields() {
        // A frame carrying hypothetical PII-ish extra keys — the output
        // must still be ONLY binaryName+offset. ADR-006.
        let data = json("""
        {"callStacks":[{"callStackRootFrames":[
          {"binaryName":"MadFrogVPN","offsetIntoBinaryTextSegment":42,
           "fileName":"/Users/secret/app/Source.swift","sampleCount":99}
        ]}]}
        """)
        let frames = CrashDiagnosticReporter.parseTopFrames(fromCallStackJSON: data)
        XCTAssertEqual(frames, ["MadFrogVPN+42"])
        for f in frames {
            XCTAssertFalse(f.contains("/"), "a frame string must never contain a path: \(f)")
            XCTAssertFalse(f.lowercased().contains("secret"), "must not leak extra fields: \(f)")
        }
    }

    // MARK: - diagnosticBody

    private func sampleSummary() -> CrashDiagnosticReporter.CrashSummary {
        CrashDiagnosticReporter.CrashSummary(
            event: "crash",
            signal: "sig=SIGSEGV",
            termination: "Namespace SIGNAL, Code 11",
            appBuild: "71",
            osVersion: "iPhone OS 18.0",
            deviceType: "iPhone16,1",
            callStackTop: ["MadFrogVPN+4096", "libsystem+128"]
        )
    }

    func testDiagnosticBody_hasExactlyTheSummaryFields() {
        let body = CrashDiagnosticReporter.diagnosticBody(for: sampleSummary(), now: Date())
        // The privacy contract: a fixed, known field set — nothing else.
        XCTAssertEqual(Set(body.keys), [
            "event", "crash_signal", "crash_termination",
            "app_build", "os_version", "device_type",
            "call_stack_top", "ts",
        ], "diagnosticBody must ship exactly the summary fields — no extras (ADR-006)")
    }

    func testDiagnosticBody_carriesValuesAndUsesPassedTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = CrashDiagnosticReporter.diagnosticBody(for: sampleSummary(), now: now)
        XCTAssertEqual(body["event"] as? String, "crash")
        XCTAssertEqual(body["crash_signal"] as? String, "sig=SIGSEGV")
        XCTAssertEqual(body["app_build"] as? String, "71")
        XCTAssertEqual(body["call_stack_top"] as? [String], ["MadFrogVPN+4096", "libsystem+128"])
        XCTAssertEqual(body["ts"] as? String, ISO8601DateFormatter().string(from: now),
                       "ts must come from the passed `now`, not Date() — keeps the fn pure/testable")
    }

    func testDiagnosticBody_isJSONSerializable() {
        let body = CrashDiagnosticReporter.diagnosticBody(for: sampleSummary(), now: Date())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body),
                      "the POST body must be JSON-serializable")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }
}

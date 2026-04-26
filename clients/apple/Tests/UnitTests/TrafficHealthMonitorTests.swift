import XCTest
@testable import MadFrogVPN

/// Tests for `TrafficHealthMonitor`. Drive `tickIfEligible()` directly so we
/// can run a deterministic sequence of probe results in microseconds without
/// waiting on the actual probeInterval.
@MainActor
final class TrafficHealthMonitorTests: XCTestCase {

    /// Mutable knobs and counters per test. `probeResults` is consumed
    /// FIFO — each `tickIfEligible()` pulls the next entry. Running off
    /// the end is treated as `.success` so degenerate tests don't hang.
    final class Probe {
        var results: [TrafficHealthMonitor.ProbeResult] = []
        var calls = 0
        func next() -> TrafficHealthMonitor.ProbeResult {
            calls += 1
            return results.isEmpty ? .success : results.removeFirst()
        }
    }

    final class Flags {
        var vpnConnected = true
        var commandClientConnected = true
        var appActive = true
        var userEnabled = true
        var stallCount = 0
        var logLines: [String] = []
    }

    private func makeMonitor(
        probe: Probe,
        flags: Flags,
        onStall: (() async -> Void)? = nil,
        stallThreshold: Int = 2,
        cooldown: Duration = .seconds(60),
        suspend: Duration = .seconds(5),
        maxFallbacksPerHour: Int = 5
    ) -> TrafficHealthMonitor {
        TrafficHealthMonitor(
            probeInterval: .milliseconds(10),
            probeTimeoutSeconds: 1.0,
            cooldownAfterFallback: cooldown,
            suspendAfterManualSwitch: suspend,
            stallThreshold: stallThreshold,
            maxFallbacksPerHour: maxFallbacksPerHour,
            dependencies: .init(
                isVPNConnected: { flags.vpnConnected },
                isCommandClientConnected: { flags.commandClientConnected },
                isAppActive: { flags.appActive },
                isUserEnabled: { flags.userEnabled },
                probe: { _, _ in probe.next() },
                onStallDetected: {
                    flags.stallCount += 1
                    if let onStall { await onStall() }
                },
                log: { msg in flags.logLines.append(msg) }
            )
        )
    }

    // MARK: - Probe outcomes

    func testTwoFailuresTriggerStall() async {
        let probe = Probe()
        let flags = Flags()
        probe.results = [.failure(reason: "t1"), .failure(reason: "t2")]
        let mon = makeMonitor(probe: probe, flags: flags)

        await mon.tickIfEligible()
        XCTAssertEqual(flags.stallCount, 0, "single failure must not fire stall")

        await mon.tickIfEligible()
        XCTAssertEqual(flags.stallCount, 1, "second consecutive failure fires stall")
    }

    func testSuccessResetsFailureCounter() async {
        let probe = Probe()
        let flags = Flags()
        probe.results = [.failure(reason: "x"), .success, .failure(reason: "y")]
        let mon = makeMonitor(probe: probe, flags: flags)

        await mon.tickIfEligible()  // fail #1
        await mon.tickIfEligible()  // success — counter reset
        await mon.tickIfEligible()  // fail #1 again
        XCTAssertEqual(flags.stallCount, 0, "interleaved success must reset counter")
    }

    func testCooldownGate() async {
        let probe = Probe()
        let flags = Flags()
        // 4 failures back-to-back — without cooldown that'd be 2 stalls.
        // With a 60s cooldown only the first stall fires.
        probe.results = Array(repeating: .failure(reason: "x"), count: 4)
        let mon = makeMonitor(probe: probe, flags: flags, cooldown: .seconds(60))

        await mon.tickIfEligible()
        await mon.tickIfEligible()  // stall #1
        await mon.tickIfEligible()
        await mon.tickIfEligible()
        XCTAssertEqual(flags.stallCount, 1, "cooldown must suppress further stalls")
    }

    // MARK: - Eligibility

    /// Build-39: the foreground gate (`isAppActive`) was removed because
    /// stall detection only matters when the user IS using the network —
    /// the same window when the gate also paused us. The PacketTunnel
    /// extension hosts a parallel probe (`TunnelStallProbe`) that runs
    /// even while iOS suspends the main app entirely; this main-app
    /// monitor is now defense-in-depth for the foreground window. The
    /// test inverts the old assertion: backgrounded must NOT skip the
    /// probe.
    func testProbesRegardlessOfForegroundState() async {
        let probe = Probe()
        let flags = Flags()
        flags.appActive = false
        probe.results = [.failure(reason: "a"), .failure(reason: "b")]
        let mon = makeMonitor(probe: probe, flags: flags)

        await mon.tickIfEligible()
        await mon.tickIfEligible()
        XCTAssertEqual(probe.calls, 2, "must probe even while backgrounded (build-39)")
        XCTAssertEqual(flags.stallCount, 1, "two failures while backgrounded must still trigger stall")
    }

    func testNotEligibleWhenUserDisabled() async {
        let probe = Probe()
        let flags = Flags()
        flags.userEnabled = false
        probe.results = [.failure(reason: "a"), .failure(reason: "b")]
        let mon = makeMonitor(probe: probe, flags: flags)

        await mon.tickIfEligible()
        await mon.tickIfEligible()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(flags.stallCount, 0, "user toggle off → no fallback")
    }

    func testNotEligibleWhenVPNDown() async {
        let probe = Probe()
        let flags = Flags()
        flags.vpnConnected = false
        probe.results = [.failure(reason: "a"), .failure(reason: "b")]
        let mon = makeMonitor(probe: probe, flags: flags)

        await mon.tickIfEligible()
        await mon.tickIfEligible()
        XCTAssertEqual(probe.calls, 0, "tunnel down → don't probe")
    }

    // MARK: - Suspend window

    func testSuspendForManualSwitchSkipsProbe() async {
        let probe = Probe()
        let flags = Flags()
        probe.results = [.failure(reason: "a"), .failure(reason: "b"), .failure(reason: "c")]
        let mon = makeMonitor(probe: probe, flags: flags, suspend: .seconds(60))

        mon.suspendForManualSwitch()
        await mon.tickIfEligible()
        await mon.tickIfEligible()
        XCTAssertEqual(probe.calls, 0, "during suspend window probe must be skipped")
    }

    // MARK: - Per-hour cap

    func testHourlyCapStopsAfterMax() async {
        let probe = Probe()
        let flags = Flags()
        probe.results = Array(repeating: .failure(reason: "x"), count: 20)
        // Cooldown=0 (effectively) so each pair-of-fails fires a stall;
        // cap=2 so only 2 stalls fire in this run.
        let mon = makeMonitor(
            probe: probe,
            flags: flags,
            stallThreshold: 1,
            cooldown: .zero,
            maxFallbacksPerHour: 2
        )

        for _ in 0..<10 {
            await mon.tickIfEligible()
        }
        XCTAssertEqual(flags.stallCount, 2, "must cap at maxFallbacksPerHour")
    }
}

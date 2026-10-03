import Foundation
import Testing
@testable import LidwakeKit

@Suite("Dashboard")
struct DashboardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(
        paused: Bool = false,
        assertions: [Assertion] = [],
        cutouts: [String] = [],
        offIn: TimeInterval? = nil,
        temperature: Double? = 55,
    ) -> DaemonStatus {
        DaemonStatus(
            isBlocking: !assertions.isEmpty,
            assertions: assertions,
            lidClosed: true,
            helperConnected: true,
            cpuTemperatureCelsius: temperature,
            lastEvent: nil,
            paused: paused,
            environment: DaemonEnvironment(
                sleepDisabled: !assertions.isEmpty,
                batteryPercent: 64,
                onBattery: true,
                thermalState: 1,
                activeCutouts: cutouts,
                offAt: offIn.map { now.addingTimeInterval($0) },
                settings: LidwakeSettings(),
            ),
        )
    }

    private func render(_ s: DaemonStatus?, width: Int = 80) -> [String] {
        Dashboard(width: width, color: false).render(s, now: now)
    }

    private func agent(_ tool: String, reason: String? = nil) -> Assertion {
        Assertion(key: "\(tool):1", tool: tool, reason: reason, pid: 4242, processName: tool, acquiredAt: now.addingTimeInterval(-725))
    }

    @Test
    func `the headline says on, off, idle or cutout`() {
        #expect(render(status(paused: true))[0].contains("○ OFF"))
        #expect(render(status())[0].contains("● ON · idle"))
        #expect(render(status(assertions: [agent("claude-code")]))[0].contains("● ON · keeping the Mac awake"))
        #expect(render(status(cutouts: ["lowBattery"]))[0].contains("▲ CUTOUT · low battery"))
    }

    @Test
    func `agents show tool, pid, state, age and reason`() {
        let lines = render(status(assertions: [agent("claude-code", reason: "refactor auth")]))
        let line = lines.first { $0.contains("claude-code") }
        #expect(line?.contains("pid 4242") == true)
        #expect(line?.contains("working") == true)
        #expect(line?.contains("12m") == true)
        #expect(line?.contains("refactor auth") == true)
    }

    @Test
    func `the off timer counts down to its deadline`() {
        let line = render(status(offIn: 3_725)).first { $0.contains("Off timer") }
        #expect(line?.contains("1h 02m") == true)
        #expect(render(status()).contains { $0.contains("not set") })
        #expect(render(status(paused: true, offIn: 600)).contains { $0.contains("lidwake is off") })
    }

    @Test
    func `temperature zones climb toward the cutout`() {
        #expect(Dashboard.tempZone(50, cutout: 80) == .normal)
        #expect(Dashboard.tempZone(60, cutout: 80) == .warm)
        #expect(Dashboard.tempZone(76, cutout: 80) == .hot)
        #expect(Dashboard.tempZone(80, cutout: 80) == .critical)
        #expect(render(status(temperature: 81)).contains { $0.contains("81°C critical") })
        #expect(render(status(temperature: nil)).contains { $0.contains("unreadable") })
    }

    @Test
    func `thermal pressure marks the current state`() {
        let line = render(status()).first { $0.contains("Thermal") }
        #expect(line?.contains("● fair") == true)
        #expect(line?.contains("○ nominal") == true)
    }

    @Test(arguments: [48, 64, 80, 120])
    func `lines fit the terminal width`(width: Int) {
        let lines = render(status(assertions: [agent("claude-code", reason: String(repeating: "long reason ", count: 20))], offIn: 600), width: width)
        let limit = max(48, min(width, 96))
        for line in lines {
            #expect(line.count <= limit, "\(line.count) > \(limit): \(line)")
        }
    }

    @Test
    func `color is all-or-nothing`() {
        let plain = render(status()).joined()
        let colored = Dashboard(width: 80, color: true).render(status(), now: now).joined()
        #expect(!plain.contains("\u{1B}["))
        #expect(colored.contains("\u{1B}["))
    }

    @Test
    func `a missing daemon gets its own screen`() {
        #expect(render(nil).contains { $0.contains("daemon not running") })
    }
}

@Suite("OffTimer")
struct OffTimerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `a deadline is clamped to a minute … a day, and zero cancels`() {
        #expect(OffTimer.deadline(after: 3_600, now: now) == now.addingTimeInterval(3_600))
        #expect(OffTimer.deadline(after: 5, now: now) == now.addingTimeInterval(60))
        #expect(OffTimer.deadline(after: 99 * 3_600, now: now) == now.addingTimeInterval(24 * 3_600))
        #expect(OffTimer.deadline(after: 0, now: now) == nil)
        #expect(OffTimer.deadline(after: nil, now: now) == nil)
        #expect(OffTimer.deadline(after: .infinity, now: now) == nil)
    }

    @Test
    func `due once the deadline passes`() {
        #expect(!OffTimer.isDue(nil, now: now))
        #expect(!OffTimer.isDue(now.addingTimeInterval(1), now: now))
        #expect(OffTimer.isDue(now, now: now))
    }

    @Test
    func `the timer key steps through the presets and back to off`() {
        // Typed locals: comparing an Optional<Double> to a literal inside #expect crashes the
        // Swift 6.2.4 compiler (SILGen reabstraction thunk).
        let steps: [TimeInterval?] = [nil, 900, 3_000, 14_400].map { OffTimer.nextPreset(after: $0) }
        let expected: [TimeInterval?] = [900, 1_800, 3_600, nil]
        #expect(steps == expected)
    }
}

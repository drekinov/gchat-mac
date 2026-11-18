import AppKit
import ChatModel
import Foundation

struct BenchConfig {
    var seconds: Int
    var accounts: Int
    var traffic: Bool
    var interval: Double
    var spacesToOpen: Int

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--bench") else { return nil }
        seconds = arguments.dropFirst(index + 1).first.flatMap { Int($0) } ?? 240
        accounts = 3
        if let at = arguments.firstIndex(of: "--bench-accounts"), at + 1 < arguments.count,
            let value = Int(arguments[at + 1])
        {
            accounts = min(max(value, 1), FakeScript.maxAccounts)
        }
        traffic = arguments.contains("--bench-traffic")
        interval = 5
        spacesToOpen = 10
        if let at = arguments.firstIndex(of: "--bench-open"), at + 1 < arguments.count,
            let value = Int(arguments[at + 1])
        {
            spacesToOpen = max(0, value)
        }
        if let at = arguments.firstIndex(of: "--bench-interval"), at + 1 < arguments.count,
            let value = Double(arguments[at + 1]), value > 0
        {
            interval = value
        }
    }
}

/// Drives the real window through a fixed script and prints process metrics, so memory and CPU can be compared
/// between builds. Idle phases are summarised separately because that is the state the app spends its life in.
@MainActor
struct BenchRunner {
    let model: AppModel
    let config: BenchConfig

    private struct Mark {
        var time: Double
        var metrics: ProcessMetrics
    }

    private struct PhaseResult {
        var name: String
        var start: Mark
        var end: Mark
        var endFootprint: Double
    }

    func run() async {
        setlinebuf(stdout)
        NSApplication.shared.activate()
        let clock = ContinuousClock()
        let origin = clock.now
        func now() -> Double {
            let parts = (clock.now - origin).components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        var phase = "boot"
        var last = Mark(time: 0, metrics: .sample())
        var results: [PhaseResult] = []
        var current: (name: String, start: Mark)?

        func line(_ mark: Mark, reference: Mark) -> String {
            let dt = max(mark.time - reference.time, 0.001)
            let cpu = (mark.metrics.cpuSeconds - reference.metrics.cpuSeconds) / dt * 100
            let wake = Double(mark.metrics.wakeups &- reference.metrics.wakeups) / dt
            let m = mark.metrics
            let counters = BenchCounters.values
            return String(
                format:
                    "BENCH t=%.0f phase=%@ footprint=%.1fMB peak=%.1fMB rss=%.1fMB cpu_user+sys=%.1fs cpu=%.1f%% wakeups=%llu (%.0f/s) threads=%d snapshots=%d reloads=%d imgloads=%d gifframes=%d active=%d",
                mark.time, phase, m.footprintMB, m.peakMB, m.rssMB, m.cpuSeconds, cpu, m.wakeups, wake, m.threads,
                counters.snapshots, counters.reloads, counters.imageLoads,
                counters.gifFrames, NSApplication.shared.isActive ? 1 : 0)
        }

        func begin(_ name: String) {
            if let current {
                let end = Mark(time: now(), metrics: .sample())
                results.append(
                    PhaseResult(
                        name: current.name, start: current.start, end: end, endFootprint: end.metrics.footprintMB))
            }
            phase = name
            current = (name, Mark(time: now(), metrics: .sample()))
        }

        print(
            "BENCH config accounts=\(config.accounts) traffic=\(config.traffic) seconds=\(config.seconds) timing=production"
        )
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(config.interval))
                let mark = Mark(time: now(), metrics: .sample())
                print(line(mark, reference: last))
                last = mark
            }
        }

        begin("startup")
        for _ in 0..<300 {
            if model.accounts.count == config.accounts,
                model.accounts.allSatisfy({ !(model.snapshots[$0.id]?.spaces.isEmpty ?? true) })
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(5))

        let inbox = model.inbox
        let releases = inbox.first { $0.summary.title == "Releases" }
        var spaces = inbox.filter { $0.summary.title != "Releases" }.prefix(9).map(\.id)
        if let releases { spaces.append(releases.id) }
        spaces = Array(spaces.suffix(config.spacesToOpen))

        begin("idle-inbox")
        try? await Task.sleep(for: .seconds(30))

        begin("open-spaces")
        for key in spaces {
            model.select(key)
            try? await Task.sleep(for: .seconds(3))
        }

        begin("scroll")
        for toTop in [true, false, true, false] {
            model.scrollOpenSpace(toTop: toTop)
            try? await Task.sleep(for: .seconds(1.5))
        }

        begin("idle-space")
        try? await Task.sleep(for: .seconds(60))

        begin("tail")
        if config.spacesToOpen > 0, let plain = inbox.first(where: { $0.summary.title == "Engineering" }) {
            model.select(plain.id)
        }
        let remaining = Double(config.seconds) - now()
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        begin("done")
        sampler.cancel()

        let final = Mark(time: now(), metrics: .sample())
        print(line(final, reference: last))
        print("BENCH summary (average over each phase; footprint is the value when the phase ended)")
        for result in results where ["idle-inbox", "idle-space", "tail"].contains(result.name) {
            let dt = max(result.end.time - result.start.time, 0.001)
            let cpu = (result.end.metrics.cpuSeconds - result.start.metrics.cpuSeconds) / dt * 100
            let wake = Double(result.end.metrics.wakeups &- result.start.metrics.wakeups) / dt
            print(
                String(
                    format: "BENCH summary phase=%@ duration=%.0fs footprint=%.1fMB cpu=%.2f%% wakeups=%.1f/s",
                    result.name, dt, result.endFootprint, cpu, wake))
        }
        print(
            String(
                format: "BENCH summary peak=%.1fMB final_footprint=%.1fMB rss=%.1fMB threads=%d",
                final.metrics.peakMB, final.metrics.footprintMB, final.metrics.rssMB, final.metrics.threads))
        exit(0)
    }
}

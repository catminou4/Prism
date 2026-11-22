import AppKit
import Darwin
import PrismCore
import PrismData
import QuartzCore
import SwiftUI
import Testing
@testable import PrismUI

/// Run in Release with PRISM_SCROLL_PERF=1. The window is never ordered onscreen.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_SCROLL_PERF"] == "1"))
struct ScrollPerformanceTests {
    @Test func titleGrid() async throws {
        _ = NSApplication.shared
        let titles = (0..<100_000).map { index in
            MediaTitle(id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                       title: "Film \(index)", year: 2000 + index % 25, variants: [])
        }
        let model = AppModel(directories: .temporary("prism-scroll-bench"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)
        let clock = ContinuousClock()
        let startup = clock.now
        let host = NSHostingView(
            rootView: ScrollView {
                TitleGrid(items: titles, availableWidth: size.width)
            }
            .frame(width: size.width, height: size.height)
            .environment(model)
            .environment(navigation)
        )
        host.frame = frame
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        layout(host)
        let startupMS = milliseconds(startup.duration(to: clock.now))
        let scroll = try #require(scrollView(in: host))
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let direction: CGFloat = clip.isFlipped ? 1 : -1
        try await Task.sleep(for: .milliseconds(100))
        let steps = 240
        let interval: Duration = .nanoseconds(8_333_333)
        var samples: [Double] = []
        let startUsage = usage()
        let startEnergy = energy()
        let scrollStart = clock.now
        for step in 1...steps {
            try await clock.sleep(until: scrollStart.advanced(by: interval * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 48))
            let start = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            samples.append(milliseconds(start.duration(to: clock.now)))
            if step == steps / 2 { #expect(abs(clip.bounds.origin.y - destination.y) < 1) }
        }
        let wallSeconds = milliseconds(scrollStart.duration(to: clock.now)) / 1_000
        let endEnergy = energy()
        let endUsage = usage()
        let sorted = samples.sorted()
        let budget = 1_000.0 / 120
        let overBudget = samples.count { $0 > budget }
        let cpuMS = (cpuSeconds(endUsage) - cpuSeconds(startUsage)) * 1_000
        print("[scroll-perf] 100k posters, \(steps) steps at 48 pt: first layout \(format(startupMS)) ms, "
            + "p50 \(format(sorted[steps / 2 - 1])) ms, p95 \(format(sorted[steps * 95 / 100 - 1])) ms, "
            + "max \(format(sorted[steps - 1])) ms, \(overBudget)/\(steps) over \(format(budget)) ms, "
            + "CPU \(format(cpuMS)) ms, peak RSS \(format(Double(endUsage.ru_maxrss) / 1_048_576)) MiB")
        if let startEnergy, let endEnergy, endEnergy > startEnergy {
            let joules = Double(endEnergy - startEnergy) / 1e9
            print("[scroll-perf] Kernel-attributed process energy \(format(joules)) J, "
                + "\(format(joules / wallSeconds)) W over \(format(wallSeconds)) s")
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private func usage() -> rusage {
        var result = rusage()
        getrusage(RUSAGE_SELF, &result)
        return result
    }

    private func energy() -> UInt64? {
        var result = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? result.ri_energy_nj : nil
    }

    private func cpuSeconds(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

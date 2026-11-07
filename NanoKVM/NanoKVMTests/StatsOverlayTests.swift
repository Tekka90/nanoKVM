import SwiftUI
import Testing
@testable import NanoKVM

@MainActor
struct StatsOverlayTests {
    private func withShowStats(_ value: Bool, _ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "showStats")
        defaults.set(value, forKey: "showStats")
        await body()
        if let old { defaults.set(old, forKey: "showStats") } else { defaults.removeObject(forKey: "showStats") }
    }

    @Test func collapsedShowsOnlyButton() async {
        await withShowStats(false) {
            await mount(StatsOverlay(stream: VideoStream(host: "unused.test", token: "t")), wait: .milliseconds(200))
        }
    }

    @Test func expandedWithEmptyHistory() async {
        await withShowStats(true) {
            await mount(StatsOverlay(stream: VideoStream(host: "unused.test", token: "t")), wait: .milliseconds(300))
        }
    }

    @Test func expandedWithSamples() async {
        let stream = VideoStream(host: "unused.test", token: "t")
        stream.start()
        for _ in 0..<5 { stream.decode(Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF])) }
        await withShowStats(true) {
            await mount(StatsOverlay(stream: stream), wait: .milliseconds(1600))
        }
        stream.stop()
    }
}

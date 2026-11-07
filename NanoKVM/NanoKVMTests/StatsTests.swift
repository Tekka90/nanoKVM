import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct StatsTests {
    @Test func firstTickHasNoSample() {
        var m = StreamMeter()
        m.record(bytes: 1000, keyframe: true)
        #expect(m.tick(now: Date()) == nil)
    }

    @Test func tickComputesBitrateAndFPS() {
        var m = StreamMeter()
        let t0 = Date()
        _ = m.tick(now: t0)
        for i in 0..<30 { m.record(bytes: 12_500, keyframe: i == 0) }
        let s = m.tick(now: t0.addingTimeInterval(1))
        #expect(s != nil)
        #expect(abs(s!.kbps - 3000) < 0.001)
        #expect(abs(s!.fps - 30) < 0.001)
        #expect(m.keyframes == 1 && m.totalFrames == 30 && m.totalBytes == 375_000)
    }

    @Test func tickResetsInterval() {
        var m = StreamMeter()
        let t0 = Date()
        _ = m.tick(now: t0)
        m.record(bytes: 1000, keyframe: false)
        _ = m.tick(now: t0.addingTimeInterval(1))
        let s = m.tick(now: t0.addingTimeInterval(2))
        #expect(s?.kbps == 0 && s?.fps == 0)
    }

    @Test func tooShortIntervalIgnored() {
        var m = StreamMeter()
        let t0 = Date()
        _ = m.tick(now: t0)
        #expect(m.tick(now: t0.addingTimeInterval(0.01)) == nil)
    }

    @Test func historyKeepsLast60() {
        var h: [StatSample] = []
        for i in 1...75 { h = StreamMeter.append(StatSample(id: i, kbps: Double(i), fps: 1), to: h) }
        #expect(h.count == 60 && h.first?.id == 16 && h.last?.id == 75)
        #expect(h.peakKbps == 75)
        #expect(abs(h.averageKbps - 45.5) < 0.001)
        #expect([StatSample]().averageKbps == 0 && [StatSample]().peakKbps == 0)
    }

    @Test func resetClearsCounters() {
        var m = StreamMeter()
        m.record(bytes: 5, keyframe: true)
        m.reset()
        #expect(m.totalFrames == 0 && m.keyframes == 0)
    }

    @Test func bitrateFormatting() {
        #expect(formatBitrate(850) == "850 kbps")
        #expect(formatBitrate(2500) == "2.5 Mbps")
    }

    @Test func streamRecordsDecodedFrames() {
        let stream = VideoStream(host: "x", token: "t")
        stream.decode(Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF]))
        #expect(stream.meter.totalFrames == 1 && stream.meter.keyframes == 1)
    }

    // MARK: Keychain

    @Test func deleteAllAlsoRemovesLegacySSHPassword() {
        let id = UUID()
        defer { Keychain.deleteAll(for: id) }
        Keychain.setPassword("web", for: id)
        Keychain.setPassword("root", for: id, suffix: Keychain.sshSuffix)
        Keychain.deleteAll(for: id)
        #expect(Keychain.password(for: id) == nil)
        #expect(Keychain.password(for: id, suffix: Keychain.sshSuffix) == nil)
    }
}

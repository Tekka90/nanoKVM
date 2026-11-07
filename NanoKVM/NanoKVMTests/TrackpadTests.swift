import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct TrackpadTests {
    @Test func slowMovementUsesBaseSpeed() {
        var e = TrackpadEngine(speed: 2)
        // 1 pt distance: gain = 2 * (1 + 1/20) = 2.1 -> 2 whole units, remainder kept
        let d = e.move(dx: 1, dy: 0)
        #expect(d.dx == 2 && d.dy == 0)
    }

    @Test func fastMovementIsAcceleratedAndCapped() {
        var slow = TrackpadEngine(speed: 1)
        var fast = TrackpadEngine(speed: 1)
        let a = slow.move(dx: 5, dy: 0).dx
        let b = fast.move(dx: 40, dy: 0).dx
        #expect(Double(b) / 40 > Double(a) / 5)
        #expect(slow.gain(forDistance: 400) == slow.gain(forDistance: 40))
        #expect(slow.gain(forDistance: 400) == 3)
    }

    @Test func fractionsAccumulateInsteadOfBeingLost() {
        var e = TrackpadEngine(speed: 0.5)
        var total = 0
        for _ in 0..<20 { total += e.move(dx: 0.2, dy: 0).dx }
        #expect(total > 0)
        e.reset()
        #expect(e.move(dx: 0.1, dy: 0.1) == (0, 0))
    }

    @Test func negativeDirectionIsSymmetric() {
        var a = TrackpadEngine(speed: 1.5)
        var b = TrackpadEngine(speed: 1.5)
        let p = a.move(dx: 7, dy: 3)
        let n = b.move(dx: -7, dy: -3)
        #expect(p.dx == -n.dx && p.dy == -n.dy)
    }

    @Test func reversedScrollFlipsTicks() {
        var e = TrackpadEngine()
        e.naturalScroll = false
        #expect(e.scroll(dy: 40) == [-1, -1])
        #expect(e.scroll(dy: -20) == [1])
    }

    @Test func naturalScrollDefaultsOnAndPersistsPerDevice() {
        let id = UUID()
        defer { UserDefaults.standard.removeObject(forKey: "naturalScroll.\(id.uuidString)") }
        #expect(PointerPrefs.naturalScroll(for: id))
        PointerPrefs.setNaturalScroll(false, for: id)
        #expect(!PointerPrefs.naturalScroll(for: id))
        #expect(PointerPrefs.naturalScroll(for: UUID()))
    }

    @Test func scrollEmitsOneTickPerStepAndKeepsRemainder() {
        var e = TrackpadEngine()
        #expect(e.scroll(dy: 10).isEmpty)
        #expect(e.scroll(dy: 10) == [1])
        #expect(e.scroll(dy: -65) == [-1, -1, -1])
        #expect(e.scroll(dy: -15) == [-1])
    }

    @Test func prefsAreClampedAndPerDevice() {
        let a = UUID(), b = UUID()
        defer {
            for id in [a, b] {
                UserDefaults.standard.removeObject(forKey: "trackpadSpeed.\(id.uuidString)")
                for store in [UserDefaults.standard] { store.removeObject(forKey: "trackpad.\(id.uuidString)") }
                NSUbiquitousKeyValueStore.default.removeObject(forKey: "trackpad.\(id.uuidString)")
            }
        }
        #expect(PointerPrefs.speed(for: a) == PointerPrefs.defaultSpeed)
        PointerPrefs.setSpeed(99, for: a)
        #expect(PointerPrefs.speed(for: a) == PointerPrefs.speedRange.upperBound)
        PointerPrefs.setSpeed(0, for: a)
        #expect(PointerPrefs.speed(for: a) == PointerPrefs.speedRange.lowerBound)
        PointerPrefs.setTrackpad(true, for: a)
        #expect(PointerPrefs.trackpad(for: a))
        #expect(PointerPrefs.trackpad(for: b) == PointerPrefs.defaultTrackpad)
        PointerPrefs.setTrackpad(false, for: b)
        #expect(!PointerPrefs.trackpad(for: b))
    }

    @Test func sessionLoadsAndPersistsTrackpad() async {
        let server = MockServer()
        server.lenient = true
        let device = SavedDevice(name: "TP-\(UUID().uuidString.prefix(6))", host: server.host, username: "admin")
        defer {
            UserDefaults.standard.removeObject(forKey: "trackpadSpeed.\(device.id.uuidString)")
            UserDefaults.standard.removeObject(forKey: "trackpad.\(device.id.uuidString)")
            NSUbiquitousKeyValueStore.default.removeObject(forKey: "trackpad.\(device.id.uuidString)")
        }
        let s = DeviceSession(device: device, makeClient: { MockServer.client(host: $0) }, passwordProvider: { _ in "pw" })
        #expect(s.trackpad == PointerPrefs.defaultTrackpad)
        s.trackpad = true
        s.trackpadSpeed = 2.5
        await s.applyPointerMode()
        #expect(server.last("POST /hid/pointer-mode")?.json["mode"] as? String == "relative")
        s.trackpad = false
        await s.applyPointerMode()
        #expect(server.last("POST /hid/pointer-mode")?.json["mode"] as? String == "absolute")
        let again = DeviceSession(device: device, makeClient: { MockServer.client(host: $0) }, passwordProvider: { _ in "pw" })
        #expect(again.trackpadSpeed == 2.5)
    }

    @Test func relativePointerCanPressButtons() {
        let input = InputSender(host: "unused.test", token: "t")
        var sent: [Data] = []
        input.onSend = { sent.append($0) }
        input.relativePointer(dx: 0, dy: 0, buttons: 1)
        input.relativePointer(dx: 3, dy: -2)
        input.relativePointer(dx: 0, dy: 0, buttons: 0)
        let b = sent.map { Array($0.dropFirst(13))[0] }
        #expect(b == [1, 1, 0])
    }
}

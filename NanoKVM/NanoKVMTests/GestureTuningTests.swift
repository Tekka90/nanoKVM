import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct GestureTuningTests {
    @Test func defaultsKeepOriginalBehaviour() {
        let t = GestureTuning()
        #expect(t.tapMaxDuration == 0.6 && t.tapMaxMovement == 15)
        #expect(t.doubleTapGap == 0.3 && t.doubleTapDistance == 80)
        #expect(t.holdDuration == 1.0 && t.scrollStep == 20 && t.accelerationBoost == 2)
    }

    @Test func storesPerDeviceAndResetsWhenDefault() {
        let id = UUID()
        defer { GestureTuning.store(GestureTuning(), for: id) }
        #expect(GestureTuning.stored(for: id) == GestureTuning())
        var t = GestureTuning()
        t.doubleTapGap = 0.5
        GestureTuning.store(t, for: id)
        #expect(GestureTuning.stored(for: id).doubleTapGap == 0.5)
        #expect(GestureTuning.stored(for: UUID()) == GestureTuning())
        GestureTuning.store(GestureTuning(), for: id)
        #expect(UserDefaults.standard.data(forKey: "gestureTuning.\(id.uuidString)") == nil)
    }

    @Test func outOfRangeValuesAreClamped() {
        var t = GestureTuning()
        t.holdDuration = 99
        t.scrollStep = 0
        let c = t.clamped()
        #expect(c.holdDuration == GestureTuning.holdDurationRange.upperBound)
        #expect(c.scrollStep == GestureTuning.scrollStepRange.lowerBound)
    }

    @Test func accelerationBoostScalesFastStrokes() {
        var e = TrackpadEngine(speed: 1)
        #expect(e.gain(forDistance: 40) == 3)
        e.accelerationBoost = 0
        #expect(e.gain(forDistance: 40) == 1)
    }
}

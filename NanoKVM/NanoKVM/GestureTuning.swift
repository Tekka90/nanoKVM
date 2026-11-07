import Foundation

/// Timing and distance thresholds of the trackpad gestures, adjustable per device (defaults match the original behaviour).
struct GestureTuning: Codable, Equatable {
    /// A touch counts as a tap when it is shorter than this (seconds) and moves less than `tapMaxMovement` (points).
    var tapMaxDuration = 0.6
    var tapMaxMovement = 15.0
    /// Putting a finger down again within this gap (seconds) and distance (points) of a tap presses and holds the button.
    var doubleTapGap = 0.3
    var doubleTapDistance = 80.0
    /// Resting a finger this long (seconds) presses the button; moving afterwards drags.
    var holdDuration = 1.0
    /// Minimum press (seconds) for the tap-then-press recognizer.
    var tapHoldDuration = 0.1
    /// Finger travel (points) per wheel tick.
    var scrollStep = 20.0
    /// Extra pointer gain for fast strokes, as a multiple of the base speed (the gain ramps up to 1 + this).
    var accelerationBoost = 2.0

    static let tapMaxDurationRange = 0.15...1.0
    static let tapMaxMovementRange = 5.0...40.0
    static let doubleTapGapRange = 0.1...1.0
    static let doubleTapDistanceRange = 20.0...200.0
    static let holdDurationRange = 0.2...2.0
    static let tapHoldDurationRange = 0.05...0.4
    static let scrollStepRange = 8.0...60.0
    static let accelerationBoostRange = 0.0...4.0

    func clamped() -> GestureTuning {
        var t = self
        t.tapMaxDuration = tapMaxDuration.clamped(to: Self.tapMaxDurationRange)
        t.tapMaxMovement = tapMaxMovement.clamped(to: Self.tapMaxMovementRange)
        t.doubleTapGap = doubleTapGap.clamped(to: Self.doubleTapGapRange)
        t.doubleTapDistance = doubleTapDistance.clamped(to: Self.doubleTapDistanceRange)
        t.holdDuration = holdDuration.clamped(to: Self.holdDurationRange)
        t.tapHoldDuration = tapHoldDuration.clamped(to: Self.tapHoldDurationRange)
        t.scrollStep = scrollStep.clamped(to: Self.scrollStepRange)
        t.accelerationBoost = accelerationBoost.clamped(to: Self.accelerationBoostRange)
        return t
    }

    private static func key(_ id: UUID) -> String { "gestureTuning.\(id.uuidString)" }

    static func stored(for id: UUID, defaults: UserDefaults = .standard) -> GestureTuning {
        guard let data = defaults.data(forKey: key(id)), let t = try? JSONDecoder().decode(GestureTuning.self, from: data) else { return GestureTuning() }
        return t.clamped()
    }

    static func store(_ tuning: GestureTuning, for id: UUID, defaults: UserDefaults = .standard) {
        if tuning == GestureTuning() { defaults.removeObject(forKey: key(id)); return }
        if let data = try? JSONEncoder().encode(tuning.clamped()) { defaults.set(data, forKey: key(id)) }
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}

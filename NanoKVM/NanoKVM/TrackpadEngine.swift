import CoreGraphics
import Foundation

/// Per-device trackpad preferences (the mode is synced through iCloud, the speed stays local).
enum PointerPrefs {
    static let defaultSpeed = 1.5
    static let speedRange: ClosedRange<Double> = 0.5...4

    #if os(iOS)
    static let defaultTrackpad = true
    #else
    static let defaultTrackpad = false
    #endif

    /// On by default on iOS until the user makes a choice (which is then stored explicitly, on or off).
    static func trackpad(for id: UUID) -> Bool {
        let key = "trackpad.\(id.uuidString)"
        guard UserDefaults.standard.object(forKey: key) != nil || NSUbiquitousKeyValueStore.default.object(forKey: key) != nil else {
            return defaultTrackpad
        }
        return SyncedFlag.isOn("trackpad", id)
    }
    static func setTrackpad(_ on: Bool, for id: UUID) { SyncedFlag.set(on, "trackpad", id) }

    static func speed(for id: UUID) -> Double {
        let v = UserDefaults.standard.object(forKey: "trackpadSpeed.\(id.uuidString)") as? Double ?? defaultSpeed
        return min(max(v, speedRange.lowerBound), speedRange.upperBound)
    }

    /// Natural scrolling (content follows the fingers) is on unless the user turns it off.
    static func naturalScroll(for id: UUID) -> Bool {
        UserDefaults.standard.object(forKey: "naturalScroll.\(id.uuidString)") as? Bool ?? true
    }
    static func setNaturalScroll(_ on: Bool, for id: UUID) { UserDefaults.standard.set(on, forKey: "naturalScroll.\(id.uuidString)") }

    static func setSpeed(_ speed: Double, for id: UUID) {
        UserDefaults.standard.set(min(max(speed, speedRange.lowerBound), speedRange.upperBound), forKey: "trackpadSpeed.\(id.uuidString)")
    }
}

/// Turns finger movement into whole-number relative mouse deltas, with acceleration.
struct TrackpadEngine {
    var speed: Double = PointerPrefs.defaultSpeed
    /// Finger travel (in points) per scroll tick.
    var scrollStep: CGFloat = 20
    /// The gain ramps from 1× to (1 + this)× the base speed as the stroke gets faster.
    var accelerationBoost = 2.0
    /// When off, the wheel direction is reversed (finger down scrolls down).
    var naturalScroll = true
    private var remainder = CGPoint.zero
    private var scrollRemainder: CGFloat = 0

    /// Slow movements keep the base speed; fast ones are boosted (3× with the default boost).
    func gain(forDistance distance: Double) -> Double {
        speed * (1 + accelerationBoost * min(distance, 40) / 40)
    }

    mutating func move(dx: CGFloat, dy: CGFloat) -> (dx: Int, dy: Int) {
        let g = gain(forDistance: Double(hypot(dx, dy)))
        remainder.x += dx * g
        remainder.y += dy * g
        let ix = Int(remainder.x.rounded(.towardZero))
        let iy = Int(remainder.y.rounded(.towardZero))
        remainder.x -= CGFloat(ix)
        remainder.y -= CGFloat(iy)
        return (ix, iy)
    }

    /// Wheel ticks (+1 / -1 each) for a vertical finger travel.
    mutating func scroll(dy: CGFloat) -> [Int] {
        scrollRemainder += dy
        var ticks: [Int] = []
        while abs(scrollRemainder) >= scrollStep {
            let sign = scrollRemainder > 0 ? 1 : -1
            ticks.append(naturalScroll ? sign : -sign)
            scrollRemainder -= CGFloat(sign) * scrollStep
        }
        return ticks
    }

    mutating func reset() {
        remainder = .zero
        scrollRemainder = 0
    }
}

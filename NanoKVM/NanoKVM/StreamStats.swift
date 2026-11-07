import Foundation

struct StatSample: Equatable, Identifiable {
    let id: Int
    let kbps: Double
    let fps: Double
}

/// Accumulates frame sizes and turns them into one bitrate/fps sample per interval.
struct StreamMeter {
    static let capacity = 60
    private var bytes = 0
    private var frames = 0
    private var lastTick: Date?
    private(set) var keyframes = 0
    private(set) var totalBytes = 0
    private(set) var totalFrames = 0
    private var nextID = 0

    mutating func record(bytes count: Int, keyframe: Bool) {
        bytes += count
        frames += 1
        totalBytes += count
        totalFrames += 1
        if keyframe { keyframes += 1 }
    }

    /// Closes the current interval. Returns nil for the first call (no baseline yet).
    mutating func tick(now: Date = Date()) -> StatSample? {
        defer { bytes = 0; frames = 0; lastTick = now }
        guard let last = lastTick else { return nil }
        let dt = now.timeIntervalSince(last)
        guard dt > 0.05 else { return nil }
        nextID += 1
        return StatSample(id: nextID, kbps: Double(bytes) * 8 / 1000 / dt, fps: Double(frames) / dt)
    }

    mutating func reset() { self = StreamMeter() }

    static func append(_ sample: StatSample, to history: [StatSample]) -> [StatSample] {
        Array((history + [sample]).suffix(capacity))
    }
}

extension Array where Element == StatSample {
    var averageKbps: Double { isEmpty ? 0 : map(\.kbps).reduce(0, +) / Double(count) }
    var peakKbps: Double { map(\.kbps).max() ?? 0 }
}

func formatBitrate(_ kbps: Double) -> String {
    kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : String(format: "%.0f kbps", kbps)
}

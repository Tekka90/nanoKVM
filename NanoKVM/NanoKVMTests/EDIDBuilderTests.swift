import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct EDIDBuilderTests {
    private func sum(_ d: Data, _ r: Range<Int>) -> Int { r.reduce(0) { $0 + Int(d[$1]) } % 256 }

    @Test(arguments: [(1920, 1080, 60), (2560, 1600, 30), (3456, 2234, 30), (1024, 768, 60), (1280, 1024, 60), (1440, 900, 60), (1500, 1000, 60), (800, 600, 30)])
    func structureIsValid(w: Int, h: Int, hz: Int) {
        let d = EDIDBuilder(width: w, height: h, refresh: hz, name: "Test").build()
        #expect(d.count == 256)
        #expect(Array(d[0..<8]) == [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
        #expect(sum(d, 0..<128) == 0)
        #expect(sum(d, 128..<256) == 0)
        #expect(d[126] == 1)
        #expect(d[128] == 0x02 && d[129] == 0x03)
        #expect(d[18] == 1 && d[19] == 4)
    }

    @Test func timing1080p60MatchesReducedBlanking() {
        let t = EDIDBuilder(width: 1920, height: 1080, refresh: 60, name: "x").timing
        #expect(t.hActive == 1920 && t.vActive == 1080)
        #expect(t.hBlank == 160 && t.hFront == 48 && t.hSync == 32)
        #expect(t.vSync == 5)
        #expect(abs(t.pixelClockMHz - 138.5) < 1.5)
        #expect(t.pixelClock10kHz == t.pixelClock10kHz)
    }

    @Test(arguments: [(1024, 768, 4), (1920, 1080, 5), (1920, 1200, 6), (1280, 1024, 7), (1500, 900, 7), (2000, 1000, 10)])
    func vSyncDependsOnAspectRatio(w: Int, h: Int, expected: Int) {
        #expect(EDIDBuilder(width: w, height: h, refresh: 60, name: "x").timing.vSync == expected)
    }

    @Test func dtdEncodesTiming() {
        let b = EDIDBuilder(width: 1920, height: 1080, refresh: 60, name: "x")
        let t = b.timing
        let d = b.build()
        #expect(Int(d[54]) | Int(d[55]) << 8 == t.pixelClock10kHz)
        #expect(Int(d[56]) | (Int(d[58] >> 4) << 8) == 1920)
        #expect(Int(d[59]) | (Int(d[61] >> 4) << 8) == 1080)
        #expect(Int(d[58] & 0x0F) << 8 | Int(d[57]) == t.hBlank)
        #expect(d[71] == 0x1A)
    }

    @Test func monitorNameDescriptor() {
        let d = EDIDBuilder(width: 1920, height: 1080, refresh: 60, name: "MacBook Pro").build()
        #expect(Array(d[90..<95]) == [0, 0, 0, 0xFC, 0])
        let text = String(decoding: d[95..<108], as: UTF8.self)
        #expect(text.hasPrefix("MacBook Pro\n"))
    }

    @Test func monitorNameIsFilteredAndTruncated() {
        let d = EDIDBuilder(width: 1920, height: 1080, refresh: 60, name: "Écran-très-long-nom-1234567").build()
        let text = String(decoding: d[95..<108], as: UTF8.self)
        #expect(!text.contains("É"))
        #expect(text.count == 13)
        let exact = EDIDBuilder(width: 1920, height: 1080, refresh: 60, name: "ABCDEFGHIJKLM").build()
        #expect(String(decoding: exact[95..<108], as: UTF8.self) == "ABCDEFGHIJKLM")
    }

    @Test func normalizedRoundsAndClamps() {
        let n = EDIDBuilder.normalized(width: 1917, height: 1081)
        #expect(n.width % 8 == 0 && n.width == 1920)
        #expect(n.height == 1080)
        let small = EDIDBuilder.normalized(width: 100, height: 100)
        #expect(small.width == 640 && small.height == 480)
    }

    @Test func rangeLimitsDescriptorPresent() {
        let d = EDIDBuilder(width: 1920, height: 1080, refresh: 60, name: "x").build()
        #expect(Array(d[72..<77]) == [0, 0, 0, 0xFD, 0])
        #expect(d[77] == 55 && d[78] == 130)
    }

    @Test func physicalSizeIsClamped() {
        let d = EDIDBuilder(width: 4000, height: 2000, refresh: 30, name: "x").build()
        #expect(d[21] > 0 && d[22] > 0)
        let tiny = EDIDBuilder(width: 640, height: 480, refresh: 60, name: "x").build()
        #expect(tiny[21] >= 1 && tiny[22] >= 1)
    }

    @Test func pixelClockGrowsWithRefresh() {
        let a = EDIDBuilder(width: 3456, height: 2234, refresh: 30, name: "x").timing.pixelClockMHz
        let b = EDIDBuilder(width: 3456, height: 2234, refresh: 60, name: "x").timing.pixelClockMHz
        #expect(b > a)
        #expect(a < 300 && b > 300)
    }
}

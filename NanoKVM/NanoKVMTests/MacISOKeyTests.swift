import Testing
@testable import NanoKVM

struct ISOUsageTests {
    @Test func swapsGraveAndNonUSBackslash() {
        #expect(swappedISOUsage(0x35) == 0x64)
        #expect(swappedISOUsage(0x64) == 0x35)
        #expect(swappedISOUsage(4) == 4)
    }

    #if os(macOS)
    @Test func isoSwapsSectionAndGrave() {
        #expect(macHIDUsage(keyCode: 10, isISO: true) == 53)
        #expect(macHIDUsage(keyCode: 50, isISO: true) == 100)
        #expect(macHIDUsage(keyCode: 10, isISO: false) == 100)
        #expect(macHIDUsage(keyCode: 50, isISO: false) == 53)
        #expect(macHIDUsage(keyCode: 0, isISO: true) == 4)
    }

    @Test func hugeKeyboardTypeDoesNotCrash() {
        #expect(macKeyboardTypeIsISO(Int64(Int16.max) + 1) == false)
        #expect(macKeyboardTypeIsISO(-70000) == false)
        _ = macKeyboardTypeIsISO(41)
        _ = macKeyboardTypeIsISO(0)
    }
    #endif
}

import Foundation
import Testing
@testable import NanoKVM

@Suite(.serialized)
struct ScreenshotModeTests {
    private let key = "screenshots-host"

    @Test func inactiveWithoutLaunchArgument() {
        UserDefaults.standard.removeObject(forKey: key)
        #expect(ScreenshotMode.host == nil)
        #expect(ScreenshotMode.device == nil)
        #expect(ScreenshotMode.password(for: ScreenshotMode.deviceID) == nil)
        #expect(!ScreenshotMode.forcesFlag("externalPower", ScreenshotMode.deviceID))
    }

    @Test func providesTheDemoDeviceAndPasswordOnlyForIt() {
        UserDefaults.standard.set("127.0.0.1:8443", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(ScreenshotMode.device?.host == "127.0.0.1:8443")
        #expect(ScreenshotMode.device?.id == ScreenshotMode.deviceID)
        #expect(ScreenshotMode.password(for: ScreenshotMode.deviceID) == ScreenshotMode.password)
        #expect(ScreenshotMode.password(for: UUID()) == nil)
        #expect(ScreenshotMode.forcesFlag("externalPower", ScreenshotMode.deviceID))
        #expect(!ScreenshotMode.forcesFlag("externalPower", UUID()))
        #expect(!ScreenshotMode.forcesFlag("other", ScreenshotMode.deviceID))
    }

    @Test func pinnedHostIgnoresThePort() {
        #expect(PinnedHostDelegate(host: "127.0.0.1:8443").hostWithoutPort == "127.0.0.1")
        #expect(PinnedHostDelegate(host: "kvm.local").hostWithoutPort == "kvm.local")
        #expect(PinnedHostDelegate(host: "fe80::1").hostWithoutPort == "fe80::1")
    }
}

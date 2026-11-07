import Foundation
import SwiftUI
import Testing
@testable import NanoKVM

@MainActor
struct EDIDControllerTests {
    let server = MockServer()
    /// The controller holds its session unowned, so keep sessions alive for the whole run.
    private nonisolated(unsafe) static var keep: [DeviceSession] = []

    private func make() -> (DeviceSession, EDIDController) {
        let device = SavedDevice(name: "T", host: server.host, username: "admin")
        let session = DeviceSession(device: device, makeClient: { MockServer.client(host: $0) }, passwordProvider: { _ in "pw" })
        Self.keep.append(session)
        let c = session.edidController
        c.tick = .milliseconds(1)
        return (session, c)
    }

    private func cleanFlags(_ id: UUID) {
        for name in ["externalPower", "autoEDID"] {
            UserDefaults.standard.removeObject(forKey: "\(name).\(id.uuidString)")
            NSUbiquitousKeyValueStore.default.removeObject(forKey: "\(name).\(id.uuidString)")
        }
    }

    @Test func fileNamesAndClientName() {
        let (_, c) = make()
        c.displayProvider = { .fallback }
        c.refreshDisplay()
        #expect(c.fileName(usePoints: true) == "\(c.clientName).bin")
        #expect(c.fileName(usePoints: false) == "\(c.clientName)_HiDPI.bin")
        #expect(!c.clientName.isEmpty)
        #expect(c.clientName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    @Test func nativeSizeIsLandscapeAndScales() {
        let (_, c) = make()
        let px = c.nativeSize(usePoints: false)
        let pt = c.nativeSize(usePoints: true)
        #expect(px.width >= px.height && pt.width >= pt.height)
        #expect(px.width >= pt.width)
    }

    private func screen(_ tag: String, _ w: CGFloat, _ h: CGFloat, scale: CGFloat = 2) -> DisplayInfo {
        DisplayInfo(tag: tag, label: tag.isEmpty ? "Built-in" : tag, points: .init(width: w, height: h), pixels: .init(width: w * scale, height: h * scale))
    }

    @Test func displaySizeIsLandscape() {
        let d = screen("", 800, 1200)
        #expect(d.size(usePoints: true) == CGSize(width: 1200, height: 800))
        #expect(d.size(usePoints: false) == CGSize(width: 2400, height: 1600))
    }

    @Test func screenChangeUpdatesSizeAndFileName() {
        let (_, c) = make()
        var current = screen("", 1512, 982)
        c.displayProvider = { current }
        #expect(c.refreshDisplay())
        #expect(!c.refreshDisplay())
        let builtIn = c.fileName(usePoints: false)
        #expect(!builtIn.contains("DELL"))
        current = screen("DELL-U2720Q", 2560, 1440)
        #expect(c.refreshDisplay())
        #expect(c.nativeSize(usePoints: true) == CGSize(width: 2560, height: 1440))
        #expect(c.fileName(usePoints: true) == "\(c.clientName)_DELL-U2720Q.bin")
        #expect(c.fileName(usePoints: false) == "\(c.clientName)_DELL-U2720Q_HiDPI.bin")
        #expect(c.fileName(usePoints: false) != builtIn)
    }

    @Test func monitoringReactsToNotificationOnlyWhenAutoSwitchIsOn() async {
        let (s, c) = make()
        let id = s.device.id
        defer { cleanFlags(id) }
        var current = screen("", 1512, 982)
        c.displayProvider = { current }
        c.displayDebounce = .milliseconds(1)
        c.startMonitoring()
        c.startMonitoring()
        current = screen("EXT", 2560, 1440)
        c.displayMayHaveChanged()
        #expect(c.display.tag == "EXT")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(server.requests.isEmpty)
        c.stopMonitoring()
    }

    @Test func autoSwitchRematchesAfterScreenChange() async {
        let (s, c) = make()
        let id = s.device.id
        defer { cleanFlags(id) }
        PowerConfirmation.set(true, for: id)
        SyncedFlag.set(true, "autoEDID", id)
        server.lenient = true
        var current = screen("", 1512, 982)
        c.displayProvider = { current }
        c.displayDebounce = .milliseconds(1)
        c.refreshDisplay()
        current = screen("EXT", 2560, 1440)
        c.displayMayHaveChanged()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.contains { $0.path.contains("edid") })
    }

    @Test func preferencesPersist() {
        let (_, c) = make()
        let oldPoints = c.usePoints, oldHz = c.hz
        defer { c.usePoints = oldPoints; c.hz = oldHz }
        c.usePoints = true; c.hz = 45
        #expect(c.usePoints && c.hz == 45)
        c.usePoints = false
        #expect(!c.usePoints)
    }

    @Test func flagsReflectSyncedValues() {
        let (s, c) = make()
        defer { cleanFlags(s.device.id) }
        #expect(!c.powerConfirmed && !c.autoSwitch)
        PowerConfirmation.set(true, for: s.device.id)
        SyncedFlag.set(true, "autoEDID", s.device.id)
        #expect(c.powerConfirmed && c.autoSwitch)
    }

    @Test func waitForSignalTimesOutWithoutStream() async {
        let (_, c) = make()
        #expect(await c.waitForSignal(timeout: 10) == false)
        #expect(c.status == "Waiting for signal… 10 s")
    }

    @Test func switchToSameEDIDDoesNothing() async {
        let (_, c) = make()
        server.on("GET /vm/edid", data: ["edid": "same.bin", "width": 1, "height": 1])
        await c.switchTo("same.bin")
        #expect(server.last("POST /vm/edid") == nil)
        #expect(c.error == nil)
    }

    @Test func switchToReportsServerError() async {
        let (_, c) = make()
        server.on("GET /vm/edid", data: ["edid": "old.bin", "width": 1, "height": 1])
        server.on("POST /vm/edid", code: -1, msg: "denied")
        await c.switchTo("new.bin")
        #expect(c.error?.contains("denied") == true)
        #expect(c.status == nil)
    }

    @Test func switchToRestoresPreviousWhenNoSignal() async {
        let (_, c) = make()
        server.on("GET /vm/edid", data: ["edid": "old.bin", "width": 1, "height": 1])
        server.on("POST /vm/edid")
        await c.switchTo("new.bin")
        let posts = server.requests(to: "POST /vm/edid").map { $0.json["edid"] as? String }
        #expect(posts == ["new.bin", "old.bin"])
        #expect(KVMLog.store.contents().contains("EDID switch old.bin -> new.bin"))
        #expect(c.error == "No signal. Check the HDMI cable and the KVM's power.")
    }

    @Test func switchToWithoutPreviousSkipsRestore() async {
        let (_, c) = make()
        server.on("GET /vm/edid", code: -1, msg: "unavailable")
        server.on("POST /vm/edid")
        await c.switchTo("new.bin")
        #expect(server.requests(to: "POST /vm/edid").count == 1)
    }

    @Test func matchRejectsExcessivePixelClock() async {
        let (_, c) = make()
        await c.match(usePoints: false, hz: 240)
        #expect(c.error?.contains("MHz") == true)
        #expect(server.last("POST /vm/edid/upload") == nil)
    }

    @Test func matchUploadsAndRemovesOtherVariant() async {
        let (_, c) = make()
        let name = c.fileName(usePoints: true)
        let other = c.fileName(usePoints: false)
        server.on("POST /vm/edid/upload")
        server.on("GET /vm/edid", data: ["edid": name, "width": 1, "height": 1])
        server.on("GET /vm/edid/custom", data: ["edidList": [name, other]])
        server.on("POST /vm/edid/delete")
        await c.match(usePoints: true, hz: 30)
        let upload = server.last("POST /vm/edid/upload")
        #expect(upload?.text.contains("filename=\"\(name)\"") == true)
        #expect(server.last("POST /vm/edid/delete")?.json["edid"] as? String == other)
    }

    @Test func matchReportsUploadFailure() async {
        let (_, c) = make()
        server.on("POST /vm/edid/upload", code: -1, msg: "power")
        await c.match(usePoints: true, hz: 30)
        #expect(c.error?.contains("power") == true)
    }

    @Test func autoSwitchRequiresFlagsAndRunsOnce() async {
        let (s, c) = make()
        defer { cleanFlags(s.device.id) }
        server.on("GET /vm/edid", data: ["edid": "other.bin", "width": 1, "height": 1])
        await c.autoSwitchIfNeeded()
        #expect(server.requests.isEmpty)
        SyncedFlag.set(true, "autoEDID", s.device.id)
        await c.autoSwitchIfNeeded()
        #expect(server.requests.isEmpty)
    }

    @Test func autoSwitchUsesExistingEDID() async {
        let (s, c) = make()
        defer { cleanFlags(s.device.id) }
        PowerConfirmation.set(true, for: s.device.id)
        SyncedFlag.set(true, "autoEDID", s.device.id)
        let name = c.fileName(usePoints: c.usePoints)
        server.on("GET /vm/edid", data: ["edid": "other.bin", "width": 1, "height": 1])
        server.on("GET /vm/edid/custom", data: ["edidList": [name]])
        server.on("POST /vm/edid")
        await c.autoSwitchIfNeeded()
        #expect(server.requests(to: "POST /vm/edid").first?.json["edid"] as? String == name)
        let count = server.requests.count
        await c.autoSwitchIfNeeded()
        #expect(server.requests.count == count)
    }

    @Test func autoSwitchCreatesMissingEDID() async {
        let (s, c) = make()
        defer { cleanFlags(s.device.id) }
        PowerConfirmation.set(true, for: s.device.id)
        SyncedFlag.set(true, "autoEDID", s.device.id)
        c.hz = 30
        server.on("GET /vm/edid", data: ["edid": "other.bin", "width": 1, "height": 1])
        server.on("GET /vm/edid/custom", data: ["edidList": ["x.bin"]])
        server.on("POST /vm/edid/upload")
        server.on("POST /vm/edid")
        await c.autoSwitchIfNeeded()
        #expect(server.last("POST /vm/edid/upload") != nil)
    }

    @Test func autoSwitchSkipsWhenAlreadyActive() async {
        let (s, c) = make()
        defer { cleanFlags(s.device.id) }
        PowerConfirmation.set(true, for: s.device.id)
        SyncedFlag.set(true, "autoEDID", s.device.id)
        let name = c.fileName(usePoints: c.usePoints)
        server.on("GET /vm/edid", data: ["edid": name, "width": 1, "height": 1])
        await c.autoSwitchIfNeeded()
        #expect(server.last("POST /vm/edid") == nil)
    }
}

@MainActor
struct PageKitTests {
    @Test func runSucceeds() async {
        let p = PageState()
        await p.run { }
        #expect(p.error == nil && !p.busy)
    }

    @Test func runCapturesErrorAndClearsItOnSuccess() async {
        let p = PageState()
        await p.run { throw KVMError.message("bad") }
        #expect(p.error == "bad" && !p.busy)
        await p.run { }
        #expect(p.error == nil)
    }

    @Test func clipboardRoundTrip() {
        let text = "nanokvm-test-\(UUID().uuidString)"
        copyToClipboard(text)
        #if os(macOS)
        #expect(NSPasteboard.general.string(forType: .string) == text)
        #else
        #expect(UIPasteboard.general.string == text)
        #endif
    }
}

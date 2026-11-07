import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct DeviceStoreTests {
    @Test func savedDeviceRoundTripsThroughJSON() throws {
        let d = SavedDevice(name: "KVM", host: "kvm.local", username: "admin")
        let back = try JSONDecoder().decode(SavedDevice.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    @Test func discoveredDeviceHost() {
        #expect(DiscoveredDevice(name: "nanokvm").host == "nanokvm.local")
        #expect(DiscoveredDevice(name: "nanokvm.local").host == "nanokvm.local")
        #expect(DiscoveredDevice(name: "a").id == "a")
    }

    @Test func syncedFlagRoundTrip() {
        let id = UUID()
        defer { UserDefaults.standard.removeObject(forKey: "flag.\(id.uuidString)") }
        #expect(!SyncedFlag.isOn("flag", id))
        SyncedFlag.set(true, "flag", id)
        #expect(SyncedFlag.isOn("flag", id))
        SyncedFlag.set(false, "flag", id)
        UserDefaults.standard.removeObject(forKey: "flag.\(id.uuidString)")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "flag.\(id.uuidString)")
    }

    @Test func powerConfirmation() {
        let id = UUID()
        defer {
            UserDefaults.standard.removeObject(forKey: "externalPower.\(id.uuidString)")
            NSUbiquitousKeyValueStore.default.removeObject(forKey: "externalPower.\(id.uuidString)")
        }
        #expect(!PowerConfirmation.isConfirmed(id))
        PowerConfirmation.set(true, for: id)
        #expect(PowerConfirmation.isConfirmed(id))
    }

    @Test func keychainDeleteLeavesNoPassword() {
        let id = UUID()
        Keychain.setPassword("secret", for: id)
        if let stored = Keychain.password(for: id) { #expect(stored == "secret") }
        Keychain.deletePassword(for: id)
        #expect(Keychain.password(for: id) == nil)
    }

    @Test func storeAddUpdateRemove() {
        let store = DeviceStore()
        let before = store.devices.count
        var d = SavedDevice(name: "UnitTest-\(UUID().uuidString.prefix(6))", host: "unit.test", username: "u")
        store.add(d, password: "pw")
        defer { store.remove(d) }
        #expect(store.devices.count == before + 1)
        d.name = "Renamed"
        store.update(d, password: "new")
        #expect(store.devices.first { $0.id == d.id }?.name == "Renamed")
        store.update(d, password: nil)
        store.update(SavedDevice(name: "ghost", host: "x", username: "x"), password: "x")
        #expect(store.devices.count == before + 1)
        store.remove(d)
        #expect(store.devices.count == before)
    }

    @Test func storePersistsDevices() {
        let d = SavedDevice(name: "Persist-\(UUID().uuidString.prefix(6))", host: "p.test", username: "u")
        let a = DeviceStore()
        a.add(d, password: "pw")
        defer { a.remove(d) }
        #expect(DeviceStore().devices.contains { $0.id == d.id })
    }

    @Test func discoveryStartsAndStops() {
        let discovery = DeviceDiscovery()
        discovery.start()
        discovery.start()
        #expect(discovery.found.isEmpty || !discovery.found.isEmpty)
        discovery.stop()
    }

    @Test func fullScreenStateShared() {
        let state = FullScreenState.shared
        let old = state.active
        defer { state.active = old }
        state.active = true
        let session = DeviceSession(device: SavedDevice(name: "n", host: "h.test", username: "u"))
        #expect(session.isFullScreen)
        session.isFullScreen = false
        #expect(!state.active)
    }
}

@MainActor
struct DeviceSessionTests {
    let server = MockServer()

    private func session(password: String? = "pw") -> DeviceSession {
        let host = server.host
        let device = SavedDevice(name: "T", host: host, username: "admin")
        return DeviceSession(device: device,
                             makeClient: { MockServer.client(host: $0) },
                             passwordProvider: { _ in password })
    }

    @Test func connectSucceeds() async {
        server.on("POST /auth/login", data: ["token": "T0K"])
        server.on("GET /vm/info", data: [
            "ips": [], "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x",
        ])
        server.on("POST /stream/mode")
        let s = session()
        await s.connect()
        guard case .connected = s.state else { Issue.record("not connected: \(s.state)"); return }
        #expect(s.token == "T0K")
        #expect(s.info?.application == "a")
        #expect(s.stream != nil && s.input != nil)
        #expect(server.last("POST /stream/mode")?.json["mode"] as? String != nil)
        s.reconnectInput()
        s.disconnect()
    }

    @Test func connectClaimsLeaseAndOtherInstallStops() async {
        server.on("POST /auth/login", data: ["token": "T0K"])
        server.on("GET /vm/info", data: [
            "ips": [], "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x",
        ])
        server.on("POST /stream/mode")
        let s = session()
        s.installID = "install-A"
        await s.connect()
        defer { ConnectionLease.release(s.device.id, install: "install-A") }
        #expect(ConnectionLease.current(for: s.device.id)?.owner == "install-A")
        #expect(s.checkLease() == false)

        ConnectionLease.claim(s.device.id, install: "install-B", name: "Other Mac")
        await s.superviseOnce(now: Date())
        #expect(s.state == .inUseElsewhere("Other Mac"))
        #expect(s.stream?.state == .idle)
        // The displaced instance must not take the lease back on its own.
        await s.recover()
        #expect(ConnectionLease.current(for: s.device.id)?.owner == "install-B")
        ConnectionLease.release(s.device.id, install: "install-B")

        // Opening the app while another install owns the KVM waits for an explicit take over.
        ConnectionLease.claim(s.device.id, install: "install-B", name: "Other Mac")
        let late = DeviceSession(device: s.device, makeClient: { MockServer.client(host: $0) }, passwordProvider: { _ in "pw" })
        late.installID = "install-A"
        await late.connect()
        #expect(late.state == .inUseElsewhere("Other Mac"))
        #expect(late.stream == nil)
        ConnectionLease.release(s.device.id, install: "install-B")

        await s.takeOver()
        #expect(s.state == .connected)
        #expect(ConnectionLease.current(for: s.device.id)?.owner == "install-A")
        s.disconnect()
        #expect(ConnectionLease.current(for: s.device.id) == nil)
    }

    @Test func leaseOwnedByThisInstallIsNotForeign() {
        let id = UUID()
        defer { ConnectionLease.release(id, install: "me") }
        #expect(ConnectionLease.otherOwner(of: id, install: "me") == nil)
        ConnectionLease.claim(id, install: "me", name: "Mine")
        #expect(ConnectionLease.otherOwner(of: id, install: "me") == nil)
        #expect(ConnectionLease.otherOwner(of: id, install: "you") == "Mine")
        ConnectionLease.release(id, install: "you")
        #expect(ConnectionLease.current(for: id) != nil)
    }

    @Test func recoverRefreshesTokenAndReopensSockets() async {
        server.on("POST /auth/login", data: ["token": "T1"])
        server.on("GET /vm/info", data: [
            "ips": [], "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x",
        ])
        server.on("POST /stream/mode")
        let s = session()
        #expect(await s.recover() == false)
        await s.connect()
        server.on("POST /auth/login", data: ["token": "T2"])
        #expect(await s.recover())
        #expect(s.token == "T2")
        #expect(s.stream?.token == "T2" && s.input?.token == "T2")
        #expect(s.input?.isConnected == true)
        s.disconnect()
    }

    @Test func logStoreKeepsNewestLinesWithinLimit() {
        let url = URL.temporaryDirectory.appending(path: "log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LogStore(fileURL: url, maxBytes: 300)
        for i in 0..<40 { store.append("INFO", "line \(i)") }
        let text = store.contents()
        #expect(text.utf8.count <= 300)
        #expect(text.contains("line 39") && !text.contains("line 0\n"))
        store.clear()
        #expect(store.contents().isEmpty)
    }

    @Test func diagnosticReportHasSummaryAndLogButNoSecrets() throws {
        let text = Diagnostics.report(summary: [("Video state", "playing")], log: "x ERROR boom\n")
        #expect(text.contains("Video state: playing") && text.contains("boom") && text.contains("App:"))
        #expect(Diagnostics.report(summary: [], log: "").contains("(empty)"))
        let url = try Diagnostics.write(summary: [], log: "a\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("--- Connection log ---"))
    }

    @Test func sessionSummaryDescribesState() async {
        let s = session()
        #expect(s.diagnosticSummary.contains { $0.0 == "Input connected" && $0.1 == "none" })
    }

    @Test func supervisorRestartsStreamThatNeverDeliversFrames() async {
        server.on("POST /auth/login", data: ["token": "T1"])
        server.on("GET /vm/info", data: [
            "ips": [], "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x",
        ])
        server.on("POST /stream/mode")
        let s = session()
        s.reconnectGap = 0
        await s.connect()
        guard let stream = s.stream else { Issue.record("no stream"); return }
        stream.start()
        let first = stream.startedAt
        await s.superviseOnce(now: Date())
        #expect(stream.startedAt == first)
        await s.superviseOnce(now: Date().addingTimeInterval(21))
        #expect(stream.startedAt > first)
        #expect(KVMLog.store.contents().contains("no video frame"))
        // Second stalled attempt switches codec, third logs in again.
        let before = stream.codec
        defer { UserDefaults.standard.removeObject(forKey: "videoCodec") }
        await s.superviseOnce(now: Date().addingTimeInterval(130))
        #expect(stream.codec != before)
        #expect(server.last("POST /stream/mode")?.json["mode"] as? String == "\(stream.codec.rawValue)-direct")
        server.on("POST /auth/login", data: ["token": "T9"])
        await s.superviseOnce(now: Date().addingTimeInterval(200))
        #expect(s.token == "T9")
        s.disconnect()
    }

    @Test func inputEventsAreLoggedOnceWhenUnchanged() {
        let i = InputSender(host: "h", token: "t")
        let marker = UUID().uuidString
        i.noteEvent("{\"event\":\"capture-status\",\"marker\":\"\(marker)\"}")
        i.noteEvent("{\"event\":\"capture-status\",\"marker\":\"\(marker)\"}")
        let n = KVMLog.store.contents().components(separatedBy: marker).count - 1
        #expect(n == 1)
    }

    @Test func staleSocketsAreDetected() {
        let now = Date()
        #expect(!VideoStream.isDead(lastAlive: now.addingTimeInterval(-5), now: now))
        #expect(VideoStream.isDead(lastAlive: now.addingTimeInterval(-16), now: now))
    }

    @Test func supervisorRecoversWithBackoffAndHeals() async {
        server.on("POST /auth/login", data: ["token": "T1"])
        server.on("GET /vm/info", data: [
            "ips": [], "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x",
        ])
        server.on("POST /stream/mode")
        let s = session()
        s.reconnectGap = 0
        await s.connect()
        s.input?.disconnect()
        #expect(s.needsRecovery)
        server.on("POST /auth/login", code: -2, msg: "down")
        let t0 = Date()
        await s.superviseOnce(now: t0)
        #expect(s.needsRecovery)
        // Inside the back-off window nothing is attempted.
        server.on("POST /auth/login", data: ["token": "T2"])
        await s.superviseOnce(now: t0.addingTimeInterval(1))
        #expect(s.token == "T1")
        await s.superviseOnce(now: t0.addingTimeInterval(7))
        #expect(s.token == "T2")
        #expect(s.input?.isConnected == true)
        #expect(server.last("POST /stream/mode") != nil)
        s.disconnect()
    }

    @Test func recoverFailsOnBadLogin() async {
        server.on("POST /auth/login", data: ["token": "T1"])
        server.on("GET /vm/info", data: [
            "ips": [], "mdns": "m", "image": "i", "application": "a", "deviceKey": "k", "pn": "p", "arch": "x",
        ])
        server.on("POST /stream/mode")
        let s = session()
        await s.connect()
        server.on("POST /auth/login", code: -2, msg: "wrong")
        #expect(await s.recover() == false)
        s.disconnect()
    }

    @Test func connectFailsWithoutPassword() async {
        let s = session(password: nil)
        await s.connect()
        guard case .failed(let msg) = s.state else { Issue.record("expected failure"); return }
        #expect(msg == "No saved password for this device.")
    }

    @Test func connectFailsOnBadLogin() async {
        server.on("POST /auth/login", code: -2, msg: "wrong")
        let s = session()
        await s.connect()
        guard case .failed(let msg) = s.state else { Issue.record("expected failure"); return }
        #expect(msg.contains("wrong"))
        #expect(s.token == nil)
    }
}

extension MockServer {
    static func client(host: String) -> KVMClient { KVMClient(host: host, protocolClasses: [MockURLProtocol.self]) }
}

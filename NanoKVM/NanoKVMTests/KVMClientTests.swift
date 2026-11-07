import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct KVMClientTests {
    let server = MockServer()

    private func loggedIn() async throws -> KVMClient {
        server.on("POST /auth/login", data: ["token": "tok123"])
        let c = server.client()
        try await c.login(username: "admin", password: "pw")
        return c
    }

    @Test func urlBuilder() {
        let c = KVMClient(host: "10.0.0.5")
        #expect(c.url("/vm/info").absoluteString == "https://10.0.0.5/api/vm/info")
        #expect(c.currentToken == nil)
    }

    @Test func loginStoresTokenAndSendsCredentials() async throws {
        let c = try await loggedIn()
        #expect(c.currentToken == "tok123")
        let req = try #require(server.last("POST /auth/login"))
        #expect(req.json["username"] as? String == "admin")
        #expect(req.json["password"] as? String == "pw")
        #expect(req.headers["Origin"] == "https://\(server.host)")
        #expect(req.headers["Referer"] == "https://\(server.host)/")
        #expect(req.headers["Cookie"] == nil)
    }

    @Test func authenticatedRequestsCarryCookie() async throws {
        let c = try await loggedIn()
        server.on("GET /vm/hostname", data: ["hostname": "kvm-1"])
        #expect(try await c.hostname() == "kvm-1")
        #expect(server.last("GET /vm/hostname")?.headers["Cookie"] == "nano-kvm-token=tok123")
    }

    @Test func serverErrorIsThrown() async {
        server.on("POST /auth/login", data: [String: Any](), code: -2, msg: "bad password")
        await #expect(throws: KVMError.self) { try await server.client().login(username: "a", password: "b") }
        do { try await server.client().login(username: "a", password: "b") } catch {
            #expect(error.localizedDescription == "Device error -2: bad password")
        }
    }

    @Test func missingDataIsInvalidResponse() async {
        server.onRaw("GET /vm/info", MockServer.envelope(code: 0, msg: "ok", data: nil))
        do { _ = try await server.client().info(); Issue.record("expected failure") } catch let e as KVMError {
            #expect(e.localizedDescription == "Invalid response from device")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func malformedBodyThrows() async {
        server.onRaw("GET /vm/info", Data("<html>".utf8))
        await #expect(throws: (any Error).self) { try await server.client().info() }
    }

    @Test func errorDescriptions() {
        #expect(KVMError.message("x").localizedDescription == "x")
        #expect(KVMError.server(3, "m").localizedDescription == "Device error 3: m")
        #expect(KVMError.invalidResponse.localizedDescription == "Invalid response from device")
    }

    @Test func typedGetters() async throws {
        server.on("GET /vm/info", data: [
            "ips": [["name": "wlan0", "addr": "10.0.0.2", "version": "IPv4", "type": "Wireless"]],
            "mdns": "kvm.local", "image": "v1", "application": "0.2", "deviceKey": "k", "pn": "p", "arch": "riscv",
        ])
        server.on("GET /stream/encoder", data: ["rate_control": "cbr", "bitrate": 8000, "gop": 30, "fps": 30])
        server.on("GET /network/wifi", data: ["supported": true, "connected": true, "wifi": ["ssid": "Home", "security": "SAE"]])
        server.on("GET /vm/edid", data: ["edid": "x.bin", "width": 1920, "height": 1080])
        let c = server.client()
        let info = try await c.info()
        #expect(info.ips.first?.id == "10.0.0.2")
        #expect(info.mdns == "kvm.local")
        let enc = try await c.encoder()
        #expect(enc.bitrate == 8000 && enc.gop == 30 && enc.fps == 30 && enc.rate_control == "cbr")
        let wifi = try await c.wifi()
        #expect(wifi.connected && wifi.wifi?.ssid == "Home")
        let edid = try await c.edid()
        #expect(edid.width == 1920 && edid.edid == "x.bin")
    }

    @Test func commandsSendExpectedRequests() async throws {
        server.lenient = true
        let c = server.client()
        try await c.pasteText("hello")
        #expect(server.last("POST /hid/paste")?.json["content"] as? String == "hello")
        try await c.resetHID()
        #expect(server.last("POST /hid/reset") != nil)
        try await c.setPointerMode("relative")
        #expect(server.last("POST /hid/pointer-mode")?.json["mode"] as? String == "relative")
        try await c.setJiggler(enabled: true, mode: "absolute")
        #expect(server.last("POST /vm/mouse-jiggler")?.json["enabled"] as? Bool == true)
        try await c.setRateControl("vbr")
        #expect(server.last("POST /stream/rate-control")?.json["mode"] as? String == "vbr")
        try await c.setBitrate(4000)
        #expect(server.last("POST /stream/quality")?.json["quality"] as? Int == 4000)
        try await c.setGOP(60)
        #expect(server.last("POST /stream/gop")?.json["gop"] as? Int == 60)
        try await c.setStreamMode("h265-direct")
        #expect(server.last("POST /stream/mode")?.json["mode"] as? String == "h265-direct")
        try await c.setFPS(15)
        #expect(server.last("POST /stream/fps")?.json["fps"] as? Int == 15)
        try await c.setEDID("a.bin")
        #expect(server.last("POST /vm/edid")?.json["edid"] as? String == "a.bin")
        try await c.deleteEDID("a.bin")
        #expect(server.last("POST /vm/edid/delete")?.json["edid"] as? String == "a.bin")
        try await c.setHDMICapture(false)
        #expect(server.last("POST /vm/hdmi/capture")?.json["enabled"] as? Bool == false)
        try await c.mount(file: "x.iso", cdrom: true, readOnly: false)
        let m = try #require(server.last("POST /storage/image/mount")?.json)
        #expect(m["file"] as? String == "x.iso" && m["cdrom"] as? Bool == true && m["readOnly"] as? Bool == false)
        try await c.deleteImage("x.iso")
        #expect(server.last("POST /storage/image/delete")?.json["file"] as? String == "x.iso")
        try await c.wake(mac: "AA")
        #expect(server.last("POST /network/wol")?.json["mac"] as? String == "AA")
        try await c.removeWoL(mac: "AA")
        #expect(server.last("DELETE /network/wol/mac")?.json["mac"] as? String == "AA")
        try await c.nameWoL(mac: "AA", name: "PC")
        #expect(server.last("POST /network/wol/mac/name")?.json["name"] as? String == "PC")
        try await c.reboot()
        #expect(server.last("POST /vm/system/reboot") != nil)
        try await c.setSSH(true)
        #expect(server.last("POST /vm/ssh/enable") != nil)
        try await c.setSSH(false)
        #expect(server.last("POST /vm/ssh/disable") != nil)
        try await c.setMDNS(true)
        #expect(server.last("POST /vm/mdns/enable") != nil)
        try await c.setMDNS(false)
        #expect(server.last("POST /vm/mdns/disable") != nil)
    }

    @Test func commandSurfacesServerError() async {
        server.on("POST /hid/reset", code: -5, msg: "nope")
        await #expect(throws: KVMError.self) { try await server.client().resetHID() }
    }

    @Test func simpleGetters() async throws {
        server.on("GET /hid/pointer-mode", data: ["mode": "absolute"])
        server.on("GET /vm/mouse-jiggler", data: ["enabled": true, "mode": "relative"])
        server.on("GET /vm/edid/custom", data: ["edidList": ["a.bin", "b.bin"]])
        server.on("GET /vm/hdmi/capture", data: ["enabled": true])
        server.on("GET /storage/image", data: ["files": ["a.iso"]])
        server.on("GET /storage/image/mounted", data: ["mounted": true, "file": "a.iso", "cdrom": true, "readOnly": true])
        server.on("GET /vm/ssh", data: ["enabled": true])
        server.on("GET /vm/mdns", data: ["enabled": false])
        let c = server.client()
        #expect(try await c.pointerMode() == "absolute")
        let j = try await c.jiggler()
        #expect(j.enabled && j.mode == "relative")
        #expect(try await c.customEDIDs() == ["a.bin", "b.bin"])
        #expect(try await c.hdmiCapture())
        #expect(try await c.images() == ["a.iso"])
        let mounted = try await c.mountedImage()
        #expect(mounted.mounted && mounted.file == "a.iso" && mounted.cdrom && mounted.readOnly)
        #expect(try await c.sshEnabled())
        #expect(try await c.mdnsEnabled() == false)
    }

    @Test func emptyListsDefaultToEmpty() async throws {
        server.on("GET /vm/edid/custom", data: [String: Any]())
        server.on("GET /storage/image", data: [String: Any]())
        server.on("GET /network/wol/mac", data: [String: Any]())
        let c = server.client()
        #expect(try await c.customEDIDs().isEmpty)
        #expect(try await c.images().isEmpty)
        #expect(try await c.wolList().isEmpty)
    }

    @Test func wolListParsesNamesAndSkipsBlanks() async throws {
        server.on("GET /network/wol/mac", data: ["macs": ["AA:BB:CC:DD:EE:FF Desktop PC", "11:22:33:44:55:66", "   "]])
        let list = try await server.client().wolList()
        #expect(list.count == 2)
        #expect(list[0].mac == "AA:BB:CC:DD:EE:FF" && list[0].name == "Desktop PC" && list[0].id == list[0].mac)
        #expect(list[1].name == "")
    }

    @Test func uploadEDIDIsMultipart() async throws {
        server.on("POST /vm/edid/upload")
        try await server.client().uploadEDID(Data([1, 2, 3]), filename: "Mac.bin")
        let req = try #require(server.last("POST /vm/edid/upload"))
        #expect(req.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(req.text.contains("filename=\"Mac.bin\""))
    }

    @Test func uploadEDIDError() async {
        server.on("POST /vm/edid/upload", code: -1, msg: "bad")
        await #expect(throws: KVMError.self) { try await server.client().uploadEDID(Data([1]), filename: "x.bin") }
    }

    @Test func uploadImageSplitsIntoChunks() async throws {
        server.on("POST /storage/image/upload")
        let url = try tempFile(size: 9 * 1024 * 1024)
        let progress = ProgressBox()
        try await server.client().uploadImage(at: url) { progress.values.append($0) }
        let reqs = server.requests(to: "POST /storage/image/upload")
        #expect(reqs.count == 2)
        #expect(reqs[0].query.contains("chunkIndex=0") && reqs[1].query.contains("chunkIndex=1"))
        #expect(reqs[0].query.contains("totalChunks=2") && reqs[0].query.contains("filename=test.iso"))
        #expect(reqs[0].body.count == 8 * 1024 * 1024 && reqs[1].body.count == 1024 * 1024)
        #expect(progress.values == [0.5, 1.0])
    }

    @Test func uploadImageRejectsEmptyFile() async throws {
        let url = try tempFile(size: 0)
        await #expect(throws: KVMError.self) { try await server.client().uploadImage(at: url) { _ in } }
    }

    @Test func uploadImageCancelsOnServerError() async throws {
        server.on("POST /storage/image/upload", code: -1, msg: "disk full")
        server.on("POST /storage/image/upload/cancel")
        let url = try tempFile(size: 1024)
        await #expect(throws: KVMError.self) { try await server.client().uploadImage(at: url) { _ in } }
        #expect(server.last("POST /storage/image/upload/cancel")?.json["uploadId"] is String)
    }
}

final class ProgressBox: @unchecked Sendable { var values: [Double] = [] }

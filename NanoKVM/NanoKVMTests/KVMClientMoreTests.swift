import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct KVMClientMoreTests {
    let server = MockServer()

    @Test func rawReturnsDataDictionary() async throws {
        server.on("GET /x", data: ["a": 1])
        let d = try await server.client().raw("GET", "/x")
        #expect(d.int("a") == 1)
    }

    @Test func rawReturnsEmptyWhenNoData() async throws {
        server.onRaw("POST /x", MockServer.envelope(code: 0, msg: "ok", data: nil))
        #expect(try await server.client().raw("POST", "/x").isEmpty)
    }

    @Test func rawThrowsOnErrorCode() async {
        server.on("GET /x", code: -3, msg: "boom")
        do { _ = try await server.client().get("/x"); Issue.record("expected failure") } catch let e as KVMError {
            #expect(e.localizedDescription == "Device error -3: boom")
        } catch { Issue.record("wrong error") }
    }

    @Test func rawThrowsOnGarbage() async {
        server.onRaw("GET /x", Data("nope".utf8))
        await #expect(throws: (any Error).self) { try await server.client().get("/x") }
    }

    @Test func rawThrowsWhenEnvelopeLacksCode() async {
        server.onRaw("GET /x", Data("{\"hello\":1}".utf8))
        await #expect(throws: KVMError.self) { try await server.client().get("/x") }
    }

    @Test func rawSendsBodyAndHeaders() async throws {
        server.on("POST /x")
        try await server.client().raw("POST", "/x", body: ["k": "v"])
        let r = try #require(server.last("POST /x"))
        #expect(r.json["k"] as? String == "v")
        #expect(r.headers["Content-Type"] == "application/json")
        #expect(r.headers["Origin"] == "https://\(server.host)")
    }

    @Test func rawArrayParsesList() async throws {
        server.on("GET /apps", data: [["id": "a"], ["id": "b"]])
        let list = try await server.client().rawArray("/apps")
        #expect(list.map { $0.str("id") } == ["a", "b"])
    }

    @Test func rawArrayEmptyWhenNotArray() async throws {
        server.on("GET /apps", data: ["x": 1])
        #expect(try await server.client().rawArray("/apps").isEmpty)
    }

    @Test func uploadFileMultipart() async throws {
        server.on("POST /up")
        try await server.client().uploadFile(Data("abc".utf8), filename: "s.sh", to: "/up")
        let r = try #require(server.last("POST /up"))
        #expect(r.text.contains("name=\"file\"; filename=\"s.sh\""))
        #expect(r.text.contains("abc"))
    }

    @Test func uploadFileError() async {
        server.on("POST /up", code: -1, msg: "no")
        await #expect(throws: KVMError.self) { try await server.client().uploadFile(Data(), filename: "a", to: "/up") }
    }

    @Test func wrappersHitTheRightEndpoints() async throws {
        server.lenient = true
        let c = server.client()
        try await c.wifiConnect(ssid: "S", password: "P")
        #expect(server.last("POST /network/wifi/connect")?.json["ssid"] as? String == "S")
        try await c.wifiDisconnect()
        #expect(server.last("POST /network/wifi/disconnect") != nil)
        _ = try await c.tailscaleAction("up")
        #expect(server.last("POST /extensions/tailscale/up") != nil)
        try await c.tailscaleToggle("exit-node", true)
        #expect(server.last("POST /extensions/tailscale/exit-node")?.json["enabled"] as? Bool == true)
        try await c.setHostname("kvm2")
        #expect(server.last("POST /vm/hostname")?.json["hostname"] as? String == "kvm2")
        try await c.setWebTitle("T")
        #expect(server.last("POST /vm/web-title")?.json["title"] as? String == "T")
        try await c.setTimezone("Europe/Paris")
        #expect(server.last("POST /vm/timezone")?.json["timezone"] as? String == "Europe/Paris")
        try await c.syncTime()
        #expect(server.last("POST /vm/time/sync") != nil)
        try await c.setLowPower(true)
        #expect(server.last("POST /vm/low-power")?.json["enable"] as? Bool == true)
        try await c.setSwap(false)
        #expect(server.last("POST /vm/swap")?.json["enable"] as? Bool == false)
        try await c.setHidMode("hid-only")
        #expect(server.last("POST /hid/mode")?.json["mode"] as? String == "hid-only")
        try await c.setPreviewUpdates(true)
        #expect(server.last("POST /application/preview")?.json["enable"] as? Bool == true)
        try await c.updateApplication()
        #expect(server.last("POST /application/update") != nil)
        try await c.setMCP(true)
        #expect(server.last("POST /ai/config")?.json["mcpEnabled"] as? Bool == true)
        try await c.setMemoryFabric(true)
        #expect(server.last("POST /ai/memory-fabric")?.json["enabled"] as? Bool == true)
        try await c.setTimelapse(true)
        #expect(server.last("POST /ai/screen-timelapse/state")?.json["enabled"] as? Bool == true)
        try await c.deleteScript("a.sh")
        #expect(server.last("DELETE /vm/script")?.json["name"] as? String == "a.sh")
        try await c.uploadScript(Data("echo".utf8), filename: "a.sh")
        #expect(server.last("POST /vm/script/upload") != nil)
    }

    @Test func gettersParseData() async throws {
        server.on("GET /network/wifi/scan", data: ["wifiList": [["ssid": "A"], ["ssid": "B"]]])
        server.on("GET /extensions/tailscale/status", data: ["state": "running"])
        server.on("GET /hid/mode", data: ["mode": "hid-only"])
        server.on("GET /application/version", data: ["current": "1", "latest": "2"])
        server.on("GET /ai/services", data: ["memoryMiB": 246])
        server.on("GET /vm/script", data: ["files": ["a.sh"]])
        server.on("POST /ai/mcp/key", data: ["mcpApiKey": "K"])
        server.on("POST /ai/mcp/key/regenerate", data: ["mcpApiKey": "K2"])
        server.on("POST /vm/script/run", data: ["log": "done"])
        let c = server.client()
        #expect(try await c.wifiScan().count == 2)
        #expect(try await c.tailscale().str("state") == "running")
        #expect(try await c.hidMode() == "hid-only")
        #expect(try await c.appVersion().str("latest") == "2")
        #expect(try await c.aiServices().int("memoryMiB") == 246)
        #expect(try await c.scripts() == ["a.sh"])
        #expect(try await c.mcpKey() == "K")
        #expect(try await c.regenerateMCPKey() == "K2")
        #expect(try await c.runScript("a.sh", background: false) == "done")
        #expect(server.last("POST /vm/script/run")?.json["type"] as? String == "foreground")
        _ = try await c.runScript("a.sh", background: true)
        #expect(server.last("POST /vm/script/run")?.json["type"] as? String == "background")
    }

    @Test func gettersDefaultWhenFieldsMissing() async throws {
        server.on("GET /network/wifi/scan")
        server.on("GET /hid/mode")
        server.on("GET /vm/script")
        server.on("POST /ai/mcp/key")
        server.on("POST /ai/mcp/key/regenerate")
        server.on("POST /vm/script/run")
        let c = server.client()
        #expect(try await c.wifiScan().isEmpty)
        #expect(try await c.hidMode() == "normal")
        #expect(try await c.scripts().isEmpty)
        #expect(try await c.mcpKey() == "")
        #expect(try await c.regenerateMCPKey() == "")
        #expect(try await c.runScript("x", background: false) == "")
    }

    @Test func dictionaryHelpers() {
        let d: JSON = ["s": "x", "b": true, "i": 4]
        #expect(d.str("s") == "x" && d.str("none") == "")
        #expect(d.bool("b") && !d.bool("none"))
        #expect(d.int("i") == 4 && d.int("none") == 0)
    }
}

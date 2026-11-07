import Foundation

typealias JSON = [String: Any]

extension KVMClient {
    /// Loosely typed request: returns the envelope's `data` as a dictionary (empty when absent).
    @discardableResult
    func raw(_ method: String, _ path: String, body: JSON? = nil, timeout: TimeInterval = 10) async throws -> JSON {
        var req = URLRequest(url: url(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let token = currentToken { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await session.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? JSON, let code = obj["code"] as? Int else {
            throw KVMError.invalidResponse
        }
        guard code == 0 else { throw KVMError.server(code, obj["msg"] as? String ?? "") }
        return obj["data"] as? JSON ?? [:]
    }

    func get(_ path: String) async throws -> JSON { try await raw("GET", path) }

    func uploadFile(_ data: Data, filename: String, to path: String) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url(path), timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let token = currentToken { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
        let (resp, _) = try await session.upload(for: req, from: body)
        let env = try JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: resp)
        guard env.code == 0 else { throw KVMError.server(env.code, env.msg) }
    }

    // MARK: Network
    func wifiScan() async throws -> [JSON] { try await get("/network/wifi/scan")["wifiList"] as? [JSON] ?? [] }
    func wifiConnect(ssid: String, password: String) async throws {
        try await raw("POST", "/network/wifi/connect", body: ["ssid": ssid, "password": password], timeout: 60)
    }
    func wifiDisconnect() async throws { try await raw("POST", "/network/wifi/disconnect") }
    func tailscale() async throws -> JSON { try await get("/extensions/tailscale/status") }
    func tailscaleAction(_ action: String) async throws -> JSON {
        try await raw("POST", "/extensions/tailscale/\(action)", timeout: 60)
    }
    func tailscaleToggle(_ what: String, _ enabled: Bool) async throws {
        try await raw("POST", "/extensions/tailscale/\(what)", body: ["enabled": enabled])
    }
    func setHostname(_ name: String) async throws { try await raw("POST", "/vm/hostname", body: ["hostname": name]) }

    // MARK: Device
    func setWebTitle(_ title: String) async throws { try await raw("POST", "/vm/web-title", body: ["title": title]) }
    func setTimezone(_ tz: String) async throws { try await raw("POST", "/vm/timezone", body: ["timezone": tz]) }
    func syncTime() async throws { try await raw("POST", "/vm/time/sync", timeout: 30) }
    func setLowPower(_ on: Bool) async throws { try await raw("POST", "/vm/low-power", body: ["enable": on]) }
    func setSwap(_ on: Bool) async throws { try await raw("POST", "/vm/swap", body: ["enable": on], timeout: 60) }
    func hidMode() async throws -> String { try await get("/hid/mode")["mode"] as? String ?? "normal" }
    func setHidMode(_ mode: String) async throws { try await raw("POST", "/hid/mode", body: ["mode": mode], timeout: 30) }

    // MARK: Updates
    func appVersion() async throws -> JSON { try await get("/application/version") }
    func setPreviewUpdates(_ on: Bool) async throws { try await raw("POST", "/application/preview", body: ["enable": on]) }
    func updateApplication() async throws { try await raw("POST", "/application/update", timeout: 900) }

    // MARK: AI / MCP
    func aiServices() async throws -> JSON { try await get("/ai/services") }
    func setMCP(_ on: Bool) async throws { try await raw("POST", "/ai/config", body: ["mcpEnabled": on], timeout: 60) }
    func mcpKey() async throws -> String { try await raw("POST", "/ai/mcp/key")["mcpApiKey"] as? String ?? "" }
    func regenerateMCPKey() async throws -> String {
        let d = try await raw("POST", "/ai/mcp/key/regenerate")
        return d["mcpApiKey"] as? String ?? ""
    }
    func setMemoryFabric(_ on: Bool) async throws { try await raw("POST", "/ai/memory-fabric", body: ["enabled": on], timeout: 60) }
    func setTimelapse(_ on: Bool) async throws { try await raw("POST", "/ai/screen-timelapse/state", body: ["enabled": on], timeout: 60) }

    // MARK: Scripts
    func scripts() async throws -> [String] { try await get("/vm/script")["files"] as? [String] ?? [] }
    func runScript(_ name: String, background: Bool) async throws -> String {
        try await raw("POST", "/vm/script/run", body: ["name": name, "type": background ? "background" : "foreground"], timeout: 120)["log"] as? String ?? ""
    }
    func deleteScript(_ name: String) async throws { try await raw("DELETE", "/vm/script", body: ["name": name]) }
    func uploadScript(_ data: Data, filename: String) async throws { try await uploadFile(data, filename: filename, to: "/vm/script/upload") }
}

extension KVMClient {
    /// For endpoints whose `data` is an array.
    func rawArray(_ path: String) async throws -> [JSON] {
        var req = URLRequest(url: url(path), timeoutInterval: 10)
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let token = currentToken { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
        let (data, _) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? JSON
        return obj?["data"] as? [JSON] ?? []
    }
}

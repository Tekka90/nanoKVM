import Foundation

struct MountedImage: Decodable {
    let mounted: Bool
    let file: String
    let cdrom: Bool
    let readOnly: Bool
}

struct ImageList: Decodable { let files: [String]? }
struct WoLList: Decodable { let macs: [String]? }
struct EDIDCustomList: Decodable { let edidList: [String]? }
struct EnabledState: Decodable { let enabled: Bool }
struct JigglerState: Decodable { let enabled: Bool; let mode: String }
struct PointerMode: Decodable { let mode: String }
struct HostnameInfo: Decodable { let hostname: String }

struct WoLEntry: Identifiable, Hashable {
    var id: String { mac }
    let mac: String
    let name: String
}

extension KVMClient {
    /// Request whose response carries no useful `data` (or may omit it).
    func command(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let token = currentToken { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await session.data(for: req)
        let env = try JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data)
        guard env.code == 0 else { throw KVMError.server(env.code, env.msg) }
    }

    // MARK: HID
    func pasteText(_ text: String) async throws { try await command("POST", "/hid/paste", body: ["content": text]) }
    func resetHID() async throws { try await command("POST", "/hid/reset") }
    func pointerMode() async throws -> String { (try await send("GET", "/hid/pointer-mode") as PointerMode).mode }
    func setPointerMode(_ mode: String) async throws { try await command("POST", "/hid/pointer-mode", body: ["mode": mode]) }
    func jiggler() async throws -> JigglerState { try await send("GET", "/vm/mouse-jiggler") }
    func setJiggler(enabled: Bool, mode: String) async throws {
        try await command("POST", "/vm/mouse-jiggler", body: ["enabled": enabled, "mode": mode])
    }

    // MARK: Stream
    func setRateControl(_ mode: String) async throws { try await command("POST", "/stream/rate-control", body: ["mode": mode]) }
    func setBitrate(_ kbps: Int) async throws { try await command("POST", "/stream/quality", body: ["quality": kbps]) }
    func setGOP(_ gop: Int) async throws { try await command("POST", "/stream/gop", body: ["gop": gop]) }
    func setStreamMode(_ mode: String) async throws { try await command("POST", "/stream/mode", body: ["mode": mode]) }
    func setFPS(_ fps: Int) async throws { try await command("POST", "/stream/fps", body: ["fps": fps]) }

    // MARK: Display
    func customEDIDs() async throws -> [String] { (try await send("GET", "/vm/edid/custom") as EDIDCustomList).edidList ?? [] }
    func setEDID(_ name: String) async throws { try await command("POST", "/vm/edid", body: ["edid": name]) }
    func deleteEDID(_ name: String) async throws { try await command("POST", "/vm/edid/delete", body: ["edid": name]) }

    func uploadEDID(_ data: Data, filename: String) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url("/vm/edid/upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let token = currentToken { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
        let (resp, _) = try await session.upload(for: req, from: body)
        let env = try JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: resp)
        guard env.code == 0 else { throw KVMError.server(env.code, env.msg) }
    }
    func hdmiCapture() async throws -> Bool { (try await send("GET", "/vm/hdmi/capture") as EnabledState).enabled }
    func setHDMICapture(_ enabled: Bool) async throws { try await command("POST", "/vm/hdmi/capture", body: ["enabled": enabled]) }

    // MARK: Virtual media
    func images() async throws -> [String] { (try await send("GET", "/storage/image") as ImageList).files ?? [] }
    func mountedImage() async throws -> MountedImage { try await send("GET", "/storage/image/mounted") }
    /// Pass an empty file name to unmount.
    func mount(file: String, cdrom: Bool, readOnly: Bool) async throws {
        try await command("POST", "/storage/image/mount", body: ["file": file, "cdrom": cdrom, "readOnly": readOnly])
    }
    func deleteImage(_ file: String) async throws { try await command("POST", "/storage/image/delete", body: ["file": file]) }

    /// Uploads a local file in 8 MiB chunks, the same way the web UI does.
    func uploadImage(at fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let chunkSize = 8 * 1024 * 1024
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw KVMError.invalidResponse }
        let total = (size + chunkSize - 1) / chunkSize
        let uploadID = UUID().uuidString
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        for index in 0..<total {
            guard let chunk = try handle.read(upToCount: chunkSize) else { break }
            var comps = URLComponents(url: url("/storage/image/upload"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                .init(name: "uploadId", value: uploadID),
                .init(name: "filename", value: fileURL.lastPathComponent),
                .init(name: "chunkSize", value: String(chunkSize)),
                .init(name: "chunkIndex", value: String(index)),
                .init(name: "totalChunks", value: String(total)),
            ]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let token = currentToken { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
            let (data, _) = try await session.upload(for: req, from: chunk)
            let env = try JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data)
            guard env.code == 0 else {
                try? await command("POST", "/storage/image/upload/cancel", body: ["uploadId": uploadID])
                throw KVMError.server(env.code, env.msg)
            }
            progress(Double(index + 1) / Double(total))
        }
    }

    // MARK: Wake on LAN
    func wolList() async throws -> [WoLEntry] {
        (try await send("GET", "/network/wol/mac") as WoLList).macs?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return WoLEntry(mac: parts[0], name: parts.count > 1 ? parts[1] : "")
            } ?? []
    }
    func wake(mac: String) async throws { try await command("POST", "/network/wol", body: ["mac": mac]) }
    func removeWoL(mac: String) async throws { try await command("DELETE", "/network/wol/mac", body: ["mac": mac]) }
    func nameWoL(mac: String, name: String) async throws {
        try await command("POST", "/network/wol/mac/name", body: ["mac": mac, "name": name])
    }

    // MARK: System
    func hostname() async throws -> String { (try await send("GET", "/vm/hostname") as HostnameInfo).hostname }
    func reboot() async throws { try await command("POST", "/vm/system/reboot") }
    func sshEnabled() async throws -> Bool { (try await send("GET", "/vm/ssh") as EnabledState).enabled }
    func setSSH(_ enabled: Bool) async throws { try await command("POST", "/vm/ssh/\(enabled ? "enable" : "disable")") }
    func mdnsEnabled() async throws -> Bool { (try await send("GET", "/vm/mdns") as EnabledState).enabled }
    func setMDNS(_ enabled: Bool) async throws { try await command("POST", "/vm/mdns/\(enabled ? "enable" : "disable")") }
}

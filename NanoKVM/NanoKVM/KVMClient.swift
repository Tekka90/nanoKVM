import Foundation

struct APIEnvelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: T?
}

struct EmptyData: Decodable {}

struct DeviceInfo: Decodable {
    struct IP: Decodable, Identifiable {
        var id: String { addr }
        let name: String
        let addr: String
        let version: String
        let type: String
    }
    let ips: [IP]
    let mdns: String
    let image: String
    let application: String
    let deviceKey: String
    let pn: String
    let arch: String
}

struct EncoderSettings: Decodable {
    let rate_control: String
    let bitrate: Int
    let gop: Int
    let fps: Int
}

struct WiFiStatus: Decodable {
    struct Network: Decodable {
        let ssid: String
        let security: String
    }
    let supported: Bool
    let connected: Bool
    let wifi: Network?
}

struct EDIDInfo: Decodable {
    let edid: String
    let width: Int
    let height: Int
}

enum KVMError: LocalizedError {
    case server(Int, String)
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .server(let code, let msg): "Device error \(code): \(msg)"
        case .invalidResponse: "Invalid response from device"
        case .message(let m): m
        }
    }
}

/// Trusts the device's self-signed certificate, but only for the configured host.
final class PinnedHostDelegate: NSObject, URLSessionDelegate {
    let host: String
    init(host: String) { self.host = host }

    // The protection space reports the host without its port.
    var hostWithoutPort: String {
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[0]) : host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == hostWithoutPort, let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class KVMClient {
    let host: String
    let session: URLSession
    private(set) var token: String?
    var currentToken: String? { token }

    /// `protocolClasses` lets tests intercept requests.
    init(host: String, protocolClasses: [AnyClass]? = nil) {
        self.host = host
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: PinnedHostDelegate(host: host), delegateQueue: nil)
    }

    func url(_ path: String) -> URL {
        URL(string: "https://\(host)/api\(path)")!
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let token { req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await session.data(for: req)
        let env: APIEnvelope<T>
        do { env = try JSONDecoder().decode(APIEnvelope<T>.self, from: data) } catch {
            // Error replies carry no usable `data`; report the device's own message instead.
            if let failure = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data), failure.code != 0 {
                throw KVMError.server(failure.code, failure.msg)
            }
            throw error
        }
        guard env.code == 0 else { throw KVMError.server(env.code, env.msg) }
        guard let value = env.data else { throw KVMError.invalidResponse }
        return value
    }

    func login(username: String, password: String) async throws {
        struct Token: Decodable { let token: String }
        let t: Token = try await send("POST", "/auth/login", body: ["username": username, "password": password])
        token = t.token
    }

    func info() async throws -> DeviceInfo { try await send("GET", "/vm/info") }
    func encoder() async throws -> EncoderSettings { try await send("GET", "/stream/encoder") }
    func wifi() async throws -> WiFiStatus { try await send("GET", "/network/wifi") }
    func edid() async throws -> EDIDInfo { try await send("GET", "/vm/edid") }
}

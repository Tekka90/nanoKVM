import Foundation
@testable import NanoKVM

/// One request captured by the mock server.
struct Req: @unchecked Sendable {
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: Data

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    var text: String { String(decoding: body, as: UTF8.self) }
}

/// In-process fake of the NanoKVM HTTP API, reachable only through `MockURLProtocol`.
final class MockServer: @unchecked Sendable {
    let host = "mock-\(UUID().uuidString.prefix(8).lowercased()).test"
    private let lock = NSLock()
    private var routes: [String: (Req) -> Data] = [:]
    private var log: [Req] = []
    /// When true, unknown routes answer `{code:0,data:{}}`; otherwise code -1.
    var lenient = false

    init() { MockURLProtocol.register(self) }
    deinit { MockURLProtocol.unregister(host) }

    var requests: [Req] { lock.withLock { log } }
    func requests(to key: String) -> [Req] { requests.filter { "\($0.method) \($0.path)" == key } }
    func last(_ key: String) -> Req? { requests(to: key).last }

    /// `key` is "METHOD /path" without the `/api` prefix.
    func on(_ key: String, data: Any = [String: Any](), code: Int = 0, msg: String = "success") {
        onRaw(key, MockServer.envelope(code: code, msg: msg, data: data))
    }

    func onRaw(_ key: String, _ data: Data) { lock.withLock { routes[key] = { _ in data } } }
    func onDynamic(_ key: String, _ handler: @escaping (Req) -> Data) { lock.withLock { routes[key] = handler } }

    static func envelope(code: Int, msg: String, data: Any?) -> Data {
        var obj: [String: Any] = ["code": code, "msg": msg]
        if let data { obj["data"] = data }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    func client() -> KVMClient { KVMClient(host: host, protocolClasses: [MockURLProtocol.self]) }

    func respond(_ req: Req) -> Data {
        let handler: ((Req) -> Data)? = lock.withLock {
            log.append(req)
            return routes["\(req.method) \(req.path)"]
        }
        if let handler { return handler(req) }
        return lenient ? MockServer.envelope(code: 0, msg: "success", data: [String: Any]())
                       : MockServer.envelope(code: -1, msg: "not found", data: nil)
    }
}

final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var servers: [String: MockServer] = [:]

    static func register(_ s: MockServer) { lock.withLock { servers[s.host] = s } }
    static func unregister(_ host: String) { lock.withLock { servers[host] = nil } }
    private static func server(_ host: String) -> MockServer? { lock.withLock { servers[host] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = Self.server(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer[0..<n])
            }
            stream.close()
        }
        let path = url.path.hasPrefix("/api") ? String(url.path.dropFirst(4)) : url.path
        let req = Req(method: request.httpMethod ?? "GET", path: path, query: url.query ?? "",
                      headers: request.allHTTPHeaderFields ?? [:], body: body)
        let data = server.respond(req)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func tempFile(size: Int, name: String = "test.iso") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 0xAB, count: size).write(to: url)
    return url
}

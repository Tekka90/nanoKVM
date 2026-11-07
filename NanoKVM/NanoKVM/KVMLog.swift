import Foundation
import os

/// Connection log: forwarded to unified logging and kept in a small rotating file so it can be exported from Settings.
enum KVMLog {
    private static let logger = Logger(subsystem: "org.jupille.NanoKVM", category: "connection")
    static let store = LogStore(fileURL: URL.cachesDirectory.appending(path: "nanokvm-connection.log"))

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        store.append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        store.append("ERROR", message)
    }
}

final class LogStore: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "org.jupille.NanoKVM.log")

    init(fileURL: URL, maxBytes: Int = 200_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    func append(_ level: String, _ message: String, date: Date = Date()) {
        let line = "\(date.formatted(.iso8601)) \(level) \(message)\n"
        queue.async { [self] in
            var text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            text += line
            try? Self.trimmed(text, maxBytes: maxBytes).write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func contents() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Keeps the newest lines once the log outgrows `maxBytes`.
    static func trimmed(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var size = text.utf8.count
        while size > maxBytes / 2, !lines.isEmpty { size -= lines.removeFirst().utf8.count + 1 }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum Diagnostics {
    /// Never includes passwords or tokens.
    static func report(summary: [(String, String)], log: String, now: Date = Date()) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "NanoKVM diagnostics \(now.formatted(.iso8601))",
            "App: \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        lines += summary.map { "\($0.0): \($0.1)" }
        return lines.joined(separator: "\n") + "\n\n--- Connection log ---\n" + (log.isEmpty ? "(empty)\n" : log)
    }

    static func write(summary: [(String, String)], log: String) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "NanoKVM-diagnostics.txt")
        try report(summary: summary, log: log).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

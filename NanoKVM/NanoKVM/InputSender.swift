import Foundation

/// Sends keyboard / pointer events to the device over `/api/ws`.
///
/// Message: [0]=3 (input router) [1]=1 (version) [2]=source [3]=report kind [4]=flags
/// [5..8]=sequence u32 LE [9..12]=timestamp ms u32 LE [13...]=payload.
@MainActor
@Observable
final class InputSender {
    private enum Report: UInt8 { case keyboard = 1, relativePointer = 2, absolutePointer = 3 }
    private let sourceBrowserKeyboard: UInt8 = 1
    private let sourceVirtualKeyboard: UInt8 = 16
    private let sourceBrowserPointer: UInt8 = 2

    private(set) var isConnected = false
    private let host: String
    var token: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    @ObservationIgnored private(set) var lastAlive = Date()
    private var sequence: UInt32 = 0
    private let startTime = Date()

    private var modifiers: UInt8 = 0
    private var pressedKeys: [UInt8] = []
    private(set) var buttons: UInt8 = 0
    /// Receives every outgoing message (used by tests).
    @ObservationIgnored var onSend: ((Data) -> Void)?

    init(host: String, token: String) {
        self.host = host
        self.token = token
    }

    func connect() {
        disconnect()
        var request = URLRequest(url: URL(string: "wss://\(host)/api/ws")!)
        request.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: PinnedHostDelegate(host: host), delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        isConnected = true
        lastAlive = Date()
        receiver = Task { [weak self] in
            // Incoming JSON events are not used yet; keep reading to detect closure.
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.lastAlive = Date()
                    if case .string(let text) = message { self?.noteEvent(text) }
                } catch {
                    // A newer connection may already have replaced this one.
                    if let self, self.task === task {
                        KVMLog.error("input receive failed: \(error.localizedDescription)")
                        self.isConnected = false
                    }
                    return
                }
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if VideoStream.isDead(lastAlive: self.lastAlive, now: Date()) {
                    KVMLog.error("input socket silent, marking disconnected")
                    self.isConnected = false
                    self.task?.cancel(with: .goingAway, reason: nil)
                    return
                }
                self.sendRaw(Data([0]))
                task.sendPing { [weak self] error in
                    if error == nil { Task { @MainActor in self?.lastAlive = Date() } }
                }
            }
        }
    }

    /// Device events (e.g. capture status) are logged when they change, to help diagnose missing video.
    func noteEvent(_ text: String) {
        let key = String(text.prefix(200))
        guard key != lastEvent else { return }
        lastEvent = key
        KVMLog.info("device event: \(key)")
    }

    private var lastEvent = ""

    func disconnect() {
        releaseAll()
        heartbeat?.cancel()
        receiver?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        isConnected = false
    }

    // MARK: Keyboard

    /// `usage` is a USB HID keyboard usage (0xE0...0xE7 are modifiers).
    func keyDown(_ usage: UInt8) {
        if (0xE0...0xE7).contains(usage) {
            modifiers |= 1 << (usage - 0xE0)
        } else if !pressedKeys.contains(usage) {
            if pressedKeys.count >= 6 { pressedKeys.removeFirst() }
            pressedKeys.append(usage)
        }
        sendKeyboardReport(source: sourceBrowserKeyboard)
    }

    func keyUp(_ usage: UInt8) {
        if (0xE0...0xE7).contains(usage) {
            modifiers &= ~(1 << (usage - 0xE0))
        } else {
            pressedKeys.removeAll { $0 == usage }
        }
        sendKeyboardReport(source: sourceBrowserKeyboard)
    }

    func setModifiers(_ mask: UInt8) {
        modifiers = mask
        sendKeyboardReport(source: sourceBrowserKeyboard)
    }

    func releaseAll() {
        guard modifiers != 0 || !pressedKeys.isEmpty || buttons != 0 else { return }
        modifiers = 0
        pressedKeys = []
        buttons = 0
        sendKeyboardReport(source: sourceBrowserKeyboard)
    }

    /// Presses the given usages together, then releases them (e.g. Ctrl+Alt+Del).
    func sendCombo(_ usages: [UInt8]) {
        var mods: UInt8 = 0
        var keys: [UInt8] = []
        for u in usages {
            if (0xE0...0xE7).contains(u) { mods |= 1 << (u - 0xE0) } else { keys.append(u) }
        }
        send(source: sourceVirtualKeyboard, kind: .keyboard, payload: [mods, 0] + (keys + [0, 0, 0, 0, 0, 0]).prefix(6))
        send(source: sourceVirtualKeyboard, kind: .keyboard, payload: [UInt8](repeating: 0, count: 8))
    }

    /// Wakes a sleeping host display. F15 is used because it has no side effect on
    /// macOS, Windows or Linux, and unlike Shift it can't trigger Sticky Keys.
    func wake() { sendCombo([Self.wakeKey]) }
    static let wakeKey: UInt8 = 0x6E

    private func sendKeyboardReport(source: UInt8) {
        let keys = (pressedKeys + [0, 0, 0, 0, 0, 0]).prefix(6)
        send(source: source, kind: .keyboard, payload: [modifiers, 0] + keys)
    }

    // MARK: Pointer

    /// Button bits: 1 = left, 2 = right, 4 = middle. `x`/`y` are normalized 0...1.
    func pointer(x: Double, y: Double, buttons newButtons: UInt8? = nil, wheel: Int = 0) {
        if let newButtons { buttons = newButtons }
        var payload = [UInt8](repeating: 0, count: 7)
        payload[0] = buttons & 31
        let px = UInt16((max(0, min(1, x)) * 65535).rounded())
        let py = UInt16((max(0, min(1, y)) * 65535).rounded())
        payload[1] = UInt8(px & 0xFF); payload[2] = UInt8(px >> 8)
        payload[3] = UInt8(py & 0xFF); payload[4] = UInt8(py >> 8)
        let w = UInt16(bitPattern: Int16(max(-32768, min(32767, wheel))))
        payload[5] = UInt8(w & 0xFF); payload[6] = UInt8(w >> 8)
        send(source: sourceBrowserPointer, kind: .absolutePointer, payload: payload)
    }

    func relativePointer(dx: Int, dy: Int, wheel: Int = 0, buttons newButtons: UInt8? = nil) {
        if let newButtons { buttons = newButtons }
        var payload = [UInt8](repeating: 0, count: 7)
        payload[0] = buttons & 31
        for (i, v) in [dx, dy, wheel].enumerated() {
            let u = UInt16(bitPattern: Int16(max(-32768, min(32767, v))))
            payload[1 + i * 2] = UInt8(u & 0xFF)
            payload[2 + i * 2] = UInt8(u >> 8)
        }
        send(source: sourceBrowserPointer, kind: .relativePointer, payload: payload)
    }

    // MARK: Transport

    private func send(source: UInt8, kind: Report, payload: [UInt8]) {
        sequence &+= 1
        let ms = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(startTime) * 1000))
        var data = Data([3, 1, source, kind.rawValue, 0])
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: ms.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        sendRaw(data)
    }

    private func sendRaw(_ data: Data) {
        onSend?(data)
        task?.send(.data(data)) { _ in }
    }
}

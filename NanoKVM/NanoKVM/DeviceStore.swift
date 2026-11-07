import Foundation
import Network
import Security

struct SavedDevice: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var username: String
}

enum Keychain {
    private static let service = "org.jupille.NanoKVM"

    private static func base(for id: UUID, dataProtection: Bool, suffix: String = "") -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString + suffix,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Legacy suffix of the SSH root password item, only used to clean it up.
    static let sshSuffix = ".ssh"

    static func password(for id: UUID, suffix: String = "") -> String? {
        // Synced (data protection) keychain first, then the legacy local item.
        for dp in [true, false] {
            var query = base(for: id, dataProtection: dp, suffix: suffix)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, let value = String(data: data, encoding: .utf8) { return value }
        }
        return nil
    }

    /// Stores the password in iCloud Keychain so it follows the device list across your devices.
    static func setPassword(_ password: String, for id: UUID, suffix: String = "") {
        deletePassword(for: id, suffix: suffix)
        var add = base(for: id, dataProtection: true, suffix: suffix)
        add[kSecAttrSynchronizable as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func deletePassword(for id: UUID, suffix: String = "") {
        for dp in [true, false] { SecItemDelete(base(for: id, dataProtection: dp, suffix: suffix) as CFDictionary) }
    }

    /// Removes both the web and the SSH password of a device.
    static func deleteAll(for id: UUID) {
        deletePassword(for: id)
        deletePassword(for: id, suffix: sshSuffix)
    }
}

/// Per-KVM boolean preferences, synced via iCloud.
enum SyncedFlag {
    private static func key(_ name: String, _ id: UUID) -> String { "\(name).\(id.uuidString)" }

    static func isOn(_ name: String, _ id: UUID) -> Bool {
        if ScreenshotMode.forcesFlag(name, id) { return true }
        let k = key(name, id)
        return NSUbiquitousKeyValueStore.default.bool(forKey: k) || UserDefaults.standard.bool(forKey: k)
    }

    static func set(_ value: Bool, _ name: String, _ id: UUID) {
        let k = key(name, id)
        UserDefaults.standard.set(value, forKey: k)
        NSUbiquitousKeyValueStore.default.set(value, forKey: k)
    }
}

/// Acknowledgement that the NanoKVM has external power.
enum PowerConfirmation {
    static func isConfirmed(_ id: UUID) -> Bool { SyncedFlag.isOn("externalPower", id) }
    static func set(_ value: Bool, for id: UUID) { SyncedFlag.set(value, "externalPower", id) }
}

@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [SavedDevice] = []
    private let key = "savedDevices"
    private let cloud = NSUbiquitousKeyValueStore.default

    init() {
        if let demo = ScreenshotMode.device {
            devices = [demo]
            return
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            devices = decoded
        }
        mergeFromCloud()
        // Upgrade legacy local passwords to iCloud Keychain.
        for d in devices { if let pw = Keychain.password(for: d.id) { Keychain.setPassword(pw, for: d.id) } }
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mergeFromCloud() }
        }
        cloud.synchronize()
    }

    /// iCloud is the source of truth once it has data; local-only devices are pushed up.
    private func mergeFromCloud() {
        guard let data = cloud.data(forKey: key), let remote = try? JSONDecoder().decode([SavedDevice].self, from: data) else {
            if !devices.isEmpty { save() }
            return
        }
        if remote != devices {
            devices = remote
            if let encoded = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(encoded, forKey: key) }
        }
    }

    func add(_ device: SavedDevice, password: String) {
        devices.append(device)
        Keychain.setPassword(password, for: device.id)
        save()
    }

    func update(_ device: SavedDevice, password: String?) {
        guard let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[i] = device
        if let password, !password.isEmpty { Keychain.setPassword(password, for: device.id) }
        save()
    }

    func remove(_ device: SavedDevice) {
        devices.removeAll { $0.id == device.id }
        Keychain.deleteAll(for: device.id)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: key)
        cloud.set(data, forKey: key)
    }
}

struct DiscoveredDevice: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var host: String { name.hasSuffix(".local") ? name : "\(name).local" }
}

/// Browses the LAN for HTTP services and surfaces anything that looks like a NanoKVM.
@MainActor
@Observable
final class DeviceDiscovery {
    private(set) var found: [DiscoveredDevice] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in
                self?.found = names
                    .filter { $0.localizedCaseInsensitiveContains("kvm") }
                    .sorted()
                    .map(DiscoveredDevice.init)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// An authenticated connection to one device.
@MainActor
@Observable
final class FullScreenState {
    static let shared = FullScreenState()
    var active = false
    var railRevealed = false
}

@MainActor
@Observable
final class DeviceSession {
    @ObservationIgnored var screenAppearances = 0
    var isFullScreen: Bool {
        get { FullScreenState.shared.active }
        set { FullScreenState.shared.active = newValue }
    }
    enum State: Equatable { case connecting, connected, failed(String), inUseElsewhere(String) }

    let device: SavedDevice
    private(set) var state: State = .connecting
    private(set) var client: KVMClient
    @ObservationIgnored private let makeClient: (String) -> KVMClient
    @ObservationIgnored private let passwordProvider: (UUID) -> String?
    private(set) var info: DeviceInfo?
    private(set) var stream: VideoStream?
    private(set) var input: InputSender?
    /// Touch acts as a trackpad (relative movement) instead of pointing directly at the screen.
    /// iOS on-screen keyboard requested from the rail.
    var softKeyboard = false
    var trackpad: Bool { didSet { PointerPrefs.setTrackpad(trackpad, for: device.id) } }
    var keyboardTarget: KeyboardTarget { didSet { KeyboardTarget.store(keyboardTarget, for: device.id) } }
    var naturalScroll: Bool { didSet { PointerPrefs.setNaturalScroll(naturalScroll, for: device.id) } }
    var trackpadSpeed: Double { didSet { PointerPrefs.setSpeed(trackpadSpeed, for: device.id) } }
    var gestureTuning: GestureTuning { didSet { GestureTuning.store(gestureTuning, for: device.id) } }
    @ObservationIgnored private(set) lazy var edidController = EDIDController(session: self)

    init(device: SavedDevice,
         makeClient: @escaping (String) -> KVMClient = { KVMClient(host: $0) },
         passwordProvider: @escaping (UUID) -> String? = { ScreenshotMode.password(for: $0) ?? Keychain.password(for: $0) }) {
        self.device = device
        self.makeClient = makeClient
        self.passwordProvider = passwordProvider
        client = makeClient(device.host)
        trackpad = PointerPrefs.trackpad(for: device.id)
        trackpadSpeed = PointerPrefs.speed(for: device.id)
        naturalScroll = PointerPrefs.naturalScroll(for: device.id)
        gestureTuning = GestureTuning.stored(for: device.id)
        keyboardTarget = KeyboardTarget.stored(for: device.id)
    }

    /// Keeps the KVM's HID mode in step with the trackpad setting.
    func applyPointerMode() async {
        try? await client.setPointerMode(trackpad ? "relative" : "absolute")
    }

    var token: String? { client.currentToken }

    /// The device drops the input socket when virtual media changes; reopen it.
    func reconnectInput() { input?.connect() }

    /// Install identifier used for the connection lease; replaceable in tests.
    @ObservationIgnored var installID = ConnectionLease.installID

    /// Stops this instance when another install of the app has taken over the KVM, instead of fighting for it.
    @discardableResult
    func checkLease() -> Bool {
        guard case .connected = state, let other = ConnectionLease.otherOwner(of: device.id, install: installID) else { return false }
        KVMLog.info("connection taken over by \(other); disconnecting")
        disconnect()
        state = .inUseElsewhere(other)
        return true
    }

    /// Connects again on purpose (user action), which makes this instance the owner.
    func takeOver() async {
        await connect(force: true)
        startSupervising()
    }

    func disconnect() {
        ConnectionLease.release(device.id, install: installID)
        supervisor?.cancel()
        supervisor = nil
        stream?.stop()
        input?.disconnect()
    }

    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var retryDelay = 3.0
    @ObservationIgnored private var nextAttempt = Date.distantPast
    @ObservationIgnored private var lastNoSignalRestart = Date.distantPast
    @ObservationIgnored private var stalledRestarts = 0
    /// Pause between closing the old video socket and opening a new one, so the device sees the viewer leave.
    @ObservationIgnored var reconnectGap = 1.0
    /// Seconds a freshly opened stream may stay without a frame before it is restarted.
    /// Long enough not to churn viewers, short enough to nudge the target and record the device's HDMI state.
    @ObservationIgnored var firstFrameTimeout = 20.0

    /// Watches the sockets and heals them without user action (sleep/wake, lost Wi-Fi, device restarts).
    func startSupervising() {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                await self.superviseOnce(now: Date())
            }
        }
    }

    /// One supervision step: recover dead sockets with back-off, and periodically restart a stream stuck without signal.
    func superviseOnce(now: Date) async {
        guard case .connected = state, !isRecovering else { return }
        if checkLease() { return }
        if stream?.state == .playing { stalledRestarts = 0 }
        guard now >= nextAttempt else { return }
        if needsRecovery {
            KVMLog.info("supervisor: recovering")
            if await recover() {
                retryDelay = 3
            } else {
                retryDelay = min(retryDelay * 2, 30)
                KVMLog.error("supervisor: recovery failed, retry in \(self.retryDelay)s")
            }
            nextAttempt = now.addingTimeInterval(retryDelay)
        } else if let stream, let since = stream.noSignalSince,
                  now.timeIntervalSince(since) > 10, now.timeIntervalSince(lastNoSignalRestart) > 15 {
            // The signal may be back while the stream still waits on the old capture session.
            KVMLog.info("supervisor: restarting stream after no-signal")
            lastNoSignalRestart = now
            stream.start()
        } else if let stream, stream.state == .connecting, now.timeIntervalSince(stream.startedAt) > firstFrameTimeout {
            // Socket open but no picture (seen after the app was away): reopen, and every third time log in again.
            stalledRestarts += 1
            await logCaptureState()
            if input?.isConnected == true { input?.wake() }
            KVMLog.error("supervisor: no video frame \(Int(now.timeIntervalSince(stream.startedAt)))s after start (attempt \(stalledRestarts))")
            switch stalledRestarts % 3 {
            case 0:
                _ = await recover()
            case 2:
                await switchCodecAfterStall(stream)
            default:
                stream.stop()
                try? await Task.sleep(for: .seconds(reconnectGap))
                stream.start()
            }
        }
    }

    /// The KVM's encoder for one codec can stop producing frames while the other still works (seen on a NanoKVM Go+ with H.264 direct).
    func switchCodecAfterStall(_ stream: VideoStream) async {
        let next: VideoStream.Codec = stream.codec == .h264 ? .h265 : .h264
        KVMLog.error("supervisor: no frames with \(stream.codec.rawValue), switching to \(next.rawValue)")
        stream.stop()
        stream.codec = next
        UserDefaults.standard.set(next.rawValue, forKey: "videoCodec")
        try? await client.setStreamMode("\(next.rawValue)-direct")
        try? await Task.sleep(for: .seconds(reconnectGap))
        stream.start()
    }

    /// Records what the KVM says about its HDMI input, to tell "no signal" from "stream not delivering".
    func logCaptureState() async {
        for path in ["/vm/hdmi", "/vm/hdmi/capture"] {
            do {
                let data = try await client.raw("GET", path, timeout: 4)
                KVMLog.info("GET \(path) -> \(data)")
            } catch {
                KVMLog.error("GET \(path) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Facts for the exported diagnostic file (no secrets).
    var diagnosticSummary: [(String, String)] {
        [("Device host", device.host),
         ("Device image", info?.image ?? "?"),
         ("Device application", info?.application ?? "?"),
         ("Video state", stream.map { "\($0.state)" } ?? "none"),
         ("Video seconds since last data", stream.map { String(Int(Date().timeIntervalSince($0.lastAlive))) } ?? "-"),
         ("Input connected", input.map { "\($0.isConnected)" } ?? "none"),
         ("Video frames this connection", stream.map { String($0.meter.totalFrames) } ?? "-"),
         ("Codec", stream?.codec.rawValue ?? "?"),
         ("Trackpad", "\(trackpad)"),
         ("Auto-switch EDID", "\(SyncedFlag.isOn("autoEDID", device.id))")]
    }

    /// Re-authenticates and reopens the video and input sockets after a connection loss
    /// (app suspended, network change). Keeps the same stream/input objects so views stay bound.
    @discardableResult
    func recover() async -> Bool {
        guard case .connected = state, let stream, let input,
              let password = passwordProvider(device.id), !isRecovering else { return false }
        isRecovering = true
        defer { isRecovering = false }
        if checkLease() { return false }
        ConnectionLease.claim(device.id, install: installID)
        let fresh = makeClient(device.host)
        do {
            try await fresh.login(username: device.username, password: password)
        } catch {
            KVMLog.error("recover: login failed: \(error.localizedDescription)")
            return false
        }
        client = fresh
        guard let token = fresh.currentToken else { return false }
        stream.token = token
        input.token = token
        // Another client (web UI) may have switched the device to a different stream mode meanwhile.
        try? await fresh.setStreamMode("\(stream.codec.rawValue)-direct")
        KVMLog.info("recover: sockets reopened")
        stream.stop()
        try? await Task.sleep(for: .seconds(reconnectGap))
        stream.start()
        input.connect()
        return true
    }

    /// True when either socket is down and a recovery is worthwhile.
    var needsRecovery: Bool {
        guard let stream, let input else { return false }
        if case .failed = stream.state { return true }
        if VideoStream.isDead(lastAlive: stream.lastAlive, now: Date()), stream.state != .idle { return true }
        return !input.isConnected
    }

    /// Without `force`, a KVM that another install of the app currently owns is left alone until the user takes it over.
    func connect(force: Bool = false) async {
        if !force, let other = ConnectionLease.otherOwner(of: device.id, install: installID) {
            state = .inUseElsewhere(other)
            return
        }
        state = .connecting
        guard let password = passwordProvider(device.id) else {
            state = .failed("No saved password for this device.")
            return
        }
        let fresh = makeClient(device.host)
        do {
            try await fresh.login(username: device.username, password: password)
            client = fresh
            info = try? await fresh.info()
            if let token = fresh.currentToken {
                let video = VideoStream(host: device.host, token: token)
                stream = video
                try? await fresh.setStreamMode("\(video.codec.rawValue)-direct")
                let sender = InputSender(host: device.host, token: token)
                sender.connect()
                input = sender
            }
            ConnectionLease.claim(device.id, install: installID)
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

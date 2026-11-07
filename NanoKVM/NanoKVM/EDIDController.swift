import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The screen the app is currently shown on.
struct DisplayInfo: Equatable {
    /// Empty for the device's built-in screen, otherwise a file-name-safe screen name.
    var tag: String
    var label: String
    var points: CGSize
    var pixels: CGSize

    func size(usePoints: Bool) -> CGSize {
        let s = usePoints ? points : pixels
        return CGSize(width: max(s.width, s.height), height: min(s.width, s.height))
    }

    static let fallback = DisplayInfo(tag: "", label: "Display", points: .init(width: 1920, height: 1080), pixels: .init(width: 1920, height: 1080))
}

/// Switches the KVM's EDID to match this device, with progress and automatic rollback.
@MainActor
@Observable
final class EDIDController {
    unowned let session: DeviceSession
    var status: String?
    var error: String?
    private var autoDone = false
    /// Polling interval while waiting for video; shortened in tests.
    @ObservationIgnored var tick: Duration = .seconds(1)
    /// Where the screen is read from; replaced in tests.
    @ObservationIgnored var displayProvider: () -> DisplayInfo = EDIDController.currentDisplay
    /// Wait before reacting to a screen change, so a burst of notifications counts once.
    @ObservationIgnored var displayDebounce: Duration = .seconds(3)
    private(set) var display: DisplayInfo = .fallback
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(session: DeviceSession) {
        self.session = session
        display = displayProvider()
    }

    isolated deinit { stopMonitoring() }

    /// Screen the app window is on right now (not just the main screen).
    static func currentDisplay() -> DisplayInfo {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let screen = scene?.screen ?? UIScreen.main
        let builtIn = screen === UIScreen.main
        // UIKit can't tell an inner foldable screen from an external monitor, so name it by its pixel size.
        let px = screen.nativeBounds.size
        let tag = "Screen-\(Int(min(px.width, px.height)))x\(Int(max(px.width, px.height)))"
        return DisplayInfo(tag: builtIn ? "" : tag, label: builtIn ? "Built-in display" : "Second display",
                           points: screen.bounds.size, pixels: screen.nativeBounds.size)
        #else
        let window = NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first { $0.isVisible }
        guard let screen = window?.screen ?? NSScreen.main else { return .fallback }
        // Full screen can't use the notch band, so match what is actually drawable.
        var s = screen.frame.size
        s.height -= screen.safeAreaInsets.top
        let k = screen.backingScaleFactor
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let builtIn = id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        return DisplayInfo(tag: builtIn ? "" : String(sanitize(screen.localizedName).prefix(24)), label: screen.localizedName,
                           points: s, pixels: CGSize(width: s.width * k, height: s.height * k))
        #endif
    }

    /// Re-reads the screen; returns true when it changed.
    @discardableResult
    func refreshDisplay() -> Bool {
        let new = displayProvider()
        guard new != display else { return false }
        display = new
        return true
    }

    /// Watches for monitors being plugged, unplugged, resized, or the window moving to another screen.
    func startMonitoring() {
        guard observers.isEmpty else { return }
        refreshDisplay()
        #if os(iOS)
        let names: [Notification.Name] = [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScreen.modeDidChangeNotification, UIScene.didActivateNotification]
        #else
        let names: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification]
        #endif
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayMayHaveChanged() }
            }
        }
    }

    func stopMonitoring() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        debounceTask?.cancel()
    }

    /// With auto-switch on, re-matches the KVM once the screen has settled on something new.
    func displayMayHaveChanged() {
        guard refreshDisplay(), autoSwitch, powerConfirmed else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: displayDebounce)
            guard !Task.isCancelled, status == nil else { return }
            refreshDisplay()
            autoDone = false
            await autoSwitchIfNeeded()
        }
    }

    var powerConfirmed: Bool { PowerConfirmation.isConfirmed(session.device.id) }
    var autoSwitch: Bool { SyncedFlag.isOn("autoEDID", session.device.id) }

    var usePoints: Bool {
        get { UserDefaults.standard.bool(forKey: "matchUsePoints") }
        set { UserDefaults.standard.set(newValue, forKey: "matchUsePoints") }
    }
    var hz: Int {
        get { UserDefaults.standard.object(forKey: "matchHz") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "matchHz") }
    }

    func nativeSize(usePoints: Bool) -> CGSize { display.size(usePoints: usePoints) }

    /// Name of this device, restricted to characters the KVM accepts in file names.
    var clientName: String {
        #if os(iOS)
        let raw = UIDevice.current.name
        #else
        let raw = Host.current().localizedName ?? "Mac"
        #endif
        let joined = Self.sanitize(raw)
        return joined.isEmpty ? "Device" : joined
    }

    nonisolated static func sanitize(_ raw: String) -> String {
        let cleaned = raw.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        return cleaned.split(separator: "-").joined(separator: "-")
    }

    /// One file per device and screen, so a laptop gets a separate EDID for each monitor it meets.
    func fileName(usePoints: Bool) -> String {
        "\(clientName)\(display.tag.isEmpty ? "" : "_" + display.tag)\(usePoints ? "" : "_HiDPI").bin"
    }

    func waitForSignal(timeout: Int) async -> Bool {
        for i in 0..<(timeout / 5) {
            session.stream?.start()
            for _ in 0..<5 {
                try? await Task.sleep(for: tick)
                if session.stream?.state == .playing { return true }
            }
            status = "Waiting for signal… \((i + 1) * 5) s"
        }
        return false
    }

    /// Selects an EDID, waits for video, and restores the previous one if none comes back.
    func switchTo(_ name: String) async {
        let previous = (try? await session.client.edid().edid) ?? ""
        if previous == name { return }
        KVMLog.info("EDID switch \(previous.isEmpty ? "?" : previous) -> \(name) (auto: \(autoSwitch))")
        status = "Switching display… waiting for signal"
        defer { status = nil }
        do {
            try await session.client.setEDID(name)
            if await waitForSignal(timeout: 45) { return }
            status = "No signal. Restoring previous display…"
            if !previous.isEmpty { try await session.client.setEDID(previous) }
            let ok = await waitForSignal(timeout: 45)
            error = ok ? "No signal with the new EDID; previous one restored." : "No signal. Check the HDMI cable and the KVM's power."
        } catch { self.error = error.localizedDescription }
    }

    /// Generates this device's EDID, uploads it, switches to it and removes its other variant.
    func match(usePoints: Bool, hz: Int) async {
        do {
            let size = nativeSize(usePoints: usePoints)
            let n = EDIDBuilder.normalized(width: Int(size.width), height: Int(size.height))
            let b = EDIDBuilder(width: n.width, height: n.height, refresh: hz, name: String(clientName.prefix(13)))
            guard n.width <= 4095, n.height <= 4095 else {
                throw KVMError.message("\(n.width)×\(n.height) is beyond the 4095 px an EDID can describe. Match in points instead.")
            }
            guard b.timing.pixelClockMHz <= 300 else {
                throw KVMError.message("\(n.width)×\(n.height)@\(hz) needs \(Int(b.timing.pixelClockMHz)) MHz, above the ~300 MHz limit. Lower the refresh rate.")
            }
            let name = fileName(usePoints: usePoints)
            try await session.client.uploadEDID(b.build(), filename: name)
            await switchTo(name)
            let other = fileName(usePoints: !usePoints)
            if (try? await session.client.customEDIDs())?.contains(other) == true,
               (try? await session.client.edid().edid) == name {
                try? await session.client.deleteEDID(other)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Runs once per connection when the user enabled auto-switching.
    func autoSwitchIfNeeded() async {
        guard !autoDone, autoSwitch, powerConfirmed else { return }
        autoDone = true
        let name = fileName(usePoints: usePoints)
        guard let current = try? await session.client.edid().edid, current != name else { return }
        if let list = try? await session.client.customEDIDs(), list.contains(name) {
            await switchTo(name)
        } else {
            await match(usePoints: usePoints, hz: hz)
        }
    }
}

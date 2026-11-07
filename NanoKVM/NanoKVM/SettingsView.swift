import SwiftUI

private struct QualityPreset: Identifiable {
    var id: String { name }
    let name: String
    let mode: String
    let bitrate: Int
    let gop: Int
}

private let presets: [QualityPreset] = [
    .init(name: "Auto (VBR)", mode: "vbr", bitrate: 10240, gop: 300),
    .init(name: "Lossless", mode: "cbr", bitrate: 10240, gop: 120),
    .init(name: "High", mode: "cbr", bitrate: 8192, gop: 120),
    .init(name: "Medium", mode: "cbr", bitrate: 4096, gop: 240),
    .init(name: "Low", mode: "cbr", bitrate: 1024, gop: 240),
]

private let builtinEDIDs: [(id: String, label: String)] = [
    ("nanokvm-go-3840x2160-50", "3840 × 2160 @ 50 Hz"),
    ("nanokvm-go-3840x2160-30", "3840 × 2160 @ 30 Hz"),
    ("nanokvm-go-3440x1440-60", "3440 × 1440 @ 60 Hz"),
    ("nanokvm-go-2560x1440-60", "2560 × 1440 @ 60 Hz"),
    ("nanokvm-go-1920x1080-60", "1920 × 1080 @ 60 Hz"),
]

struct SettingsView: View {
    let session: DeviceSession
    @State private var encoder: EncoderSettings?
    @State private var edid = ""
    @State private var confirmMatch = false
    @State private var pendingEDID: String?
    @State private var powerOK = false
    @State private var autoEDID = false
    @State private var usePoints = false
    @State private var matchHz = 30
    private var edidCtl: EDIDController { session.edidController }
    private var nativeW: Int { Int(edidCtl.nativeSize(usePoints: usePoints).width) }
    private var nativeH: Int { Int(edidCtl.nativeSize(usePoints: usePoints).height) }
    @State private var customEDIDs: [String] = []
    @State private var hdmiCapture = true
    @State private var pointerMode = "absolute"
    @State private var jigglerEnabled = false
    @State private var jigglerMode = "relative"
    @State private var ssh = false
    @State private var mdns = false
    @State private var hostname = ""
    @State private var wifi: WiFiStatus?
    @State private var confirmReboot = false
    @State private var error: String?
    @State private var loaded = false
    @State private var diagnosticURL: URL?
    @AppStorage("swapISOKeys") private var swapISOKeys = true
    @State private var codec = UserDefaults.standard.string(forKey: "videoCodec") ?? "h264"

    var body: some View {
        Form {
            #if os(macOS)
            Section("Scrolling") {
                Toggle("Natural scrolling", isOn: Binding(get: { session.naturalScroll }, set: { session.naturalScroll = $0 }))
                Text("Turn off to reverse the wheel direction sent to the target. Per device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #endif
            Section("Video quality") {
                if let encoder {
                    LabeledContent("Current", value: "\(encoder.rate_control.uppercased()) · \(encoder.bitrate) kbps · GOP \(encoder.gop)")
                }
                ForEach(presets) { preset in
                    Button(preset.name) { Task { await apply(preset) } }
                }
                Picker("Codec", selection: Binding(get: { codec }, set: { setCodec($0) })) {
                    Text("H.264").tag("h264")
                    Text("H.265 (HEVC)").tag("h265")
                }
                Picker("Frame rate", selection: Binding(get: { encoder?.fps ?? 0 }, set: { fps in Task { await setFPS(fps) } })) {
                    if (encoder?.fps ?? 0) == 0 { Text("Unset (no video!)").tag(0) }
                    ForEach([15, 20, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            Section("Display") {
                Toggle("External power connected", isOn: Binding(get: { powerOK }, set: { powerOK = $0; PowerConfirmation.set($0, for: session.device.id) }))
                Text("I confirm the NanoKVM is powered by its own USB-C supply. Changing the EDID briefly cuts the signal, and without external power the NanoKVM can crash or misbehave.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("EDID", selection: Binding(get: { edid }, set: { value in if value != edid { pendingEDID = value } })) {
                    if edid.isEmpty { Text("Loading…").tag("") }
                    else if !builtinEDIDs.contains(where: { $0.id == edid }) && !customEDIDs.contains(edid) {
                        Text(edid.replacingOccurrences(of: ".bin", with: "")).tag(edid)
                    }
                    ForEach(builtinEDIDs, id: \.id) { Text($0.label).tag($0.id) }
                    ForEach(customEDIDs, id: \.self) { Text($0.replacingOccurrences(of: ".bin", with: "")).tag($0) }
                }
                .disabled(!powerOK)
                Toggle("Auto-switch to this device's display (also when the screen changes)", isOn: Binding(get: { autoEDID }, set: { autoEDID = $0; SyncedFlag.set($0, "autoEDID", session.device.id) }))
                    .disabled(!powerOK)
                Text("When on, connecting from this device switches the KVM to its matching EDID and removes the other variant. It also re-matches a few seconds after you plug in, unplug or move to another screen. Each screen gets its own EDID file. Synced via iCloud.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Match using", selection: $usePoints) {
                    Text("Native pixels (sharpest)").tag(false)
                    Text("Screen points (UI size)").tag(true)
                }
                Button("Match \(edidCtl.display.label) (\(nativeW)×\(nativeH))") { confirmMatch = true }
                    .disabled(!powerOK)
                Stepper("Refresh: \(matchHz) Hz", value: $matchHz, in: 24...60, step: 6)
                if !customEDIDs.isEmpty {
                    Button("Delete custom EDIDs", role: .destructive) { Task { await deleteCustom() } }
                }
                Toggle("HDMI capture", isOn: Binding(get: { hdmiCapture }, set: { v in Task { await run { try await session.client.setHDMICapture(v); hdmiCapture = v } } }))
            }
            Section("Input") {
                Picker("Target computer", selection: Binding(get: { session.keyboardTarget }, set: { session.keyboardTarget = $0 })) {
                    ForEach(KeyboardTarget.allCases) { Text($0.title).tag($0) }
                }
                Text("Chooses the modifier names, extra keys and shortcuts offered by the Keys menu and the on-screen keyboard bar. Per device.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Pointer mode", selection: Binding(get: { pointerMode }, set: { v in Task { await run { try await session.client.setPointerMode(v); pointerMode = v } } })) {
                    if pointerMode.isEmpty { Text("Loading…").tag("") }
                    Text("Absolute").tag("absolute")
                    Text("Relative").tag("relative")
                }
                #if os(iOS)
                Toggle("Trackpad mode", isOn: Binding(get: { session.trackpad }, set: { v in
                    session.trackpad = v
                    Task { await session.applyPointerMode(); pointerMode = v ? "relative" : "absolute" }
                }))
                if session.trackpad {
                    VStack(alignment: .leading) {
                        Text("Speed: \(session.trackpadSpeed, format: .number.precision(.fractionLength(1)))×")
                        Slider(value: Binding(get: { session.trackpadSpeed }, set: { session.trackpadSpeed = $0 }), in: PointerPrefs.speedRange, step: 0.1)
                    }
                }
                Toggle("Natural scrolling", isOn: Binding(get: { session.naturalScroll }, set: { session.naturalScroll = $0 }))
                Toggle("Swap ± § and ` ~ keys (ISO keyboards)", isOn: $swapISOKeys)
                NavigationLink("Adjust and test gestures") { GestureTuningView(session: session) }
                Text("Two-finger scroll: on moves the content with your fingers; off reverses the direction. Per device.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Touch moves the remote cursor like a laptop trackpad: drag to move, tap to click, two-finger tap to right-click, two-finger drag to scroll, hold briefly then drag to drag items. Sets the KVM to relative mode. Per device.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
                Toggle("Mouse jiggler", isOn: Binding(get: { jigglerEnabled }, set: { v in Task { await setJiggler(v) } }))
                Button("Reset USB HID") { Task { await run { try await session.client.resetHID(); session.reconnectInput() } } }
            }
            Section("Diagnostics") {
                Button("Prepare diagnostic file") {
                    Task { await run { diagnosticURL = try Diagnostics.write(summary: session.diagnosticSummary, log: KVMLog.store.contents()) } }
                }
                if let diagnosticURL { ShareLink(item: diagnosticURL) }
                Text("Connection events and state, without passwords. Share it when the picture or input stops working.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Device") {
                if let info = session.info {
                    LabeledContent("Hostname", value: info.mdns)
                    LabeledContent("Image", value: info.image)
                    LabeledContent("Application", value: info.application)
                    ForEach(info.ips) { LabeledContent($0.name, value: $0.addr) }
                }
                if let w = wifi?.wifi { LabeledContent("Wi-Fi", value: "\(w.ssid) (\(w.security))") }
                Toggle("SSH", isOn: Binding(get: { ssh }, set: { v in Task { await run { try await session.client.setSSH(v); ssh = v } } }))
                Toggle("mDNS (.local name)", isOn: Binding(get: { mdns }, set: { v in Task { await run { try await session.client.setMDNS(v); mdns = v } } }))
                Button("Reboot NanoKVM", role: .destructive) { confirmReboot = true }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            powerOK = PowerConfirmation.isConfirmed(session.device.id)
            autoEDID = SyncedFlag.isOn("autoEDID", session.device.id)
            usePoints = edidCtl.usePoints
            matchHz = edidCtl.hz
            if !loaded { await load() }
        }
        .confirmationDialog("Change the remote display to \(nativeW)×\(nativeH)?", isPresented: $confirmMatch) {
            Button("Apply") { Task { await matchNative() } }
        } message: {
            Text(powerWarning)
        }
        .confirmationDialog("Change the display EDID?", isPresented: Binding(get: { pendingEDID != nil }, set: { if !$0 { pendingEDID = nil } })) {
            Button("Change") { if let v = pendingEDID { Task { await switchEDID(v) } } }
        } message: {
            Text(powerWarning)
        }
        .confirmationDialog("Reboot the NanoKVM?", isPresented: $confirmReboot) {
            Button("Reboot", role: .destructive) { Task { await run { try await session.client.reboot() } } }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        let c = session.client
        encoder = try? await c.encoder()
        if let e = try? await c.edid() { edid = e.edid }
        customEDIDs = (try? await c.customEDIDs()) ?? []
        hdmiCapture = (try? await c.hdmiCapture()) ?? true
        pointerMode = (try? await c.pointerMode()) ?? "absolute"
        if let j = try? await c.jiggler() { jigglerEnabled = j.enabled; jigglerMode = j.mode }
        ssh = (try? await c.sshEnabled()) ?? false
        mdns = (try? await c.mdnsEnabled()) ?? false
        wifi = try? await c.wifi()
        loaded = true
    }

    private func apply(_ preset: QualityPreset) async {
        await run {
            try await session.client.setRateControl(preset.mode)
            try await session.client.setBitrate(preset.bitrate)
            try await session.client.setGOP(preset.gop)
            encoder = try? await session.client.encoder()
        }
    }

    private func setCodec(_ value: String) {
        codec = value
        UserDefaults.standard.set(value, forKey: "videoCodec")
        Task {
            do {
                try await session.client.setStreamMode("\(value)-direct")
                session.stream?.codec = VideoStream.Codec(rawValue: value) ?? .h264
                session.stream?.start()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func setFPS(_ fps: Int) async {
        await run {
            try await session.client.setFPS(fps)
            encoder = try? await session.client.encoder()
        }
    }

    private let powerWarning = "The signal drops for several seconds while the host re-detects the display. If no image returns within 45 s, the previous EDID is restored automatically."

    private func switchEDID(_ value: String) async {
        pendingEDID = nil
        await edidCtl.switchTo(value)
        await reloadEDIDs()
    }

    private func matchNative() async {
        edidCtl.usePoints = usePoints
        edidCtl.hz = matchHz
        await edidCtl.match(usePoints: usePoints, hz: matchHz)
        await reloadEDIDs()
    }

    private func reloadEDIDs() async {
        if let e = try? await session.client.edid() { edid = e.edid }
        customEDIDs = (try? await session.client.customEDIDs()) ?? customEDIDs
        if let e = edidCtl.error { error = e; edidCtl.error = nil }
    }

    private func deleteCustom() async {
        await run {
            if let current = try? await session.client.edid().edid, !builtinEDIDs.contains(where: { $0.id == current }) {
                try await session.client.setEDID("nanokvm-go-1920x1080-60")
            }
            for n in customEDIDs { try await session.client.deleteEDID(n) }
            customEDIDs = (try? await session.client.customEDIDs()) ?? []
            edid = (try? await session.client.edid().edid) ?? edid
        }
    }

    private func setJiggler(_ enabled: Bool) async {
        await run {
            try await session.client.setJiggler(enabled: enabled, mode: jigglerMode)
            jigglerEnabled = enabled
        }
    }
}

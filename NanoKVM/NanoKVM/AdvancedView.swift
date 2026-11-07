import SwiftUI
import UniformTypeIdentifiers

/// Remaining device options: USB identity/network, virtual devices, static IP, Wi-Fi preset,
/// security, image download, apps and the finger robot accessory.
struct AdvancedView: View {
    let session: DeviceSession
    @State private var page = PageState()
    private var client: KVMClient { session.client }

    // USB identity
    @State private var usbIdEnabled = false
    @State private var vid = ""
    @State private var pid = ""
    @State private var bcd = ""
    @State private var serial = ""
    @State private var maker = ""
    @State private var product = ""
    // USB network
    @State private var usbMode = "server"
    @State private var usbIPv4 = ""
    @State private var usbForwarding = false
    // Virtual devices
    @State private var virtual: JSON = [:]
    @State private var diskSize = 5120.0
    @State private var cdromName = ""
    @State private var cdromNameOn = false
    @State private var diskName = ""
    @State private var diskNameOn = false
    @State private var audioName = ""
    @State private var audioNameOn = false
    // Network
    @State private var staticOn = false
    @State private var staticIP = ""
    @State private var presetSSID = ""
    @State private var presetPass = ""
    // Security
    @State private var signature = true
    @State private var twoFA: JSON = [:]
    @State private var username = ""
    @State private var newUser = ""
    @State private var newPass = ""
    @State private var newPass2 = ""
    @State private var confirmPassword = false
    // Image download
    @State private var downloadURL = ""
    @State private var downloadEnabled = false
    @State private var downloadStatus: JSON = [:]
    // Finger robot, apps
    @State private var robot: JSON = [:]
    @State private var apps: [JSON] = []

    var body: some View {
        Form {
            usbSection
            virtualSection
            networkSection
            downloadSection
            securitySection
            robotSection
            appsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .pageAlerts(page)
        .task { await load() }
        .confirmationDialog("Change the login?", isPresented: $confirmPassword) {
            Button("Change", role: .destructive) { Task { await changePassword() } }
        } message: { Text("The new login is also saved in this app's Keychain. Other devices must be updated by editing the device.") }
    }

    // MARK: Sections

    private var usbSection: some View {
        Group {
            Section {
                Toggle("Custom USB identity", isOn: $usbIdEnabled)
                if usbIdEnabled {
                    TextField("Vendor ID (hex)", text: $vid)
                    TextField("Product ID (hex)", text: $pid)
                    TextField("bcdDevice", text: $bcd)
                    TextField("Serial number", text: $serial)
                    TextField("Manufacturer", text: $maker)
                    TextField("Product", text: $product)
                }
                Button("Apply USB identity") {
                    Task {
                        await page.run {
                            try await client.raw("POST", "/vm/usb-id", body: [
                                "enabled": usbIdEnabled, "vid": vid, "pid": pid, "bcdDevice": bcd,
                                "serialnumber": serial, "manufacturer": maker, "product": product,
                            ], timeout: 30)
                            page.notice = "USB identity applied. The target may re-enumerate the keyboard."
                        }
                    }
                }
            } header: { Text("USB identity") } footer: { Text("Changes how the KVM presents itself to the target computer.") }

            Section("USB network") {
                Picker("Mode", selection: $usbMode) {
                    Text("Server (KVM gives IP)").tag("server")
                    Text("Client").tag("client")
                }
                if usbMode == "server" {
                    TextField("IPv4 (blank = default)", text: $usbIPv4)
                    Toggle("Forward traffic to the network", isOn: $usbForwarding)
                }
                Button("Apply USB network") {
                    Task {
                        await page.run {
                            try await client.raw("POST", "/vm/usb-network", body: [
                                "mode": usbMode,
                                "ipv4": usbMode == "server" ? usbIPv4.trimmingCharacters(in: .whitespaces) : "",
                                "forwarding": usbMode == "server" && usbForwarding,
                            ], timeout: 30)
                            page.notice = "USB network applied."
                        }
                    }
                }
            }
        }
    }

    private var virtualSection: some View {
        Group {
            Section {
                virtualToggle("Virtual network adapter", device: "network", key: "isNetworkEnabled")
                virtualToggle("Virtual disk", device: "disk", key: "isDiskEnabled")
                if virtual.bool("isDiskEnabled") == false {
                    VStack(alignment: .leading) {
                        Text("Disk size: \(Int(diskSize)) MiB")
                        Slider(value: $diskSize,
                               in: Double(max(virtual.int("diskMinSizeMiB"), 1024))...Double(max(virtual.int("diskMaxSizeMiB"), 2048)),
                               step: 256)
                    }
                }
                Picker("Audio", selection: Binding(get: { virtual.str("audioMode").isEmpty ? "off" : virtual.str("audioMode") },
                                                   set: { v in Task { await page.run {
                                                       try await client.raw("POST", "/vm/device/virtual", body: ["device": "audio", "mode": v], timeout: 30)
                                                       virtual = try await client.get("/vm/device/virtual")
                                                   } } })) {
                    Text("Off").tag("off")
                    Text("Microphone").tag("mic")
                    Text("Microphone + speaker").tag("duplex")
                }
                Button("Refresh virtual devices on the target") {
                    Task { await page.run { try await client.raw("POST", "/vm/device/virtual/refresh", body: ["device": "disk"]) } }
                }
            } header: { Text("Virtual devices") } footer: { Text("Toggling a device briefly disconnects USB from the target.") }

            Section("Reported names") {
                nameRow("CD-ROM name", on: $cdromNameOn, text: $cdromName, path: "/vm/disk-inquiry-cdrom")
                nameRow("Disk name", on: $diskNameOn, text: $diskName, path: "/vm/disk-inquiry")
                nameRow("Audio function name", on: $audioNameOn, text: $audioName, path: "/vm/uac2-function-name")
            }
        }
    }

    private var networkSection: some View {
        Section {
            Toggle("Static IP", isOn: $staticOn)
            if staticOn { TextField("IP address (e.g. 10.0.0.50)", text: $staticIP) }
            Button("Apply static IP") {
                Task {
                    await page.run {
                        try await client.raw("POST", "/network/static-ip",
                                             body: ["enabled": staticOn, "ip": staticOn ? staticIP : ""], timeout: 30)
                        page.notice = "Saved. The new address applies after the KVM's network restarts or it reboots."
                    }
                }
            }
            TextField("Fallback Wi-Fi name", text: $presetSSID)
            SecureField("Fallback Wi-Fi password", text: $presetPass)
            HStack {
                Button("Save Wi-Fi preset") {
                    Task { await page.run { try await client.raw("POST", "/network/wifi/preset", body: ["ssid": presetSSID, "password": presetPass]) } }
                }.disabled(presetSSID.isEmpty)
                Button("Remove preset", role: .destructive) {
                    Task { await page.run { try await client.raw("POST", "/network/wifi/preset/remove"); presetSSID = ""; presetPass = "" } }
                }
            }
        } header: { Text("Network extras") } footer: { Text("A wrong static IP can make the KVM unreachable; a reboot from the device's own screen may be needed.") }
    }

    private var downloadSection: some View {
        Section {
            if downloadEnabled {
                TextField("Image URL", text: $downloadURL)
                Button("Download to the KVM") {
                    Task { await page.run { try await client.raw("POST", "/storage/download/image", body: ["file": downloadURL], timeout: 30); await refreshDownload() } }
                }.disabled(downloadURL.isEmpty)
                LabeledContent("Status", value: downloadStatus.str("status"))
                if !downloadStatus.str("percentage").isEmpty { LabeledContent("Progress", value: downloadStatus.str("percentage") + " %") }
                HStack {
                    Button("Pause") { Task { await page.run { try await client.raw("POST", "/storage/download/image/pause"); await refreshDownload() } } }
                    Button("Resume") { Task { await page.run { try await client.raw("POST", "/storage/download/image/resume"); await refreshDownload() } } }
                    Button("Cancel", role: .destructive) { Task { await page.run { try await client.raw("POST", "/storage/download/image/cancel"); await refreshDownload() } } }
                    Button("Refresh") { Task { await refreshDownload() } }
                }
            } else {
                Text("Not available on this device.").foregroundStyle(.secondary)
            }
        } header: { Text("Download an image to the KVM") }
    }

    private var securitySection: some View {
        Group {
            Section {
                Toggle("Verify update signatures", isOn: Binding(get: { signature }, set: { v in
                    Task { await page.run { try await client.raw("POST", "/application/signature-verification", body: ["enabled": v]); signature = v } }
                }))
                LabeledContent("Two-factor authentication", value: twoFA.bool("enabled") ? "On" : "Off")
                LabeledContent("Account", value: username)
            } header: { Text("Security") } footer: { Text("Two-factor setup needs an authenticator app and is only shown here, not changed.") }

            Section("Change login") {
                TextField("New username", text: $newUser)
                SecureField("New password", text: $newPass)
                SecureField("Repeat password", text: $newPass2)
                Button("Change login…", role: .destructive) { confirmPassword = true }
                    .disabled(newUser.isEmpty || newPass.count < 4 || newPass != newPass2)
            }
        }
    }

    private var robotSection: some View {
        Section {
            if robot.bool("available") {
                Toggle("Finger robot", isOn: .constant(robot.bool("enabled"))).disabled(true)
                HStack {
                    Button("Press") { Task { await page.run { try await client.raw("POST", "/vm/finger-robot/press", body: [:]) } } }
                    Button("Release") { Task { await page.run { try await client.raw("POST", "/vm/finger-robot/release", body: [:]) } } }
                }
            } else {
                Text("No finger robot accessory detected.").foregroundStyle(.secondary)
            }
        } header: { Text("Finger robot") }
    }

    private var appsSection: some View {
        Section {
            if apps.isEmpty { Text("No apps installed.").foregroundStyle(.secondary) }
            ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
                LabeledContent(app.str("name").isEmpty ? app.str("id") : app.str("name"), value: app.str("version"))
            }
        } header: { Text("Installed apps") }
    }

    // MARK: Helpers

    private func virtualToggle(_ title: String, device: String, key: String) -> some View {
        Toggle(title, isOn: Binding(get: { virtual.bool(key) }, set: { _ in
            Task {
                await page.run {
                    if device == "disk" && virtual.bool(key) {
                        try await client.raw("POST", "/vm/device/virtual/disk/disable", timeout: 60)
                    } else if device == "disk" {
                        try await client.raw("POST", "/vm/device/virtual", body: ["device": "disk", "diskSizeMiB": Int(diskSize)], timeout: 120)
                    } else {
                        try await client.raw("POST", "/vm/device/virtual", body: ["device": device], timeout: 30)
                    }
                    virtual = try await client.get("/vm/device/virtual")
                }
            }
        }))
    }

    private func nameRow(_ title: String, on: Binding<Bool>, text: Binding<String>, path: String) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: on)
            if on.wrappedValue {
                HStack {
                    TextField("Name", text: text)
                    Button("Save") { Task { await page.run { try await client.raw("POST", path, body: ["enabled": true, "value": text.wrappedValue]) } } }
                }
            } else {
                Button("Use default") { Task { await page.run { try await client.raw("POST", path, body: ["enabled": false, "value": ""]) } } }
                    .font(.footnote)
            }
        }
    }

    private func changePassword() async {
        await page.run {
            try await client.raw("POST", "/auth/password", body: ["username": newUser, "password": newPass])
            Keychain.setPassword(newPass, for: session.device.id)
            page.notice = "Login changed. If the app is asked to sign in again, edit the device with the new login (\(newUser))."
            newPass = ""; newPass2 = ""
        }
    }

    private func refreshDownload() async {
        downloadStatus = (try? await client.get("/storage/download/image/status")) ?? [:]
    }

    private func load() async {
        await page.run {
            if let d = try? await client.get("/vm/usb-id") {
                usbIdEnabled = d.bool("enabled"); vid = d.str("vid"); pid = d.str("pid"); bcd = d.str("bcdDevice")
                serial = d.str("serialnumber"); maker = d.str("manufacturer"); product = d.str("product")
            }
            if let d = try? await client.get("/vm/usb-network") {
                usbMode = d.str("mode") == "client" ? "client" : "server"
                usbIPv4 = d.str("ipv4"); usbForwarding = d.bool("forwarding")
            }
            if let d = try? await client.get("/vm/device/virtual") {
                virtual = d
                diskSize = Double(max(d.int("diskMinSizeMiB"), 5120))
            }
            if let d = try? await client.get("/vm/disk-inquiry-cdrom") { cdromNameOn = d.bool("enabled"); cdromName = d.str("value") }
            if let d = try? await client.get("/vm/disk-inquiry") { diskNameOn = d.bool("enabled"); diskName = d.str("value") }
            if let d = try? await client.get("/vm/uac2-function-name") { audioNameOn = d.bool("enabled"); audioName = d.str("value") }
            if let d = try? await client.get("/network/static-ip") { staticOn = d.bool("enabled"); staticIP = d.str("ip") }
            if let d = try? await client.get("/network/wifi/preset") { presetSSID = d.str("ssid") }
            if let d = try? await client.get("/application/signature-verification") { signature = d.bool("enabled") }
            if let d = try? await client.get("/auth/2fa/status") { twoFA = d }
            if let d = try? await client.get("/auth/account") { username = d.str("username"); newUser = username }
            if let d = try? await client.get("/storage/download/image/enabled") { downloadEnabled = d.bool("enabled") }
            robot = (try? await client.get("/vm/finger-robot")) ?? [:]
            if let data = try? await client.rawArray("/apps") { apps = data }
            await refreshDownload()
        }
    }
}

import SwiftUI

struct DevicePageView: View {
    let session: DeviceSession
    @State private var page = PageState()
    @State private var info: DeviceInfo?
    @State private var hardware = ""
    @State private var webTitle = ""
    @State private var timezone = ""
    @State private var timeSynced = false
    @State private var lowPower = false
    @State private var swap = false
    @State private var hidMode = "normal"
    @State private var version: JSON = [:]
    @State private var preview = false
    @State private var confirmReboot = false
    @State private var confirmUpdate = false

    private var client: KVMClient { session.client }

    var body: some View {
        Form {
            Section("Device") {
                if let info {
                    LabeledContent("Firmware image", value: info.image)
                    LabeledContent("Application", value: info.application)
                    LabeledContent("Hardware", value: hardware)
                    LabeledContent("Device key", value: info.deviceKey)
                    ForEach(info.ips) { ip in LabeledContent("\(ip.name) (\(ip.type))", value: ip.addr) }
                }
            }
            Section("General") {
                HStack {
                    TextField("Web UI title", text: $webTitle)
                    Button("Save") { Task { await page.run { try await client.setWebTitle(webTitle) } } }
                }
                Toggle("Low power mode", isOn: Binding(get: { lowPower }, set: { v in Task { await page.run { try await client.setLowPower(v); lowPower = v } } }))
                Toggle("Swap file", isOn: Binding(get: { swap }, set: { v in Task { await page.run { try await client.setSwap(v); swap = v } } }))
                Picker("USB mode", selection: Binding(get: { hidMode }, set: { v in Task { await page.run { try await client.setHidMode(v); hidMode = v } } })) {
                    Text("Normal (HID + storage + network)").tag("normal")
                    Text("HID only").tag("hid-only")
                }
            }
            Section("Time") {
                LabeledContent("Synchronized", value: timeSynced ? "Yes" : "No")
                HStack {
                    TextField("Time zone (e.g. Europe/Paris)", text: $timezone)
                    Button("Save") { Task { await page.run { try await client.setTimezone(timezone) } } }
                        .disabled(timezone.isEmpty)
                }
                Button("Sync time now") { Task { await page.run { try await client.syncTime(); await loadTime() } } }
            }
            Section("Updates") {
                LabeledContent("Installed", value: version.str("current"))
                LabeledContent("Latest", value: version.str("latest"))
                Toggle("Include preview releases", isOn: Binding(get: { preview }, set: { v in Task { await page.run { try await client.setPreviewUpdates(v); preview = v } } }))
                Button("Update now…") { confirmUpdate = true }
                    .disabled(version.str("current") == version.str("latest"))
            }
            Section("Power") {
                Button("Reboot KVM…", role: .destructive) { confirmReboot = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Device")
        .pageAlerts(page)
        .task { await load() }
        .confirmationDialog("Reboot the KVM?", isPresented: $confirmReboot) {
            Button("Reboot", role: .destructive) { Task { await page.run { try await client.reboot() } } }
        } message: { Text("The video and keyboard disappear for about a minute.") }
        .confirmationDialog("Update the KVM software?", isPresented: $confirmUpdate) {
            Button("Update") { Task { await page.run { try await client.updateApplication(); page.notice = "Update finished. The KVM may restart." } } }
        } message: { Text("This can take several minutes. Keep the KVM powered.") }
    }

    private func load() async {
        info = try? await client.info()
        hardware = (try? await client.get("/vm/hardware"))?.str("version") ?? ""
        webTitle = (try? await client.get("/vm/web-title"))?.str("title") ?? ""
        lowPower = (try? await client.get("/vm/low-power"))?.bool("enabled") ?? false
        swap = (try? await client.get("/vm/swap"))?.bool("enabled") ?? false
        hidMode = (try? await client.hidMode()) ?? "normal"
        timezone = (try? await client.get("/vm/timezone"))?.str("timezone") ?? ""
        version = (try? await client.appVersion()) ?? [:]
        preview = (try? await client.get("/application/preview"))?.bool("enabled") ?? false
        await loadTime()
    }

    private func loadTime() async {
        timeSynced = (try? await client.get("/vm/time/status"))?.bool("isSynchronized") ?? false
    }
}

import SwiftUI

struct NetworkView: View {
    let session: DeviceSession
    @State private var page = PageState()
    @State private var wifi: JSON = [:]
    @State private var networks: [JSON] = []
    @State private var scanning = false
    @State private var target: JSON?
    @State private var password = ""
    @State private var confirmDisconnect = false
    @State private var tailscale: JSON = [:]
    @State private var hostname = ""
    @State private var mdns = false
    @State private var ssh = false
    @State private var loginURL: URL?

    private var client: KVMClient { session.client }

    var body: some View {
        Form {
            wifiSection
            tailscaleSection
            Section("Name & access") {
                HStack {
                    TextField("Hostname", text: $hostname)
                    Button("Save") { Task { await page.run { try await client.setHostname(hostname); page.notice = "Hostname saved. It applies after a reboot." } } }
                        .disabled(hostname.isEmpty)
                }
                Toggle("mDNS (\(hostname).local)", isOn: Binding(get: { mdns }, set: { v in
                    Task { await page.run { try await client.command("POST", "/vm/mdns/\(v ? "enable" : "disable")"); mdns = v } }
                }))
                Toggle("SSH server", isOn: Binding(get: { ssh }, set: { v in
                    Task { await page.run { try await client.setSSH(v); ssh = v } }
                }))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Network")
        .pageAlerts(page)
        .task { await load() }
        .sheet(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil; password = "" } })) { connectSheet }
        .confirmationDialog("Disconnect Wi-Fi?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await page.run { try await client.wifiDisconnect() } } }
        } message: { Text("If this is how you reach the KVM, you will lose the connection.") }
    }

    private var wifiSection: some View {
        Section("Wi-Fi") {
            LabeledContent("Status", value: wifi.bool("connected") ? ((wifi["wifi"] as? JSON)?.str("ssid") ?? "Connected") : "Not connected")
            Button(scanning ? "Scanning…" : "Scan for networks", systemImage: "wifi") { Task { await scan() } }
                .disabled(scanning)
            ForEach(Array(networks.enumerated()), id: \.offset) { _, n in
                Button { target = n } label: {
                    HStack {
                        Text(n.str("ssid"))
                        Spacer()
                        Text("\(n.str("security")) · \(n.int("signal")) dBm").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if wifi.bool("connected") {
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
            }
        }
    }

    private var tailscaleSection: some View {
        Section("Tailscale") {
            let state = tailscale.str("state")
            LabeledContent("State", value: state.isEmpty ? "Unknown" : state)
            if !tailscale.str("ip").isEmpty { LabeledContent("Address", value: tailscale.str("ip")) }
            if !tailscale.str("account").isEmpty { LabeledContent("Account", value: tailscale.str("account")) }
            switch state {
            case "running":
                Button("Disconnect (down)") { Task { await ts("down") } }
                Toggle("Advertise as exit node", isOn: Binding(get: { tailscale.bool("advertiseExitNode") }, set: { v in
                    Task { await page.run { try await client.tailscaleToggle("exit-node", v) }; await refreshTailscale() }
                }))
                Toggle("Advertise LAN subnet \(tailscale.str("lanSubnet"))", isOn: Binding(get: { tailscale.bool("advertiseSubnetRoute") }, set: { v in
                    Task { await page.run { try await client.tailscaleToggle("subnet-route", v) }; await refreshTailscale() }
                }))
                Button("Log out", role: .destructive) { Task { await ts("logout") } }
            case "stopped": Button("Connect (up)") { Task { await ts("up") } }
            case "notLogin": Button("Log in…") { Task { await login() } }
            case "notRunning": Button("Start service") { Task { await ts("start") } }
            case "notInstall": Text("Tailscale is not installed on the KVM. Install it from the web interface.").font(.footnote).foregroundStyle(.secondary)
            default: EmptyView()
            }
            if let loginURL { Link("Open login page", destination: loginURL) }
        }
    }

    private var connectSheet: some View {
        NavigationStack {
            Form {
                Section("Connect to \(target?.str("ssid") ?? "")") {
                    SecureField("Password", text: $password)
                    Text("Warning: the KVM drops its current connection while joining. If the join fails you may have to reboot it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { target = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let ssid = target?.str("ssid") ?? ""
                        let pw = password
                        target = nil; password = ""
                        Task { await page.run { try await client.wifiConnect(ssid: ssid, password: pw) } }
                    }.disabled(password.isEmpty)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 220)
    }

    private func load() async {
        wifi = (try? await client.get("/network/wifi")) ?? [:]
        hostname = (try? await client.hostname()) ?? ""
        mdns = (try? await client.mdnsEnabled()) ?? false
        ssh = (try? await client.sshEnabled()) ?? false
        await refreshTailscale()
    }

    private func refreshTailscale() async { tailscale = (try? await client.tailscale()) ?? [:] }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        await page.run { networks = try await client.wifiScan() }
    }

    private func ts(_ action: String) async {
        await page.run { _ = try await client.tailscaleAction(action) }
        await refreshTailscale()
    }

    private func login() async {
        await page.run {
            let d = try await client.tailscaleAction("login")
            loginURL = URL(string: d.str("url"))
        }
    }
}

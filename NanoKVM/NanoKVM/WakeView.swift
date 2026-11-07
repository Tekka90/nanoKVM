import SwiftUI

struct WakeView: View {
    let session: DeviceSession
    @State private var entries: [WoLEntry] = []
    @State private var newMac = ""
    @State private var newName = ""
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Saved machines") {
                if entries.isEmpty { Text("No saved MAC addresses").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.name.isEmpty ? entry.mac : entry.name)
                            if !entry.name.isEmpty { Text(entry.mac).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Wake", systemImage: "power") { Task { await wake(entry.mac) } }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { Task { await remove(entry) } } }
                    #if os(macOS)
                    .contextMenu { Button("Remove", role: .destructive) { Task { await remove(entry) } } }
                    #endif
                }
            }
            Section("Add / wake a MAC address") {
                TextField("AA:BB:CC:DD:EE:FF", text: $newMac).autocorrectionDisabled()
                TextField("Name (optional)", text: $newName)
                HStack {
                    Button("Wake now") { Task { await wake(newMac) } }
                    Button("Save") { Task { await save() } }
                }
                .disabled(!isValidMAC(newMac))
            }
            if let status { Section { Text(status).foregroundStyle(.green) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Wake on LAN")
        .task { await refresh() }
    }

    private func isValidMAC(_ s: String) -> Bool {
        s.range(of: #"^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
    }

    private func refresh() async {
        do { entries = try await session.client.wolList() } catch { entries = [] }
    }

    private func wake(_ mac: String) async {
        do {
            try await session.client.wake(mac: mac)
            status = "Magic packet sent to \(mac)"
            error = nil
        } catch { self.error = error.localizedDescription; status = nil }
    }

    private func save() async {
        do {
            // The device stores a MAC when a magic packet is sent to it.
            try await session.client.wake(mac: newMac)
            if !newName.isEmpty { try await session.client.nameWoL(mac: newMac, name: newName) }
            newMac = ""; newName = ""
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ entry: WoLEntry) async {
        do {
            try await session.client.removeWoL(mac: entry.mac)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

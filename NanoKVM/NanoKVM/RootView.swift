import SwiftUI

struct RootView: View {
    @State private var store = DeviceStore()
    @State private var discovery = DeviceDiscovery()
    @State private var selected: SavedDevice.ID?
    @State private var editing: SavedDevice?
    @State private var showAdd = false
    @State private var addPrefill: DiscoveredDevice?
    @State private var confirmRemove = false

    private var current: SavedDevice? {
        store.devices.first { $0.id == selected } ?? store.devices.first
    }

    var body: some View {
        Group {
            if let device = current {
                DeviceView(device: device, deviceMenu: AnyView(deviceMenu(for: device))).id(device)
            } else {
                ContentUnavailableView {
                    Label("No devices", systemImage: "display")
                } description: {
                    Text("Add your NanoKVM to get started.")
                } actions: {
                    Button("Add Device") { addPrefill = nil; showAdd = true }
                    ForEach(discovery.found) { found in
                        Button("Add \(found.name)") { addPrefill = found; showAdd = true }
                    }
                }
            }
        }
        #if os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        .confirmationDialog("Remove this device?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { if let current { store.remove(current) } }
        }
        .sheet(isPresented: $showAdd) {
            DeviceForm(device: nil, prefill: addPrefill) { device, password in
                store.add(device, password: password)
                selected = device.id
            }
        }
        .sheet(item: $editing) { device in
            DeviceForm(device: device, prefill: nil) { updated, password in
                store.update(updated, password: password)
            }
        }
        .onAppear { discovery.start() }
    }

    private func deviceMenu(for device: SavedDevice) -> some View {
        let unsaved = discovery.found.filter { d in !store.devices.contains { $0.host == d.host } }
        return Menu {
            ForEach(store.devices) { d in
                Button { selected = d.id } label: {
                    Label(d.name, systemImage: d.id == device.id ? "checkmark" : "display")
                }
            }
            Divider()
            Button("Add Device…", systemImage: "plus") { addPrefill = nil; showAdd = true }
            ForEach(unsaved) { found in
                Button("Add \(found.name)…", systemImage: "plus.circle") { addPrefill = found; showAdd = true }
            }
            Divider()
            Button("Edit “\(device.name)”…", systemImage: "pencil") { editing = device }
            Button("Remove “\(device.name)”…", systemImage: "trash", role: .destructive) { confirmRemove = true }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "externaldrive.connected.to.line.below").font(.title3)
                Text(device.name).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
    }
}

struct DeviceForm: View {
    let device: SavedDevice?
    let prefill: DiscoveredDevice?
    let onSave: (SavedDevice, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var username = "admin"
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Host or IP (e.g. kvm-studio.local)", text: $host)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(device == nil ? "Password" : "Password (leave empty to keep)", text: $password)
            }
            .formStyle(.grouped)
            .navigationTitle(device == nil ? "Add Device" : "Edit Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var d = device ?? SavedDevice(name: name, host: host, username: username)
                        d.name = name.isEmpty ? host : name
                        d.host = host.trimmingCharacters(in: .whitespaces)
                        d.username = username
                        onSave(d, password)
                        dismiss()
                    }
                    .disabled(host.isEmpty || username.isEmpty || (device == nil && password.isEmpty))
                }
            }
        }
        .onAppear {
            if let device {
                name = device.name; host = device.host; username = device.username
            } else if let prefill {
                name = prefill.name; host = prefill.host
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

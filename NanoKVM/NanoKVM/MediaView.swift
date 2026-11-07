import SwiftUI
import UniformTypeIdentifiers

struct MediaView: View {
    let session: DeviceSession
    @State private var images: [String] = []
    @State private var mounted: MountedImage?
    @State private var asCDROM = true
    @State private var readOnly = true
    @State private var busy = false
    @State private var uploadProgress: Double?
    @State private var showImporter = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Mounted") {
                if let mounted, mounted.mounted {
                    LabeledContent("Image", value: (mounted.file as NSString).lastPathComponent)
                    LabeledContent("Type", value: mounted.cdrom ? "CD-ROM" : "Disk")
                    Button("Eject", role: .destructive) { Task { await unmount() } }.disabled(busy)
                } else {
                    Text("Nothing mounted").foregroundStyle(.secondary)
                }
            }
            Section("Mount options") {
                Picker("Present as", selection: $asCDROM) {
                    Text("CD-ROM").tag(true)
                    Text("USB disk").tag(false)
                }
                Toggle("Read only", isOn: $readOnly)
            }
            Section("Images on device") {
                if images.isEmpty { Text("No images").foregroundStyle(.secondary) }
                ForEach(images, id: \.self) { file in
                    HStack {
                        Label((file as NSString).lastPathComponent, systemImage: "opticaldisc")
                        Spacer()
                        Button("Mount") { Task { await mount(file) } }.disabled(busy)
                    }
                    #if os(macOS)
                    .contextMenu { Button("Delete", role: .destructive) { Task { await delete(file) } } }
                    #endif
                    .swipeActions { Button("Delete", role: .destructive) { Task { await delete(file) } } }
                }
            }
            Section("Upload") {
                Button("Refresh list", systemImage: "arrow.clockwise") { Task { await refresh() } }
                if let uploadProgress {
                    ProgressView(value: uploadProgress)
                } else {
                    Button("Upload image…", systemImage: "square.and.arrow.up") { showImporter = true }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Virtual Media")
        .task { await refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await upload(url) } }
        }
    }

    private func refresh() async {
        do {
            images = try await session.client.images()
            mounted = try await session.client.mountedImage()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func mount(_ file: String) async {
        busy = true
        defer { busy = false }
        do {
            try await session.client.mount(file: file, cdrom: asCDROM, readOnly: readOnly)
            session.reconnectInput()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func unmount() async {
        busy = true
        defer { busy = false }
        do {
            try await session.client.mount(file: "", cdrom: asCDROM, readOnly: readOnly)
            session.reconnectInput()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ file: String) async {
        do {
            try await session.client.deleteImage(file)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func upload(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            try await session.client.uploadImage(at: url) { value in
                Task { @MainActor in uploadProgress = value }
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

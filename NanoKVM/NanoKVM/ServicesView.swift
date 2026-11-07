import SwiftUI
import UniformTypeIdentifiers

struct ServicesView: View {
    let session: DeviceSession
    @State private var page = PageState()
    @State private var mcp = false
    @State private var memoryFabric = false
    @State private var timelapse = false
    @State private var memoryMiB = 0
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var confirmRegenerate = false
    @State private var scripts: [String] = []
    @State private var scriptLog: String?
    @State private var importing = false

    private var client: KVMClient { session.client }
    private var endpoint: String { "https://\(session.device.host)/api/mcp" }

    private var clientConfig: String {
        """
        {
          "mcpServers": {
            "nanokvm": {
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(apiKey)" }
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section("MCP server (AI control)") {
                Toggle("Enable MCP", isOn: Binding(get: { mcp }, set: { v in Task { await setMCP(v) } }))
                if mcp {
                    LabeledContent("Endpoint") { Text(endpoint).textSelection(.enabled) }
                    LabeledContent("API key") { Text(showKey ? apiKey : String(repeating: "•", count: 12)).textSelection(.enabled) }
                    Button(showKey ? "Hide key" : "Show key") { Task { await toggleKey() } }
                    Button("Copy key", systemImage: "doc.on.doc") { Task { await copyKey() } }
                    Button("Copy client configuration", systemImage: "curlybraces") { Task { await copyConfig() } }
                    Button("Regenerate key…", role: .destructive) { confirmRegenerate = true }
                }
                Text("Lets an AI assistant see the screen and control the keyboard and mouse. Anyone with the key has full control of the target machine.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Other AI services") {
                if memoryMiB > 0 { LabeledContent("KVM memory", value: "\(memoryMiB) MiB") }
                Toggle("Memory fabric", isOn: Binding(get: { memoryFabric }, set: { v in Task { await page.run { try await client.setMemoryFabric(v); memoryFabric = v } } }))
                Toggle("Screen timelapse", isOn: Binding(get: { timelapse }, set: { v in Task { await page.run { try await client.setTimelapse(v); timelapse = v } } }))
                Text("These need at least 200 MiB of free memory on the KVM.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Scripts on the KVM") {
                if scripts.isEmpty { Text("No scripts").foregroundStyle(.secondary) }
                ForEach(scripts, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Run") { Task { await run(name, background: false) } }
                        Button("Background") { Task { await run(name, background: true) } }
                        Button(role: .destructive) { Task { await page.run { try await client.deleteScript(name); await reloadScripts() } } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }
                Button("Upload script…", systemImage: "square.and.arrow.up") { importing = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Services")
        .pageAlerts(page)
        .task { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                await page.run {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try await client.uploadScript(try Data(contentsOf: url), filename: url.lastPathComponent)
                    await reloadScripts()
                }
            }
        }
        .confirmationDialog("Regenerate the MCP key?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { Task { await page.run { apiKey = try await client.regenerateMCPKey(); showKey = true } } }
        } message: { Text("Every client using the old key stops working.") }
        .sheet(isPresented: Binding(get: { scriptLog != nil }, set: { if !$0 { scriptLog = nil } })) {
            NavigationStack {
                ScrollView { Text(scriptLog ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle("Script output")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { scriptLog = nil } } }
            }
            .frame(minWidth: 420, minHeight: 300)
        }
    }

    private func load() async {
        if let services = try? await client.aiServices() { memoryMiB = services.int("memoryMiB") }
        mcp = (try? await client.get("/ai/config"))?.bool("mcpEnabled") ?? false
        memoryFabric = (try? await client.get("/ai/memory-fabric"))?.bool("enabled") ?? false
        timelapse = (try? await client.get("/ai/screen-timelapse/state"))?.bool("enabled") ?? false
        await reloadScripts()
    }

    private func reloadScripts() async { scripts = (try? await client.scripts()) ?? [] }

    private func setMCP(_ on: Bool) async {
        await page.run {
            try await client.setMCP(on)
            mcp = on
            apiKey = ""
            showKey = false
        }
    }

    private func ensureKey() async throws {
        if apiKey.isEmpty { apiKey = try await client.mcpKey() }
    }

    private func toggleKey() async {
        if !showKey { await page.run { try await ensureKey() } }
        showKey.toggle()
    }

    private func copyKey() async {
        await page.run { try await ensureKey(); copyToClipboard(apiKey); page.notice = "API key copied." }
    }

    private func copyConfig() async {
        await page.run { try await ensureKey(); copyToClipboard(clientConfig); page.notice = "Client configuration copied." }
    }

    private func run(_ name: String, background: Bool) async {
        await page.run {
            let log = try await client.runScript(name, background: background)
            scriptLog = background ? "Started in the background.\n\(log)" : (log.isEmpty ? "(no output)" : log)
        }
    }
}

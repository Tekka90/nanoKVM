import SwiftUI

private enum Section_: String, CaseIterable, Identifiable {
    case screen = "Screen", media = "Media", wake = "Wake", network = "Network", services = "Services", device = "Device", advanced = "Advanced", settings = "Settings"
    var id: String { rawValue }
    /// Pages grouped under the single "KVM" rail entry.
    static let kvmPages: [Section_] = [.media, .wake, .network, .services, .device, .advanced]
    var icon: String {
        switch self {
        case .screen: "display"
        case .media: "opticaldisc"
        case .wake: "power"
        case .network: "network"
        case .services: "sparkles"
        case .device: "cpu"
        case .advanced: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

struct DeviceView: View {
    let device: SavedDevice
    let deviceMenu: AnyView
    @State private var session: DeviceSession
    @State private var selection: Section_ = .screen
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var hideTask: Task<Void, Never>?
    @AppStorage("captureShortcuts") private var captureShortcuts = true
    private var fullScreen: Bool { FullScreenState.shared.active }
    private var railRevealed: Bool { FullScreenState.shared.railRevealed }

    init(device: SavedDevice, deviceMenu: AnyView) {
        self.device = device
        self.deviceMenu = deviceMenu
        _session = State(initialValue: DeviceSession(device: device))
    }

    var body: some View {
        Group {
            switch session.state {
            case .connecting:
                ProgressView("Connecting to \(device.name)…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't connect", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await session.takeOver() } }
                    // Lets you re-enter the password, switch device or remove this one.
                    deviceMenu.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .frame(maxWidth: 160)
                }
            case .inUseElsewhere(let other):
                ContentUnavailableView {
                    Label("In use on \(other)", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Only one device connects to this KVM at a time. Taking over disconnects \(other).")
                } actions: {
                    Button("Take over") { Task { await session.takeOver() } }
                        .buttonStyle(.borderedProminent)
                }
            case .connected:
                connected
            }
        }
        .task(id: device.id) {
            await session.connect()
            guard session.state == .connected else { return }
            session.startSupervising()
            session.edidController.startMonitoring()
            await session.edidController.autoSwitchIfNeeded()
        }
        .alert("Display", isPresented: Binding(get: { session.edidController.error != nil }, set: { if !$0 { session.edidController.error = nil } })) {
            Button("OK") {}
        } message: { Text(session.edidController.error ?? "") }
        .overlay {
            if let status = session.edidController.status {
                VStack(spacing: 12) { ProgressView(); Text(status).multilineTextAlignment(.center) }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onChange(of: scenePhase) { old, phase in
            guard phase == .active else { return }
            // Sockets are usually dead after the app was suspended, even if they look open.
            if old == .background || session.needsRecovery { Task { await session.recover() } }
        }
        .onDisappear { session.disconnect() }
    }

    // MARK: Layout

    private var connected: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if !fullScreen { rail }
                content
            }
            if fullScreen {
                Color.clear
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { if $0 { reveal() } }
                    .onTapGesture { reveal() }
                    .gesture(DragGesture(minimumDistance: 8).onEnded { _ in reveal() })
                #if os(iOS)
                // No hover on touch screens: tapping the content dismisses the rail.
                if railRevealed {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { FullScreenState.shared.railRevealed = false }
                }
                #endif
                if railRevealed {
                    rail
                        .onHover { inside in inside ? hideTask?.cancel() : scheduleHide() }
                        .transition(.move(edge: .leading))
                }
            }
            // Keeps the shortcut alive while the rail is hidden.
            Button("") { toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0)
        }
        .animation(.easeOut(duration: 0.15), value: railRevealed)
        // Folding or unfolding a dual-screen phone resizes the view without a screen notification.
        .onGeometryChange(for: CGSize.self, of: \.size) { _ in session.edidController.displayMayHaveChanged() }
        .ignoresSafeArea(edges: fullScreen ? .all : [])
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $showPaste) { pasteSheet }
        .alert("Error", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        #if os(iOS)
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
        #else
        .task {
            // The window may already be full screen when restored at launch.
            try? await Task.sleep(for: .milliseconds(600))
            if let w = NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) }) {
                w.styleMask.insert(.fullSizeContentView)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                FullScreenState.shared.active = true
                if captureShortcuts {
                    NSApp.presentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock, .disableProcessSwitching, .disableHideApplication]
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if let w = note.object as? NSWindow {
                w.styleMask.insert(.fullSizeContentView)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
            }
            FullScreenState.shared.active = true
            if captureShortcuts {
                NSApp.presentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock, .disableProcessSwitching, .disableHideApplication]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            FullScreenState.shared.active = false
            FullScreenState.shared.railRevealed = false
            NSApp.presentationOptions = []
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .screen: ScreenView(session: session)
        case .media: NavigationStack { MediaView(session: session) }
        case .wake: NavigationStack { WakeView(session: session) }
        case .network: NavigationStack { NetworkView(session: session) }
        case .services: NavigationStack { ServicesView(session: session) }
        case .device: NavigationStack { DevicePageView(session: session) }
        case .advanced: NavigationStack { AdvancedView(session: session) }
        case .settings: NavigationStack { SettingsView(session: session) }
        }
    }

    // MARK: Rail

    // Scrolls when short (keyboard up, landscape phone) so it never forces the row taller than the screen.
    private var rail: some View {
        GeometryReader { geo in
            ScrollView {
                railItems
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                    .frame(width: 76)
                    .frame(minHeight: geo.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 76)
        .background(.regularMaterial)
    }

    private var railItems: some View {
        VStack(spacing: 4) {
            deviceMenu
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            Divider().padding(.vertical, 6)
            Button { selection = .screen } label: {
                railLabel("Screen", Section_.screen.icon, highlighted: selection == .screen)
            }
            .buttonStyle(.plain)
            Menu {
                ForEach(Section_.kvmPages) { page in
                    Button { selection = page } label: { Label(page.rawValue, systemImage: page.icon) }
                }
            } label: {
                railLabel("KVM", "server.rack", highlighted: Section_.kvmPages.contains(selection))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            Button { selection = .settings } label: {
                railLabel("Settings", Section_.settings.icon, highlighted: selection == .settings)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if selection == .screen, let input = session.input {
                Divider().padding(.vertical, 6)
                Menu {
                    #if os(macOS)
                    Toggle("Send ⌘ shortcuts to remote", isOn: $captureShortcuts)
                    Divider()
                    #endif
                    ForEach(session.keyboardTarget.combos) { combo in Button(combo.name) { input.sendCombo(combo.usages) } }
                } label: { railLabel("Keys", "keyboard") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                #if os(iOS)
                Button { session.softKeyboard.toggle() } label: { railLabel("Type", "keyboard.badge.ellipsis", highlighted: session.softKeyboard) }
                    .buttonStyle(.plain)
                #endif
                Button { showPaste = true } label: { railLabel("Paste", "doc.on.clipboard") }
                    .buttonStyle(.plain)
                Button { Task { await session.recover() } } label: { railLabel("Reconnect", "arrow.clockwise") }
                    .buttonStyle(.plain)
                Button { toggleFullScreen() } label: {
                    railLabel(fullScreen ? "Exit" : "Full", fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
            }
            #if os(macOS)
            Divider().padding(.vertical, 6)
            Button { NSApp.terminate(nil) } label: { railLabel("Quit", "power") }
                .buttonStyle(.plain)
            #endif
        }
    }

    private func railLabel(_ title: String, _ icon: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
        .background(highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func reveal() {
        hideTask?.cancel()
        FullScreenState.shared.railRevealed = true
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { FullScreenState.shared.railRevealed = false }
        }
    }

    private func toggleFullScreen() {
        #if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
        #else
        withAnimation {
            FullScreenState.shared.active.toggle()
            FullScreenState.shared.railRevealed = false
        }
        #endif
    }

    // MARK: Paste

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Typed on the remote machine as keystrokes.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pasteText)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .border(.quaternary)
            }
            .padding()
            .navigationTitle("Paste Text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPaste = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let text = pasteText
                        showPaste = false
                        Task {
                            do { try await session.client.pasteText(text) } catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(pasteText.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

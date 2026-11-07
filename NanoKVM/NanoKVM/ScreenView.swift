import SwiftUI

struct KeyCombo: Identifiable {
    var id: String { name }
    let name: String
    let usages: [UInt8]
}

struct ScreenView: View {
    let session: DeviceSession

    var body: some View {
        if let stream = session.stream, let input = session.input {
            let state = FullScreenState.shared
            ZStack {
                Color.black
                InteractiveVideoView(layer: stream.layer, input: input, videoSize: stream.videoSize,
                                     trackpad: session.trackpad, trackpadSpeed: session.trackpadSpeed, naturalScroll: session.naturalScroll, tuning: session.gestureTuning,
                                     softKeyboard: session.softKeyboard, keyboardTarget: session.keyboardTarget, onSoftKeyboardHidden: { session.softKeyboard = false },
                                     reserveLeft: state.active ? (state.railRevealed ? 90 : 10) : 0)
                overlay(for: stream.state)
                StatsOverlay(stream: stream)
            }
            .ignoresSafeArea(edges: state.active ? .all : [.bottom, .trailing])
            .ignoresSafeArea(.keyboard)
            .task(id: session.trackpad) { if session.trackpad { await session.applyPointerMode() } }
            .task(id: stream.state.isNoSignal) {
                // Host display asleep: nudge it with a harmless key, a few times, then give up.
                guard stream.state.isNoSignal else { return }
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled, stream.state.isNoSignal else { return }
                    if input.isConnected { input.wake() }
                }
            }
            .task(id: stream.state.isFailed) {
                // Back off a few times automatically before asking the user.
                guard stream.state.isFailed else { return }
                for delay in [1.0, 3.0, 6.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, stream.state.isFailed else { return }
                    if await session.recover() { return }
                }
            }
            .onAppear { session.screenAppearances += 1; stream.start(); if !input.isConnected { input.connect() } }
            .onDisappear {
                session.screenAppearances -= 1
                input.releaseAll()
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if session.screenAppearances <= 0 { stream.stop() }
                }
            }
        } else {
            ContentUnavailableView("Not connected", systemImage: "display")
        }
    }

    @ViewBuilder
    private func overlay(for state: VideoStream.State) -> some View {
        switch state {
        case .connecting:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("Waiting for video…")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            }
        case .noSignal(let reason):
            Label(reason, systemImage: "display.trianglebadge.exclamationmark").foregroundStyle(.white)
        case .failed(let error):
            VStack {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await session.recover() } }
            }
        default:
            EmptyView()
        }
    }
}

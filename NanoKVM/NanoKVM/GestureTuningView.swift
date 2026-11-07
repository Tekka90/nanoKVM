#if os(iOS)
import SwiftUI

/// A practice area that runs the real trackpad gesture code without sending anything to the KVM,
/// with sliders for every threshold.
struct GestureTuningView: View {
    let session: DeviceSession
    @State private var log: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            GestureTestPad(tuning: session.gestureTuning, speed: session.trackpadSpeed, naturalScroll: session.naturalScroll) { line in
                log.append(line)
                if log.count > 40 { log.removeFirst(log.count - 40) }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                Text("Practice here: click, double-click, right-click (two fingers), scroll (two fingers), drag, tap-and-hold.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(8).allowsHitTesting(false)
            }
            .padding()
            HStack {
                Text("Events").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.removeAll() }.font(.caption)
            }
            .padding(.horizontal)
            ScrollView {
                Text(log.reversed().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .frame(height: 110)
            Form { sliders }
        }
        .navigationTitle("Gesture tuning")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var sliders: some View {
        Section("Pointer") {
            slider("Speed", \.trackpadSpeedProxy, PointerPrefs.speedRange, 0.1, "×")
            tuned("Acceleration boost", \.accelerationBoost, GestureTuning.accelerationBoostRange, 0.1, "×")
            tuned("Scroll step (pt per tick)", \.scrollStep, GestureTuning.scrollStepRange, 1, " pt")
            Toggle("Natural scrolling", isOn: Binding(get: { session.naturalScroll }, set: { session.naturalScroll = $0 }))
        }
        Section("Tap") {
            tuned("Max tap duration", \.tapMaxDuration, GestureTuning.tapMaxDurationRange, 0.05, " s")
            tuned("Max tap movement", \.tapMaxMovement, GestureTuning.tapMaxMovementRange, 1, " pt")
        }
        Section("Double-tap and hold") {
            tuned("Max gap before second touch", \.doubleTapGap, GestureTuning.doubleTapGapRange, 0.05, " s")
            tuned("Max distance to second touch", \.doubleTapDistance, GestureTuning.doubleTapDistanceRange, 5, " pt")
            tuned("Tap-then-press minimum", \.tapHoldDuration, GestureTuning.tapHoldDurationRange, 0.05, " s")
        }
        Section("Press and hold") {
            tuned("Hold duration", \.holdDuration, GestureTuning.holdDurationRange, 0.05, " s")
        }
        Section {
            Button("Reset to defaults", role: .destructive) {
                session.gestureTuning = GestureTuning()
                session.trackpadSpeed = PointerPrefs.defaultSpeed
                session.naturalScroll = true
            }
        }
    }

    private func tuned(_ title: String, _ key: WritableKeyPath<GestureTuning, Double>, _ range: ClosedRange<Double>, _ step: Double, _ unit: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(session.gestureTuning[keyPath: key], format: .number.precision(.fractionLength(step < 1 ? 2 : 0)))\(unit)")
            Slider(value: Binding(get: { session.gestureTuning[keyPath: key] }, set: { session.gestureTuning[keyPath: key] = $0 }), in: range, step: step)
        }
    }

    private func slider(_ title: String, _ key: ReferenceWritableKeyPath<DeviceSession, Double>, _ range: ClosedRange<Double>, _ step: Double, _ unit: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(session[keyPath: key], format: .number.precision(.fractionLength(1)))\(unit)")
            Slider(value: Binding(get: { session[keyPath: key] }, set: { session[keyPath: key] = $0 }), in: range, step: step)
        }
    }
}

private extension DeviceSession {
    var trackpadSpeedProxy: Double {
        get { trackpadSpeed }
        set { trackpadSpeed = newValue }
    }
}

private struct GestureTestPad: UIViewRepresentable {
    let tuning: GestureTuning
    let speed: Double
    let naturalScroll: Bool
    let onEvent: (String) -> Void

    func makeUIView(context: Context) -> InputUIView {
        let view = InputUIView()
        view.trackpad = true
        return view
    }

    func updateUIView(_ view: InputUIView, context: Context) {
        view.tuning = tuning
        view.engine.speed = speed
        view.engine.naturalScroll = naturalScroll
        view.onEvent = onEvent
    }
}
#endif

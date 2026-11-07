#if os(iOS)
import AVFoundation
import Testing
import UIKit
@testable import NanoKVM

@MainActor
struct IOSInputViewTests {
    final class Capture { var messages: [Data] = [] }

    private func make() -> (InputUIView, Capture) {
        let sender = InputSender(host: "unused.test", token: "t")
        let capture = Capture()
        sender.onSend = { capture.messages.append($0) }
        let view = InputUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.input = sender
        view.videoSize = CGSize(width: 1920, height: 1080)
        return (view, capture)
    }

    @Test func typedTextIsForwardedAsKeyReports() {
        let (v, c) = make()
        v.insertText("a")
        #expect(!c.messages.isEmpty)
    }

    @Test func deleteSendsBackspace() {
        let (v, c) = make()
        v.deleteBackward()
        #expect(!c.messages.isEmpty)
        #expect(v.hasText)
    }

    @Test func systemKeyboardStaysHiddenUntilRequested() {
        let (v, _) = make()
        #expect(v.inputView != nil)
        #expect(v.inputAccessoryView == nil)
        v.softKeyboard = true
        #expect(v.inputView == nil)
        #expect(v.inputAccessoryView != nil)
        v.softKeyboard = false
        #expect(v.inputView != nil)
    }

    @Test func keyboardTargetChangeIsAccepted() {
        let (v, _) = make()
        v.keyboardTarget = .mac
        v.keyboardTarget = .windows
        #expect(v.keyboardTarget == .windows)
    }

    @Test func textInputTraitsDisableAutocorrection() {
        let (v, _) = make()
        #expect(v.autocorrectionType == .no)
        #expect(v.autocapitalizationType == .none)
        #expect(v.keyboardType == .asciiCapable)
        #expect(v.canBecomeFirstResponder)
    }

    @Test func reservedStripPassesTouchesThrough() {
        let (v, _) = make()
        v.reserveLeft = 60
        #expect(v.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)
        #expect(v.hitTest(CGPoint(x: 200, y: 100), with: nil) != nil)
    }

    @Test func trackpadModeCanBeToggled() {
        let (v, _) = make()
        v.trackpad = true
        v.trackpad = false
        #expect(!v.trackpad)
    }

    @Test func tuningIsApplied() {
        let (v, _) = make()
        var t = GestureTuning()
        t.scrollStep = 33
        t.accelerationBoost = 3
        v.tuning = t
        #expect(v.engine.accelerationBoost == 3)
    }

    @Test func videoLayerIsAttachedAndReplaced() {
        let (v, _) = make()
        let first = AVSampleBufferDisplayLayer()
        let second = AVSampleBufferDisplayLayer()
        v.videoLayer = first
        #expect(first.superlayer === v.layer)
        v.videoLayer = second
        #expect(first.superlayer == nil)
        #expect(second.superlayer === v.layer)
    }

    @Test func videoSizeChangeRelaysOut() {
        let (v, _) = make()
        v.videoSize = CGSize(width: 1280, height: 720)
        v.layoutIfNeeded()
        #expect(v.userZoom == 1)
    }

    @Test func gesturesAreInstalled() {
        let (v, _) = make()
        #expect((v.gestureRecognizers?.count ?? 0) >= 10)
    }

    @Test func representableMountsInAWindow() async {
        let sender = InputSender(host: "unused.test", token: "t")
        await mount(InteractiveVideoView(layer: AVSampleBufferDisplayLayer(), input: sender,
                                         videoSize: CGSize(width: 10, height: 10), trackpad: true, reserveLeft: 20),
                    wait: .milliseconds(200))
    }
}
#endif

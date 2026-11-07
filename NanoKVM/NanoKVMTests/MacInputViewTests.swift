#if os(macOS)
import AppKit
import AVFoundation
import Testing
@testable import NanoKVM

@MainActor
struct MacInputViewTests {
    final class Capture { var messages: [Data] = [] }

    private func make() -> (InputNSView, InputSender, Capture, NSWindow) {
        let sender = InputSender(host: "unused.test", token: "t")
        let capture = Capture()
        sender.onSend = { capture.messages.append($0) }
        let view = InputNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.input = sender
        view.videoSize = CGSize(width: 400, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, sender, capture, window)
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, chars: String = "a",
                     flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint = CGPoint(x: 200, y: 150)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func withCapture<T>(_ value: Bool?, _ body: () -> T) -> T {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "captureShortcuts")
        if let value { defaults.set(value, forKey: "captureShortcuts") } else { defaults.removeObject(forKey: "captureShortcuts") }
        defer { if let old { defaults.set(old, forKey: "captureShortcuts") } else { defaults.removeObject(forKey: "captureShortcuts") } }
        return body()
    }

    @Test func keyDownAndUpSendReports() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.keyDown(with: key(.keyDown, code: 0))
        v.keyUp(with: key(.keyUp, code: 0))
        #expect(c.messages.count == 2)
    }

    @Test func unknownKeyIsIgnored() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.keyDown(with: key(.keyDown, code: 200))
        v.keyUp(with: key(.keyUp, code: 200))
        v.flagsChanged(with: key(.flagsChanged, code: 200))
        #expect(c.messages.isEmpty)
    }

    @Test func modifierPressAndRelease() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.flagsChanged(with: key(.flagsChanged, code: 56, flags: .shift))
        v.flagsChanged(with: key(.flagsChanged, code: 56, flags: []))
        #expect(c.messages.count == 2)
    }

    @Test func capsLockIsTapped() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.flagsChanged(with: key(.flagsChanged, code: 57, flags: .capsLock))
        #expect(c.messages.count == 2)
    }

    @Test func modifierWithoutFlagMappingIsIgnored() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.flagsChanged(with: key(.flagsChanged, code: 63))
        #expect(c.messages.isEmpty)
    }

    @Test func commandShortcutIsForwardedWhenCapturing() {
        let (v, _, c, w) = make(); defer { w.close() }
        let handled = withCapture(true) {
            v.performKeyEquivalent(with: key(.keyDown, code: 8, chars: "c", flags: .command))
        }
        #expect(handled)
        #expect(c.messages.count == 2)
    }

    @Test func essentialShortcutsStayLocalWhenNotCapturing() {
        let (v, _, c, w) = make(); defer { w.close() }
        let handled = withCapture(false) {
            v.performKeyEquivalent(with: key(.keyDown, code: 12, chars: "q", flags: .command))
        }
        #expect(!handled)
        #expect(c.messages.isEmpty)
    }

    @Test func nonEssentialShortcutIsForwardedWhenNotCapturing() {
        let (v, _, c, w) = make(); defer { w.close() }
        let handled = withCapture(false) {
            v.performKeyEquivalent(with: key(.keyDown, code: 8, chars: "c", flags: .command))
        }
        #expect(handled)
        #expect(c.messages.count == 2)
    }

    @Test func fullScreenShortcutStaysLocal() {
        let (v, _, c, w) = make(); defer { w.close() }
        let handled = withCapture(true) {
            v.performKeyEquivalent(with: key(.keyDown, code: 3, chars: "f", flags: [.command, .control]))
        }
        #expect(!handled)
        #expect(c.messages.isEmpty)
    }

    @Test func shortcutIgnoredWithoutFocusOrMapping() {
        let (v, _, c, w) = make(); defer { w.close() }
        let unmapped = withCapture(true) {
            v.performKeyEquivalent(with: key(.keyDown, code: 200, chars: "x", flags: .command))
        }
        #expect(!unmapped)
        w.makeFirstResponder(nil)
        let unfocused = withCapture(true) {
            v.performKeyEquivalent(with: key(.keyDown, code: 8, chars: "c", flags: .command))
        }
        #expect(!unfocused)
        #expect(c.messages.isEmpty)
    }

    @Test func resigningFirstResponderReleasesKeys() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.keyDown(with: key(.keyDown, code: 0))
        let before = c.messages.count
        #expect(v.resignFirstResponder())
        #expect(c.messages.count > before)
    }

    @Test func leftClickSetsAndClearsButton() {
        let (v, s, c, w) = make(); defer { w.close() }
        v.mouseDown(with: mouse(.leftMouseDown))
        #expect(s.buttons == 1)
        v.mouseUp(with: mouse(.leftMouseUp))
        #expect(s.buttons == 0)
        #expect(c.messages.count == 2)
    }

    @Test func rightAndOtherButtons() {
        let (v, s, _, w) = make(); defer { w.close() }
        v.rightMouseDown(with: mouse(.rightMouseDown))
        #expect(s.buttons == 2)
        v.otherMouseDown(with: mouse(.otherMouseDown))
        #expect(s.buttons == 6)
        v.rightMouseUp(with: mouse(.rightMouseUp))
        v.otherMouseUp(with: mouse(.otherMouseUp))
        #expect(s.buttons == 0)
    }

    @Test func movesAndDragsSendPointerReports() {
        let (v, _, c, w) = make(); defer { w.close() }
        v.mouseMoved(with: mouse(.mouseMoved))
        v.mouseDragged(with: mouse(.leftMouseDragged))
        v.rightMouseDragged(with: mouse(.rightMouseDragged))
        v.otherMouseDragged(with: mouse(.otherMouseDragged))
        #expect(c.messages.count == 4)
    }

    @Test func scrollSendsWheelThenReset() {
        let (v, _, c, w) = make(); defer { w.close() }
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
        v.scrollWheel(with: NSEvent(cgEvent: cg)!)
        #expect(c.messages.count == 2)
        let none = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
        v.scrollWheel(with: NSEvent(cgEvent: none)!)
        #expect(c.messages.count == 2)
    }

    @Test func wheelDirectionFollowsNaturalSetting() {
        #expect(macWheelTicks(deltaY: 3, natural: true) == -1)
        #expect(macWheelTicks(deltaY: -3, natural: true) == 1)
        #expect(macWheelTicks(deltaY: 3, natural: false) == 1)
        #expect(macWheelTicks(deltaY: -3, natural: false) == -1)
        #expect(macWheelTicks(deltaY: 0, natural: true) == 0)
    }

    @Test func trackpadScrollAccumulatesIntoFewTicks() {
        var a = MacScrollAccumulator()
        var total = 0
        for _ in 0..<30 { total += a.add(deltaY: 3, precise: true) }
        #expect(total == 2)
        #expect(a.add(deltaY: 0, precise: true) == 0)
        a.reset()
        #expect(a.add(deltaY: -45, precise: true) == -1)
        #expect(a.add(deltaY: 0.5, precise: false) == 1)
        #expect(a.add(deltaY: -0.5, precise: false) == -1)
    }

    @Test func reservedStripPassesClicksThrough() {
        let (v, _, _, w) = make(); defer { w.close() }
        v.reserveLeft = 50
        #expect(v.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(v.hitTest(NSPoint(x: 100, y: 100)) != nil)
    }

    @Test func trackingAreaIsReplacedOnUpdate() {
        let (v, _, _, w) = make(); defer { w.close() }
        v.updateTrackingAreas()
        v.updateTrackingAreas()
        #expect(v.trackingAreas.count == 1)
    }

    @Test func keyboardTypeHelperHandlesAnyValue() {
        #expect(!macKeyboardTypeIsISO(Int64.max))
        #expect(!macKeyboardTypeIsISO(Int64.min))
        _ = macKeyboardTypeIsISO(0)
        _ = macKeyboardTypeIsISO(41)
    }

    @Test func representableMountsInAWindow() async {
        let sender = InputSender(host: "unused.test", token: "t")
        await mount(InteractiveVideoView(layer: AVSampleBufferDisplayLayer(), input: sender,
                                         videoSize: CGSize(width: 10, height: 10), reserveLeft: 20),
                    wait: .milliseconds(200))
    }
}
#endif

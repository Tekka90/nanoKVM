import AVFoundation
import SwiftUI

/// Maps a point in a view to normalized 0...1 coordinates of the video image (aspect-fit).
/// ISO Apple keyboards report the grave (0x35) and non-US backslash (0x64) usages swapped.
func swappedISOUsage(_ usage: UInt8) -> UInt8 { usage == 0x35 ? 0x64 : usage == 0x64 ? 0x35 : usage }

func normalizedVideoPoint(_ point: CGPoint, in bounds: CGSize, video: CGSize) -> (x: Double, y: Double) {
    guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else {
        return (Double(point.x / max(bounds.width, 1)), Double(point.y / max(bounds.height, 1)))
    }
    let scale = min(bounds.width / video.width, bounds.height / video.height)
    let w = video.width * scale, h = video.height * scale
    let ox = (bounds.width - w) / 2, oy = (bounds.height - h) / 2
    return (Double((point.x - ox) / w), Double((point.y - oy) / h))
}

/// Same as above for a video drawn into an arbitrary rect (panned while the keyboard is up).
func normalizedVideoPoint(_ point: CGPoint, in rect: CGRect) -> (x: Double, y: Double) {
    guard rect.width > 0, rect.height > 0 else { return (0, 0) }
    return (Double((point.x - rect.minX) / rect.width), Double((point.y - rect.minY) / rect.height))
}

#if os(macOS)
import AppKit
import Carbon.HIToolbox

private let macKeyToHID: [UInt16: UInt8] = [
    0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25, 10: 100, 11: 5, 12: 20, 13: 26,
    14: 8, 15: 21, 16: 28, 17: 23, 18: 30, 19: 31, 20: 32, 21: 33, 22: 35, 23: 34, 24: 46, 25: 38,
    26: 36, 27: 45, 28: 37, 29: 39, 30: 48, 31: 18, 32: 24, 33: 47, 34: 12, 35: 19, 36: 40, 37: 15,
    38: 13, 39: 52, 40: 14, 41: 51, 42: 49, 43: 54, 44: 56, 45: 17, 46: 16, 47: 55, 48: 43, 49: 44,
    50: 53, 51: 42, 53: 41, 57: 57,
    // Modifiers: left ctrl/shift/alt/gui = E0...E3, right = E4...E7
    59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5, 61: 0xE6, 54: 0xE7,
    122: 58, 120: 59, 99: 60, 118: 61, 96: 62, 97: 63, 98: 64, 100: 65, 101: 66, 109: 67, 103: 68, 111: 69,
    105: 104, 107: 105, 113: 106,
    114: 73, 115: 74, 116: 75, 117: 76, 119: 77, 121: 78, 123: 80, 124: 79, 125: 81, 126: 82,
    71: 83, 75: 84, 67: 85, 78: 86, 69: 87, 76: 88, 81: 103,
    83: 89, 84: 90, 85: 91, 86: 92, 87: 93, 88: 94, 89: 95, 91: 96, 92: 97, 82: 98, 65: 99,
]

/// Apple ISO keyboards report the § (10) and ` (50) keys swapped relative to their physical positions.
func macHIDUsage(keyCode: UInt16, isISO: Bool) -> UInt8? {
    var code = keyCode
    if isISO { if code == 10 { code = 50 } else if code == 50 { code = 10 } }
    return macKeyToHID[code]
}

private func macIsISO(_ event: NSEvent) -> Bool {
    guard let type = event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType) else { return false }
    return macKeyboardTypeIsISO(type)
}

/// Keyboard types from some devices exceed Int16; those can't be Apple layouts, so treat them as non-ISO.
func macKeyboardTypeIsISO(_ type: Int64) -> Bool {
    guard let t = Int16(exactly: type) else { return false }
    return Int64(KBGetLayoutType(t)) == Int64(kKeyboardISO)
}

private let macModifierFlags: [UInt16: NSEvent.ModifierFlags] = [
    59: .control, 62: .control, 56: .shift, 60: .shift, 58: .option, 61: .option, 55: .command, 54: .command,
]

final class InputNSView: NSView {
    var input: InputSender?
    var videoSize: CGSize = .zero
    var reserveLeft: CGFloat = 0
    var naturalScroll = true
    private var scrollAccumulator = MacScrollAccumulator()
    private var trackingArea: NSTrackingArea?

    /// Lets SwiftUI's side rail, drawn beneath this view, receive clicks in the reserved left strip.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if reserveLeft > 0, p.x < reserveLeft { return nil }
        return super.hitTest(point)
    }
    private var heldKeys = Set<UInt16>()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func releaseAll() {
        heldKeys.removeAll()
        input?.releaseAll()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let usage = macHIDUsage(keyCode: event.keyCode, isISO: macIsISO(event)) else { return }
        input?.keyDown(usage)
        heldKeys.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = macHIDUsage(keyCode: event.keyCode, isISO: macIsISO(event)) else { return }
        input?.keyUp(usage)
        heldKeys.remove(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let usage = macHIDUsage(keyCode: event.keyCode, isISO: macIsISO(event)) else { return }
        if event.keyCode == 57 { // Caps Lock reports state changes, so tap it
            input?.keyDown(usage); input?.keyUp(usage); return
        }
        guard let flag = macModifierFlags[event.keyCode] else { return }
        if event.modifierFlags.contains(flag) { input?.keyDown(usage) } else { input?.keyUp(usage) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Forward Command shortcuts to the remote, but keep the essential app shortcuts local.
        let capture = UserDefaults.standard.object(forKey: "captureShortcuts") as? Bool ?? true
        let local: Set<String> = capture ? [] : ["q", "w", "h", "m", ","]
        if event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers, local.contains(c) {
            return false
        }
        // Full screen toggles must stay local, otherwise there's no way out.
        if let c = event.charactersIgnoringModifiers?.lowercased(), c == "f",
           event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.control) || event.modifierFlags.contains(.shift) {
            return false
        }
        guard window?.firstResponder === self, macHIDUsage(keyCode: event.keyCode, isISO: macIsISO(event)) != nil else { return false }
        keyDown(with: event)
        // Key-up is not delivered for swallowed shortcuts, so release right after.
        keyUp(with: event)
        return true
    }

    // MARK: Pointer

    private func send(_ event: NSEvent, buttons: UInt8? = nil, wheel: Int = 0) {
        let p = convert(event.locationInWindow, from: nil)
        let n = normalizedVideoPoint(CGPoint(x: p.x, y: bounds.height - p.y), in: bounds.size, video: videoSize)
        input?.pointer(x: n.x, y: n.y, buttons: buttons, wheel: wheel)
    }

    private func setButton(_ bit: UInt8, down: Bool, event: NSEvent) {
        let current = input?.buttons ?? 0
        send(event, buttons: down ? current | bit : current & ~bit)
    }

    override func mouseMoved(with event: NSEvent) { send(event) }
    override func mouseDragged(with event: NSEvent) { send(event) }
    override func rightMouseDragged(with event: NSEvent) { send(event) }
    override func otherMouseDragged(with event: NSEvent) { send(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); setButton(1, down: true, event: event) }
    override func mouseUp(with event: NSEvent) { setButton(1, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) { setButton(2, down: true, event: event) }
    override func rightMouseUp(with event: NSEvent) { setButton(2, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) { setButton(4, down: true, event: event) }
    override func otherMouseUp(with event: NSEvent) { setButton(4, down: false, event: event) }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin { scrollAccumulator.reset() }
        let ticks = scrollAccumulator.add(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard ticks != 0 else { return }
        let sign = macWheelTicks(deltaY: 1, natural: naturalScroll)
        for _ in 0..<min(abs(ticks), 5) {
            send(event, wheel: ticks > 0 ? sign : -sign)
            send(event, wheel: 0)
        }
    }
}

/// Turns macOS scroll deltas into whole wheel ticks. Trackpads report points (many small events), so they accumulate.
struct MacScrollAccumulator {
    static let pointsPerTick: CGFloat = 40
    private var remainder: CGFloat = 0

    mutating func reset() { remainder = 0 }

    /// Returns signed whole ticks (positive = deltaY positive).
    mutating func add(deltaY: CGFloat, precise: Bool) -> Int {
        guard deltaY != 0 else { return 0 }
        if !precise { return deltaY > 0 ? 1 : -1 }
        remainder += deltaY
        let whole = Int((remainder / Self.pointsPerTick).rounded(.towardZero))
        remainder -= CGFloat(whole) * Self.pointsPerTick
        return whole
    }
}

/// macOS already applies the system scroll direction to `scrollingDeltaY`; natural keeps the remote content following the fingers.
func macWheelTicks(deltaY: CGFloat, natural: Bool) -> Int {
    guard deltaY != 0 else { return 0 }
    return (deltaY > 0) == natural ? -1 : 1
}

struct InteractiveVideoView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let input: InputSender
    let videoSize: CGSize
    var trackpad = false
    var trackpadSpeed = PointerPrefs.defaultSpeed
    var naturalScroll = true
    var tuning = GestureTuning()
    var softKeyboard = false
    var keyboardTarget = KeyboardTarget.windows
    var onSoftKeyboardHidden: () -> Void = {}
    var reserveLeft: CGFloat = 0

    func makeNSView(context: Context) -> InputNSView {
        let view = InputNSView()
        view.wantsLayer = true
        view.layer = layer
        view.input = input
        return view
    }

    func updateNSView(_ view: InputNSView, context: Context) {
        view.input = input
        view.videoSize = videoSize
        view.reserveLeft = reserveLeft
        view.naturalScroll = naturalScroll
    }
}
#else
import UIKit

final class InputUIView: UIView, UIGestureRecognizerDelegate, UIKeyInput {
    var input: InputSender?
    var onSoftKeyboardHidden: (() -> Void)?
    var softKeyboard = false {
        didSet { if softKeyboard != oldValue { reloadInputViews() } }
    }
    var keyboardTarget = KeyboardTarget.windows {
        didSet { if keyboardTarget != oldValue { _ = sticky.consume(); accessoryBar.target = keyboardTarget } }
    }
    private var keyboardOverlap: CGFloat = 0
    private var focus = CGPoint(x: 0.5, y: 0.5)
    private var contentRect = CGRect.zero
    private var panOrigin: CGPoint?
    private(set) var userZoom: CGFloat = 1
    private var pinchStartZoom: CGFloat = 1
    private var pinching = false
    private var isPanning: Bool { keyboardOverlap > 0 || userZoom > 1 }
    private var touchPoint: CGPoint?
    private var mouseOver = false
    private var mouseGestures: [UIGestureRecognizer] = []
    private var edgeTimer: Timer?
    private let noKeyboard = UIView()
    private var sticky = StickyModifiers()
    private lazy var accessoryBar: KeyAccessoryBar = {
        let bar = KeyAccessoryBar()
        bar.target = keyboardTarget
        bar.onKey = { [weak self] usage in
            guard let self else { return }
            self.input?.sendCombo(self.sticky.consume() + [usage])
        }
        bar.onModifier = { [weak self] usage in self?.sticky.toggle(usage) ?? false }
        bar.onHide = { [weak self] in
            guard let self else { return }
            self.softKeyboard = false
            self.onSoftKeyboardHidden?()
        }
        return bar
    }()

    // Without a request the system keyboard stays hidden; hardware keys go through `presses`.
    override var inputView: UIView? { softKeyboard ? nil : noKeyboard }
    var hasText: Bool { true }
    override var inputAccessoryView: UIView? { softKeyboard ? accessoryBar : nil }
    func insertText(_ text: String) {
        input?.type(text, modifiers: sticky.consume())
        accessoryBar.clearArmed()
    }
    func deleteBackward() { input?.sendCombo(sticky.consume() + [KeyMap.backspace]); accessoryBar.clearArmed() }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { relayoutVideo() } }
    }
    var videoLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let videoLayer { layer.addSublayer(videoLayer) }
        }
    }
    var trackpad = false {
        didSet { if trackpad != oldValue { engine.reset(); if holding { endHold() } } }
    }
    var engine = TrackpadEngine()
    private var holding = false
    private var buttonsViaAbsolute = false
    /// Receives a line for every recognised gesture (the tuning test pad shows them).
    var onEvent: ((String) -> Void)?
    private func debug(_ line: String) { onEvent?(line) }

    var tuning = GestureTuning() {
        didSet { applyTuning() }
    }
    private var holdGesture: UILongPressGestureRecognizer?
    private var tapHoldGesture: UILongPressGestureRecognizer?

    private func applyTuning() {
        holdGesture?.minimumPressDuration = tuning.holdDuration
        tapHoldGesture?.minimumPressDuration = tuning.tapHoldDuration
        engine.scrollStep = CGFloat(tuning.scrollStep)
        engine.accelerationBoost = tuning.accelerationBoost
    }
    private var suppressClick = false
    // Raw-touch tracking for tap-and-drag, independent of gesture recognizer arbitration.
    private var touchStart: (time: Date, point: CGPoint)?
    private var lastTap: (time: Date, point: CGPoint)?
    private var dragArmed = false
    private var absoluteGestures: [UIGestureRecognizer] = []
    private var trackpadGestures: [UIGestureRecognizer] = []
    private var pinchGesture: UIGestureRecognizer?
    var reserveLeft: CGFloat = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if reserveLeft > 0, point.x < reserveLeft { return nil }
        return super.hitTest(point, with: event)
    }

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = direct
        addGestureRecognizer(tap)

        let right = UILongPressGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        right.minimumPressDuration = 0.6
        right.allowedTouchTypes = direct
        addGestureRecognizer(right)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.allowedTouchTypes = direct
        addGestureRecognizer(drag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = [.continuous, .discrete]
        addGestureRecognizer(scroll)

        absoluteGestures = [tap, right, drag]

        // A physical mouse or trackpad works in both modes, like on a desktop.
        let mouse = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        let mouseTap = UITapGestureRecognizer(target: self, action: #selector(mouseClicked(_:)))
        mouseTap.allowedTouchTypes = mouse
        let mouseRight = UITapGestureRecognizer(target: self, action: #selector(mouseRightClicked(_:)))
        mouseRight.allowedTouchTypes = mouse
        mouseRight.buttonMaskRequired = .secondary
        let mouseDrag = UIPanGestureRecognizer(target: self, action: #selector(mouseDragged(_:)))
        mouseDrag.maximumNumberOfTouches = 1
        mouseDrag.allowedTouchTypes = mouse
        for g in [mouseTap, mouseRight, mouseDrag] { addGestureRecognizer(g) }
        mouseGestures = [mouseTap, mouseRight, mouseDrag]
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pinchGesture = pinch
        clipsToBounds = true
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.keyboardFrameChanged(end) }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.softKeyboard { self.softKeyboard = false; self.onSoftKeyboardHidden?() } }
        }

        // Trackpad mode: touches move the remote cursor relatively.
        let directOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let move = UIPanGestureRecognizer(target: self, action: #selector(trackpadMoved(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        move.allowedTouchTypes = directOnly
        let click = UITapGestureRecognizer(target: self, action: #selector(trackpadClicked(_:)))
        click.allowedTouchTypes = directOnly
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(trackpadRightClicked(_:)))
        twoFinger.numberOfTouchesRequired = 2
        twoFinger.allowedTouchTypes = directOnly
        // Holding still briefly presses the button; moving afterwards then drags.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(trackpadHeld(_:)))
        hold.minimumPressDuration = tuning.holdDuration
        hold.allowedTouchTypes = directOnly
        // Tap, then press again: the button goes down at once so the next move drags (tap-and-drag).
        let tapHold = UILongPressGestureRecognizer(target: self, action: #selector(trackpadTapHeld(_:)))
        tapHold.numberOfTapsRequired = 1
        tapHold.minimumPressDuration = 0.1
        tapHold.allowedTouchTypes = directOnly
        // The raw-touch tap-and-drag detection must keep receiving touches while these recognize.
        for g in [move, click, twoFinger, hold, tapHold] { g.cancelsTouchesInView = false; addGestureRecognizer(g) }
        trackpadGestures = [move, click, twoFinger, hold, tapHold]
        holdGesture = hold
        tapHoldGesture = tapHold
        for g in absoluteGestures + trackpadGestures + [scroll] { g.delegate = self }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard trackpad else { return }
        guard event?.allTouches?.count == 1, let t = touches.first else { debug("down: \(event?.allTouches?.count ?? 0) touches, ignored"); return }
        let p = t.location(in: self)
        touchStart = (Date(), p)
        if let last = lastTap {
            let dt = Date().timeIntervalSince(last.time), dist = hypot(p.x - last.point.x, p.y - last.point.y)
            let ok = dt < tuning.doubleTapGap && dist < tuning.doubleTapDistance
            debug(String(format: "down: gap %.2fs (max %.2f) dist %.0f (max %.0f) %@", dt, tuning.doubleTapGap, dist, tuning.doubleTapDistance, ok ? "→ hold armed" : "→ too late/far"))
            if ok {
                dragArmed = true
                if !holding {
                    holding = true
                    suppressClick = true
                    debug("BUTTON DOWN (double-tap and hold)")
                    press(1)
                }
            }
        } else {
            debug("down: no previous tap")
        }
    }

    private func touchFinished(_ touches: Set<UITouch>) {
        defer { dragArmed = false; touchStart = nil }
        if holding {
            debug("up: finger lifted while holding")
            endHold()
            Task { try? await Task.sleep(for: .milliseconds(300)); suppressClick = false }
            return
        }
        guard trackpad, let t = touches.first, let start = touchStart else { return }
        let p = t.location(in: self)
        let dur = Date().timeIntervalSince(start.time), dist = hypot(p.x - start.point.x, p.y - start.point.y)
        if dur < tuning.tapMaxDuration, dist < tuning.tapMaxMovement {
            lastTap = (Date(), p)
            debug(String(format: "up: tap %.2fs (max %.2f) move %.0f (max %.0f)", dur, tuning.tapMaxDuration, dist, tuning.tapMaxMovement))
        } else {
            lastTap = nil
            debug(String(format: "up: not a tap %.2fs (max %.2f) move %.0f (max %.0f)", dur, tuning.tapMaxDuration, dist, tuning.tapMaxMovement))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchFinished(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchFinished(touches)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if absoluteGestures.contains(g) { return !trackpad }
        if trackpadGestures.contains(g) { return trackpad }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g === pinchGesture || other === pinchGesture { return true }
        return trackpad && trackpadGestures.contains(g) && trackpadGestures.contains(other)
    }

    /// Zooms around the fingers (direct touch) or around the pointer (trackpad); 1× restores the normal view.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinching = true
            pinchStartZoom = userZoom
            if trackpad { warpPointer(to: g.location(in: self)) }
        case .changed:
            let rect = contentRect.isEmpty ? CGRect(origin: .zero, size: bounds.size) : contentRect
            let anchor = g.location(in: self)
            let n = normalizedVideoPoint(anchor, in: rect)
            let zoom = KeyboardViewport.clampedZoom(pinchStartZoom * g.scale)
            guard zoom != userZoom else { return }
            userZoom = zoom
            let fit = KeyboardViewport.fitRect(bounds: bounds.size, video: videoSize)
            panOrigin = CGPoint(x: anchor.x - n.x * fit.width * zoom, y: anchor.y - n.y * fit.height * zoom)
            relayoutVideo()
        default:
            pinching = false
            if userZoom < 1.05 { userZoom = 1; relayoutVideo() }
        }
    }


    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayoutVideo()
    }

    // Only a keyboard docked at the bottom covers the view; floating or split ones are ignored.
    private func keyboardFrameChanged(_ end: CGRect?) {
        var overlap: CGFloat = 0
        if let end, let window, softKeyboard {
            let f = convert(end, from: nil)
            let docked = abs(end.maxY - window.bounds.maxY) < 1 && end.width >= window.bounds.width * 0.9
            if docked { overlap = max(0, bounds.maxY - f.minY) }
        }
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        if overlap == 0 { setTouch(nil) }
        relayoutVideo()
    }

    private func relayoutVideo() {
        if isPanning, !trackpad || panOrigin != nil {
            let start = panOrigin ?? KeyboardViewport.rect(bounds: bounds.size, video: videoSize, overlap: keyboardOverlap, focus: focus, zoom: userZoom).origin
            contentRect = KeyboardViewport.rect(bounds: bounds.size, video: videoSize, overlap: keyboardOverlap, origin: start, zoom: userZoom)
            panOrigin = contentRect.origin
        } else {
            panOrigin = nil
            contentRect = KeyboardViewport.rect(bounds: bounds.size, video: videoSize, overlap: keyboardOverlap, focus: focus, zoom: userZoom)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = contentRect
        CATransaction.commit()
    }

    // The device reports no pointer position, so a pinch puts the pointer where the fingers are: the position is then known.
    private func warpPointer(to p: CGPoint) {
        let rect = contentRect.isEmpty ? CGRect(origin: .zero, size: bounds.size) : contentRect
        let raw = normalizedVideoPoint(p, in: rect)
        let n = (x: min(max(raw.x, 0), 1), y: min(max(raw.y, 0), 1))
        focus = CGPoint(x: n.x, y: n.y)
        input?.pointer(x: n.x, y: n.y)
    }

    private func follow(_ n: (x: Double, y: Double)) {
        focus = CGPoint(x: n.x, y: n.y)
        if isPanning, trackpad { panOrigin = nil; relayoutVideo() }
    }

    // With direct touch the picture only scrolls while the finger rests near the edge of the free area.
    private func setTouch(_ p: CGPoint?) {
        touchPoint = p
        guard p != nil, isPanning, !trackpad || mouseOver else { edgeTimer?.invalidate(); edgeTimer = nil; return }
        if edgeTimer == nil {
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.edgeScroll() }
            }
        }
    }

    private func edgeScroll() {
        guard let p = touchPoint, isPanning, !trackpad || mouseOver, let origin = panOrigin else { return }
        let band: CGFloat = mouseOver ? 180 : 70, maxSpeed: CGFloat = mouseOver ? 28 : 12
        let visibleH = bounds.height - keyboardOverlap
        func push(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            if v < lo { return min(1, (lo - v) / band) * maxSpeed }
            if v > hi { return -min(1, (v - hi) / band) * maxSpeed }
            return 0
        }
        let dx = push(p.x, band, bounds.width - band), dy = push(p.y, band, visibleH - band)
        guard dx != 0 || dy != 0 else { return }
        panOrigin = CGPoint(x: origin.x + dx, y: origin.y + dy)
        relayoutVideo()
        let n = normalizedVideoPoint(p, in: contentRect)
        input?.pointer(x: n.x, y: n.y)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    private func norm(_ p: CGPoint) -> (x: Double, y: Double) {
        let n = normalizedVideoPoint(p, in: contentRect.isEmpty ? CGRect(origin: .zero, size: bounds.size) : contentRect)
        if !trackpad { focus = CGPoint(x: n.x, y: n.y) }
        return n
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let n = norm(g.location(in: self))
        input?.pointer(x: n.x, y: n.y, buttons: 0)
        input?.pointer(x: n.x, y: n.y, buttons: 1)
        input?.pointer(x: n.x, y: n.y, buttons: 0)
    }

    @objc private func rightClick(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let n = norm(g.location(in: self))
        input?.pointer(x: n.x, y: n.y, buttons: 2)
        input?.pointer(x: n.x, y: n.y, buttons: 0)
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let n = norm(g.location(in: self))
        setTouch(g.state == .began || g.state == .changed ? g.location(in: self) : nil)
        switch g.state {
        case .began: input?.pointer(x: n.x, y: n.y, buttons: 1)
        case .changed: input?.pointer(x: n.x, y: n.y)
        default: input?.pointer(x: n.x, y: n.y, buttons: 0)
        }
    }

    // A physical mouse always sends absolute positions: they match the real pointer, zoomed or not.
    private func mouseNorm(_ p: CGPoint) -> (x: Double, y: Double) {
        let raw = normalizedVideoPoint(p, in: contentRect.isEmpty ? CGRect(origin: .zero, size: bounds.size) : contentRect)
        let n = (x: min(max(raw.x, 0), 1), y: min(max(raw.y, 0), 1))
        focus = CGPoint(x: n.x, y: n.y)
        return n
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { mouseOver = false; setTouch(nil); return }
        mouseOver = true
        // Pin the picture so only edge scrolling moves it, keeping the real and remote pointers aligned.
        if trackpad, isPanning, panOrigin == nil { panOrigin = contentRect.origin }
        setTouch(g.location(in: self))
        let n = mouseNorm(g.location(in: self))
        input?.pointer(x: n.x, y: n.y)
    }

    @objc private func mouseClicked(_ g: UITapGestureRecognizer) {
        let n = mouseNorm(g.location(in: self))
        input?.pointer(x: n.x, y: n.y, buttons: 0)
        input?.pointer(x: n.x, y: n.y, buttons: 1)
        input?.pointer(x: n.x, y: n.y, buttons: 0)
    }

    @objc private func mouseRightClicked(_ g: UITapGestureRecognizer) {
        let n = mouseNorm(g.location(in: self))
        input?.pointer(x: n.x, y: n.y, buttons: 2)
        input?.pointer(x: n.x, y: n.y, buttons: 0)
    }

    @objc private func mouseDragged(_ g: UIPanGestureRecognizer) {
        let n = mouseNorm(g.location(in: self))
        switch g.state {
        case .began: input?.pointer(x: n.x, y: n.y, buttons: 1)
        case .changed: input?.pointer(x: n.x, y: n.y)
        default: input?.pointer(x: n.x, y: n.y, buttons: 0)
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        if pinching { g.setTranslation(.zero, in: self); return }
        let n = norm(g.location(in: self))
        let ticks = engine.scroll(dy: g.translation(in: self).y)
        g.setTranslation(.zero, in: self)
        if let t = ticks.first { debug("SCROLL \(t > 0 ? "up" : "down") ×\(ticks.count) (wheel \(t > 0 ? "+" : "-")1)") }
        for t in ticks {
            if trackpad { input?.relativePointer(dx: 0, dy: 0, wheel: t) } else { input?.pointer(x: n.x, y: n.y, wheel: t) }
        }
        if trackpad { if !ticks.isEmpty { input?.relativePointer(dx: 0, dy: 0, wheel: 0) } } else {
            input?.pointer(x: n.x, y: n.y, wheel: 0)
        }
    }

    // MARK: Trackpad

    @objc private func trackpadMoved(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let d = engine.move(dx: t.x, dy: t.y)
            if d.dx != 0 || d.dy != 0 {
                debug(holding ? "DRAG \(d.dx),\(d.dy)" : "MOVE \(d.dx),\(d.dy)")
                if videoSize.width > 0, videoSize.height > 0 {
                    let x = min(max(focus.x + CGFloat(d.dx) / videoSize.width, 0), 1)
                    let y = min(max(focus.y + CGFloat(d.dy) / videoSize.height, 0), 1)
                    if isPanning {
                        // The remote OS scales relative moves by its own pointer settings, so its cursor can't be tracked.
                        // While the camera follows the pointer, the app owns the position and sends it absolutely.
                        input?.pointer(x: Double(x), y: Double(y))
                    } else {
                        input?.relativePointer(dx: d.dx, dy: d.dy)
                    }
                    follow((x: x, y: y))
                } else {
                    input?.relativePointer(dx: d.dx, dy: d.dy)
                }
            }
        case .ended, .cancelled, .failed:
            engine.reset()
            if holding { endHold() }
        default: break
        }
    }

    @objc private func trackpadClicked(_ g: UITapGestureRecognizer) {
        if suppressClick { suppressClick = false; return }
        click(1)
    }
    @objc private func trackpadRightClicked(_ g: UITapGestureRecognizer) { click(2) }

    private func click(_ button: UInt8) {
        debug(button == 2 ? "RIGHT CLICK" : "CLICK")
        press(button)
        press(0)
    }

    // Buttons go through the same device as the movement, or the remote sees a press on one and a release on the other.
    private func press(_ buttons: UInt8) {
        if buttons != 0 { buttonsViaAbsolute = isPanning }
        if buttonsViaAbsolute, videoSize.width > 0 {
            input?.pointer(x: Double(focus.x), y: Double(focus.y), buttons: buttons)
        } else {
            input?.relativePointer(dx: 0, dy: 0, buttons: buttons)
        }
    }

    @objc private func trackpadHeld(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            debug("press-and-hold → BUTTON DOWN")
            holding = true
            press(1)
        case .ended, .cancelled, .failed:
            if holding { endHold() }
        default: break
        }
    }

    @objc private func trackpadTapHeld(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            debug(holding ? "tap-hold: already down" : "tap-hold → BUTTON DOWN")
            guard !holding else { return }
            holding = true
            suppressClick = true
            press(1)
        case .ended, .cancelled, .failed:
            if holding { endHold() }
            Task { try? await Task.sleep(for: .milliseconds(300)); suppressClick = false }
        default: break
        }
    }

    private func endHold() {
        debug("BUTTON UP")
        holding = false
        press(0)
    }

    private func hardwareUsage(_ key: UIKey) -> UInt8 {
        let usage = UInt8(clamping: key.keyCode.rawValue)
        return UserDefaults.standard.object(forKey: "swapISOKeys") as? Bool ?? true ? swappedISOUsage(usage) : usage
    }

    // Hardware keyboard: UIKeyboardHIDUsage raw values equal USB HID usages.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, key.keyCode.rawValue < 0xE8 {
                input?.keyDown(hardwareUsage(key))
            } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, key.keyCode.rawValue < 0xE8 { input?.keyUp(hardwareUsage(key)) }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        input?.releaseAll()
    }
}

struct InteractiveVideoView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let input: InputSender
    let videoSize: CGSize
    var trackpad = false
    var trackpadSpeed = PointerPrefs.defaultSpeed
    var naturalScroll = true
    var tuning = GestureTuning()
    var softKeyboard = false
    var keyboardTarget = KeyboardTarget.windows
    var onSoftKeyboardHidden: () -> Void = {}
    var reserveLeft: CGFloat = 0

    func makeUIView(context: Context) -> InputUIView {
        let view = InputUIView()
        view.videoLayer = layer
        view.input = input
        return view
    }

    func updateUIView(_ view: InputUIView, context: Context) {
        view.input = input
        view.videoSize = videoSize
        view.trackpad = trackpad
        view.engine.speed = trackpadSpeed
        view.engine.naturalScroll = naturalScroll
        view.tuning = tuning
        view.onSoftKeyboardHidden = onSoftKeyboardHidden
        view.keyboardTarget = keyboardTarget
        view.softKeyboard = softKeyboard
        view.reserveLeft = reserveLeft
    }
}
#endif

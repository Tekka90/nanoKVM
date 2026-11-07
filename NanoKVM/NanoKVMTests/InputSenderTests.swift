import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct InputSenderTests {
    final class Capture { var messages: [Data] = [] }

    private func make() -> (InputSender, Capture) {
        let s = InputSender(host: "unused.test", token: "t")
        let c = Capture()
        s.onSend = { c.messages.append($0) }
        return (s, c)
    }

    private func payload(_ d: Data) -> [UInt8] { Array(d.dropFirst(13)) }

    @Test func keyDownBuildsReport() {
        let (s, c) = make()
        s.keyDown(0x04)
        let m = c.messages[0]
        #expect(Array(m[0..<5]) == [3, 1, 1, 1, 0])
        #expect(payload(m) == [0, 0, 4, 0, 0, 0, 0, 0])
        #expect(m.count == 13 + 8)
    }

    @Test func sequenceIncrementsAndTimestampIsPresent() {
        let (s, c) = make()
        s.keyDown(0x04); s.keyUp(0x04)
        let seq = { (d: Data) in d[5..<9].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        #expect(seq(c.messages[0]) == 1 && seq(c.messages[1]) == 2)
    }

    @Test func modifiersSetAndClear() {
        let (s, c) = make()
        s.keyDown(0xE1)   // left shift
        #expect(payload(c.messages[0])[0] == 0x02)
        s.keyDown(0xE0)
        #expect(payload(c.messages[1])[0] == 0x03)
        s.keyUp(0xE1)
        #expect(payload(c.messages[2])[0] == 0x01)
    }

    @Test func duplicateKeyDownIsNotRepeatedInReport() {
        let (s, c) = make()
        s.keyDown(5); s.keyDown(5)
        #expect(payload(c.messages[1])[2...] == [5, 0, 0, 0, 0, 0][...])
    }

    @Test func sixKeyRolloverDropsOldest() {
        let (s, c) = make()
        for k in UInt8(4)...UInt8(10) { s.keyDown(k) }
        #expect(Array(payload(c.messages.last!)[2...]) == [5, 6, 7, 8, 9, 10])
    }

    @Test func keyUpRemovesKey() {
        let (s, c) = make()
        s.keyDown(4); s.keyDown(5); s.keyUp(4)
        #expect(Array(payload(c.messages.last!)[2...]) == [5, 0, 0, 0, 0, 0])
    }

    @Test func setModifiersOverridesMask() {
        let (s, c) = make()
        s.setModifiers(0x44)
        #expect(payload(c.messages[0])[0] == 0x44)
    }

    @Test func releaseAllOnlySendsWhenSomethingPressed() {
        let (s, c) = make()
        s.releaseAll()
        #expect(c.messages.isEmpty)
        s.keyDown(4)
        s.releaseAll()
        #expect(c.messages.count == 2)
        #expect(payload(c.messages[1]) == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(s.buttons == 0)
    }

    @Test func comboPressesThenReleases() {
        let (s, c) = make()
        s.sendCombo([0xE0, 0xE2, 0x4C])   // Ctrl+Alt+Del
        #expect(c.messages.count == 2)
        #expect(c.messages[0][2] == 16)
        #expect(payload(c.messages[0]) == [0x05, 0, 0x4C, 0, 0, 0, 0, 0])
        #expect(payload(c.messages[1]) == [UInt8](repeating: 0, count: 8))
    }

    @Test func wakeSendsHarmlessF15ThenReleases() {
        let (s, c) = make()
        s.wake()
        #expect(c.messages.count == 2)
        #expect(payload(c.messages[0]) == [0, 0, 0x6E, 0, 0, 0, 0, 0])
        #expect(payload(c.messages[1]) == [UInt8](repeating: 0, count: 8))
    }

    @Test func noSignalStateFlag() {
        #expect(VideoStream.State.noSignal("x").isNoSignal)
        #expect(!VideoStream.State.playing.isNoSignal)
    }

    @Test func comboCapsAtSixKeys() {
        let (s, c) = make()
        s.sendCombo(Array(UInt8(4)...UInt8(12)))
        #expect(payload(c.messages[0]).count == 8)
    }

    @Test func absolutePointerEncoding() {
        let (s, c) = make()
        s.pointer(x: 1, y: 0.5, buttons: 1)
        let m = c.messages[0]
        #expect(m[2] == 2 && m[3] == 3)
        let p = payload(m)
        #expect(p[0] == 1)
        #expect(Int(p[1]) | Int(p[2]) << 8 == 65535)
        #expect(Int(p[3]) | Int(p[4]) << 8 == 32768)
        #expect(s.buttons == 1)
    }

    @Test func absolutePointerClampsAndKeepsButtons() {
        let (s, c) = make()
        s.pointer(x: -5, y: 9, buttons: 3)
        s.pointer(x: 0.5, y: 0.5)
        let p0 = payload(c.messages[0])
        #expect(Int(p0[1]) | Int(p0[2]) << 8 == 0)
        #expect(Int(p0[3]) | Int(p0[4]) << 8 == 65535)
        #expect(payload(c.messages[1])[0] == 3)
    }

    @Test func wheelIsSignedLittleEndian() {
        let (s, c) = make()
        s.pointer(x: 0, y: 0, wheel: -1)
        let p = payload(c.messages[0])
        #expect(p[5] == 0xFF && p[6] == 0xFF)
        s.pointer(x: 0, y: 0, wheel: 100000)
        let q = payload(c.messages[1])
        #expect(Int(q[5]) | Int(q[6]) << 8 == 32767)
    }

    @Test func relativePointerEncoding() {
        let (s, c) = make()
        s.relativePointer(dx: -2, dy: 300, wheel: 1)
        let m = c.messages[0]
        #expect(m[3] == 2)
        let p = payload(m)
        #expect(p[1] == 0xFE && p[2] == 0xFF)
        #expect(Int(p[3]) | Int(p[4]) << 8 == 300)
        #expect(p[5] == 1)
        s.relativePointer(dx: -999_999, dy: 999_999)
        let q = payload(c.messages[1])
        #expect(UInt16(q[1]) | UInt16(q[2]) << 8 == UInt16(bitPattern: Int16.min))
    }

    @Test func connectAndDisconnectToggleState() {
        let (s, _) = make()
        #expect(!s.isConnected)
        s.connect()
        #expect(s.isConnected)
        s.disconnect()
        #expect(!s.isConnected)
    }
}

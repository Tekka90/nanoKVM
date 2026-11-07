import Foundation
import Testing
@testable import NanoKVM

@MainActor
struct KeyMapTests {
    @Test func lettersDigitsAndCase() {
        #expect(KeyMap.usages(for: "a") == [4])
        #expect(KeyMap.usages(for: "z") == [29])
        #expect(KeyMap.usages(for: "A") == [0xE1, 4])
        #expect(KeyMap.usages(for: "1") == [30])
        #expect(KeyMap.usages(for: "0") == [39])
    }

    @Test func punctuationAndShifted() {
        #expect(KeyMap.usages(for: " ") == [44])
        #expect(KeyMap.usages(for: "\n") == [40] && KeyMap.usages(for: "\r") == [40])
        #expect(KeyMap.usages(for: "/") == [56])
        #expect(KeyMap.usages(for: "?") == [0xE1, 56])
        #expect(KeyMap.usages(for: "!") == [0xE1, 30])
        #expect(KeyMap.usages(for: "_") == [0xE1, 45])
        #expect(KeyMap.usages(for: "\"") == [0xE1, 52])
    }

    @Test func unsupportedCharactersAreNil() {
        #expect(KeyMap.usages(for: "é") == nil)
        #expect(KeyMap.usages(for: "😀") == nil)
    }

    @Test func typeSendsPressAndReleasePerCharacter() {
        let s = InputSender(host: "x", token: "t")
        var sent: [Data] = []
        s.onSend = { sent.append($0) }
        s.type("aé")
        #expect(sent.count == 2)
        #expect(sent[0][13 + 2] == 4)
    }
}

@MainActor
struct StickyModifierTests {
    @Test func toggleArmsAndDisarms() {
        var m = StickyModifiers()
        #expect(m.toggle(0xE0) == true && m.isArmed(0xE0))
        #expect(m.toggle(0xE0) == false && !m.isArmed(0xE0))
    }

    @Test func consumeReturnsAndClears() {
        var m = StickyModifiers()
        m.toggle(0xE0); m.toggle(0xE2)
        #expect(m.consume() == [0xE0, 0xE2])
        #expect(m.consume().isEmpty)
    }

    @Test func modifiersApplyToFirstTypedCharacterOnly() {
        let s = InputSender(host: "x", token: "t")
        var sent: [Data] = []
        s.onSend = { sent.append($0) }
        s.type("cc", modifiers: [0xE0])
        #expect(sent.count == 4)
        #expect(sent[0][13] == 0x01 && sent[0][13 + 2] == 6)   // Ctrl+C
        #expect(sent[2][13] == 0x00 && sent[2][13 + 2] == 6)   // plain c
    }
}

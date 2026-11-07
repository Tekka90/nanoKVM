import Foundation
import Testing
@testable import NanoKVM

struct KeyboardTargetTests {
    @Test func defaultsToWindowsAndPersists() {
        let id = UUID()
        defer {
            UserDefaults.standard.removeObject(forKey: "keyboardTarget.\(id.uuidString)")
            NSUbiquitousKeyValueStore.default.removeObject(forKey: "keyboardTarget.\(id.uuidString)")
        }
        #expect(KeyboardTarget.stored(for: id) == .windows)
        KeyboardTarget.store(.mac, for: id)
        #expect(KeyboardTarget.stored(for: id) == .mac)
    }

    @Test func labelsAndKeysDiffer() {
        #expect(KeyboardTarget.mac.guiTitle.contains("Cmd"))
        #expect(KeyboardTarget.windows.guiTitle == "Win")
        #expect(KeyboardTarget.windows.barKeys.contains { $0.title == "Ins" })
        #expect(!KeyboardTarget.mac.barKeys.contains { $0.title == "Ins" })
        #expect(KeyboardTarget.mac.combos.contains { $0.usages == [0xE3, 44] })
        #expect(KeyboardTarget.windows.combos.contains { $0.usages == [0xE0, 0xE2, 76] })
    }
}

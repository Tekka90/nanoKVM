import CoreGraphics
import Foundation

/// The kind of computer the KVM is plugged into; decides modifier names and the extra keys offered.
enum KeyboardTarget: String, CaseIterable, Identifiable {
    case windows, mac
    var id: String { rawValue }

    var title: String { self == .mac ? "Mac" : "Windows / Linux" }
    var altTitle: String { self == .mac ? "⌥ Opt" : "Alt" }
    var guiTitle: String { self == .mac ? "⌘ Cmd" : "Win" }

    /// Keys shown in the bar above the on-screen keyboard (HID usages).
    var barKeys: [(title: String, usage: UInt8)] {
        let common: [(String, UInt8)] = [
            ("Esc", 41), ("Tab", 43), ("←", 80), ("↑", 82), ("↓", 81), ("→", 79),
            ("Home", 74), ("End", 77), ("PgUp", 75), ("PgDn", 78),
        ]
        let functionKeys = (1...12).map { ("F\($0)", UInt8(57 + $0)) }
        switch self {
        case .windows: return common + [("Del", 76), ("Ins", 73), ("PrtSc", 70), ("Menu", 101)] + functionKeys
        case .mac: return common + [("⌦ Del", 76)] + functionKeys
        }
    }

    var combos: [KeyCombo] {
        switch self {
        case .windows: return windowsCombos
        case .mac: return macCombos
        }
    }

    private static func key(_ id: UUID) -> String { "keyboardTarget.\(id.uuidString)" }

    static func stored(for id: UUID) -> KeyboardTarget {
        let raw = UserDefaults.standard.string(forKey: key(id)) ?? NSUbiquitousKeyValueStore.default.string(forKey: key(id))
        return raw.flatMap(KeyboardTarget.init(rawValue:)) ?? .windows
    }

    static func store(_ target: KeyboardTarget, for id: UUID) {
        UserDefaults.standard.set(target.rawValue, forKey: key(id))
        NSUbiquitousKeyValueStore.default.set(target.rawValue, forKey: key(id))
    }
}

private let ctrl: UInt8 = 0xE0, shift: UInt8 = 0xE1, alt: UInt8 = 0xE2, gui: UInt8 = 0xE3

let windowsCombos: [KeyCombo] = [
    .init(name: "Ctrl + Alt + Del", usages: [ctrl, alt, 76]),
    .init(name: "Ctrl + Shift + Esc", usages: [ctrl, shift, 41]),
    .init(name: "Alt + Tab", usages: [alt, 43]),
    .init(name: "Alt + F4", usages: [alt, 61]),
    .init(name: "Win / Super", usages: [gui]),
    .init(name: "Win + L", usages: [gui, 15]),
    .init(name: "Win + D", usages: [gui, 7]),
    .init(name: "Esc", usages: [41]),
    .init(name: "Tab", usages: [43]),
    .init(name: "Print Screen", usages: [70]),
    .init(name: "F2 (BIOS)", usages: [59]),
    .init(name: "F11 (Boot menu)", usages: [68]),
    .init(name: "F12 (Boot menu)", usages: [69]),
    .init(name: "Del (BIOS)", usages: [76]),
]

let macCombos: [KeyCombo] = [
    .init(name: "⌘ Space (Spotlight)", usages: [gui, 44]),
    .init(name: "⌘ Tab (Switch app)", usages: [gui, 43]),
    .init(name: "⌘ Q (Quit app)", usages: [gui, 20]),
    .init(name: "⌘ W (Close window)", usages: [gui, 26]),
    .init(name: "⌥ ⌘ Esc (Force Quit)", usages: [alt, gui, 41]),
    .init(name: "⌃ ⌘ Q (Lock screen)", usages: [ctrl, gui, 20]),
    .init(name: "⌃ ↑ (Mission Control)", usages: [ctrl, 82]),
    .init(name: "⌃ ⌘ F (Full screen)", usages: [ctrl, gui, 9]),
    .init(name: "⌘ ⇧ 3 (Screenshot)", usages: [gui, shift, 32]),
    .init(name: "⌘ ⇧ 4 (Screenshot area)", usages: [gui, shift, 33]),
    .init(name: "Esc", usages: [41]),
    .init(name: "Tab", usages: [43]),
    .init(name: "⌘ R (Recovery at startup)", usages: [gui, 21]),
    .init(name: "⌥ (Startup Manager)", usages: [alt]),
]

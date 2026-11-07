import Foundation

/// US-layout mapping from typed characters to USB HID keyboard usages (for the on-screen keyboard).
enum KeyMap {
    static let shiftUsage: UInt8 = 0xE1
    static let backspace: UInt8 = 0x2A

    private static let unshifted: [Character: UInt8] = {
        var m: [Character: UInt8] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[c] = UInt8(4 + i) }
        for (i, c) in "1234567890".enumerated() { m[c] = UInt8(30 + i) }
        let punctuation: [(Character, UInt8)] = [
            ("\n", 40), ("\t", 43), (" ", 44), ("-", 45), ("=", 46), ("[", 47), ("]", 48),
            ("\\", 49), (";", 51), ("'", 52), ("`", 53), (",", 54), (".", 55), ("/", 56),
        ]
        for (c, u) in punctuation { m[c] = u }
        return m
    }()

    private static let shifted: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (s, b) in zip("!@#$%^&*()", "1234567890") { m[s] = b }
        for (s, b) in zip("_+{}|:\"~<>?", "-=[]\\;'`,./") { m[s] = b }
        return m
    }()

    /// HID usages to press together for `c`, or nil when it has no US-layout key.
    static func usages(for c: Character) -> [UInt8]? {
        if c == "\r" { return [40] }
        if let u = unshifted[c] { return [u] }
        if let base = shifted[c], let u = unshifted[base] { return [shiftUsage, u] }
        if c.isUppercase, c.unicodeScalars.count == 1, let u = unshifted[Character(c.lowercased())] { return [shiftUsage, u] }
        return nil
    }
}

extension InputSender {
    /// Types text as key presses; characters without a US-layout key are skipped.
    func type(_ text: String, modifiers: [UInt8] = []) {
        var mods = modifiers
        for c in text {
            if let usages = KeyMap.usages(for: c) {
                sendCombo(mods + usages)
                mods = []
            }
        }
    }
}

/// Modifiers armed from the keyboard accessory bar; they apply to the next key only.
struct StickyModifiers {
    private(set) var armed: [UInt8] = []

    @discardableResult
    mutating func toggle(_ usage: UInt8) -> Bool {
        if let i = armed.firstIndex(of: usage) { armed.remove(at: i); return false }
        armed.append(usage)
        return true
    }

    func isArmed(_ usage: UInt8) -> Bool { armed.contains(usage) }

    /// Returns the armed modifiers and disarms them.
    mutating func consume() -> [UInt8] {
        defer { armed = [] }
        return armed
    }
}

import Foundation

/// Builds a 256-byte EDID (base block + CTA-861 extension with an HDMI vendor block)
/// advertising a single preferred timing computed with CVT reduced blanking (v1).
struct EDIDBuilder {
    let width: Int
    let height: Int
    let refresh: Int
    let name: String

    struct Timing {
        let pixelClock10kHz: Int
        let hActive: Int, hBlank: Int, hFront: Int, hSync: Int
        let vActive: Int, vBlank: Int, vFront: Int, vSync: Int
        var pixelClockMHz: Double { Double(pixelClock10kHz) / 100 }
    }

    /// Width is rounded to a multiple of 8, as CVT requires.
    static func normalized(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(640, (width + 4) / 8 * 8), max(480, height & ~1))
    }

    var timing: Timing {
        let hBlank = 160, hFront = 48, hSync = 32
        let v = Double(height)
        let ratio = Double(width) / v
        let vSync: Int
        switch ratio {
        case 1.30...1.36: vSync = 4      // 4:3
        case 1.74...1.80: vSync = 5      // 16:9
        case 1.58...1.62: vSync = 6      // 16:10
        case 1.22...1.28: vSync = 7      // 5:4
        case 1.65...1.70: vSync = 7      // 15:9
        default: vSync = 10
        }
        let hPeriod = (1.0 / Double(refresh) - 460e-6) / v
        let vbiLines = Int(460e-6 / hPeriod) + 1
        let vBlank = max(vbiLines, 3 + vSync + 6)
        let vTotal = height + vBlank
        let clock = (width + hBlank) * vTotal * refresh
        return Timing(pixelClock10kHz: clock / 10_000,
                      hActive: width, hBlank: hBlank, hFront: hFront, hSync: hSync,
                      vActive: height, vBlank: vBlank, vFront: 3, vSync: vSync)
    }

    func build() -> Data {
        let t = timing
        var b = [UInt8](repeating: 0, count: 256)

        b.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        b[8] = 0x39; b[9] = 0x76           // manufacturer "NKV"
        b[10] = 0x01; b[11] = 0x00         // product code
        b[12] = 0x01                       // serial
        b[16] = 1; b[17] = 36              // week 1, year 2026
        b[18] = 1; b[19] = 4               // EDID 1.4
        b[20] = 0xA2                       // digital, 8 bpc, HDMI-a
        let wCM = min(255, max(1, Int((Double(width) / 110 * 2.54).rounded())))
        let hCM = min(255, max(1, Int((Double(height) / 110 * 2.54).rounded())))
        b[21] = UInt8(wCM); b[22] = UInt8(hCM)
        b[23] = 0x78                       // gamma 2.2
        b[24] = 0x06                       // sRGB, preferred timing is native
        b.replaceSubrange(25..<35, with: [0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])
        for i in 0..<8 { b[38 + i * 2] = 0x01; b[39 + i * 2] = 0x01 }

        writeDTD(&b, at: 54, timing: t, widthMM: wCM * 10, heightMM: hCM * 10)

        // Display range limits
        let rl = 72
        b.replaceSubrange(rl..<(rl + 5), with: [0, 0, 0, 0xFD, 0])
        b[rl + 5] = UInt8(max(1, min(255, refresh - 5)))
        b[rl + 6] = UInt8(min(255, refresh + 70))
        let vTotal = t.vActive + t.vBlank
        let hKHz = Int((Double((t.hActive + t.hBlank) * vTotal * refresh) / Double(t.hActive + t.hBlank) / 1000).rounded(.up))
        b[rl + 7] = UInt8(min(255, max(15, hKHz - 5)))
        b[rl + 8] = UInt8(min(255, hKHz + 10))
        b[rl + 9] = UInt8(min(255, Int((t.pixelClockMHz / 10).rounded(.up)) + 1))
        b[rl + 10] = 0x00; b[rl + 11] = 0x0A
        for i in 12..<18 { b[rl + i] = 0x20 }

        // Monitor name
        let nd = 90
        b.replaceSubrange(nd..<(nd + 5), with: [0, 0, 0, 0xFC, 0])
        var chars = Array(name.utf8.filter { $0 >= 32 && $0 < 127 }.prefix(13))
        if chars.count < 13 { chars.append(0x0A) }
        while chars.count < 13 { chars.append(0x20) }
        b.replaceSubrange((nd + 5)..<(nd + 18), with: chars)

        // Dummy descriptor
        b.replaceSubrange(108..<113, with: [0, 0, 0, 0x10, 0])

        b[126] = 1
        b[127] = checksum(b[0..<127])

        // CTA-861 extension: HDMI vendor-specific block so hosts treat the sink as HDMI.
        b[128] = 0x02; b[129] = 0x03
        b[130] = 10                         // first DTD offset
        b[131] = 0x00
        b.replaceSubrange(132..<138, with: [0x65, 0x03, 0x0C, 0x00, 0x10, 0x00])
        b[255] = checksum(b[128..<255])
        return Data(b)
    }

    private func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        UInt8((256 - Int(bytes.reduce(0) { Int($0) + Int($1) } % 256)) % 256)
    }

    private func writeDTD(_ b: inout [UInt8], at o: Int, timing t: Timing, widthMM: Int, heightMM: Int) {
        b[o] = UInt8(t.pixelClock10kHz & 0xFF)
        b[o + 1] = UInt8((t.pixelClock10kHz >> 8) & 0xFF)
        b[o + 2] = UInt8(t.hActive & 0xFF)
        b[o + 3] = UInt8(t.hBlank & 0xFF)
        b[o + 4] = UInt8(((t.hActive >> 8) << 4) | (t.hBlank >> 8))
        b[o + 5] = UInt8(t.vActive & 0xFF)
        b[o + 6] = UInt8(t.vBlank & 0xFF)
        b[o + 7] = UInt8(((t.vActive >> 8) << 4) | (t.vBlank >> 8))
        b[o + 8] = UInt8(t.hFront & 0xFF)
        b[o + 9] = UInt8(t.hSync & 0xFF)
        b[o + 10] = UInt8(((t.vFront & 0xF) << 4) | (t.vSync & 0xF))
        b[o + 11] = UInt8(((t.hFront >> 8) << 6) | ((t.hSync >> 8) << 4) | ((t.vFront >> 4) << 2) | (t.vSync >> 4))
        b[o + 12] = UInt8(widthMM & 0xFF)
        b[o + 13] = UInt8(heightMM & 0xFF)
        b[o + 14] = UInt8(((widthMM >> 8) << 4) | (heightMM >> 8))
        b[o + 17] = 0x1A                    // digital separate sync, +HSync, -VSync
    }
}

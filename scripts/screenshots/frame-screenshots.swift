#!/usr/bin/env swift
// Usage: frame-screenshots.swift <rawDir> <framedDir>
// Composites each raw simulator screenshot into a device bezel on a gradient with a caption.
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: frame-screenshots.swift <raw> <framed>"); exit(2) }
let rawRoot = URL(fileURLWithPath: args[1]), outRoot = URL(fileURLWithPath: args[2])
let bezelRoot = URL(fileURLWithPath: args[1]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bezels")

let captions: [String: String] = [
    "01-screen": "Your remote screen,\nin your hands",
    "02-kvm-menu": "The full NanoKVM\nweb UI, built in",
    "03-display": "Match the KVM to your\nscreen, on the fly",
    "04-gestures": "Fine-tune the pointer,\ntaps and scrolling",
    "05-video": "Tune video quality\nand frame rate",
]

struct Device {
    let canvas: CGSize
    let screenOrigin: CGPoint  // top-left of the transparent screen area inside the bezel PNG
    let portrait: Bool
}

// Bezels come from scripts/fetch-bezels.sh. The screen area matches the simulator screenshot pixel for pixel.
// Duo has no App Store category, so its canvases are our own choice.
let devices: [String: Device] = [
    "iphone-6.9": Device(canvas: CGSize(width: 1320, height: 2868), screenOrigin: CGPoint(x: 75, y: 66), portrait: true),
    "iphone-6.9-land": Device(canvas: CGSize(width: 2868, height: 1320), screenOrigin: CGPoint(x: 66, y: 76), portrait: false),
    "ipad-13": Device(canvas: CGSize(width: 2064, height: 2752), screenOrigin: CGPoint(x: 118, y: 124), portrait: true),
    "duo-folded": Device(canvas: CGSize(width: 1320, height: 2868), screenOrigin: CGPoint(x: 88, y: 80), portrait: true),
    "mac-14": Device(canvas: CGSize(width: 2880, height: 1800), screenOrigin: CGPoint(x: 418, y: 288), portrait: false),
    "duo-unfolded": Device(canvas: CGSize(width: 2752, height: 2064), screenOrigin: CGPoint(x: 120, y: 120), portrait: false),
]

func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// The screen is the transparent region of the bezel connected to its centre; clipping to it keeps the
// shot's square corners from poking out past the device's rounded body.
func screenMask(of bezel: CGImage) -> CGImage? {
    let w = bezel.width, h = bezel.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.draw(bezel, in: CGRect(x: 0, y: 0, width: w, height: h))
    var mask = [UInt8](repeating: 0, count: w * h)
    var stack = [(h / 2) * w + w / 2]
    while let i = stack.popLast() {
        if mask[i] != 0 || px[i * 4 + 3] > 8 { continue }
        mask[i] = 255
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }
        if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }
        if y < h - 1 { stack.append(i + w) }
    }
    // Grow by a pixel so the bezel's anti-aliased edge covers the seam.
    var grown = mask
    for y in 1..<(h - 1) { for x in 1..<(w - 1) where mask[y * w + x] == 0 {
        let i = y * w + x
        if mask[i - 1] != 0 || mask[i + 1] != 0 || mask[i - w] != 0 || mask[i + w] != 0 { grown[i] = 255 }
    } }
    guard let mc = CGContext(data: &grown, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
    return mc.makeImage()
}

func render(_ shot: CGImage, bezel: CGImage, device d: Device, caption: String) -> CGImage? {
    let W = Int(d.canvas.width), H = Int(d.canvas.height)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let cw = d.canvas.width, ch = d.canvas.height
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(red: 0.10, green: 0.50, blue: 0.92, alpha: 1),
        CGColor(red: 0.04, green: 0.12, blue: 0.40, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: ch), end: CGPoint(x: cw, y: 0), options: [])

    // Caption at the top.
    let fontSize = ch * (d.portrait ? 0.034 : 0.05)
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = fontSize * 0.08
    let text = NSAttributedString(string: caption, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.white, .paragraphStyle: para,
    ])
    let textH = text.boundingRect(with: CGSize(width: cw * 0.9, height: ch), options: [.usesLineFragmentOrigin]).height
    let captionTop = ch * 0.05
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(in: CGRect(x: cw * 0.05, y: ch - captionTop - textH, width: cw * 0.9, height: textH))
    NSGraphicsContext.restoreGraphicsState()

    let availH = ch - captionTop - textH - ch * 0.04 - ch * 0.03
    let deviceW = d.portrait ? cw * 0.9 : min(cw * 0.92, availH * CGFloat(bezel.width) / CGFloat(bezel.height))
    let s = deviceW / CGFloat(bezel.width)
    let frameH = CGFloat(bezel.height) * s
    let originX = (cw - deviceW) / 2
    let originY: CGFloat = d.portrait ? ch - captionTop - textH - ch * 0.04 - frameH : ch * 0.03
    let frame = CGRect(x: originX, y: originY, width: deviceW, height: frameH)
    let screen = CGRect(x: frame.minX + d.screenOrigin.x * s,
                        y: frame.maxY - (d.screenOrigin.y + CGFloat(shot.height)) * s,
                        width: CGFloat(shot.width) * s, height: CGFloat(shot.height) * s)

    ctx.saveGState()
    if let mask = screenMask(of: bezel) { ctx.clip(to: frame, mask: mask) }
    ctx.draw(shot, in: screen.insetBy(dx: -1, dy: -1))
    ctx.restoreGState()
    ctx.draw(bezel, in: frame)
    return ctx.makeImage()
}

let fm = FileManager.default
for (name, device) in devices.sorted(by: { $0.key < $1.key }) {
    let dir = rawRoot.appendingPathComponent(name)
    guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
    let outDir = outRoot.appendingPathComponent(name)
    try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    for f in files.sorted() where f.hasSuffix(".png") {
        let key = String(f.dropLast(4))
        guard let shot = load(dir.appendingPathComponent(f)),
              let bezel = load(bezelRoot.appendingPathComponent("\(name).png")),
              let img = render(shot, bezel: bezel, device: device, caption: captions[key] ?? ""),
              let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(f) as CFURL, "public.png" as CFString, 1, nil)
        else { print("skip \(name)/\(f)"); continue }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("framed \(name)/\(f)")
    }
}

// Usage: mac-scroll <x> <y> <pixels>   scrolls the content under the point (global display coordinates) down by that many pixels.
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count == 4, let x = Double(a[1]), let y = Double(a[2]), let dy = Int32(a[3]) else { print("usage: mac-scroll x y pixels"); exit(2) }
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
usleep(300_000)
for _ in 0..<10 {
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -dy / 10, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    usleep(40_000)
}

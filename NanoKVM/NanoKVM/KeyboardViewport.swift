import CoreGraphics

/// Where the remote screen is drawn while it is zoomed or the on-screen keyboard covers the bottom of the view.
///
/// Without zoom the picture keeps its normal size. The free area (above the keyboard) acts as a window
/// onto it, centred on the pointer, so what you type into is never hidden behind the keyboard.
struct KeyboardViewport {
    static let zoomRange: ClosedRange<CGFloat> = 1...6
    static func clampedZoom(_ z: CGFloat) -> CGFloat { min(max(z, zoomRange.lowerBound), zoomRange.upperBound) }

    static func fitRect(bounds: CGSize, video: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// `focus` is the pointer in 0...1 video coordinates; `overlap` the height of the keyboard over the view.
    static func rect(bounds: CGSize, video: CGSize, overlap: CGFloat, focus: CGPoint, zoom: CGFloat = 1) -> CGRect {
        let fit = fitRect(bounds: bounds, video: video)
        guard overlap > 0 || zoom > 1, overlap < bounds.height, video.width > 0, video.height > 0 else { return fit }
        let visible = CGSize(width: bounds.width, height: bounds.height - overlap)
        let size = CGSize(width: fit.width * max(zoom, 1), height: fit.height * max(zoom, 1))
        let f = CGPoint(x: min(max(focus.x, 0), 1), y: min(max(focus.y, 0), 1))
        return CGRect(origin: CGPoint(x: origin(visible.width, size.width, f.x), y: origin(visible.height, size.height, f.y)), size: size)
    }

    /// Picture placed at an explicit `origin` (clamped so no part of it becomes unreachable).
    static func rect(bounds: CGSize, video: CGSize, overlap: CGFloat, origin: CGPoint, zoom: CGFloat = 1) -> CGRect {
        let fit = fitRect(bounds: bounds, video: video)
        guard overlap > 0 || zoom > 1, overlap < bounds.height, video.width > 0, video.height > 0 else { return fit }
        let visible = CGSize(width: bounds.width, height: bounds.height - overlap)
        let size = CGSize(width: fit.width * max(zoom, 1), height: fit.height * max(zoom, 1))
        return CGRect(origin: CGPoint(x: clamp(origin.x, visible.width, size.width), y: clamp(origin.y, visible.height, size.height)), size: size)
    }

    private static func clamp(_ o: CGFloat, _ visible: CGFloat, _ size: CGFloat) -> CGFloat {
        size <= visible ? (visible - size) / 2 : min(0, max(visible - size, o))
    }

    private static func origin(_ visible: CGFloat, _ size: CGFloat, _ focus: CGFloat) -> CGFloat {
        if size <= visible { return (visible - size) / 2 }
        return min(0, max(visible - size, visible / 2 - focus * size))
    }
}

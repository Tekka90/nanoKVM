import CoreGraphics
import Testing
@testable import NanoKVM

struct KeyboardViewportTests {
    let video = CGSize(width: 1920, height: 1080)

    @Test func noKeyboardIsAspectFit() {
        let b = CGSize(width: 800, height: 400)
        #expect(KeyboardViewport.rect(bounds: b, video: video, overlap: 0, focus: CGPoint(x: 0.5, y: 0.5)) == KeyboardViewport.fitRect(bounds: b, video: video))
    }

    @Test func sizeNeverChangesWithKeyboard() {
        let b = CGSize(width: 800, height: 400)
        let r = KeyboardViewport.rect(bounds: b, video: video, overlap: 200, focus: CGPoint(x: 0.5, y: 0.5))
        #expect(r.size == KeyboardViewport.fitRect(bounds: b, video: video).size)
    }

    @Test func smallPictureMovesAboveKeyboard() {
        let b = CGSize(width: 400, height: 800)
        let r = KeyboardViewport.rect(bounds: b, video: video, overlap: 400, focus: CGPoint(x: 0.5, y: 1))
        #expect(r.minY >= 0 && r.maxY <= 400)
    }

    @Test func tallPictureCentresOnPointerAndClamps() {
        let b = CGSize(width: 800, height: 450)
        let mid = KeyboardViewport.rect(bounds: b, video: video, overlap: 250, focus: CGPoint(x: 0.5, y: 0.5))
        #expect(abs((mid.minY + 0.5 * mid.height) - 100) < 0.01)
        let bottom = KeyboardViewport.rect(bounds: b, video: video, overlap: 250, focus: CGPoint(x: 0.5, y: 1))
        #expect(abs(bottom.maxY - 200) < 0.01)
        let top = KeyboardViewport.rect(bounds: b, video: video, overlap: 250, focus: CGPoint(x: 0.5, y: 0))
        #expect(abs(top.minY) < 0.01)
    }

    @Test func coveredViewIsIgnored() {
        let b = CGSize(width: 400, height: 800)
        #expect(KeyboardViewport.rect(bounds: b, video: video, overlap: 900, focus: .zero) == KeyboardViewport.fitRect(bounds: b, video: video))
    }

    @Test func rectNormalisation() {
        let n = normalizedVideoPoint(CGPoint(x: 150, y: 50), in: CGRect(x: 50, y: 0, width: 200, height: 100))
        #expect(n.x == 0.5 && n.y == 0.5)
    }
}

struct KeyboardViewportPanTests {
    let video = CGSize(width: 1920, height: 1080)
    let bounds = CGSize(width: 800, height: 450)

    @Test func explicitOriginIsClampedSoEdgesStayReachable() {
        let top = KeyboardViewport.rect(bounds: bounds, video: video, overlap: 250, origin: CGPoint(x: 0, y: 500))
        #expect(top.minY == 0)
        let bottom = KeyboardViewport.rect(bounds: bounds, video: video, overlap: 250, origin: CGPoint(x: 0, y: -900))
        #expect(abs(bottom.maxY - 200) < 0.01)
    }

    @Test func explicitOriginWithoutKeyboardIsFit() {
        #expect(KeyboardViewport.rect(bounds: bounds, video: video, overlap: 0, origin: CGPoint(x: 5, y: 5)) == KeyboardViewport.fitRect(bounds: bounds, video: video))
    }
}

struct ViewportZoomTests {
    let video = CGSize(width: 1920, height: 1080)
    let bounds = CGSize(width: 800, height: 450)

    @Test func zoomEnlargesPictureAndCentresOnFocus() {
        let fit = KeyboardViewport.fitRect(bounds: bounds, video: video)
        let r = KeyboardViewport.rect(bounds: bounds, video: video, overlap: 0, focus: CGPoint(x: 0.5, y: 0.5), zoom: 2)
        #expect(abs(r.width - fit.width * 2) < 0.01)
        #expect(abs((r.minX + 0.5 * r.width) - bounds.width / 2) < 0.01)
    }

    @Test func zoomedPictureAlwaysCoversTheView() {
        for f in [0.0, 0.3, 1.0] {
            let r = KeyboardViewport.rect(bounds: bounds, video: video, overlap: 0, focus: CGPoint(x: f, y: f), zoom: 3)
            #expect(r.minX <= 0.01 && r.maxX >= bounds.width - 0.01)
            #expect(r.minY <= 0.01 && r.maxY >= bounds.height - 0.01)
        }
    }

    @Test func zoomCombinesWithKeyboard() {
        let r = KeyboardViewport.rect(bounds: bounds, video: video, overlap: 200, origin: CGPoint(x: -1000, y: -1000), zoom: 2)
        #expect(abs(r.maxY - 250) < 0.01)
    }

    @Test func zoomIsClamped() {
        #expect(KeyboardViewport.clampedZoom(0.3) == 1)
        #expect(KeyboardViewport.clampedZoom(50) == KeyboardViewport.zoomRange.upperBound)
        #expect(KeyboardViewport.clampedZoom(2.5) == 2.5)
    }
}

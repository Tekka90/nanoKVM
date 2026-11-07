import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import Testing
@testable import NanoKVM

/// Produces real encoded frames so the decoder path can be exercised without a device.
enum TestEncoder {
    static let size = 128

    /// Returns a device-style frame: [keyframe flag][8 byte timestamp][Annex-B NAL units].
    static func frame(codec: CMVideoCodecType, timestamp: UInt64 = 1000) -> Data? {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(size), height: Int32(size), codecType: codec,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess, let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 0x80, CVPixelBufferGetDataSize(pixels)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var output: CMSampleBuffer?
        let done = DispatchSemaphore(value: 0)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels,
                                                     presentationTimeStamp: CMTime(value: 0, timescale: 30), duration: .invalid,
                                                     frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                                                     infoFlagsOut: nil) { st, _, sample in
            if st == noErr { output = sample }
            done.signal()
        }
        guard status == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        _ = done.wait(timeout: .now() + 10)
        VTCompressionSessionInvalidate(session)
        guard let sample = output, let fd = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }

        let start: [UInt8] = [0, 0, 0, 1]
        var data = Data([1])
        var ts = timestamp.littleEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }

        var count = 0
        if codec == kCMVideoCodecType_H264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var len = 0
            if codec == kCMVideoCodecType_H264 {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if let ptr { data.append(contentsOf: start); data.append(ptr, count: len) }
        }

        var raw: UnsafeMutablePointer<Int8>?
        var total = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &raw) == kCMBlockBufferNoErr,
              let raw else { return nil }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self), count: total)
        var offset = 0
        while offset + 4 <= total {
            let len = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard offset + len <= total else { break }
            data.append(contentsOf: start)
            data.append(contentsOf: bytes[offset..<(offset + len)])
            offset += len
        }
        return data
    }
}

@MainActor
struct VideoStreamTests {
    private func stream(_ codec: VideoStream.Codec = .h264) -> VideoStream {
        let s = VideoStream(host: "unused.test", token: "t")
        s.codec = codec
        return s
    }

    @Test func splitsThreeByteStartCodes() {
        let bytes: [UInt8] = [0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3]
        let nals = VideoStream.splitAnnexB(bytes, from: 0)
        #expect(nals.map(Array.init) == [[0x67, 1, 2], [0x68, 3]])
    }

    @Test func splitsFourByteStartCodesAndTrimsPadding() {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x65, 9, 0, 0, 0, 0, 0, 1, 0x41, 7, 0, 0]
        let nals = VideoStream.splitAnnexB(bytes, from: 0)
        #expect(nals.map(Array.init) == [[0x65, 9], [0x41, 7]])
    }

    @Test func splitHonoursStartOffsetAndEmptyInput() {
        #expect(VideoStream.splitAnnexB([], from: 0).isEmpty)
        #expect(VideoStream.splitAnnexB([1, 2, 3, 4], from: 0).isEmpty)
        let bytes: [UInt8] = [9, 9, 0, 0, 1, 5, 6]
        #expect(VideoStream.splitAnnexB(bytes, from: 2).map(Array.init) == [[5, 6]])
        #expect(VideoStream.splitAnnexB(bytes, from: 6).isEmpty)
    }

    @Test func statusMessagesMapToStates() {
        let s = stream()
        func status(_ code: String) { s.handle(.string("{\"event\":\"video-status\",\"data\":\"\(code)\"}")) }
        status("-1"); #expect(s.state == .noSignal("No image"))
        status("-2"); #expect(s.state == .noSignal("Inconsistent video mode"))
        status("-3"); #expect(s.state == .noSignal("Capture disabled"))
        status("-9"); #expect(s.state == .noSignal("Video signal changing (status -9)"))
        status("1");  #expect(s.state == .noSignal("Video signal changing (status -9)"))
    }

    @Test func unknownStatusDoesNotBlankFlowingVideo() {
        let s = stream()
        s.lastFrameAt = Date()
        s.handle(.string("{\"event\":\"video-status\",\"data\":\"-4\"}"))
        #expect(s.state == .idle)
        #expect(s.noSignalSince == nil)
    }

    @Test func ignoresUnrelatedTextMessages() {
        let s = stream()
        s.handle(.string("not json"))
        s.handle(.string("{\"event\":\"other\",\"data\":\"-1\"}"))
        #expect(s.state == .idle)
    }

    @Test func shortOrGarbageFramesAreIgnored() {
        let s = stream()
        s.decode(Data([1, 2, 3]))
        s.handle(.data(Data(repeating: 7, count: 50)))
        #expect(s.state == .idle && s.videoSize == .zero)
    }

    @Test func slicesWithoutParameterSetsDoNothing() {
        let s = stream()
        var d = Data([1]) + Data(repeating: 0, count: 8)
        d.append(contentsOf: [0, 0, 0, 1, 0x65, 1, 2, 3])
        s.decode(d)
        #expect(s.state == .idle)
    }

    @Test func h264FrameStartsPlaying() throws {
        guard let frame = TestEncoder.frame(codec: kCMVideoCodecType_H264) else { return }
        let s = stream(.h264)
        s.decode(frame)
        #expect(s.state == .playing)
        #expect(s.videoSize == CGSize(width: TestEncoder.size, height: TestEncoder.size))
        s.decode(frame)
        #expect(s.state == .playing)
    }

    @Test func h265FrameStartsPlaying() throws {
        guard let frame = TestEncoder.frame(codec: kCMVideoCodecType_HEVC) else { return }
        let s = stream(.h265)
        s.decode(frame)
        #expect(s.state == .playing)
        #expect(s.videoSize.width == CGFloat(TestEncoder.size))
    }

    @Test func h265NeedsVPS() throws {
        guard let frame = TestEncoder.frame(codec: kCMVideoCodecType_HEVC) else { return }
        let s = stream(.h265)
        let bytes = [UInt8](frame)
        let kept = VideoStream.splitAnnexB(bytes, from: 9).filter { (($0[$0.startIndex] >> 1) & 0x3F) != 32 }
        var d = Data(bytes[0..<9])
        for n in kept { d.append(contentsOf: [0, 0, 0, 1]); d.append(contentsOf: n) }
        s.decode(d)
        #expect(s.state == .idle)
    }

    @Test func h264ParameterSetChangeUpdatesFormat() throws {
        guard let frame = TestEncoder.frame(codec: kCMVideoCodecType_H264) else { return }
        let s = stream(.h264)
        s.decode(frame)
        let first = s.videoSize
        s.decode(frame)
        #expect(s.videoSize == first)
    }

    @Test func startAndStopManageState() {
        let s = stream()
        s.start()
        #expect(s.state == .connecting)
        s.stop()
        #expect(s.state == .idle)
        s.codec = .h265
        s.start()
        #expect(s.state == .connecting)
        s.stop()
    }

    @Test func codecRawValues() {
        #expect(VideoStream.Codec(rawValue: "h264") == .h264)
        #expect(VideoStream.Codec(rawValue: "h265") == .h265)
        #expect(VideoStream.Codec(rawValue: "av1") == nil)
    }
}

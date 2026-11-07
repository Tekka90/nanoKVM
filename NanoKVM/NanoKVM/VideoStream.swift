import AVFoundation
import CoreMedia
import Foundation

/// Receives the device's H.264 "direct" WebSocket stream and renders it on an AVSampleBufferDisplayLayer.
///
/// Frame layout: [0]=1 for keyframe, [1...8]=timestamp (µs, little endian), [9...]=Annex-B NAL units.
@MainActor
@Observable
final class VideoStream {
    enum State: Equatable {
        case idle, connecting, playing
        case noSignal(String)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
        var isNoSignal: Bool { if case .noSignal = self { true } else { false } }
    }

    enum Codec: String { case h264, h265 }
    var codec: Codec = Codec(rawValue: UserDefaults.standard.string(forKey: "videoCodec") ?? "") ?? .h264

    let layer = AVSampleBufferDisplayLayer()
    private(set) var state: State = .idle
    private(set) var videoSize: CGSize = .zero
    /// One sample per second, newest last (max 60).
    private(set) var history: [StatSample] = []
    @ObservationIgnored private(set) var meter = StreamMeter()
    private var statsTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// Last time the socket proved it is alive (any message or a pong).
    @ObservationIgnored private(set) var lastAlive = Date()
    /// When the stream last entered a no-signal state (nil otherwise).
    @ObservationIgnored private(set) var noSignalSince: Date?
    @ObservationIgnored var lastFrameAt: Date?
    /// When the current connection attempt began; used to spot a stream that opens but never delivers a frame.
    @ObservationIgnored private(set) var startedAt = Date()

    private let host: String
    var token: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?

    init(host: String, token: String) {
        self.host = host
        self.token = token
        layer.videoGravity = .resizeAspect
    }

    func start() {
        stop()
        state = .connecting
        meter.reset(); history = []
        lastAlive = Date(); noSignalSince = nil; startedAt = Date()
        KVMLog.info("video stream start (\(self.codec.rawValue))")
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if let sample = self.meter.tick() { self.history = StreamMeter.append(sample, to: self.history) }
            }
        }
        var request = URLRequest(url: URL(string: "wss://\(host)/api/stream/\(codec.rawValue)/direct")!)
        request.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: PinnedHostDelegate(host: host), delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.session = session
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handle(message)
                } catch {
                    if !Task.isCancelled {
                        KVMLog.error("video receive failed: \(error.localizedDescription)")
                        self?.state = .failed(error.localizedDescription)
                    }
                    return
                }
            }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pingInterval))
                guard let self, !Task.isCancelled else { return }
                if Self.isDead(lastAlive: self.lastAlive, now: Date()) {
                    KVMLog.error("video socket silent, marking failed")
                    self.state = .failed("Connection lost")
                    self.task?.cancel(with: .goingAway, reason: nil)
                    return
                }
                task.sendPing { [weak self] error in
                    if error == nil { Task { @MainActor in self?.lastAlive = Date() } }
                }
            }
        }
    }

    nonisolated static let pingInterval = 5.0
    nonisolated static let deadAfter = 15.0

    /// A socket that neither delivered data nor answered a ping for `deadAfter` seconds is considered gone.
    nonisolated static func isDead(lastAlive: Date, now: Date, timeout: Double = deadAfter) -> Bool {
        now.timeIntervalSince(lastAlive) > timeout
    }

    func stop() {
        if state != .idle { KVMLog.info("video stream stop (frames received: \(meter.totalFrames))") }
        statsTask?.cancel()
        statsTask = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        format = nil
        sps = nil
        pps = nil
        vps = nil
        layer.flushAndRemoveImage()
        state = .idle
    }

    func handle(_ message: URLSessionWebSocketTask.Message) {
        lastAlive = Date()
        switch message {
        case .string(let text):
            // {"event":"video-status","data":"1"}; 1 = normal
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  obj["event"] as? String == "video-status" else { return }
            let status = "\(obj["data"] ?? "")"
            if status != "1" {
                if noSignalSince == nil { noSignalSince = Date() }
                KVMLog.info("video status \(status)")
            }
            // -4 and similar codes arrive while the picture keeps flowing (e.g. the source changes resolution): don't blank it.
            let framesFlowing = Date().timeIntervalSince(lastFrameAt ?? .distantPast) < 2
            switch status {
            case "1": noSignalSince = nil
            case "-1": state = .noSignal("No image")
            case "-2": state = .noSignal("Inconsistent video mode")
            case "-3": state = .noSignal("Capture disabled")
            default:
                if framesFlowing { noSignalSince = nil } else { state = .noSignal("Video signal changing (status \(status))") }
            }
        case .data(let data):
            decode(data)
        @unknown default:
            break
        }
    }

    func decode(_ data: Data) {
        guard data.count > 9 else { return }
        let bytes = [UInt8](data)
        meter.record(bytes: data.count, keyframe: bytes[0] == 1)
        var timestamp: UInt64 = 0
        for i in 0..<8 { timestamp |= UInt64(bytes[1 + i]) << (8 * UInt64(i)) }

        var slices: [ArraySlice<UInt8>] = []
        for nal in Self.splitAnnexB(bytes, from: 9) where !nal.isEmpty {
            if codec == .h265 {
                switch (nal[nal.startIndex] >> 1) & 0x3F {
                case 32: vps = Data(nal)
                case 33: sps = Data(nal)
                case 34: pps = Data(nal)
                case 0...9, 16...21: slices.append(nal)
                default: break
                }
            } else {
                switch nal[nal.startIndex] & 0x1F {
                case 7: sps = Data(nal)
                case 8: pps = Data(nal)
                case 1, 5: slices.append(nal)
                default: break
                }
            }
        }

        if format == nil || (bytes[0] == 1 && sps != nil && pps != nil && (codec == .h264 || vps != nil)) {
            updateFormat()
        }
        guard let format, !slices.isEmpty else { return }

        var avcc = Data()
        for nal in slices {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }
        enqueue(avcc, format: format, timestampMicros: timestamp)
        noSignalSince = nil
        lastFrameAt = Date()
        if state != .playing {
            KVMLog.info("video playing \(Int(videoSize.width))x\(Int(videoSize.height))")
            state = .playing
        }
    }

    private func updateFormat() {
        guard let sps, let pps else { return }
        var sets = [sps, pps]
        if codec == .h265 {
            guard let vps else { return }
            sets = [vps, sps, pps]
        }
        var newFormat: CMVideoFormatDescription?
        let sizes = sets.map(\.count)
        let status: OSStatus = withExtendedLifetime(sets) {
            var pointers: [UnsafePointer<UInt8>] = []
            var storage: [UnsafeMutablePointer<UInt8>] = []
            for d in sets {
                let m = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
                d.copyBytes(to: m, count: d.count)
                storage.append(m); pointers.append(UnsafePointer(m))
            }
            defer { storage.forEach { $0.deallocate() } }
            if codec == .h265 {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
        }
        guard status == noErr, let newFormat else { return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: newFormat) { return }
        format = newFormat
        let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
        videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
    }

    private func enqueue(_ avcc: Data, format: CMVideoFormatDescription, timestampMicros: UInt64) {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }

        // Live stream: render each frame as soon as it is decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }

    /// Splits an Annex-B byte stream into NAL units (start codes removed).
    nonisolated static func splitAnnexB(_ bytes: [UInt8], from start: Int) -> [ArraySlice<UInt8>] {
        var starts: [(code: Int, nal: Int)] = []
        var i = start
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var result: [ArraySlice<UInt8>] = []
        for (index, s) in starts.enumerated() {
            var end = index + 1 < starts.count ? starts[index + 1].code : bytes.count
            // Drop the leading zero of a 4-byte start code or trailing zero padding.
            while end > s.nal, bytes[end - 1] == 0 { end -= 1 }
            result.append(bytes[s.nal..<end])
        }
        return result
    }
}

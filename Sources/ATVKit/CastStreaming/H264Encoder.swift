import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// A frame the way Cast Streaming wants it: a whole H.264 access unit in
/// Annex-B form (start-code delimited, SPS+PPS prepended to key frames), plus
/// the metadata the RTP layer needs.
public struct EncodedVideoFrame: Sendable {
    public var frameId: UInt32
    public var referencedFrameId: UInt32
    public var rtpTimestamp: UInt32     // 90 kHz
    public var isKeyFrame: Bool
    public var annexB: [UInt8]
}

/// Low-latency H.264 encoder built on VideoToolbox, feeding the mirroring
/// pipeline one access unit per captured frame.
///
/// Deliberately configured for latency over quality: real-time rate control,
/// no frame reordering (no B-frames), and — where the OS offers it — the
/// hardware low-latency rate controller. VideoToolbox hands back AVCC
/// (length-prefixed) NAL units; Cast receivers expect Annex-B, so each access
/// unit is rewritten with 0x00000001 start codes and key frames carry their
/// SPS/PPS inline.
public final class H264Encoder: @unchecked Sendable {

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let queue = DispatchQueue(label: "mirror.h264")

    private var frameCounter: UInt32 = 0
    private var lastFrameId: UInt32 = 0
    private var rtpBase: CMTime?
    private var forceKeyFrameNext = false

    /// Delivered on the encoder's callback thread, in encode order.
    public var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?

    public init(width: Int, height: Int, fps: Int = 30, bitRate: Int = 8_000_000) throws {
        self.width = Int32(width)
        self.height = Int32(height)

        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        if #available(macOS 11.0, *) {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let created else {
            throw ATVError.screenCapture("VideoToolbox encoder failed to start (\(status))")
        }
        session = created
        configure(session: created, fps: fps, bitRate: bitRate)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    private func configure(session: VTCompressionSession, fps: Int, bitRate: Int) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // One frame in, one frame out: never hold a frame back hoping to code
        // it more cheaply against a later one. This is the encoder's own latency.
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 1 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // Cap the rate-control buffer to ~2 frames so a burst can't build a
        // backlog that arrives late; keeps bitrate honest without a VBV delay.
        let perFrame = Double(bitRate) / Double(max(fps, 1))
        set(kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: Int(perFrame * 2 / 8)), NSNumber(value: 1.0)] as CFArray)
        // A key frame at least every few seconds, plus on demand (PLI/NACK).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4 as CFNumber)
        // Cap the coded-frame delay so frames leave the encoder promptly.
        set(kVTCompressionPropertyKey_MaxH264SliceBytes, (RtpPacketizer.maxPayload * 64) as CFNumber)
    }

    /// Ask for a key frame on the next captured frame (loss recovery, startup).
    public func requestKeyFrame() {
        queue.async { self.forceKeyFrameNext = true }
    }

    /// Encodes one captured frame. `pts` is the capture presentation time.
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        queue.sync {
            if rtpBase == nil { rtpBase = pts }
        }
        var properties: [CFString: Any] = [:]
        if queue.sync(execute: { let f = forceKeyFrameNext; forceKeyFrameNext = false; return f }) {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: properties as CFDictionary,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard let self, status == noErr, let sampleBuffer else { return }
                self.handleEncoded(sampleBuffer)
            }
    }

    public func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - AVCC -> Annex-B

    private func handleEncoded(_ sample: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        let isKey = Self.isKeyFrame(sample)

        var annexB = [UInt8]()
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            annexB.append(contentsOf: Self.parameterSetsAnnexB(format))
        }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let base = pointer else { return }
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)

        // AVCC: [4-byte big-endian length][NAL]… Rewrite each as a start code.
        var i = 0
        while i + 4 <= length {
            let nalLen = (Int(bytes[i]) << 24) | (Int(bytes[i+1]) << 16)
                       | (Int(bytes[i+2]) << 8) | Int(bytes[i+3])
            i += 4
            guard nalLen > 0, i + nalLen <= length else { break }
            annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            annexB.append(contentsOf: UnsafeBufferPointer(start: bytes + i, count: nalLen))
            i += nalLen
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        emit(annexB: annexB, isKey: isKey, pts: pts)
    }

    private func emit(annexB: [UInt8], isKey: Bool, pts: CMTime) {
        queue.sync {
            let frameId = frameCounter
            frameCounter &+= 1
            let base = rtpBase ?? pts
            let seconds = (pts - base).seconds
            let rtp = UInt32(truncatingIfNeeded: Int64((seconds * 90_000).rounded()))
            // A key frame references itself; a delta frame references its predecessor.
            let reference = isKey ? frameId : lastFrameId
            lastFrameId = frameId
            onFrame?(EncodedVideoFrame(frameId: frameId, referencedFrameId: reference,
                                       rtpTimestamp: rtp, isKeyFrame: isKey, annexB: annexB))
        }
    }

    private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        // Absent "NotSync" means this is a sync (key) frame.
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        return true
    }

    /// SPS and PPS as Annex-B NAL units, read from the format description.
    private static func parameterSetsAnnexB(_ format: CMFormatDescription) -> [UInt8] {
        var out = [UInt8]()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for index in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: size))
            }
        }
        return out
    }
}

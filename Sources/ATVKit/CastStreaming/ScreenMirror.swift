import Foundation
import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Real-time screen mirroring over Cast Streaming.
///
/// This is the low-latency path, parallel to `ScreenStream` (the HLS path).
/// Where HLS buffers seconds of video in the TV's media player, this pushes
/// each H.264 frame to the receiver's mirroring app over UDP as it is encoded,
/// for roughly a quarter-second of glass-to-glass delay.
///
///   ScreenCaptureKit → H264Encoder (Annex-B) → FrameCrypto (AES-CTR)
///   → RTP/UDP (MirrorTransport)   ‖   MirrorSession negotiates the session
///
/// v1 mirrors a whole display. Window / app / tab sources reuse the same
/// pipeline and are a follow-up.
public final class ScreenMirror: NSObject, @unchecked Sendable {

    private let queue = DispatchQueue(label: "mirror.capture")
    private var capture: SCStream?
    private var encoder: H264Encoder?
    private var transport: MirrorTransport?
    private var session: MirrorSession?
    private let crypto: FrameCrypto
    private let videoSSRC: UInt32
    private var activity: NSObjectProtocol?

    public var onStop: (@Sendable () -> Void)?

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private override init() {
        self.crypto = FrameCrypto.random()
        self.videoSSRC = MirrorSession.randomSSRC(video: true)
        super.init()
    }

    /// Negotiates with the TV and starts mirroring `displayID` (or the main
    /// display). Throws if the receiver rejects the mirroring session.
    public static func start(host: String, displayID: CGDirectDisplayID? = nil,
                             fps: Int = 30) async throws -> ScreenMirror {
        guard hasPermission else {
            throw ATVError.screenCapture("Screen Recording permission is off")
        }
        let mirror = ScreenMirror()
        try await mirror.begin(host: host, displayID: displayID, fps: fps)
        return mirror
    }

    private func begin(host: String, displayID: CGDirectDisplayID?, fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let target = content.displays.first { $0.displayID == (displayID ?? CGMainDisplayID()) }
            ?? content.displays.first
        guard let display = target else { throw ATVError.screenCapture("no display to capture") }

        // Encode a 16:9 frame regardless of the Mac display's shape. TV Cast
        // receivers scale the video to fill their 16:9 panel, so sending a
        // 16:10 (MacBook) or other non-16:9 frame comes out stretched. We let
        // ScreenCaptureKit letterbox the real display into a 16:9 canvas with
        // black bars, so the pixels we send already match the panel 1:1.
        let (width, height) = ScreenMirror.canvas16x9(for: display.frame.size)

        // Wi-Fi, not wired: keep the data rate low so frames fit the air
        // without flooding it. 1080p at 8 Mbps caused a packet-loss storm
        // (constant NACK retransmits) that showed up as lag. 720p at ~4 Mbps
        // is a quarter of the packets per frame. The encoder and the OFFER
        // must advertise the same ceiling.
        let bitRate = 4_000_000

        // 1. Negotiate. The OFFER advertises this session's key/IV and SSRC.
        let session = try await MirrorSession.connect(host: host)
        self.session = session
        let videoConfig = MirrorStreamConfig.video(index: 0, ssrc: videoSSRC, crypto: crypto,
                                                   width: width, height: height, fps: fps,
                                                   maxBitRate: bitRate)
        let result = try await session.negotiate(streams: [videoConfig])
        guard result.answer.sendIndexes.contains(0) else {
            await session.close()
            throw ATVError.screenCapture("receiver accepted the session but not the video stream")
        }

        // 2. Build the encode + transport pipeline.
        let encoder = try H264Encoder(width: width, height: height, fps: fps, bitRate: bitRate)
        let transport = MirrorTransport(host: result.host, port: result.answer.udpPort,
                                        senderSSRC: videoSSRC,
                                        videoPayloadType: CastPayloadType.videoAndroidTV)
        self.encoder = encoder
        self.transport = transport

        let crypto = self.crypto
        encoder.onFrame = { [weak transport] frame in
            guard let transport else { return }
            let encrypted = crypto.crypt(frameId: frame.frameId, frame.annexB)
            transport.sendVideo(MirrorFrame(frameId: frame.frameId,
                                            referencedFrameId: frame.referencedFrameId,
                                            rtpTimestamp: frame.rtpTimestamp,
                                            isKeyFrame: frame.isKeyFrame, payload: encrypted))
        }
        transport.onKeyFrameRequest = { [weak encoder] in encoder?.requestKeyFrame() }
        transport.start()

        // 3. Start capture.
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        // Letterbox bars default to black; we deliberately do NOT set
        // `backgroundColor` — assigning any CGColor crashes ScreenCaptureKit's
        // configuration copy/serialize on this OS (CGColorCreateCopy / null).
        // Shallow queue: hand us the newest frame and don't sit on a backlog.
        // A deep queue trades latency for smoothness, the wrong way round here.
        config.queueDepth = 3
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.capture = stream

        encoder.requestKeyFrame()   // the receiver needs a key frame to begin
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Mirroring the screen to a TV")
        Log.info("Mirror", "live mirror \(width)x\(height)@\(fps) → \(result.host):\(result.answer.udpPort)")
    }

    /// A 16:9 pixel canvas that the display's content letterboxes into,
    /// capped at 1080p and never upscaling a small display much past 2×.
    /// Even dimensions, as H.264 requires.
    static func canvas16x9(for points: CGSize) -> (Int, Int) {
        let longEdge = max(points.width, points.height) * 2   // Retina
        // Cap at 720p: 1080p over Wi-Fi drops too many packets. 720p is the
        // sweet spot of sharp-enough and reliably deliverable.
        let w = min(1280, Int(longEdge)) & ~1
        let h = (w * 9 / 16) & ~1
        return (max(w, 2), max(h, 2))
    }

    public func stop() {
        if let capture { Task { try? await capture.stopCapture() } }
        capture = nil
        encoder?.stop(); encoder = nil
        transport?.stop(); transport = nil
        let session = self.session; self.session = nil
        Task { await session?.close() }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Log.info("Mirror", "stopped")
    }
}

extension ScreenMirror: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        encoder?.encode(pixels, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Mirror", "capture stopped: \(error)")
        onStop?()
    }
}

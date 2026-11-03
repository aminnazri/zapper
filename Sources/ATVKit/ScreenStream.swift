import Foundation
import AppKit
import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Mirrors this Mac's display to a Cast receiver as live HLS.
///
/// A TV's built-in Chromecast has no receiver for a sender's screen — Chrome's
/// own "Cast screen" uses a separate streaming protocol. The Default Media
/// Receiver does play live HLS, so:
///
///   ScreenCaptureKit -> AVAssetWriter (H.264 + AAC, fragmented MP4 segments)
///   -> rolling playlist in memory -> HTTPServer -> receiver LOADs live.m3u8
///
/// Delay is set by how far behind the newest segment the receiver's player
/// sits. Left alone it holds back three target durations and trails that by
/// another second or so — about 6 s in all on a Mi TV. Short segments, a
/// HOLD-BACK hint and a catch-up seek from the sender (see AppState) bring it
/// to roughly 2 s. Real-time mirroring would need Cast Streaming instead.
public final class ScreenStream: NSObject, @unchecked Sendable {

    /// A frame waits up to this long before the TV can fetch it.
    public static let segmentSeconds = 0.5

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only allows
    /// changing it in System Settings, and the app must be relaunched.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private let queue = DispatchQueue(label: "screen.stream")
    private var capture: SCStream?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var server: HTTPServer?
    private var repeatTimer: DispatchSourceTimer?
    private var pageTimer: DispatchSourceTimer?

    /// Called when capture ends on its own — the shared window closed or the
    /// app quit.
    public var onStop: (@Sendable () -> Void)?
    /// Called with false when the shared window or app leaves the screen
    /// (another Space, a full-screen app, minimised, hidden) and true when it
    /// is back. `fullScreen` is set when the window itself is in full-screen
    /// mode — its own Space, so it goes dark whenever another app is in front.
    public var onVisibilityChange: (@Sendable (_ visible: Bool, _ fullScreen: Bool) -> Void)?
    private var activity: NSObjectProtocol?

    /// What a window or app share watches. Nil for a display, which is
    /// always on screen.
    private struct Target { var window: CGWindowID?; var pid: pid_t? }
    private var target: Target?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var audioEnabled = false
    private var visibilityTimer: DispatchSourceTimer?

    // Off-screen handling, on `queue`.
    /// macOS stops drawing windows that are not on the active Space, and
    /// capture then yields black frames or stops outright. While hidden the
    /// TV holds the last picture instead.
    private var hidden = false
    private var hiddenFullScreen = false
    private var stopped = false
    private var restarting = false
    private var lastRestart = Date.distantPast
    /// Copies taken every quarter second, newest last. Black frames arrive a
    /// moment before the window is reported gone, so the held picture comes
    /// from just before that.
    private var stills: [(time: CMTime, frame: CVPixelBuffer)] = []

    // Capture state, touched only on `queue`.
    /// Host time of the first frame. Everything written is relative to it,
    /// because the writer's HLS profile wants the session to start at zero.
    private var origin: CMTime?
    private var lastFrame: CVPixelBuffer?
    private var lastVideoTime = CMTime.negativeInfinity
    /// Where the audio written so far ends, relative to `origin`.
    private var audioEnd = CMTime.zero
    private var audioRejected = false

    // Playlist state, shared with the HTTP server's queue.
    private let lock = NSLock()
    private var initSegment: Data?
    private var segments: [(sequence: Int, duration: Double, data: Data)] = []
    private var nextSequence = 0

    public private(set) var playlistURL = ""

    // MARK: - Start

    /// Starts capturing `source`. When sharing a display, this app's own
    /// windows are left out, so the remote panel never shows up on the TV.
    public static func start(_ source: ScreenSource, audio: Bool = true,
                             fps: Int = 30) async throws -> ScreenStream {
        guard hasPermission else {
            throw ATVError.screenCapture("Screen Recording permission is off")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = ProcessInfo.processInfo.processIdentifier
        func display(_ id: CGDirectDisplayID) -> SCDisplay? {
            content.displays.first { $0.displayID == id } ?? content.displays.first
        }

        let filter: SCContentFilter
        var size: CGSize
        var crop: CGRect?
        var tracker: PageTracker?
        switch source {
        case .display(let id):
            guard let screen = display(id) else { throw ATVError.screenCapture("that display is gone") }
            let own = content.applications.filter { $0.processID == me }
            filter = SCContentFilter(display: screen, excludingApplications: own, exceptingWindows: [])
            size = screen.frame.size

        case .app(let pid):
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw ATVError.screenCapture("that app has quit")
            }
            // Show it on the display that holds most of its window area.
            let windows = ScreenSources.shareable(content.windows.filter { $0.owningApplication?.processID == pid })
            let screen = content.displays.max { a, b in
                windows.reduce(0) { $0 + $1.frame.intersection(a.frame).width * $1.frame.intersection(a.frame).height }
                    < windows.reduce(0) { $0 + $1.frame.intersection(b.frame).width * $1.frame.intersection(b.frame).height }
            } ?? display(CGMainDisplayID())
            guard let screen else { throw ATVError.screenCapture("no display to capture") }
            filter = SCContentFilter(display: screen, including: [app], exceptingWindows: [])
            size = screen.frame.size

        case .window(let id), .tab(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ATVError.screenCapture("that window has closed")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
            if case .tab = source, let pid = window.owningApplication?.processID,
               let found = PageTracker(pid: pid, windowFrame: window.frame) {
                tracker = found
                // A Chromium browser builds its tree on first request; give
                // it a moment before settling for the whole window.
                for _ in 0..<4 {
                    if let rect = found.pageRect() { crop = rect; break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if let crop { size = crop.size }
            }
        }

        let (width, height) = fit(size)
        let stream = try ScreenStream(width: width, height: height, fps: fps, audio: audio)
        switch source {
        case .display: break
        case .app(let pid): stream.target = Target(window: nil, pid: pid)
        case .window(let id), .tab(let id): stream.target = Target(window: id, pid: nil)
        }
        try await stream.begin(filter: filter, width: width, height: height, fps: fps,
                               audio: audio, crop: crop, tracker: tracker)
        return stream
    }

    /// Pixel size for a capture of `points`: Retina resolution, fitted into
    /// 1080p — TV Cast receivers rarely decode more, and the bitrate goes
    /// further on fewer pixels. Even, as H.264 requires.
    static func fit(_ points: CGSize) -> (Int, Int) {
        let w = max(points.width, 2) * 2, h = max(points.height, 2) * 2
        let scale = min(1, 1920 / w, 1080 / h)
        return (Int(w * scale) & ~1, Int(h * scale) & ~1)
    }

    private init(width: Int, height: Int, fps: Int, audio: Bool) throws {
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.segmentSeconds, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                // A segment can only be cut at a keyframe, so one per segment.
                AVVideoMaxKeyFrameIntervalKey: Int(Double(fps) * Self.segmentSeconds),
                AVVideoMaxKeyFrameIntervalDurationKey: Self.segmentSeconds,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        super.init()
        writer.delegate = self
    }

    private func begin(filter: SCContentFilter, width: Int, height: Int, fps: Int, audio: Bool,
                       crop: CGRect?, tracker: PageTracker?) async throws {
        guard writer.startWriting() else {
            throw ATVError.screenCapture("encoder failed to start: \(writer.error.map { "\($0)" } ?? "unknown")")
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6
        if let crop { config.sourceRect = crop }
        if #available(macOS 14.0, *) {
            // A resized window or page is letterboxed rather than stretched.
            config.preservesAspectRatio = true
        }
        if audio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        self.filter = filter
        self.config = config
        audioEnabled = audio
        let capture = try makeCapture(filter)
        try await capture.startCapture()
        self.capture = capture

        // ScreenCaptureKit sends nothing while the screen is still, but the
        // stream needs frames to keep cutting segments, or the TV stalls.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 1.0 / Double(fps) * 3)
        timer.setEventHandler { [weak self] in
            self?.repeatLastFrame()
            self?.fillSilence()
        }
        timer.resume()
        repeatTimer = timer

        if let tracker { followPage(tracker, config: config) }

        if target != nil {
            let watch = DispatchSource.makeTimerSource(queue: queue)
            watch.schedule(deadline: .now() + 0.25, repeating: 0.25)
            watch.setEventHandler { [weak self] in self?.checkVisibility() }
            watch.resume()
            visibilityTimer = watch
        }

        let server = try HTTPServer { [weak self] path in self?.respond(to: path) }
        self.server = server
        guard let base = server.baseURL(preferIPv6: false) else {
            throw ATVError.screenCapture("this Mac has no network address the TV can reach")
        }
        playlistURL = base + "/live.m3u8"

        // The TV would otherwise idle-dim, and the Mac sleeping ends the stream.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Mirroring the screen to a TV")
        Log.info("Screen", "capturing \(width)x\(height)@\(fps) audio=\(audio), serving \(playlistURL)")
    }

    /// Waits until the playlist holds enough segments for the receiver to
    /// start; loading earlier makes it give up on an empty playlist.
    public func waitUntilReady(segments wanted: Int = 2, timeout: TimeInterval = 12) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = segmentCount()
            if writer.status == .failed {
                throw ATVError.screenCapture("encoder failed: \(writer.error.map { "\($0)" } ?? "unknown")")
            }
            if count >= wanted { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ATVError.screenCapture("no video came out of the screen capture")
    }

    private func segmentCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return segments.count
    }

    /// Re-crops as the window is resized or another tab, with a different
    /// page area, comes to the front.
    private func followPage(_ tracker: PageTracker, config: SCStreamConfiguration) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "screen.page"))
        var current = config.sourceRect
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            guard let self, let rect = tracker.pageRect(), let capture = self.capture else { return }
            let moved = abs(rect.minX - current.minX) + abs(rect.minY - current.minY)
                + abs(rect.width - current.width) + abs(rect.height - current.height)
            guard moved > 2 else { return }
            current = rect
            config.sourceRect = rect
            capture.updateConfiguration(config) { error in
                if let error { Log.warn("Screen", "re-crop failed: \(error)") }
            }
        }
        timer.resume()
        pageTimer = timer
    }

    private func makeCapture(_ filter: SCContentFilter) throws -> SCStream {
        guard let config else { throw ATVError.screenCapture("not configured") }
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audioEnabled { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        return capture
    }

    // MARK: - Off screen (on `queue`)

    private func checkVisibility() {
        guard let target, !stopped else { return }
        let (visible, exists, fullScreen) = Self.visibility(of: target)
        hiddenFullScreen = fullScreen
        guard exists else {
            Log.info("Screen", "shared window or app is gone")
            self.target = nil
            onStop?()
            return
        }
        if visible == hidden { setHidden(!visible) }
        if visible, capture == nil { restartCapture() }
    }

    private func setHidden(_ value: Bool) {
        guard value != hidden else { return }
        hidden = value
        if value {
            let cutoff = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(value: 1, timescale: 2)
            if let still = stills.last(where: { $0.time <= cutoff }) ?? stills.first {
                lastFrame = still.frame
            }
            stills.removeAll()
        }
        Log.info("Screen", value ? "source left the screen; holding the last picture" : "source is back on screen")
        onVisibilityChange?(!value, value && hiddenFullScreen)
    }

    /// After macOS stopped the capture (error -3815, the window left the
    /// active Space), start a new one once the window is visible again.
    private func restartCapture() {
        guard !restarting, Date().timeIntervalSince(lastRestart) > 1.5, let filter else { return }
        restarting = true
        lastRestart = Date()
        let window = target?.window
        Task {
            var fresh: SCStream?
            do {
                // A window's filter is rebuilt: it records where the window was.
                var useFilter = filter
                if let window {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    if let found = content.windows.first(where: { $0.windowID == window }) {
                        useFilter = SCContentFilter(desktopIndependentWindow: found)
                    }
                }
                let capture = try makeCapture(useFilter)
                fresh = capture
                try await capture.startCapture()
            } catch {
                Log.warn("Screen", "restart failed: \(error)")
                fresh = nil
            }
            queue.async { [self] in
                restarting = false
                guard let fresh else { return }
                if stopped {
                    Task { try? await fresh.stopCapture() }
                } else {
                    capture = fresh
                    Log.info("Screen", "capture restarted")
                }
            }
        }
    }

    private static func visibility(of target: Target) -> (visible: Bool, exists: Bool, fullScreen: Bool) {
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] ?? []
        if let id = target.window {
            if onScreen.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) {
                return (true, true, false)
            }
            let anywhere = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
            return (false, !anywhere.isEmpty, anywhere.first.map(fillsDisplay) ?? false)
        }
        guard let pid = target.pid else { return (true, true, false) }
        let alive = NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
        let visible = onScreen.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        return (visible, alive, false)
    }

    /// A full-screen window covers a whole display exactly.
    private static func fillsDisplay(_ info: [String: Any]) -> Bool {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayBounds($0).equalTo(bounds) }
    }

    private func keepStill(_ pixels: CVPixelBuffer, at time: CMTime) {
        guard target != nil, time - (stills.last?.time ?? .negativeInfinity) >= CMTime(value: 1, timescale: 4),
              let copy = Self.copy(pixels) else { return }
        stills.append((time, copy))
        if stills.count > 5 { stills.removeFirst() }
    }

    /// A private copy: ScreenCaptureKit's own buffers come from a small pool
    /// it recycles, and holding several of them stalls the capture.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                            CVPixelBufferGetPixelFormatType(source),
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let copy = made else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
            let fromRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toRow = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                memcpy(to + row * toRow, from + row * fromRow, min(fromRow, toRow))
            }
        }
        CVBufferPropagateAttachments(source, copy)
        return copy
    }

    public func stop() {
        pageTimer?.cancel()
        pageTimer = nil
        repeatTimer?.cancel()
        repeatTimer = nil
        visibilityTimer?.cancel()
        visibilityTimer = nil
        let capture = queue.sync { () -> SCStream? in
            stopped = true
            defer { self.capture = nil }
            return self.capture
        }
        if let capture { Task { try? await capture.stopCapture() } }
        queue.async { [writer] in
            if writer.status == .writing { writer.cancelWriting() }
        }
        server?.stop()
        server = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Log.info("Screen", "stopped")
    }

    // MARK: - Writing (on `queue`)

    private func append(_ pixels: CVPixelBuffer, at hostTime: CMTime) {
        guard writer.status == .writing else { return }
        if origin == nil {
            origin = hostTime
            writer.startSession(atSourceTime: .zero)
        }
        guard let origin else { return }
        let time = hostTime - origin
        guard time > lastVideoTime, videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixels, withPresentationTime: time) {
            lastVideoTime = time
        } else {
            Log.warn("Screen", "frame append failed: \(writer.error.map { "\($0)" } ?? "?")")
        }
    }

    private func repeatLastFrame() {
        guard let lastFrame else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // Only fill gaps; a moving screen supplies its own frames.
        if let origin, now - origin - lastVideoTime < CMTime(value: 1, timescale: 15) { return }
        append(lastFrame, at: now)
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard let audioInput, let origin, writer.status == .writing,
              audioInput.isReadyForMoreMediaData,
              let shifted = Self.retime(sample, by: origin) else { return }
        let start = CMSampleBufferGetPresentationTimeStamp(shifted)
        // Anything overlapping silence already written is dropped; audio
        // timestamps must only move forward.
        guard start >= audioEnd - CMTime(value: 1, timescale: 1000) else { return }
        if audioInput.append(shifted) {
            audioEnd = start + CMSampleBufferGetDuration(shifted)
        } else if !audioRejected {
            // Silence keeps the stream going regardless, just without sound.
            audioRejected = true
            Log.warn("Screen", "audio append failed: \(writer.error.map { "\($0)" } ?? "?")")
        }
    }

    /// ScreenCaptureKit delivers no audio while the Mac is silent, and the
    /// writer will not cut a single segment until every track has data for
    /// it — so a quiet Mac would never start streaming. Pad gaps with silence.
    private func fillSilence() {
        guard let audioInput, let origin, writer.status == .writing,
              audioInput.isReadyForMoreMediaData,
              let format = Self.defaultAudioFormat else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()) - origin
        // Leave real audio, which arrives a little late, room to land first.
        let until = now - CMTime(value: 1, timescale: 10)
        guard until - audioEnd > CMTime(value: 1, timescale: 4) else { return }
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 48_000
        let frames = Int((until - audioEnd).seconds * rate)
        guard frames > 0, let silence = Self.silence(frames: frames, at: audioEnd, format: format),
              audioInput.append(silence) else { return }
        audioEnd = audioEnd + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
    }

    /// What ScreenCaptureKit delivers: 48 kHz stereo float, one plane per channel.
    private static let defaultAudioFormat: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        return format
    }()

    private static func silence(frames: Int, at time: CMTime,
                                format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = frames * Int(asbd.mBytesPerFrame) * (planar ? Int(asbd.mChannelsPerFrame) : 1)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
                                                             formatDescription: format, sampleCount: frames,
                                                             presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    private static func retime(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            timing[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &out)
        return out
    }

    // MARK: - Serving

    private func respond(to path: String) -> (data: Data, contentType: String)? {
        lock.lock(); defer { lock.unlock() }
        switch path {
        case "/live.m3u8":
            guard initSegment != nil, !segments.isEmpty else { return nil }
            return (Data(playlist().utf8), "application/vnd.apple.mpegurl")
        case "/init.mp4":
            return initSegment.map { ($0, "video/mp4") }
        default:
            guard path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
                  let n = Int(path.dropFirst(4).dropLast(4)),
                  let segment = segments.first(where: { $0.sequence == n }) else { return nil }
            return (segment.data, "video/iso.segment")
        }
    }

    /// Lists only the newest few segments, so the player has nowhere to
    /// start but near the live edge.
    ///
    /// HOLD-BACK and EXT-X-START ask the player to sit 1.5 s from the end
    /// rather than its default of three target durations (3 s, since the
    /// target duration must be a whole number).
    private func playlist() -> String {
        let live = segments.suffix(6)
        let target = Int((live.map(\.duration).max() ?? Self.segmentSeconds).rounded(.up))
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-TARGETDURATION:\(max(target, 1))
        #EXT-X-SERVER-CONTROL:HOLD-BACK=1.5
        #EXT-X-START:TIME-OFFSET=-1.5
        #EXT-X-MEDIA-SEQUENCE:\(live.first?.sequence ?? 0)
        #EXT-X-MAP:URI="init.mp4"

        """
        for segment in live {
            text += String(format: "#EXTINF:%.3f,\n", segment.duration) + "seg\(segment.sequence).m4s\n"
        }
        return text
    }
}

// MARK: - Delegates

extension ScreenStream: SCStreamOutput, SCStreamDelegate, AVAssetWriterDelegate {

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            // Frames marked idle or blank carry no new picture.
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let pixels = CMSampleBufferGetImageBuffer(sample), !hidden else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            lastFrame = pixels
            keepStill(pixels, at: time)
            append(pixels, at: time)
        case .audio:
            appendAudio(sample)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Screen", "capture stopped: \(error)")
        queue.async { [self] in
            guard !stopped else { return }
            capture = nil
            // A window or app may only have left the active Space; wait for
            // it to come back rather than ending the cast.
            if target == nil { onStop?() } else { setHidden(true) }
        }
    }

    public func assetWriter(_ writer: AVAssetWriter,
                            didOutputSegmentData data: Data,
                            segmentType: AVAssetSegmentType,
                            segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        switch segmentType {
        case .initialization:
            initSegment = data
        case .separable:
            let duration = segmentReport?.trackReports
                .first(where: { $0.mediaType == .video })?.duration.seconds ?? Self.segmentSeconds
            segments.append((nextSequence, duration, data))
            nextSequence += 1
            // Keep a few past the playlist window for requests already in flight.
            if segments.count > 10 { segments.removeFirst(segments.count - 10) }
        @unknown default:
            break
        }
    }
}

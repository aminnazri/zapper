import Foundation
import Network
import CoreMedia

/// The UDP data path for a mirroring session: pushes encrypted RTP to the
/// receiver and speaks just enough RTCP to stay healthy.
///
/// Outbound: RTP packets (via `RtpPacketizer`) plus a periodic RTCP Sender
/// Report that ties the stream's RTP timeline to wall-clock NTP time, which the
/// receiver needs to schedule playout.
///
/// Inbound: the receiver's RTCP. Two messages matter for a live feed:
///   • Picture Loss Indicator (PLI) / a receiver that has no key frame yet —
///     we ask the encoder for a fresh key frame via `onKeyFrameRequest`.
///   • Cast Feedback NACKs — specific packets the receiver missed; we resend
///     them from a short retransmit buffer.
/// Receiver Reports and other RTCP are logged and otherwise ignored for now.
public final class MirrorTransport: @unchecked Sendable {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mirror.udp", qos: .userInteractive)
    private let videoPacketizer: RtpPacketizer
    private let senderSSRC: UInt32

    /// Called when the receiver needs a key frame (startup or loss recovery).
    /// Already rate-limited here, so the encoder can act on every call.
    public var onKeyFrameRequest: (@Sendable () -> Void)?

    // Sender Report accounting.
    private var packetsSent: UInt32 = 0
    private var octetsSent: UInt32 = 0
    private var sentAnyFrame = false
    private var reportTimer: DispatchSourceTimer?

    // Retransmit buffer, keyed by the FULL frame id. The wire only carries the
    // low 8 bits, so NACKs are expanded against the newest frame we sent —
    // keying by the low byte alone could resend a packet from a frame 256 ids
    // earlier, which the receiver discards, leaving the picture frozen.
    private struct SentFrame {
        var packets: [[UInt8]]
        var sentAt: UInt64                 // uptime ns
        var lastResend: [UInt64]           // per packet, uptime ns (0 = never)
    }
    private var sentFrames: [UInt32: SentFrame] = [:]
    private var newestFrameId: UInt32?
    private static let retainNanos: UInt64 = 1_500_000_000
    private static let resendGuardNanos: UInt64 = 30_000_000

    // Pacing. Blasting a whole frame (a 1080p key frame is 100+ packets) into
    // Wi-Fi in one go overflows the access point's queue and drops a burst of
    // packets, which then have to be NACKed and resent — visible as stutter.
    // A token bucket spreads packets out at a few times the video bitrate.
    private let pacingBytesPerNano: Double
    private let burstBytes: Double
    private var tokens: Double
    private var lastRefill: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var urgent: [[UInt8]] = []         // retransmits, sent first
    private var pending: [[UInt8]] = []
    private var pendingHead = 0
    private var drainScheduled = false

    /// Bytes queued but not yet sent; read from the capture thread.
    private let backlogLock = NSLock()
    private var backlogBytes = 0
    private let congestionBytes: Int

    // Receiver health. The Cast Feedback "checkpoint" is the last frame the
    // receiver holds along with everything before it. If it stops moving
    // while we keep sending, the receiver is stuck behind a lost frame and
    // only a key frame will get it going again.
    private var checkpoint: UInt32?
    private var checkpointMovedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var lastKeyRequest: UInt64 = 0
    private static let stallNanos: UInt64 = 250_000_000
    private static let keyRequestGapNanos: UInt64 = 250_000_000

    public init(host: String, port: Int, senderSSRC: UInt32, videoPayloadType: UInt8,
                bitRate: Int = 4_000_000) {
        self.senderSSRC = senderSSRC
        self.videoPacketizer = RtpPacketizer(payloadType: videoPayloadType, ssrc: senderSSRC)
        // 3× the video rate, clamped to 12–40 Mbps: fast enough that a key
        // frame clears in a few tens of ms, slow enough not to burst-drop.
        let pacingBits = min(max(Double(bitRate) * 3, 12_000_000), 40_000_000)
        pacingBytesPerNano = pacingBits / 8 / 1_000_000_000
        burstBytes = Double(RtpPacketizer.maxPacketSize * 8)
        tokens = burstBytes
        // Over ~120 ms of queued data we are falling behind; ScreenMirror
        // then skips capture frames until the queue drains.
        congestionBytes = Int(pacingBits / 8 * 0.12)
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!
        connection = NWConnection(host: nwHost, port: nwPort, using: params)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Log.info("Mirror", "UDP ready")
                self?.receiveLoop()
            case .failed(let e):
                Log.error("Mirror", "UDP failed: \(e)")
            default: break
            }
        }
        connection.start(queue: queue)

        // Sender Reports twice a second, standard for Cast.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.sendSenderReport() }
        timer.resume()
        reportTimer = timer
    }

    public func stop() {
        reportTimer?.cancel(); reportTimer = nil
        connection.cancel()
    }

    /// True while the send queue holds more than ~120 ms of data. New frames
    /// should be skipped (not encoded) until it clears, so latency stays bounded.
    public var isCongested: Bool {
        backlogLock.lock(); defer { backlogLock.unlock() }
        return backlogBytes > congestionBytes
    }

    // MARK: - Outbound RTP

    /// Packetizes and queues one encoded+encrypted video frame.
    public func sendVideo(_ frame: MirrorFrame) {
        let packets = videoPacketizer.packetize(frame)
        queue.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            if !sentAnyFrame { checkpointMovedAt = now }
            sentAnyFrame = true
            newestFrameId = frame.frameId
            sentFrames[frame.frameId] = SentFrame(packets: packets, sentAt: now,
                                                  lastResend: Array(repeating: 0, count: packets.count))
            sentFrames = sentFrames.filter { now &- $0.value.sentAt < Self.retainNanos }
            for packet in packets {
                packetsSent &+= 1
                octetsSent &+= UInt32(packet.count)
            }
            enqueue(packets, urgent: false)
        }
    }

    private func enqueue(_ packets: [[UInt8]], urgent isUrgent: Bool) {
        if isUrgent { urgent.append(contentsOf: packets) } else { pending.append(contentsOf: packets) }
        let bytes = packets.reduce(0) { $0 + $1.count }
        backlogLock.lock(); backlogBytes += bytes; backlogLock.unlock()
        if !drainScheduled { drain() }
    }

    /// Sends as many queued packets as the token bucket allows, then
    /// schedules itself for when the next one fits.
    private func drain() {
        drainScheduled = false
        let now = DispatchTime.now().uptimeNanoseconds
        tokens = min(burstBytes, tokens + Double(now &- lastRefill) * pacingBytesPerNano)
        lastRefill = now

        var sentBytes = 0
        while true {
            let next: [UInt8]
            if let first = urgent.first {
                guard tokens >= Double(first.count) else { break }
                next = urgent.removeFirst()
            } else if pendingHead < pending.count {
                let candidate = pending[pendingHead]
                guard tokens >= Double(candidate.count) else { break }
                next = candidate
                pendingHead += 1
            } else {
                break
            }
            tokens -= Double(next.count)
            sentBytes += next.count
            sendDatagram(next)
        }
        if pendingHead > 256, pendingHead * 2 > pending.count {
            pending.removeFirst(pendingHead); pendingHead = 0
        } else if pendingHead == pending.count {
            pending.removeAll(keepingCapacity: true); pendingHead = 0
        }
        if sentBytes > 0 { backlogLock.lock(); backlogBytes -= sentBytes; backlogLock.unlock() }

        let waiting = urgent.first ?? (pendingHead < pending.count ? pending[pendingHead] : nil)
        if let waiting {
            let deficit = max(0, Double(waiting.count) - tokens)
            let waitNanos = max(250_000, Int(deficit / pacingBytesPerNano))
            drainScheduled = true
            queue.asyncAfter(deadline: .now() + .nanoseconds(waitNanos)) { [weak self] in self?.drain() }
        }
    }

    private func sendDatagram(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            if let error { Log.debug("Mirror", "udp send error: \(error)") }
        })
    }

    /// Maps an 8-bit wire frame id onto the newest full frame id at or before it.
    private func expandFrameId(_ low: UInt8) -> UInt32? {
        guard let newest = newestFrameId else { return nil }
        var candidate = (newest & ~0xff) | UInt32(low)
        if candidate > newest { candidate &-= 256 }
        return candidate
    }

    /// Asks the encoder for a key frame, at most once per `keyRequestGapNanos`
    /// — a receiver that is losing packets will ask repeatedly, and every key
    /// frame is big enough to make the loss worse if we answer each one.
    private func requestKeyFrame(_ reason: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastKeyRequest > Self.keyRequestGapNanos else { return }
        lastKeyRequest = now
        Log.info("Mirror", "key frame: \(reason)")
        onKeyFrameRequest?()
    }

    // MARK: - RTCP Sender Report

    /// Builds and sends an RTCP Sender Report for the video SSRC. Layout from
    /// openscreen `rtp_defines.h`: 4-byte common header + 24-byte SR body.
    private func sendSenderReport() {
        guard sentAnyFrame else { return }
        var p = [UInt8]()
        // Common header: V=2,P=0,RC=0 ; PT=200 (sender report) ; length in words-1.
        p.append(0x80)
        p.append(200)
        appendBE16(&p, 6)                 // (4 + 24) / 4 - 1 = 6
        appendBE32(&p, senderSSRC)

        // NTP timestamp for "now".
        let (ntpHi, ntpLo) = Self.ntpTimestamp(Date())
        appendBE32(&p, ntpHi)
        appendBE32(&p, ntpLo)

        // RTP timestamp for this same instant, straight from the host clock
        // the frames were stamped with. (Extrapolating from when the last
        // frame was *sent* made every frame look newer than it was by the
        // encode + queue time, and the TV added that to its playout delay.)
        let rtpNow = H264Encoder.rtpTimestamp(CMClockGetTime(CMClockGetHostTimeClock()))
        appendBE32(&p, rtpNow)

        appendBE32(&p, packetsSent)
        appendBE32(&p, octetsSent)
        sendDatagram(p)
    }

    /// Seconds-and-fraction since 1900-01-01, the NTP epoch.
    static func ntpTimestamp(_ date: Date) -> (UInt32, UInt32) {
        let unix = date.timeIntervalSince1970
        let ntp = unix + 2_208_988_800.0        // seconds between 1900 and 1970
        let seconds = UInt32(ntp.rounded(.down))
        let fraction = UInt32((ntp - Double(seconds)) * 4_294_967_296.0)
        return (seconds, fraction)
    }

    // MARK: - Inbound RTCP

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handleRtcp([UInt8](data)) }
            if error == nil { self.receiveLoop() }
        }
    }

    /// Minimal RTCP parse. We only act on Cast Feedback (PT=206, subtype=15,
    /// carries the 'CAST' word and NACK loss fields) and Picture Loss (PT=206,
    /// subtype=1). Both can mean "send a key frame"; NACK additionally names
    /// specific packets to resend.
    private func handleRtcp(_ bytes: [UInt8]) {
        var offset = 0
        while offset + 4 <= bytes.count {
            let rc = bytes[offset] & 0x1f          // report count / subtype
            let pt = bytes[offset + 1]
            let lengthWords = (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
            let packetLen = (lengthWords + 1) * 4
            guard offset + packetLen <= bytes.count else { break }
            let body = Array(bytes[offset..<(offset + packetLen)])
            if pt == 206 {
                if rc == 1 {                        // PictureLossIndicator
                    requestKeyFrame("receiver reported picture loss")
                } else if rc == 15 {                // Cast Feedback
                    handleCastFeedback(body)
                }
            }
            offset += packetLen
        }
    }

    /// Cast Feedback header (rtp_defines.h): receiver SSRC, sender SSRC, 'CAST',
    /// then checkpoint frame id, loss-field count, playout delay, then that many
    /// 4-byte loss fields (frame id, lost packet id, bit vector).
    private func handleCastFeedback(_ body: [UInt8]) {
        // Common header 4 + feedback header 16 = 20 before loss fields.
        guard body.count >= 20 else { return }
        noteCheckpoint(body[16])
        let lossCount = Int(body[17])               // '# Loss Fields'
        var o = 20
        var resent: [[UInt8]] = []
        var unrecoverable = false
        let now = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<lossCount {
            guard o + 4 <= body.count else { break }
            let frameLow = body[o]
            let lostPid = UInt16(body[o + 1]) << 8 | UInt16(body[o + 2])
            let bitVector = body[o + 3]
            o += 4
            guard let frameId = expandFrameId(frameLow), var frame = sentFrames[frameId] else {
                unrecoverable = true        // aged out: only a key frame helps now
                continue
            }
            var ids: [Int] = []
            if lostPid == 0xffff {
                ids = Array(frame.packets.indices)  // the whole frame
            } else {
                ids.append(Int(lostPid))
                for bit in 0..<8 where (bitVector >> bit) & 1 == 1 { ids.append(Int(lostPid) + bit + 1) }
            }
            for id in ids where id < frame.packets.count {
                // The receiver re-NACKs every few tens of ms until a packet
                // lands; don't resend one that is still in flight.
                guard now &- frame.lastResend[id] > Self.resendGuardNanos else { continue }
                frame.lastResend[id] = now
                resent.append(frame.packets[id])
            }
            sentFrames[frameId] = frame
        }
        if !resent.isEmpty {
            Log.debug("Mirror", "resending \(resent.count) NACKed packets")
            enqueue(resent, urgent: true)
        }
        if unrecoverable { requestKeyFrame("receiver lost a frame we no longer hold") }
    }

    /// Tracks the receiver's checkpoint and asks for a key frame if it has
    /// been stuck behind a missing frame for too long.
    private func noteCheckpoint(_ low: UInt8) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let full = expandFrameId(low), let newest = newestFrameId else { return }
        if checkpoint != full {
            checkpoint = full
            checkpointMovedAt = now
            return
        }
        if newest &- full > 2, now &- checkpointMovedAt > Self.stallNanos {
            requestKeyFrame("receiver stuck at frame \(full), newest \(newest)")
            checkpointMovedAt = now
        }
    }
}

import Foundation
import Network

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
    private let queue = DispatchQueue(label: "mirror.udp")
    private let videoPacketizer: RtpPacketizer
    private let senderSSRC: UInt32

    /// Called when the receiver asks for a key frame (startup or loss recovery).
    public var onKeyFrameRequest: (@Sendable () -> Void)?

    // Sender Report accounting.
    private var packetsSent: UInt32 = 0
    private var octetsSent: UInt32 = 0
    private var lastFrameRtp: UInt32 = 0
    private var lastFrameWallClock = Date()
    private var sentAnyFrame = false
    private var reportTimer: DispatchSourceTimer?

    // Retransmit buffer: recent packets keyed by (frameId low8, packetId).
    private var recent: [UInt32: [UInt8]] = [:]
    private var recentOrder: [UInt32] = []
    private let recentLimit = 800

    public init(host: String, port: Int, senderSSRC: UInt32, videoPayloadType: UInt8) {
        self.senderSSRC = senderSSRC
        self.videoPacketizer = RtpPacketizer(payloadType: videoPayloadType, ssrc: senderSSRC)
        let params = NWParameters.udp
        // Strip the IPv6 zone only when forming the endpoint host.
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

    // MARK: - Outbound RTP

    /// Packetizes and sends one encoded+encrypted video frame.
    public func sendVideo(_ frame: MirrorFrame) {
        let packets = videoPacketizer.packetize(frame)
        queue.async { [self] in
            lastFrameRtp = frame.rtpTimestamp
            lastFrameWallClock = Date()
            sentAnyFrame = true
            for (i, packet) in packets.enumerated() {
                packetsSent &+= 1
                octetsSent &+= UInt32(packet.count)
                stashForRetransmit(frameIdLow: frame.frameId & 0xff, packetId: UInt32(i), packet: packet)
                sendDatagram(packet)
            }
        }
    }

    private func sendDatagram(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            if let error { Log.debug("Mirror", "udp send error: \(error)") }
        })
    }

    private func stashForRetransmit(frameIdLow: UInt32, packetId: UInt32, packet: [UInt8]) {
        let key = (frameIdLow << 16) | (packetId & 0xffff)
        if recent[key] == nil { recentOrder.append(key) }
        recent[key] = packet
        if recentOrder.count > recentLimit {
            let drop = recentOrder.removeFirst()
            recent.removeValue(forKey: drop)
        }
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

        // RTP timestamp matching that instant, extrapolated from the last frame.
        let elapsed = Date().timeIntervalSince(lastFrameWallClock)
        let rtpNow = lastFrameRtp &+ UInt32(elapsed * 90_000)
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
                    Log.info("Mirror", "receiver requested a key frame (PLI)")
                    onKeyFrameRequest?()
                } else if rc == 15 {                // Cast Feedback
                    handleCastFeedback(body)
                }
            }
            offset += packetLen
        }
    }

    /// Cast Feedback header (rtp_defines.h): receiver SSRC, sender SSRC, 'CAST',
    /// then checkpoint frame id, loss-field count, playout delay, then that many
    /// 4-byte loss fields (within-frame id, lost packet id, bit vector).
    private func handleCastFeedback(_ body: [UInt8]) {
        // Common header 4 + feedback header 16 = 20 before loss fields.
        guard body.count >= 20 else { return }
        let lossCount = Int(body[4 + 12 + 1])       // '# Loss Fields'
        var o = 20
        var resent = 0
        for _ in 0..<lossCount {
            guard o + 4 <= body.count else { break }
            let frameIdLow = UInt32(body[o])
            let lostPid = UInt16(body[o + 1]) << 8 | UInt16(body[o + 2])
            let bitVector = body[o + 3]
            o += 4
            if lostPid == 0xffff {
                // Whole frame missing — a key frame request is the safe answer.
                onKeyFrameRequest?()
            } else {
                resent += resend(frameIdLow: frameIdLow, packetId: lostPid)
                for bit in 0..<8 where (bitVector >> bit) & 1 == 1 {
                    resent += resend(frameIdLow: frameIdLow, packetId: lostPid + UInt16(bit) + 1)
                }
            }
        }
        if resent > 0 { Log.debug("Mirror", "resent \(resent) NACKed packets") }
    }

    private func resend(frameIdLow: UInt32, packetId: UInt16) -> Int {
        let key = (frameIdLow << 16) | UInt32(packetId)
        guard let packet = recent[key] else { return 0 }
        sendDatagram(packet)
        return 1
    }
}

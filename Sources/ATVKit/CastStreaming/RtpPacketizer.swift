import Foundation

/// One already-encoded, already-encrypted frame ready to packetize.
public struct MirrorFrame: Sendable {
    public var frameId: UInt32          // monotonic, full width; low 8 bits go on the wire
    public var referencedFrameId: UInt32 // the frame this one decodes against (itself, if a key frame)
    public var rtpTimestamp: UInt32     // 90 kHz for video, sample-rate for audio
    public var isKeyFrame: Bool
    public var payload: [UInt8]         // encrypted bytes

    public init(frameId: UInt32, referencedFrameId: UInt32, rtpTimestamp: UInt32,
                isKeyFrame: Bool, payload: [UInt8]) {
        self.frameId = frameId
        self.referencedFrameId = referencedFrameId
        self.rtpTimestamp = rtpTimestamp
        self.isKeyFrame = isKeyFrame
        self.payload = payload
    }
}

/// Splits a `MirrorFrame` into Cast RTP packets.
///
/// Ported from openscreen `cast/streaming/impl/rtp_packetizer.cc`. The wire
/// format is standard 12-byte RTP followed by a 7-byte Cast header
/// (`rtp_defines.h`): key-frame bit, reference-frame-id flag, frame id, this
/// packet's id, the last packet id, and the referenced frame id. The Adaptive
/// Latency extension is intentionally omitted — the playout delay is fixed for
/// the whole session by the OFFER's `targetDelay`.
public final class RtpPacketizer: @unchecked Sendable {

    // Standard Ethernet MTU minus IPv4 (20) and UDP (8) headers.
    public static let maxPacketSize = 1500 - 20 - 8
    public static let baseHeaderSize = 19   // 12 RTP + 7 Cast
    public static let maxPayload = maxPacketSize - baseHeaderSize

    private let payloadType: UInt8   // 7 bits
    private let ssrc: UInt32
    private var sequenceNumber: UInt16

    public init(payloadType: UInt8, ssrc: UInt32) {
        self.payloadType = payloadType & 0x7f
        self.ssrc = ssrc
        // Cast senders have started the RTP sequence at a random value for years.
        self.sequenceNumber = UInt16.random(in: 0...UInt16.max)
    }

    /// The number of packets `payload.count` bytes will occupy (at least one).
    static func packetCount(for byteCount: Int) -> Int {
        max(1, (byteCount + maxPayload - 1) / maxPayload)
    }

    /// Produces the UDP datagrams for `frame`, in order.
    public func packetize(_ frame: MirrorFrame) -> [[UInt8]] {
        let total = Self.packetCount(for: frame.payload.count)
        var packets: [[UInt8]] = []
        packets.reserveCapacity(total)

        for packetId in 0..<total {
            let isLast = packetId == total - 1
            let start = packetId * Self.maxPayload
            let end = isLast ? frame.payload.count : min(start + Self.maxPayload, frame.payload.count)

            var p = [UInt8]()
            p.reserveCapacity(Self.baseHeaderSize + (end - start))

            // --- RTP header (12 bytes) ---
            p.append(0x80)                                        // V=2, no padding/ext/CC
            p.append((isLast ? 0x80 : 0) | payloadType)           // marker on last packet | PT
            appendBE16(&p, sequenceNumber)
            sequenceNumber = sequenceNumber &+ 1
            appendBE32(&p, frame.rtpTimestamp)
            appendBE32(&p, ssrc)

            // --- Cast header (7 bytes) ---
            // key-frame bit | has-reference-frame-id bit | extension count (0)
            p.append((frame.isKeyFrame ? 0x80 : 0) | 0x40)
            p.append(UInt8(frame.frameId & 0xff))
            appendBE16(&p, UInt16(packetId))
            appendBE16(&p, UInt16(total - 1))
            p.append(UInt8(frame.referencedFrameId & 0xff))

            // --- payload chunk ---
            if end > start { p.append(contentsOf: frame.payload[start..<end]) }
            packets.append(p)
        }
        return packets
    }
}

@inline(__always) func appendBE16(_ buf: inout [UInt8], _ v: UInt16) {
    buf.append(UInt8((v >> 8) & 0xff)); buf.append(UInt8(v & 0xff))
}

@inline(__always) func appendBE32(_ buf: inout [UInt8], _ v: UInt32) {
    buf.append(UInt8((v >> 24) & 0xff)); buf.append(UInt8((v >> 16) & 0xff))
    buf.append(UInt8((v >> 8) & 0xff));  buf.append(UInt8(v & 0xff))
}

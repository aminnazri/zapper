import Foundation

/// Builds the mirroring OFFER and parses the receiver's ANSWER, on the
/// `urn:x-cast:com.google.cast.webrtc` namespace.
///
/// Field names and shape are taken from the Cast V2 Mirroring Control Protocol
/// as implemented in openscreen (`offer_messages`, `answer_messages`) and
/// cross-checked against OwnTone's hardware-tested sender. The sender proposes
/// one or more `supportedStreams`; the receiver answers with a `udpPort`, the
/// `sendIndexes` of the streams it accepted, and its own `ssrcs` for RTCP.
public enum MirrorCodec: String, Sendable {
    case h264, vp8, opus, aac
}

/// Cast Streaming RTP payload types. AndroidTV receivers (the Mi TV included)
/// require audio=127 and video=96 regardless of codec — the documented
/// "AndroidTV hack" in openscreen's `rtp_defines.h`.
public enum CastPayloadType {
    public static let audioAndroidTV: UInt8 = 127
    public static let videoAndroidTV: UInt8 = 96
}

public struct MirrorStreamConfig: Sendable {
    public enum Kind: String, Sendable { case audio = "audio_source", video = "video_source" }

    public var index: Int
    public var kind: Kind
    public var codec: MirrorCodec
    public var payloadType: UInt8
    public var ssrc: UInt32
    public var crypto: FrameCrypto
    public var targetDelayMs: Int

    // Video
    public var width: Int
    public var height: Int
    public var maxFrameRate: String   // e.g. "30000/1000"
    public var maxBitRate: Int

    // Audio
    public var sampleRate: Int
    public var channels: Int
    public var bitRate: Int

    public static func video(index: Int, ssrc: UInt32, crypto: FrameCrypto,
                             width: Int, height: Int, fps: Int = 30,
                             maxBitRate: Int = 8_000_000, targetDelayMs: Int = 200) -> MirrorStreamConfig {
        MirrorStreamConfig(index: index, kind: .video, codec: .h264,
                           payloadType: CastPayloadType.videoAndroidTV, ssrc: ssrc, crypto: crypto,
                           targetDelayMs: targetDelayMs, width: width, height: height,
                           maxFrameRate: "\(fps)000/1000", maxBitRate: maxBitRate,
                           sampleRate: 0, channels: 0, bitRate: 0)
    }

    public static func audio(index: Int, ssrc: UInt32, crypto: FrameCrypto,
                             sampleRate: Int = 48_000, channels: Int = 2,
                             bitRate: Int = 128_000, targetDelayMs: Int = 400) -> MirrorStreamConfig {
        MirrorStreamConfig(index: index, kind: .audio, codec: .opus,
                           payloadType: CastPayloadType.audioAndroidTV, ssrc: ssrc, crypto: crypto,
                           targetDelayMs: targetDelayMs, width: 0, height: 0,
                           maxFrameRate: "", maxBitRate: 0,
                           sampleRate: sampleRate, channels: channels, bitRate: bitRate)
    }

    func json() -> [String: Any] {
        var s: [String: Any] = [
            "index": index,
            "type": kind.rawValue,
            "codecName": codec.rawValue,
            "rtpProfile": "cast",
            "rtpPayloadType": Int(payloadType),
            "ssrc": Int(ssrc),
            "targetDelay": targetDelayMs,
            "aesKey": crypto.keyHex,
            "aesIvMask": crypto.ivMaskHex,
            "receiverRtcpEventLog": false,
        ]
        switch kind {
        case .video:
            s["timeBase"] = "1/90000"
            s["maxFrameRate"] = maxFrameRate
            s["maxBitRate"] = maxBitRate
            s["renderMode"] = "video"
            s["resolutions"] = [["width": width, "height": height]]
        case .audio:
            s["timeBase"] = "1/\(sampleRate)"
            s["sampleRate"] = sampleRate
            s["channels"] = channels
            s["bitRate"] = bitRate
        }
        return s
    }
}

public enum MirrorOffer {
    /// The JSON string for an OFFER carrying `streams`, with sequence `seqNum`.
    public static func offerJSON(seqNum: Int, streams: [MirrorStreamConfig]) -> String {
        let body: [String: Any] = [
            "type": "OFFER",
            "seqNum": seqNum,
            "offer": [
                "castMode": "mirroring",
                "supportedStreams": streams.map { $0.json() },
            ],
        ]
        return json(body)
    }

    public struct Answer: Sendable {
        public var udpPort: Int
        public var sendIndexes: [Int]
        public var ssrcs: [UInt32]   // the receiver's SSRCs, in the same order as sendIndexes
    }

    /// Parses an ANSWER payload. Returns nil if it isn't an "ok" ANSWER.
    public static func parseAnswer(_ payload: String) -> Answer? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              (obj["type"] as? String) == "ANSWER",
              (obj["result"] as? String) == "ok",
              let answer = obj["answer"] as? [String: Any],
              let port = answer["udpPort"] as? Int
        else { return nil }
        let indexes = (answer["sendIndexes"] as? [Int]) ?? []
        let ssrcs = (answer["ssrcs"] as? [Int])?.map { UInt32(truncatingIfNeeded: $0) } ?? []
        return Answer(udpPort: port, sendIndexes: indexes, ssrcs: ssrcs)
    }

    /// Extracts an error description from an ANSWER that failed.
    public static func parseError(_ payload: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else { return nil }
        if (obj["result"] as? String) == "error" {
            let err = obj["error"] as? [String: Any]
            let desc = err?["description"] as? String ?? ""
            let code = err?["code"].map { "\($0)" } ?? "?"
            return "receiver error \(code): \(desc)"
        }
        return nil
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

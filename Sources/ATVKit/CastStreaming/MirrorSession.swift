import Foundation

/// Negotiates a Cast Streaming (mirroring) session over the control channel.
///
/// Sequence (all on the port-8009 TLS `CastChannel`):
///   CONNECT   -> receiver-0
///   LAUNCH    -> the mirroring receiver app
///   poll GET_STATUS until it reports the app's transportId
///   CONNECT   -> transportId
///   OFFER     -> webrtc namespace, listing the streams we can send
///   wait for ANSWER with udpPort + sendIndexes + receiver ssrcs
///
/// After this, `MirrorTransport` opens the UDP data path to `host:udpPort` and
/// pushes encrypted RTP. This type only does the handshake, so it can be tested
/// against real hardware before the encoder exists.
public final class MirrorSession: @unchecked Sendable {

    /// Mirroring receiver app ids, newest first. Not every firmware runs both;
    /// we launch the first that succeeds.
    public static let appIds = ["85CDB22F", "0F5096E8"]

    static let webrtcNamespace = "urn:x-cast:com.google.cast.webrtc"

    public struct Negotiated: Sendable {
        public var host: String
        public var transportId: String
        public var appId: String
        public var answer: MirrorOffer.Answer
        public var streams: [MirrorStreamConfig]
    }

    private let channel: CastChannel
    private let senderId = "sender-0"
    private var requestId = 1
    private var seqNum = Int.random(in: 1...100_000)
    public let host: String
    private var appSessionId: String?

    private init(channel: CastChannel, host: String) {
        self.channel = channel
        self.host = host
    }

    public static func connect(host: String) async throws -> MirrorSession {
        let channel = try await CastChannel.connect(host: host)
        let session = MirrorSession(channel: channel, host: host)
        try await session.send(namespace: CastChannel.Namespace.connection,
                               payload: #"{"type":"CONNECT"}"#, destination: "receiver-0")
        return session
    }

    private func send(namespace: String, payload: String, destination: String) async throws {
        try await channel.send(namespace: namespace, payload: payload,
                               source: senderId, destination: destination)
    }

    private func nextRequestId() -> Int { requestId += 1; return requestId }

    /// Launches a mirroring receiver and returns its transportId. Tries each
    /// app id in turn.
    private func launchMirrorApp(timeout: TimeInterval = 20) async throws -> (transport: String, appId: String) {
        for appId in Self.appIds {
            Log.info("Mirror", "launching app \(appId)")
            try await send(namespace: CastChannel.Namespace.receiver,
                           payload: #"{"type":"LAUNCH","appId":"\#(appId)","requestId":\#(nextRequestId())}"#,
                           destination: "receiver-0")
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let message = try? await channel.receive(timeout: 2, matching: {
                    $0.namespace == CastChannel.Namespace.receiver
                }) {
                    if message.payload.contains("LAUNCH_ERROR") || message.payload.contains("NOT_FOUND") {
                        Log.warn("Mirror", "app \(appId) refused: \(message.payload.prefix(160))")
                        break   // try the next app id
                    }
                    if let transport = CastSession.transportId(in: message.payload),
                       Self.appRunning(appId, in: message.payload) {
                        appSessionId = CastSession.string("sessionId", in: message.payload)
                        try await send(namespace: CastChannel.Namespace.connection,
                                       payload: #"{"type":"CONNECT"}"#, destination: transport)
                        Log.info("Mirror", "app \(appId) ready, transport \(transport)")
                        return (transport, appId)
                    }
                }
                try? await send(namespace: CastChannel.Namespace.receiver,
                                payload: #"{"type":"GET_STATUS","requestId":\#(nextRequestId())}"#,
                                destination: "receiver-0")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw ATVError.pairingFailed("no mirroring receiver app would launch (tried \(Self.appIds.joined(separator: ", ")))")
    }

    /// Confirms the RECEIVER_STATUS actually lists `appId` as running, so we do
    /// not latch onto a stale transportId from a previous app.
    private static func appRunning(_ appId: String, in payload: String) -> Bool {
        payload.contains("\"appId\":\"\(appId)\"")
    }

    /// Runs the full handshake for `streams` and returns the receiver's answer.
    public func negotiate(streams: [MirrorStreamConfig], timeout: TimeInterval = 10) async throws -> Negotiated {
        let (transport, appId) = try await launchMirrorApp()

        let seq = seqNum; seqNum += 1
        let offer = MirrorOffer.offerJSON(seqNum: seq, streams: streams)
        Log.info("Mirror", "OFFER seq \(seq): \(offer.prefix(400))")
        try await send(namespace: Self.webrtcNamespace, payload: offer, destination: transport)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let reply = try? await channel.receive(timeout: 2, matching: {
                $0.namespace == Self.webrtcNamespace
            }) else { continue }
            if let answer = MirrorOffer.parseAnswer(reply.payload) {
                Log.info("Mirror", "ANSWER udpPort \(answer.udpPort) sendIndexes \(answer.sendIndexes) ssrcs \(answer.ssrcs)")
                return Negotiated(host: host, transportId: transport, appId: appId,
                                  answer: answer, streams: streams)
            }
            if let error = MirrorOffer.parseError(reply.payload) {
                throw ATVError.pairingFailed(error)
            }
        }
        throw ATVError.pairingFailed("receiver never answered the mirroring OFFER")
    }

    /// Generates a sender SSRC in the Cast range for the given stream kind.
    public static func randomSSRC(video: Bool) -> UInt32 {
        video ? UInt32.random(in: 500_001...1_000_000) : UInt32.random(in: 1...500_000)
    }

    public var isClosed: Bool { channel.isClosed }

    public func close() async {
        if let app = appSessionId {
            try? await send(namespace: CastChannel.Namespace.receiver,
                            payload: #"{"type":"STOP","sessionId":"\#(app)","requestId":\#(nextRequestId())}"#,
                            destination: "receiver-0")
        }
        channel.close()
    }

    /// The live control channel, so the transport can send RTCP-over-channel if
    /// needed and keep the virtual connection alive.
    var controlChannel: CastChannel { channel }
}

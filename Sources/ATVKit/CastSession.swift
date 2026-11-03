import Foundation

/// Casts a local file to a Google Cast receiver.
///
/// Sequence:
///   CONNECT  -> receiver-0
///   LAUNCH   -> appId CC1AD845 (the Default Media Receiver, same app the
///               decompiled Android app uses)
///   wait for RECEIVER_STATUS carrying the app's transportId
///   CONNECT  -> transportId
///   LOAD     -> media namespace, pointing at our local HTTP server
public final class CastSession: @unchecked Sendable {

    /// What the receiver reports about the loaded media.
    public struct Playback: Sendable, Equatable {
        public enum State: String, Sendable {
            case idle = "IDLE", playing = "PLAYING", paused = "PAUSED", buffering = "BUFFERING"
        }
        public var state: State
        public var position: Double
        public var duration: Double?
        /// Set when the receiver went idle: FINISHED, CANCELLED, INTERRUPTED or ERROR.
        public var idleReason: String?
        /// Live streams only: the latest point the player will seek to, in
        /// its own timeline (which does not start where the stream did).
        public var liveEnd: Double?
    }

    private let channel: CastChannel
    private var server: MediaServer?
    private var requestId = 1
    private var transportId: String?
    /// The receiver app's session, needed to close it from here.
    private var appSessionId: String?
    /// Every media command after LOAD must name this, or the receiver answers
    /// INVALID_REQUEST and does nothing.
    private var mediaSessionId: Int?
    public let host: String

    public var isClosed: Bool { channel.isClosed }

    private init(channel: CastChannel, host: String) {
        self.channel = channel
        self.host = host
    }

    public static func open(host: String) async throws -> CastSession {
        let channel = try await CastChannel.connect(host: host)
        let session = CastSession(channel: channel, host: host)
        try await session.connectTo("receiver-0")
        return session
    }

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func connectTo(_ destination: String) async throws {
        try await channel.send(namespace: CastChannel.Namespace.connection,
                               payload: #"{"type":"CONNECT"}"#,
                               destination: destination)
    }

    /// Launches the default media receiver and returns its transport id.
    ///
    /// The receiver acknowledges the launch immediately but only lists the
    /// running app in a later `RECEIVER_STATUS`, so poll `GET_STATUS` rather
    /// than waiting passively for one to arrive.
    @discardableResult
    public func launchDefaultReceiver(timeout: TimeInterval = 25) async throws -> String {
        try await channel.send(
            namespace: CastChannel.Namespace.receiver,
            payload: #"{"type":"LAUNCH","appId":"CC1AD845","requestId":\#(nextRequestId())}"#)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let message = try? await channel.receive(timeout: 2, matching: {
                $0.namespace == CastChannel.Namespace.receiver
            }) {
                if let transport = CastSession.transportId(in: message.payload) {
                    transportId = transport
                    appSessionId = CastSession.string("sessionId", in: message.payload)
                    try await connectTo(transport)
                    Log.info("Cast", "receiver ready, transport \(transport)")
                    return transport
                }
                if message.payload.contains("LAUNCH_ERROR") {
                    throw ATVError.pairingFailed("receiver refused the launch: \(message.payload.prefix(200))")
                }
            }
            // Nudge it for a fresh status. The sleep matters: without it this
            // loop spins as fast as queued messages arrive and floods the
            // receiver with thousands of GET_STATUS requests.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? await channel.send(
                namespace: CastChannel.Namespace.receiver,
                payload: #"{"type":"GET_STATUS","requestId":\#(nextRequestId())}"#)
        }
        throw ATVError.pairingFailed("receiver never reported a running app (transportId)")
    }

    /// Serves `file` over HTTP and tells the receiver to play it.
    ///
    /// Requires the receiver to be able to reach *this* Mac. On networks with
    /// AP/client isolation that direction is blocked — use `load(url:)` with an
    /// internet-hosted stream instead, which the TV fetches directly.
    public func load(file: URL, title: String? = nil) async throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ATVError.notImplemented("file not found: \(file.path)")
        }
        let server = try MediaServer(file: file)
        self.server?.stop()
        self.server = server
        let useIPv6 = host.contains(":")
        guard let url = server.url(preferIPv6: useIPv6) else {
            throw ATVError.notImplemented("no local address to serve from")
        }
        try await load(url: url,
                       contentType: MediaServer.mimeType(for: file),
                       kind: MediaServer.mediaKind(for: file),
                       title: title ?? file.lastPathComponent)
    }

    /// Plays a stream the receiver fetches itself.
    ///
    /// This is the robust option: nothing has to reach back to this Mac, so it
    /// works even where local file serving is blocked.
    public func load(url: String,
                     contentType: String? = nil,
                     kind: String? = nil,
                     title: String? = nil,
                     fragmentedHLS: Bool = false) async throws {
        var transport: String
        if let existing = transportId {
            transport = existing
        } else {
            transport = try await launchDefaultReceiver()
        }

        let type = contentType ?? CastSession.guessContentType(url)
        let mediaKind = kind ?? (type.hasPrefix("image/") ? "PHOTO"
                                 : type.hasPrefix("audio/") ? "MUSIC_TRACK" : "MOVIE")
        let isPhoto = mediaKind == "PHOTO"
        let streamType = isPhoto ? "NONE" : (type.contains("mpegurl") ? "LIVE" : "BUFFERED")
        let metadataType = isPhoto ? 4 : mediaKind == "MUSIC_TRACK" ? 3 : 0
        let name = title ?? (URL(string: url)?.lastPathComponent ?? "Stream")

        // Serialized rather than interpolated: a file name with a quote in it
        // would otherwise produce invalid JSON that the receiver drops silently.
        var media: [String: Any] = [
            "contentId": url, "streamType": streamType, "contentType": type,
            "metadata": ["metadataType": metadataType, "title": name],
        ]
        if fragmentedHLS {
            // Without these the receiver assumes MPEG-TS segments and fails
            // to parse fragmented MP4 ones.
            media["hlsSegmentFormat"] = "fmp4"
            media["hlsVideoSegmentFormat"] = "fmp4"
        }
        let payload = CastSession.json([
            "type": "LOAD", "requestId": nextRequestId(), "autoplay": true,
            "media": media,
        ])
        mediaSessionId = nil
        Log.info("Cast", "LOAD \(url)")
        try await channel.send(namespace: CastChannel.Namespace.media,
                               payload: payload,
                               destination: transport)

        if let reply = try? await channel.receive(timeout: 15, matching: {
            $0.namespace == CastChannel.Namespace.media
        }) {
            let parsed = CastSession.playback(in: reply.payload)
            if reply.payload.contains("LOAD_FAILED") || reply.payload.contains("INVALID_REQUEST")
                || parsed?.playback.idleReason == "ERROR" {
                Log.error("Cast", "load rejected: \(reply.payload)")
                throw ATVError.pairingFailed("receiver rejected the media")
            }
            mediaSessionId = parsed?.sessionId
            Log.info("Cast", "load acknowledged, media session \(mediaSessionId.map(String.init) ?? "?")")
        } else {
            Log.warn("Cast", "no media ack within 15s")
        }
    }

    /// Playback controls, once something is loaded.
    public func play() async throws  { try await mediaCommand(["type": "PLAY"]) }
    public func pause() async throws { try await mediaCommand(["type": "PAUSE"]) }
    public func seek(to seconds: Double) async throws {
        try await mediaCommand(["type": "SEEK", "currentTime": max(0, seconds)])
    }

    private func mediaCommand(_ fields: [String: Any]) async throws {
        guard let transport = transportId, !channel.isClosed else { throw ATVError.connectionClosed }
        if mediaSessionId == nil { _ = try await status() }
        guard let media = mediaSessionId else { throw ATVError.connectionClosed }
        var message = fields
        message["requestId"] = nextRequestId()
        message["mediaSessionId"] = media
        try await channel.send(namespace: CastChannel.Namespace.media,
                               payload: CastSession.json(message),
                               destination: transport)
    }

    /// Asks the receiver where playback stands. Nil when it has no media
    /// loaded any more — someone pressed Home on the TV, or a photo was replaced.
    ///
    /// Must not run concurrently with `load`, which reads the same channel.
    public func status() async throws -> Playback? {
        guard let transport = transportId else { throw ATVError.connectionClosed }
        try await channel.send(namespace: CastChannel.Namespace.media,
                               payload: #"{"type":"GET_STATUS","requestId":\#(nextRequestId())}"#,
                               destination: transport)
        let isMedia: (CastChannel.Message) -> Bool = {
            $0.namespace == CastChannel.Namespace.media && $0.payload.contains("MEDIA_STATUS")
        }
        var latest = try await channel.receive(timeout: 3, matching: isMedia)
        // Unsolicited broadcasts queue up between polls; only the newest counts.
        while let newer = try? await channel.receive(timeout: 0.05, matching: isMedia) {
            latest = newer
        }
        guard let parsed = CastSession.playback(in: latest.payload) else {
            mediaSessionId = nil
            return nil
        }
        mediaSessionId = parsed.sessionId
        return parsed.playback
    }

    static func guessContentType(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "application/x-mpegurl" }
        if lower.contains(".mpd")  { return "application/dash+xml" }
        if lower.contains(".webm") { return "video/webm" }
        if lower.contains(".mp3")  { return "audio/mpeg" }
        if lower.contains(".jpg") || lower.contains(".jpeg") { return "image/jpeg" }
        if lower.contains(".png")  { return "image/png" }
        return "video/mp4"
    }

    /// Stops playback and closes the receiver app, so the TV goes back to
    /// what it was showing before.
    public func stop() async {
        if let transport = transportId, let media = mediaSessionId {
            try? await channel.send(namespace: CastChannel.Namespace.media,
                                    payload: #"{"type":"STOP","mediaSessionId":\#(media),"requestId":\#(nextRequestId())}"#,
                                    destination: transport)
        }
        if let app = appSessionId {
            try? await channel.send(namespace: CastChannel.Namespace.receiver,
                                    payload: #"{"type":"STOP","sessionId":"\#(app)","requestId":\#(nextRequestId())}"#)
        }
        close()
    }

    /// Lets go without touching what the TV is playing — used when a new cast
    /// replaces this one and will relaunch the receiver anyway.
    public func close() {
        server?.stop()
        server = nil
        channel.close()
    }

    /// Keeps the HTTP server alive while playback continues.
    public func waitWhilePlaying(seconds: Int) async {
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Payload parsing

    /// Pulls "transportId":"…" out of a RECEIVER_STATUS payload without a JSON
    /// model — the rest of the status is not needed.
    static func transportId(in payload: String) -> String? {
        string("transportId", in: payload)
    }

    static func string(_ key: String, in payload: String) -> String? {
        guard let range = payload.range(of: "\"\(key)\":\"") else { return nil }
        let rest = payload[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// Reads the first entry of a MEDIA_STATUS. Nil when the list is empty,
    /// which is how the receiver says nothing is loaded.
    static func playback(in payload: String) -> (sessionId: Int, playback: Playback)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let entry = (object["status"] as? [[String: Any]])?.first,
              let session = entry["mediaSessionId"] as? Int
        else { return nil }
        let state = Playback.State(rawValue: entry["playerState"] as? String ?? "") ?? .idle
        let media = entry["media"] as? [String: Any]
        return (session, Playback(state: state,
                                  position: entry["currentTime"] as? Double ?? 0,
                                  duration: (media?["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil },
                                  idleReason: entry["idleReason"] as? String,
                                  liveEnd: (entry["liveSeekableRange"] as? [String: Any])?["end"] as? Double))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

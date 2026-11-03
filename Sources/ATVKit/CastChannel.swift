import Foundation
import Network
import Security

/// Google Cast v2 transport, port 8009.
///
/// Deliberately separate from `Channel`: Cast frames messages with a 4-byte
/// big-endian length prefix (not a varint), needs no client certificate, and
/// carries JSON inside a protobuf envelope rather than typed protobufs.
///
/// CastMessage schema:
///   1 protocol_version (0 = CASTV2_1_0)
///   2 source_id        3 destination_id
///   4 namespace        5 payload_type (0 = STRING)
///   6 payload_utf8     7 payload_binary
public final class CastChannel: @unchecked Sendable {

    public static let port: UInt16 = 8009

    public enum Namespace {
        public static let connection = "urn:x-cast:com.google.cast.tp.connection"
        public static let heartbeat  = "urn:x-cast:com.google.cast.tp.heartbeat"
        public static let receiver   = "urn:x-cast:com.google.cast.receiver"
        public static let media      = "urn:x-cast:com.google.cast.media"
    }

    public struct Message {
        public let source: String
        public let destination: String
        public let namespace: String
        public let payload: String
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cast.channel")
    private var buffer = Data()
    private var pending: [Message] = []
    private var waiter: CheckedContinuation<Message, Error>?
    private let lock = NSLock()
    private var closed = false

    /// True once the receiver hung up or `close()` was called.
    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private init(connection: NWConnection) {
        self.connection = connection
    }

    // MARK: - Connect

    public static func connect(host: String,
                               timeout: TimeInterval = 6) async throws -> CastChannel {
        Log.debug("Cast", "connecting \(host):\(port)")

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        // Cast receivers present a device certificate signed by Google's own
        // chain, which the system store does not carry. Senders are expected to
        // accept it; there is no client certificate at all.
        sec_protocol_options_set_verify_block(sec, { _, _, complete in
            complete(true)
        }, DispatchQueue(label: "cast.verify"))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls, tcp: tcp))
        let queue = DispatchQueue(label: "cast.connect")

        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let resumed = LockedBox(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.swap(true) == false { k.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.swap(true) == false { k.resume(throwing: error) }
                case .cancelled:
                    if resumed.swap(true) == false { k.resume(throwing: ATVError.timeout) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.swap(true) == false {
                    connection.cancel()
                    k.resume(throwing: ATVError.timeout)
                }
            }
        }

        Log.info("Cast", "TLS ready \(host):\(port)")
        let channel = CastChannel(connection: connection)
        channel.pump()
        return channel
    }

    // MARK: - Send

    /// Last player state logged, so the once-a-second MEDIA_STATUS replies
    /// are logged only when something changes. Guarded by `lock`.
    private var loggedPlayerState: String?

    private func shouldLog(_ payload: String) -> Bool {
        guard payload.contains("\"MEDIA_STATUS\""),
              let range = payload.range(of: #""playerState":"[A-Z]+""#, options: .regularExpression)
        else { return !payload.contains("\"PONG\"") && !payload.contains("\"PING\"") }
        let state = String(payload[range])
        lock.lock(); defer { lock.unlock() }
        guard state != loggedPlayerState else { return false }
        loggedPlayerState = state
        return true
    }

    public func send(namespace: String,
                     payload: String,
                     source: String = "sender-0",
                     destination: String = "receiver-0") async throws {
        let body = Proto.encode { w in
            w.varint(1, 0)                       // protocol_version
            w.string(2, source)
            w.string(3, destination)
            w.string(4, namespace)
            w.varint(5, 0)                       // payload_type = STRING
            w.string(6, payload)
        }
        var framed = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(body)

        // Status polls run every second while casting; logging each one
        // rotated the log within minutes.
        if !payload.contains("\"GET_STATUS\"") {
            Log.debug("Cast", "-> \(namespace) \(payload.prefix(160))")
        }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { k.resume(throwing: error) } else { k.resume() }
            })
        }
    }

    // MARK: - Receive

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if isComplete || error != nil {
                self.fail(error ?? ATVError.connectionClosed)
                return
            }
            self.pump()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var parsed: [Message] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let body = Data(buffer[buffer.index(buffer.startIndex, offsetBy: 4)..<buffer.index(buffer.startIndex, offsetBy: total)])
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: total))

            let reader = Proto.Reader(body)
            let message = Message(source: reader.string(2) ?? "",
                                  destination: reader.string(3) ?? "",
                                  namespace: reader.string(4) ?? "",
                                  payload: reader.string(6) ?? "")
            parsed.append(message)
        }

        var deliver: (CheckedContinuation<Message, Error>, Message)?
        if let first = parsed.first, let waiting = waiter {
            waiter = nil
            pending.append(contentsOf: parsed.dropFirst())
            deliver = (waiting, first)
        } else {
            pending.append(contentsOf: parsed)
        }
        lock.unlock()

        for message in parsed where shouldLog(message.payload) {
            Log.debug("Cast", "<- \(message.namespace) \(message.payload.prefix(900))")
        }
        // Heartbeat must be answered or the receiver drops us.
        for message in parsed where message.namespace == Namespace.heartbeat
                                 && message.payload.contains("\"PING\"") {
            let source = message.source
            Task { [weak self] in
                try? await self?.send(namespace: Namespace.heartbeat,
                                      payload: #"{"type":"PONG"}"#,
                                      destination: source)
            }
        }
        if let (continuation, message) = deliver { continuation.resume(returning: message) }
    }

    private func fail(_ error: Error) {
        lock.lock()
        closed = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        Log.debug("Cast", "closed: \(error)")
        waiting?.resume(throwing: error)
    }

    /// Waits for the next message, optionally only one matching `predicate`.
    public func receive(timeout: TimeInterval = 8,
                        matching predicate: ((Message) -> Bool)? = nil) async throws -> Message {
        while true {
            if let ready = try takePending(matching: predicate) { return ready }
            let next = try await waitForMessage(timeout: timeout)
            if predicate == nil || predicate!(next) { return next }
        }
    }

    private func takePending(matching predicate: ((Message) -> Bool)?) throws -> Message? {
        lock.lock(); defer { lock.unlock() }
        if let predicate {
            if let index = pending.firstIndex(where: predicate) { return pending.remove(at: index) }
        } else if !pending.isEmpty {
            return pending.removeFirst()
        }
        if closed { throw ATVError.connectionClosed }
        return nil
    }

    private func waitForMessage(timeout: TimeInterval) async throws -> Message {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Message, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                k.resume(throwing: ATVError.connectionClosed)
                return
            }
            waiter = k
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let expired = self.waiter
                self.waiter = nil
                self.lock.unlock()
                expired?.resume(throwing: ATVError.timeout)
            }
        }
    }

    public func close() {
        lock.lock(); closed = true; lock.unlock()
        connection.cancel()
    }
}

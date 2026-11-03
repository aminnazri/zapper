import Foundation
import Network
import Security

/// A TLS connection carrying varint-length-delimited protobuf messages.
///
/// Also captures the device's certificate during the handshake — the pairing
/// secret is a hash over both peers' RSA public keys, so we need it.
public final class Channel: @unchecked Sendable {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atv.channel")
    private var framer = MessageFramer()
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    /// Identifies the parked waiter, so a receive's timeout only ever expires
    /// its own wait. Without it, the handshake's 6 s timer fired later and
    /// killed the session's long-running read, dropping every session ~6 s
    /// after it opened.
    private var waiterToken: UInt64 = 0
    private let stateLock = NSLock()
    private var closed = false

    public private(set) var serverCertificate: SecCertificate?

    private init(connection: NWConnection, serverCertificate: SecCertificate?) {
        self.connection = connection
        self.serverCertificate = serverCertificate
    }

    // MARK: - Connect

    public static func connect(host: String,
                               port: UInt16,
                               identity: SecIdentity,
                               timeout: TimeInterval = 4) async throws -> Channel {
        Log.debug("Channel", "connecting \(host):\(port) (timeout \(timeout)s)")
        ATVIdentity.unlockIfNeeded()
        let captured = CertBox()

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
               let leaf = chain.first {
                captured.value = leaf
            }
            complete(true)   // device is self-signed; see iu3.java in the app
        }, DispatchQueue(label: "atv.channel.verify"))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)

        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: params)
        let queue = DispatchQueue(label: "atv.channel.connect")

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

        Log.debug("Channel", "TLS ready \(host):\(port), peer cert: \(captured.value != nil)")
        let channel = Channel(connection: connection, serverCertificate: captured.value)
        channel.pump()
        return channel
    }

    // MARK: - I/O

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let messages = self.framer.append(data)
                self.stateLock.lock()
                if let waiter = self.waiter, let first = messages.first {
                    self.waiter = nil
                    self.pending.append(contentsOf: messages.dropFirst())
                    self.stateLock.unlock()
                    waiter.resume(returning: first)
                } else {
                    self.pending.append(contentsOf: messages)
                    self.stateLock.unlock()
                }
            }
            if isComplete || error != nil {
                self.fail(error ?? ATVError.connectionClosed)
                return
            }
            self.pump()
        }
    }

    private func logRecv(_ data: Data) { Log.bytes("Channel", "recv", data) }

    private func fail(_ error: Error) {
        Log.debug("Channel", "closed: \(error)")
        stateLock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        stateLock.unlock()
        waiter?.resume(throwing: error)
    }

    /// Sends one protobuf message, varint-length-prefixed.
    public func send(_ payload: Data) async throws {
        Log.bytes("Channel", "send", payload)
        let framed = MessageFramer.frame(payload)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { k.resume(throwing: error) } else { k.resume() }
            })
        }
    }

    /// Waits for the next complete message.
    public func receive(timeout: TimeInterval = 6) async throws -> Data {
        // NSLock must not be held across a suspension point, so all locking
        // happens inside these synchronous helpers.
        if let ready = try takePending() {
            Log.bytes("Channel", "recv", ready)
            return ready
        }

        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            guard let token = park(k) else { return }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expireWaiter(token)
            }
        }
    }

    private func takePending() throws -> Data? {
        stateLock.lock(); defer { stateLock.unlock() }
        if !pending.isEmpty { return pending.removeFirst() }
        if closed { throw ATVError.connectionClosed }
        return nil
    }

    /// Parks the continuation and returns its token, or nil if it was
    /// resumed straight away.
    private func park(_ continuation: CheckedContinuation<Data, Error>) -> UInt64? {
        stateLock.lock()
        // A message may have landed between takePending() and here.
        if !pending.isEmpty {
            let next = pending.removeFirst()
            stateLock.unlock()
            continuation.resume(returning: next)
            return nil
        }
        if closed {
            stateLock.unlock()
            continuation.resume(throwing: ATVError.connectionClosed)
            return nil
        }
        waiterToken &+= 1
        let token = waiterToken
        waiter = continuation
        stateLock.unlock()
        return token
    }

    private func expireWaiter(_ token: UInt64) {
        stateLock.lock()
        guard waiterToken == token, let expired = waiter else {
            stateLock.unlock()
            return
        }
        waiter = nil
        stateLock.unlock()
        expired.resume(throwing: ATVError.timeout)
    }

    public func close() {
        stateLock.lock(); closed = true; stateLock.unlock()
        connection.cancel()
    }
}

final class CertBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SecCertificate?
    var value: SecCertificate? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

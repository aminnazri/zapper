import Foundation
import Network
import Security

/// TLS parameters and connection helper for the Android TV remote protocol.
///
/// The device presents a self-signed certificate with no chain. The original
/// app accepts anything (iu3.java swallows CertificateException); we do the
/// same on first contact, then pin the DER we saw.
public enum ATVTransport {

    public static let pairingPort: UInt16 = 6467
    public static let remotePort: UInt16  = 6466

    public static func parameters(identity: SecIdentity,
                                  pinnedCert: Data? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            guard let pinnedCert else { complete(true); return }
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
                  let leaf = chain.first else { complete(false); return }
            complete((SecCertificateCopyData(leaf) as Data) == pinnedCert)
        }, DispatchQueue(label: "atv.tls.verify"))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10

        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Opens a TLS connection and returns once the handshake completes.
    /// Useful on its own as a reachability + pairing-eligibility probe.
    public static func connect(host: String,
                               port: UInt16,
                               identity: SecIdentity,
                               pinnedCert: Data? = nil,
                               timeout: TimeInterval = 4) async throws -> NWConnection {
        let params = parameters(identity: identity, pinnedCert: pinnedCert)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        let queue = DispatchQueue(label: "atv.connect")

        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let resumed = LockedBox(false)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.swap(true) == false { k.resume() }
                case .failed(let e), .waiting(let e):
                    if resumed.swap(true) == false { k.resume(throwing: e) }
                case .cancelled:
                    if resumed.swap(true) == false { k.resume(throwing: ATVError.timeout) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.swap(true) == false {
                    conn.cancel()
                    k.resume(throwing: ATVError.timeout)
                }
            }
        }
        return conn
    }
}

/// Tiny mutex box so continuations are resumed exactly once.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func swap(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = new; return old
    }
    var current: T { lock.lock(); defer { lock.unlock() }; return value }
}

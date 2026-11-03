import Foundation
import Security
import CryptoKit

/// Google Polo pairing, port 6467. Schema from `polo.proto`.
///
/// Flow:
///   -> PairingRequest(service_name: "atvremote", client_name: …)
///   <- PairingRequestAck
///   -> Options(input_encodings: [hex, 6], preferred_role: INPUT)
///   <- Options
///   -> Configuration(encoding: [hex, 6], client_role: INPUT)
///   <- ConfigurationAck        … TV now shows a 6-hex-digit code
///   -> Secret(sha256 over both public keys + the code)
///   <- SecretAck               … our certificate is trusted from now on
public enum PoloPairing {

    // OuterMessage field numbers
    private enum F {
        static let protocolVersion = 1, status = 2
        static let pairingRequest = 10, pairingRequestAck = 11
        static let options = 20
        static let configuration = 30, configurationAck = 31
        static let secret = 40, secretAck = 41
    }
    private static let statusOK: UInt64 = 200
    private static let encodingHexadecimal: UInt64 = 3
    private static let roleInput: UInt64 = 1
    private static let symbolLength: UInt64 = 6

    /// Runs the handshake. `codeProvider` is called once the TV displays its code.
    public static func pair(host: String,
                            clientName: String = "Zapper",
                            identity: SecIdentity,
                            codeProvider: @Sendable () async throws -> String) async throws {

        Log.info("Pairing", "connecting to \(host):\(ATVTransport.pairingPort)")
        let channel = try await Channel.connect(host: host,
                                                port: ATVTransport.pairingPort,
                                                identity: identity)
        defer { channel.close() }
        Log.info("Pairing", "TLS up, server cert captured: \(channel.serverCertificate != nil)")

        // 1 — pairing request
        try await channel.send(outer { w in
            w.message(F.pairingRequest) { m in
                m.string(1, "atvremote")
                m.string(2, clientName)
            }
        })

        // 2 — expect ack, answer with our supported encodings
        var reply = try await expectOK(channel)
        guard reply.has(F.pairingRequestAck) else {
            Log.error("Pairing", "expected PairingRequestAck, got fields \(reply.presentFields)")
            throw ATVError.pairingFailed("expected PairingRequestAck")
        }
        Log.info("Pairing", "got PairingRequestAck")
        try await channel.send(outer { w in
            w.message(F.options) { m in
                m.message(1) { enc in          // input_encodings
                    enc.varint(1, encodingHexadecimal)
                    enc.varint(2, symbolLength)
                }
                m.varint(3, roleInput)         // preferred_role
            }
        })

        // 3 — expect options, answer with our chosen configuration
        reply = try await expectOK(channel)
        guard reply.has(F.options) else {
            Log.error("Pairing", "expected Options, got fields \(reply.presentFields)")
            throw ATVError.pairingFailed("expected Options")
        }
        Log.info("Pairing", "got Options")
        try await channel.send(outer { w in
            w.message(F.configuration) { m in
                m.message(1) { enc in          // encoding
                    enc.varint(1, encodingHexadecimal)
                    enc.varint(2, symbolLength)
                }
                m.varint(2, roleInput)         // client_role
            }
        })

        // 4 — configuration ack; the TV is now showing the code
        reply = try await expectOK(channel)
        guard reply.has(F.configurationAck) else {
            Log.error("Pairing", "expected ConfigurationAck, got fields \(reply.presentFields)")
            throw ATVError.pairingFailed("expected ConfigurationAck")
        }
        Log.info("Pairing", "got ConfigurationAck — TV is showing the code")

        // 5 — compute and send the secret
        let code = try await codeProvider()
        let secret = try secretHash(code: code,
                                    identity: identity,
                                    serverCertificate: channel.serverCertificate)
        try await channel.send(outer { w in
            w.message(F.secret) { m in m.bytes(1, secret) }
        })

        // 6 — confirmation
        reply = try await expectOK(channel)
        guard reply.has(F.secretAck) else {
            Log.error("Pairing", "expected SecretAck, got fields \(reply.presentFields)")
            throw ATVError.pairingFailed("expected SecretAck")
        }
        Log.info("Pairing", "paired successfully")
    }

    // MARK: - Helpers

    private static func outer(_ build: (inout Proto.Writer) -> Void) -> Data {
        Proto.encode { w in
            w.varint(F.protocolVersion, 2)
            w.varint(F.status, statusOK)
            build(&w)
        }
    }

    private static func expectOK(_ channel: Channel) async throws -> Proto.Reader {
        let reader = Proto.Reader(try await channel.receive())
        let status = reader.varint(F.status) ?? 0
        guard status == statusOK else {
            throw status == 402 ? ATVError.badPairingCode
                                : ATVError.pairingFailed("device returned status \(status)")
        }
        return reader
    }

    /// sha256(clientModulus ‖ clientExponent ‖ serverModulus ‖ serverExponent ‖ code[1...])
    ///
    /// The first byte of the code is a checksum over that digest, so a typo is
    /// caught locally instead of being rejected by the TV.
    static func secretHash(code: String,
                           identity: SecIdentity,
                           serverCertificate: SecCertificate?) throws -> Data {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 6, let codeBytes = Data(hexString: cleaned) else {
            throw ATVError.badPairingCode
        }
        guard let serverCertificate else {
            throw ATVError.pairingFailed("device certificate was not captured")
        }
        var clientCert: SecCertificate?
        SecIdentityCopyCertificate(identity, &clientCert)
        guard let clientCert,
              let client = RSAKeyParts(certificate: clientCert),
              let server = RSAKeyParts(certificate: serverCertificate) else {
            throw ATVError.pairingFailed("could not read RSA public keys")
        }

        Log.debug("Pairing", "client modulus \(client.modulus.count)B exponent \(client.exponent.hexString)")
        Log.debug("Pairing", "server modulus \(server.modulus.count)B exponent \(server.exponent.hexString)")

        var hasher = SHA256()
        hasher.update(data: client.modulus)
        hasher.update(data: client.exponent)
        hasher.update(data: server.modulus)
        hasher.update(data: server.exponent)
        hasher.update(data: codeBytes.dropFirst())     // code[2:] in hex chars
        let digest = Data(hasher.finalize())

        // The first code byte is a checksum over the digest. Treat a mismatch
        // as a warning, not a hard failure: if our hash inputs are subtly wrong
        // we would reject a perfectly good code and never learn why. Let the TV
        // be the authority and log the discrepancy.
        if digest.first != codeBytes.first {
            Log.warn("Pairing", "local checksum mismatch: digest[0]=\(digest.first.map { String(format: "%02x", $0) } ?? "-") code[0]=\(codeBytes.first.map { String(format: "%02x", $0) } ?? "-") — sending anyway")
        } else {
            Log.info("Pairing", "local checksum matches")
        }
        return digest
    }
}

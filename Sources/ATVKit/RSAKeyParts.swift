import Foundation
import Security

/// Extracts the RSA modulus and exponent from a certificate, in the exact byte
/// form the Polo pairing secret hash expects.
///
/// `SecKeyCopyExternalRepresentation` returns PKCS#1 `RSAPublicKey`:
///
///     SEQUENCE { INTEGER modulus, INTEGER publicExponent }
///
/// The reference implementation hashes `bytes.fromhex(f"{modulus:X}")` and
/// `bytes.fromhex(f"0{exponent:X}")` — i.e. the integer *values*, so the DER
/// sign byte must be stripped, and the exponent is left-padded with one nibble.
public struct RSAKeyParts {
    public let modulus: Data
    public let exponent: Data

    public init?(certificate: SecCertificate) {
        guard let key = SecCertificateCopyKey(certificate),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        guard let parts = RSAKeyParts.parsePKCS1(der) else { return nil }
        self = parts
    }

    /// Minimal DER walk — two INTEGERs inside one SEQUENCE.
    static func parsePKCS1(_ der: Data) -> RSAKeyParts? {
        var index = der.startIndex

        func readLength() -> Int? {
            guard index < der.endIndex else { return nil }
            let first = der[index]; index = der.index(after: index)
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                guard index < der.endIndex else { return nil }
                value = value << 8 | Int(der[index])
                index = der.index(after: index)
            }
            return value
        }

        func readInteger() -> Data? {
            guard index < der.endIndex, der[index] == 0x02 else { return nil }
            index = der.index(after: index)
            guard let length = readLength() else { return nil }
            let end = der.index(index, offsetBy: length, limitedBy: der.endIndex) ?? der.endIndex
            var bytes = Data(der[index..<end])
            index = end
            // DER marks positive integers with a leading 0x00; the value has none.
            while bytes.first == 0x00 && bytes.count > 1 { bytes.removeFirst() }
            return bytes
        }

        guard index < der.endIndex, der[index] == 0x30 else { return nil }  // SEQUENCE
        index = der.index(after: index)
        guard readLength() != nil,
              let modulus = readInteger(),
              let exponent = readInteger() else { return nil }

        // Both values are used as their minimal big-endian representation,
        // which is exactly the DER INTEGER content with the sign byte removed.
        //
        // The reference implementation writes this as
        //   bytes.fromhex(f"{modulus:X}") and bytes.fromhex(f"0{exponent:X}")
        // which is the same thing: for the usual exponent 65537 the hex is
        // "10001" (odd length), so the leading "0" only pads it to whole bytes
        // and yields 01 00 01 — already what DER holds. Do NOT round-trip
        // through per-byte hex formatting; "%X" drops each byte's leading zero
        // and silently corrupts 01 00 01 into 01 01.
        return RSAKeyParts(modulus: modulus, exponent: exponent)
    }

    init(modulus: Data, exponent: Data) {
        self.modulus = modulus
        self.exponent = exponent
    }
}

extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex),
                  let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

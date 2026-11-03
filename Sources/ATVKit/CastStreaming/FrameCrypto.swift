import Foundation
import CommonCrypto

/// Per-frame AES-128-CTR, exactly as Cast Streaming (mirroring) defines it.
///
/// Ported from openscreen `cast/streaming/impl/frame_crypto.cc`. The cipher is
/// plain AES-128 in counter mode; what is Cast-specific is how the 16-byte
/// initial counter block (the "nonce") is built for each frame:
///
///   nonce = 16 zero bytes
///   write the frame id's low 32 bits, big-endian, at byte offset 8
///   XOR the whole 16 bytes with the per-session IV mask
///
/// The key and IV mask both come from the OFFER we send (32 hex digits each).
/// CTR is symmetric, so the receiver decrypts with the identical operation.
///
/// No external dependency: CommonCrypto ships with macOS and offers raw
/// big-endian CTR via `CCCryptorCreateWithMode`.
public struct FrameCrypto: Sendable {

    private let key: [UInt8]       // 16 bytes
    private let ivMask: [UInt8]    // 16 bytes

    public init(key: [UInt8], ivMask: [UInt8]) {
        precondition(key.count == 16 && ivMask.count == 16, "Cast AES key and IV mask are 16 bytes")
        self.key = key
        self.ivMask = ivMask
    }

    /// A fresh random key / IV mask pair for one streaming session.
    public static func random() -> FrameCrypto {
        FrameCrypto(key: randomBytes(16), ivMask: randomBytes(16))
    }

    public var keyHex: String { Self.hex(key) }
    public var ivMaskHex: String { Self.hex(ivMask) }

    /// The 16-byte initial counter block for `frameId`.
    public func nonce(frameId: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 16)
        nonce[8]  = UInt8((frameId >> 24) & 0xff)
        nonce[9]  = UInt8((frameId >> 16) & 0xff)
        nonce[10] = UInt8((frameId >> 8) & 0xff)
        nonce[11] = UInt8(frameId & 0xff)
        for i in 0..<16 { nonce[i] ^= ivMask[i] }
        return nonce
    }

    /// Encrypts (or, identically, decrypts) one frame's payload. Output is the
    /// same length as the input.
    public func crypt(frameId: UInt32, _ data: [UInt8]) -> [UInt8] {
        var iv = nonce(frameId: frameId)
        var out = [UInt8](repeating: 0, count: data.count)
        var cryptor: CCCryptorRef?

        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeMutableBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { return out }
        defer { CCCryptorRelease(cryptor) }

        if data.isEmpty { return out }
        var moved = 0
        _ = data.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        return out
    }

    // MARK: - Helpers

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func bytes(fromHex hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            out.append(b); i += 2
        }
        return out
    }
}

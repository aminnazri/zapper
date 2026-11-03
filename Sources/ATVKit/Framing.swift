import Foundation

/// Varint length-delimited framing for the protobuf message stream.
///
/// Implemented as plain buffer helpers rather than an NWProtocolFramer so the
/// same code is usable from tests and from a raw socket. Messages under 128
/// bytes encode to a single-byte prefix, so this is compatible with
/// implementations that assume a one-byte length.
public struct MessageFramer {

    private var buffer = Data()

    public init() {}

    /// Prefixes a serialized protobuf message with its varint length.
    public static func frame(_ payload: Data) -> Data {
        var out = encodeVarint(UInt64(payload.count))
        out.append(payload)
        return out
    }

    /// Feed received bytes; returns whatever complete messages are now available.
    public mutating func append(_ incoming: Data) -> [Data] {
        buffer.append(incoming)
        var messages: [Data] = []

        while true {
            guard let (length, headerSize) = Self.decodeVarint(buffer) else { break }
            let total = headerSize + Int(length)
            guard buffer.count >= total else { break }
            let start = buffer.index(buffer.startIndex, offsetBy: headerSize)
            let end = buffer.index(buffer.startIndex, offsetBy: total)
            messages.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return messages
    }

    public mutating func reset() { buffer.removeAll() }

    // MARK: - Varint

    public static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { byte |= 0x80 }
            out.append(byte)
        } while v > 0
        return out
    }

    /// Returns (value, bytesConsumed) or nil if the varint is incomplete.
    public static func decodeVarint(_ data: Data) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var count = 0
        for byte in data {
            value |= UInt64(byte & 0x7F) << shift
            count += 1
            if byte & 0x80 == 0 { return (value, count) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

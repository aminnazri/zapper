import Foundation

/// Minimal protobuf wire-format codec.
///
/// The Android TV remote protocol uses a handful of small messages, so a full
/// protobuf runtime would be disproportionate — and `protoc-gen-swift` needs
/// SwiftPM, which we deliberately do not depend on. Schema taken from
/// `polo.proto` and `remotemessage.proto`; see PROTOBUF.md.
public enum Proto {

    public enum WireType: UInt64 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    // MARK: - Encoding

    public struct Writer {
        public private(set) var data = Data()
        public init() {}

        private mutating func tag(_ field: Int, _ type: WireType) {
            data.append(MessageFramer.encodeVarint(UInt64(field) << 3 | type.rawValue))
        }

        public mutating func varint(_ field: Int, _ value: UInt64) {
            tag(field, .varint)
            data.append(MessageFramer.encodeVarint(value))
        }

        public mutating func varint(_ field: Int, _ value: Int) {
            varint(field, UInt64(value))
        }

        public mutating func bytes(_ field: Int, _ value: Data) {
            tag(field, .lengthDelimited)
            data.append(MessageFramer.encodeVarint(UInt64(value.count)))
            data.append(value)
        }

        public mutating func string(_ field: Int, _ value: String) {
            bytes(field, Data(value.utf8))
        }

        /// Nested message.
        public mutating func message(_ field: Int, _ build: (inout Writer) -> Void) {
            var inner = Writer()
            build(&inner)
            bytes(field, inner.data)
        }
    }

    public static func encode(_ build: (inout Writer) -> Void) -> Data {
        var writer = Writer()
        build(&writer)
        return writer.data
    }

    // MARK: - Decoding

    /// A parsed message: field number -> values, in encounter order.
    public struct Reader {
        public private(set) var varints: [Int: [UInt64]] = [:]
        public private(set) var blobs: [Int: [Data]] = [:]
        /// The bytes this reader was built from, for logging.
        public let raw: Data

        public init(_ data: Data) {
            raw = data
            var index = data.startIndex
            while index < data.endIndex {
                guard let (key, keyLen) = MessageFramer.decodeVarint(data[index...]) else { return }
                index = data.index(index, offsetBy: keyLen)
                let field = Int(key >> 3)
                guard let type = WireType(rawValue: key & 0x07) else { return }

                switch type {
                case .varint:
                    guard let (value, len) = MessageFramer.decodeVarint(data[index...]) else { return }
                    index = data.index(index, offsetBy: len)
                    varints[field, default: []].append(value)

                case .lengthDelimited:
                    guard let (length, len) = MessageFramer.decodeVarint(data[index...]) else { return }
                    index = data.index(index, offsetBy: len)
                    let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex)
                             ?? data.endIndex
                    blobs[field, default: []].append(Data(data[index..<end]))
                    index = end

                case .fixed64:
                    index = data.index(index, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
                case .fixed32:
                    index = data.index(index, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
                }
            }
        }

        public func has(_ field: Int) -> Bool {
            varints[field] != nil || blobs[field] != nil
        }
        public func varint(_ field: Int) -> UInt64? { varints[field]?.first }
        public func blob(_ field: Int) -> Data? { blobs[field]?.first }
        public func string(_ field: Int) -> String? {
            blob(field).map { String(decoding: $0, as: UTF8.self) }
        }
        public func message(_ field: Int) -> Reader? { blob(field).map { Reader($0) } }

        /// Field numbers actually present — useful when a reply is unexpected.
        public var presentFields: [Int] {
            Array(Set(varints.keys).union(blobs.keys)).sorted()
        }
    }
}

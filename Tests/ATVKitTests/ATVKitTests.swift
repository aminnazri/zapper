import XCTest
@testable import ATVKit

final class ATVKitTests: XCTestCase {

    func testMagicPacketShape() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(mac: "1c:9e:46:aa:bb:cc"))
        XCTAssertEqual(packet.count, 6 + 16 * 6)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(packet[6..<12]), [0x1c, 0x9e, 0x46, 0xaa, 0xbb, 0xcc])
    }

    func testMagicPacketRejectsBadMAC() {
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "not-a-mac"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "1c:9e:46:aa:bb"))
    }

    func testVarintRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_383, 16_384, 1_000_000] {
            let encoded = MessageFramer.encodeVarint(value)
            let decoded = try XCTUnwrap(MessageFramer.decodeVarint(encoded))
            XCTAssertEqual(decoded.0, value)
            XCTAssertEqual(decoded.1, encoded.count)
        }
    }

    func testSmallMessagesUseSingleByteLength() {
        // Compatibility with implementations that assume a one-byte prefix.
        XCTAssertEqual(MessageFramer.encodeVarint(64).count, 1)
        XCTAssertEqual(MessageFramer.encodeVarint(127).count, 1)
        XCTAssertEqual(MessageFramer.encodeVarint(128).count, 2)
    }

    func testFramerReassemblesSplitStream() {
        let a = Data([1, 2, 3])
        let b = Data([9, 9])
        let stream = MessageFramer.frame(a) + MessageFramer.frame(b)

        var framer = MessageFramer()
        var out: [Data] = []
        // feed one byte at a time to simulate TCP fragmentation
        for byte in stream {
            out.append(contentsOf: framer.append(Data([byte])))
        }
        XCTAssertEqual(out, [a, b])
    }

    func testARPNormalizesShortOctets() {
        XCTAssertEqual(ARP.normalize("1c:9e:46:a:b:c"), "1c:9e:46:0a:0b:0c")
    }

    func testDirectedBroadcast() {
        XCTAssertEqual(WakeOnLAN.directedBroadcast(for: "192.168.1.42"), "192.168.1.255")
        XCTAssertNil(WakeOnLAN.directedBroadcast(for: "nope"))
    }

    func testSubjectMatchesAppFormat() {
        let cn = ATVIdentity.subjectCommonName()
        XCTAssertTrue(cn.hasPrefix("atvremote/"))
        XCTAssertEqual(cn.split(separator: "/").count, 5)
    }

    // Verified against `ndp -an` output from a real Xiaomi Mi TV.
    func testMACRecoveryFromIPv6LinkLocal() {
        XCTAssertEqual(MACAddress.fromIPv6LinkLocal("fe80::b6c9:b9ff:fe80:f984%en0"),
                       "b4:c9:b9:80:f9:84")
        XCTAssertEqual(MACAddress.fromIPv6LinkLocal("fe80::b6c9:b9ff:fe80:b796%en0"),
                       "b4:c9:b9:80:b7:96")
    }

    func testMACRecoveryRejectsNonLinkLocal() {
        XCTAssertNil(MACAddress.fromIPv6LinkLocal("2001:db8::1"))
        XCTAssertNil(MACAddress.fromIPv6LinkLocal("192.168.1.1"))
        XCTAssertNil(MACAddress.fromIPv6LinkLocal("garbage"))
    }

    func testLimitedBroadcastConstant() {
        XCTAssertEqual(WakeOnLAN.limitedBroadcast, "255.255.255.255")
    }
}

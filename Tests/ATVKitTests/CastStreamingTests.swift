import XCTest
@testable import ATVKit

final class CastStreamingTests: XCTestCase {

    // Key/IV used to generate the reference ciphertext with `openssl enc
    // -aes-128-ctr`, where the IV is the Cast nonce for frame id 1.
    let key = FrameCrypto.bytes(fromHex: "000102030405060708090a0b0c0d0e0f")!
    let ivMask = FrameCrypto.bytes(fromHex: "101112131415161718191a1b1c1d1e1f")!

    func testCryptoMatchesOpenSSLVector() {
        let crypto = FrameCrypto(key: key, ivMask: ivMask)
        let plaintext = Array("The quick brown fox jumps over the lazy dog.".utf8)
        let cipher = crypto.crypt(frameId: 1, plaintext)
        XCTAssertEqual(FrameCrypto.hex(cipher),
            "beb89ec281e52606cd6a4fd47fd2feb76dca4cf165d11fcca95a98a2b59d1da89eb5384b1e7a8b64b0918870")
    }

    func testNonceConstruction() {
        let crypto = FrameCrypto(key: key, ivMask: ivMask)
        // frame id 1: zeros with BE32(1) at offset 8, XOR the IV mask.
        XCTAssertEqual(FrameCrypto.hex(crypto.nonce(frameId: 1)),
                       "101112131415161718191a1a1c1d1e1f")
    }

    func testCryptoIsSymmetric() {
        let crypto = FrameCrypto.random()
        let plaintext = Array("round trip payload \u{1F600}".utf8)
        let cipher = crypto.crypt(frameId: 42, plaintext)
        XCTAssertNotEqual(cipher, plaintext)
        XCTAssertEqual(crypto.crypt(frameId: 42, cipher), plaintext)
    }

    func testDifferentFrameIdsDiffer() {
        let crypto = FrameCrypto.random()
        let plaintext = Array(repeating: UInt8(0xAB), count: 64)
        XCTAssertNotEqual(crypto.crypt(frameId: 1, plaintext),
                          crypto.crypt(frameId: 2, plaintext))
    }

    func testHexRoundTrip() {
        let bytes = FrameCrypto.randomBytes(16)
        XCTAssertEqual(FrameCrypto.bytes(fromHex: FrameCrypto.hex(bytes)), bytes)
    }

    // MARK: - Packetizer

    func testSinglePacketHeader() {
        let pk = RtpPacketizer(payloadType: 96, ssrc: 0x00112233)
        let frame = MirrorFrame(frameId: 0x1234_0005, referencedFrameId: 0x1234_0005,
                                rtpTimestamp: 0xAABBCCDD, isKeyFrame: true, payload: [1, 2, 3, 4])
        let packets = pk.packetize(frame)
        XCTAssertEqual(packets.count, 1)
        let p = packets[0]
        XCTAssertEqual(p.count, 19 + 4)
        XCTAssertEqual(p[0], 0x80)                 // V=2
        XCTAssertEqual(p[1], 0x80 | 96)            // marker (last) | PT
        // bytes 4-7 RTP timestamp, 8-11 ssrc
        XCTAssertEqual(Array(p[4..<8]), [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertEqual(Array(p[8..<12]), [0x00, 0x11, 0x22, 0x33])
        // Cast header
        XCTAssertEqual(p[12], 0x80 | 0x40)         // key frame | has-ref-id
        XCTAssertEqual(p[13], 0x05)                // frame id low 8
        XCTAssertEqual(Array(p[14..<16]), [0x00, 0x00])   // packet id 0
        XCTAssertEqual(Array(p[16..<18]), [0x00, 0x00])   // max packet id 0
        XCTAssertEqual(p[18], 0x05)                // referenced frame id low 8
        XCTAssertEqual(Array(p[19...]), [1, 2, 3, 4])
    }

    func testMultiPacketSplitAndMarker() {
        let pk = RtpPacketizer(payloadType: 96, ssrc: 7)
        let payload = (0..<(RtpPacketizer.maxPayload + 10)).map { UInt8($0 & 0xff) }
        let frame = MirrorFrame(frameId: 9, referencedFrameId: 8, rtpTimestamp: 100,
                                isKeyFrame: false, payload: payload)
        let packets = pk.packetize(frame)
        XCTAssertEqual(packets.count, 2)
        // Only the last packet carries the marker bit.
        XCTAssertEqual(packets[0][1] & 0x80, 0)
        XCTAssertEqual(packets[1][1] & 0x80, 0x80)
        // max packet id == 1 in both
        XCTAssertEqual(Array(packets[0][16..<18]), [0x00, 0x01])
        XCTAssertEqual(Array(packets[1][16..<18]), [0x00, 0x01])
        // Delta frame: no key-frame bit, ref id low 8 == 8
        XCTAssertEqual(packets[0][12], 0x40)
        XCTAssertEqual(packets[0][18], 8)
        // Reassembled payload matches
        let body = Array(packets[0][19...]) + Array(packets[1][19...])
        XCTAssertEqual(body, payload)
    }

    func testOfferJSONShape() {
        let crypto = FrameCrypto.random()
        let video = MirrorStreamConfig.video(index: 0, ssrc: 500_123, crypto: crypto,
                                             width: 1280, height: 720)
        let json = MirrorOffer.offerJSON(seqNum: 7, streams: [video])
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "OFFER")
        XCTAssertEqual(obj["seqNum"] as? Int, 7)
        let offer = obj["offer"] as! [String: Any]
        XCTAssertEqual(offer["castMode"] as? String, "mirroring")
        let streams = offer["supportedStreams"] as! [[String: Any]]
        XCTAssertEqual(streams[0]["codecName"] as? String, "h264")
        XCTAssertEqual(streams[0]["rtpPayloadType"] as? Int, 96)
        XCTAssertEqual(streams[0]["timeBase"] as? String, "1/90000")
    }

    func testAnswerParsing() {
        let payload = #"{"type":"ANSWER","seqNum":7,"result":"ok","answer":{"udpPort":51706,"sendIndexes":[0,1],"ssrcs":[500124,124]}}"#
        let answer = MirrorOffer.parseAnswer(payload)
        XCTAssertEqual(answer?.udpPort, 51706)
        XCTAssertEqual(answer?.sendIndexes, [0, 1])
        XCTAssertEqual(answer?.ssrcs, [500124, 124])
    }

    func testAnswerErrorParsing() {
        let payload = #"{"type":"ANSWER","seqNum":7,"result":"error","error":{"code":404,"description":"no streams"}}"#
        XCTAssertNil(MirrorOffer.parseAnswer(payload))
        XCTAssertEqual(MirrorOffer.parseError(payload), "receiver error 404: no streams")
    }
}

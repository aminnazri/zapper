import Foundation
import ATVKit

// Minimal CLI so every layer is testable without Xcode.
//   zapper discover
//   zapper probe <host>
//   zapper pair <host>
//   zapper key <host> <name>
//   zapper wake <mac> [broadcast]
//   zapper identity [reset]

func usage() -> Never {
    print("""
    zapper — Google TV / Android TV control

      discover                 browse mDNS for devices (5s)
      probe <host>             TLS handshake against the pairing port (6467)
      pair <host>              pair with the device (prompts for the on-screen code)
      key <host> <name>        send one key: up down left right select back home
                               menu power volumeup volumedown mute playpause
                               hdmi1 hdmi2 hdmi3 hdmi4 source settings guide
                               search backspace enter
      applink <host> <uri>     launch an app link / intent on the device
      watch <host> [seconds]   print device state (foreground app, volume)
      type <host> <text…>      type text into the focused field on the TV
      wake <mac> [broadcast]   send a wake-on-LAN magic packet
      mirror <host> [secs] [q] real-time screen mirror; q is 540p, 720p or 1080p
      mirror-probe <host>      negotiate a Cast Streaming session and print the
                               receiver's ANSWER (no capture, safe to test)
      identity [reset]         show or regenerate the client certificate

    """)
    exit(1)
}

func command(named name: String) -> RemoteCommand? {
    switch name.lowercased() {
    case "up":          return .up
    case "down":        return .down
    case "left":        return .left
    case "right":       return .right
    case "select", "ok": return .select
    case "back":        return .back
    case "home":        return .home
    case "menu":        return .menu
    case "power":       return .power
    case "volumeup":    return .volumeUp
    case "volumedown":  return .volumeDown
    case "mute":        return .mute
    case "playpause":   return .playPause
    case "hdmi1":       return .input(1)
    case "hdmi2":       return .input(2)
    case "hdmi3":       return .input(3)
    case "hdmi4":       return .input(4)
    case "source", "input": return .input(0)
    case "settings":    return .settings
    case "guide":       return .guide
    case "search":      return .search
    case "backspace", "del": return .backspace
    case "enter":       return .enter
    default:            return nil
    }
}

Log.echoToConsole = true

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { usage() }

switch verb {

case "discover":
    print("Browsing for \(ATVDiscovery.serviceTypeV2) …")
    let devices = await AndroidTVAdapter().discover(duration: 5)
    if devices.isEmpty {
        print("No devices found. Check the box is awake and on the same network.")
    }
    for d in devices {
        print("  \(d.name)  \(d.host):\(d.port)  mac=\(d.mac ?? "unknown")")
    }

case "probe":
    guard args.count >= 2 else { usage() }
    let host = args[1]
    do {
        print("Opening TLS to \(host):\(ATVTransport.pairingPort) …")
        try await AndroidTVAdapter().probe(
            DiscoveredDevice(name: host, host: host, port: ATVTransport.pairingPort))
        print("Handshake OK — the device accepted our client certificate.")
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "pair":
    guard args.count >= 2 else { usage() }
    let host = args[1]
    do {
        print("Pairing with \(host) — a 6-character code should appear on the TV.")
        try await AndroidTVAdapter().pair(
            DiscoveredDevice(name: host, host: host, port: ATVTransport.pairingPort),
            pinProvider: {
                print("Enter the code shown on the TV: ", terminator: "")
                return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            })
        print("Paired. This Mac's certificate is now trusted by the device.")
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "key":
    guard args.count >= 3, let cmd = command(named: args[2]) else { usage() }
    let host = args[1]
    do {
        let session = try await AndroidTVAdapter().connect(Device(name: host, host: host))
        try await session.send(cmd)
        print("Sent \(args[2]).")
        await session.disconnect()
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "applink":
    guard args.count >= 3 else { usage() }
    do {
        let session = try await AndroidTVAdapter().connect(Device(name: args[1], host: args[1]))
        try await session.send(.launchApp(args[2]))
        print("Sent app link: \(args[2])")
        await session.disconnect()
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "longpress":
    guard args.count >= 3, let cmd = command(named: args[2]),
          let key = RemoteSession.keyCode(for: cmd) else { usage() }
    do {
        let session = try await AndroidTVAdapter().connect(Device(name: args[1], host: args[1]))
        if let remote = session as? RemoteSession {
            try await remote.longPress(key)
        }
        print("Long-pressed \(args[2]).")
        await session.disconnect()
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "watch":
    guard args.count >= 2 else { usage() }
    do {
        let session = try await AndroidTVAdapter().connect(Device(name: args[1], host: args[1]))
        let seconds = args.count >= 3 ? (Int(args[2]) ?? 15) : 15
        print("Watching device state for \(seconds)s — press keys on the TV remote too.")
        if let remote = session as? RemoteSession {
            for _ in 0..<seconds {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let s = await remote.deviceState
                print("  app=\(s.currentApp ?? "?") vol=\(s.volumeLevel.map(String.init) ?? "?") textField=\(s.textFieldFocused) ime=\(s.imeCounter)/\(s.imeFieldCounter)")
            }
        }
        await session.disconnect()
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "type":
    guard args.count >= 3 else { usage() }
    do {
        let session = try await AndroidTVAdapter().connect(Device(name: args[1], host: args[1]))
        let text = args[2...].joined(separator: " ")
        if let remote = session as? RemoteSession {
            let ready = await remote.waitForTextField()
            print(ready ? "TV text field ready." : "No TV text field focused — sending keycodes.")
        }
        if let remote = session as? RemoteSession, await remote.canEditText {
            // The edit carries the field's whole contents, so one is enough.
            try await session.send(.text(text))
            try await Task.sleep(nanoseconds: 1_500_000_000)   // collect the TV's reply for the log
        } else {
            for character in text {
                try await session.send(.character(character))
                try await Task.sleep(nanoseconds: 40_000_000)   // let the TV's IME keep up
            }
        }
        print("Typed \(text.count) characters.")
        await session.disconnect()
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "wake":
    guard args.count >= 2 else { usage() }
    let mac = args[1]
    let broadcast = args.count >= 3 ? args[2] : nil
    do {
        print("Waking \(mac) …")
        try await WakeOnLAN.wake(mac: mac, broadcast: broadcast)
        print("Magic packet sent.")
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "identity":
    if args.count >= 2, args[1] == "reset" {
        ATVIdentity.delete()
        print("Deleted stored identity. The TV will require re-pairing.")
    }
    do {
        _ = try ATVIdentity.loadOrCreate()
        print("Client identity ready: \(ATVIdentity.storageDescription)")
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "mirror-selftest":
    var pass = 0, fail = 0
    func check(_ name: String, _ ok: Bool) {
        print(ok ? "  ✅ \(name)" : "  ❌ \(name)")
        if ok { pass += 1 } else { fail += 1 }
    }
    // AES-128-CTR vector, cross-checked against `openssl enc -aes-128-ctr`.
    let key = FrameCrypto.bytes(fromHex: "000102030405060708090a0b0c0d0e0f")!
    let iv  = FrameCrypto.bytes(fromHex: "101112131415161718191a1b1c1d1e1f")!
    let crypto = FrameCrypto(key: key, ivMask: iv)
    let cipher = crypto.crypt(frameId: 1, Array("The quick brown fox jumps over the lazy dog.".utf8))
    check("crypto matches OpenSSL vector",
          FrameCrypto.hex(cipher) == "beb89ec281e52606cd6a4fd47fd2feb76dca4cf165d11fcca95a98a2b59d1da89eb5384b1e7a8b64b0918870")
    check("nonce construction", FrameCrypto.hex(crypto.nonce(frameId: 1)) == "101112131415161718191a1a1c1d1e1f")
    let rnd = FrameCrypto.random()
    let pt = Array("round trip".utf8)
    check("crypto is symmetric", rnd.crypt(frameId: 42, rnd.crypt(frameId: 42, pt)) == pt)
    check("frame ids differ", rnd.crypt(frameId: 1, pt) != rnd.crypt(frameId: 2, pt))
    // Packetizer single-packet header.
    let pk = RtpPacketizer(payloadType: 96, ssrc: 0x00112233)
    let one = pk.packetize(MirrorFrame(frameId: 0x1234_0005, referencedFrameId: 0x1234_0005,
                                       rtpTimestamp: 0xAABBCCDD, isKeyFrame: true, payload: [1,2,3,4]))
    check("single packet shape", one.count == 1 && one[0].count == 23 && one[0][0] == 0x80
          && one[0][1] == (0x80 | 96) && one[0][12] == (0x80 | 0x40) && one[0][13] == 0x05)
    // Multi-packet split + marker.
    let big = (0..<(RtpPacketizer.maxPayload + 10)).map { UInt8($0 & 0xff) }
    let many = pk.packetize(MirrorFrame(frameId: 9, referencedFrameId: 8, rtpTimestamp: 100,
                                        isKeyFrame: false, payload: big))
    check("multi packet split", many.count == 2 && (many[0][1] & 0x80) == 0 && (many[1][1] & 0x80) == 0x80)
    let body = Array(many[0][19...]) + Array(many[1][19...])
    check("payload reassembles", body == big)
    // Offer / answer round trip.
    let offer = MirrorOffer.offerJSON(seqNum: 7, streams: [
        MirrorStreamConfig.video(index: 0, ssrc: 500_123, crypto: crypto, width: 1280, height: 720)])
    check("offer is valid JSON OFFER", offer.contains("\"OFFER\"") && offer.contains("h264"))
    let ans = MirrorOffer.parseAnswer(#"{"type":"ANSWER","result":"ok","answer":{"udpPort":51706,"sendIndexes":[0,1],"ssrcs":[1,2]}}"#)
    check("answer parses", ans?.udpPort == 51706 && ans?.sendIndexes == [0,1])
    print("\n\(fail == 0 ? "ALL PASS" : "FAILURES") — \(pass) passed, \(fail) failed")
    if fail > 0 { exit(1) }

case "mirror":
    guard args.count >= 2 else { usage() }
    let host = args[1]
    let seconds = args.count >= 3 ? Int(args[2]) ?? 30 : 30
    let quality = args.count >= 4
        ? ScreenMirror.Quality.allCases.first { $0.label == args[3] || $0.rawValue == args[3] } ?? .balanced
        : .balanced
    do {
        if !ScreenMirror.hasPermission {
            print("Screen Recording permission is off — requesting it now …")
            ScreenMirror.requestPermission()
            print("Grant it in System Settings › Privacy & Security › Screen Recording, then re-run.")
            exit(1)
        }
        print("Starting real-time \(quality.label) mirror to \(host) for \(seconds)s …")
        let mirror = try await ScreenMirror.start(host: host, quality: quality)
        print("Mirroring. Ctrl-C to stop early.")
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        mirror.stop()
        print("Stopped.")
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

case "mirror-probe":
    guard args.count >= 2 else { usage() }
    let host = args[1]
    do {
        print("Connecting to Cast receiver \(host):8009 …")
        let session = try await MirrorSession.connect(host: host)
        let crypto = FrameCrypto.random()
        let video = MirrorStreamConfig.video(
            index: 0, ssrc: MirrorSession.randomSSRC(video: true), crypto: crypto,
            width: 1920, height: 1080, fps: 30)
        let audio = MirrorStreamConfig.audio(
            index: 1, ssrc: MirrorSession.randomSSRC(video: false), crypto: crypto)
        print("Launching mirroring app and sending OFFER (h264 + opus) …")
        let result = try await session.negotiate(streams: [video, audio])
        print("""

        ✅ Receiver ACCEPTED the mirroring session.
           app id:       \(result.appId)
           transport:    \(result.transportId)
           UDP port:     \(result.answer.udpPort)
           sendIndexes:  \(result.answer.sendIndexes)   (0=video, 1=audio)
           receiver ssrcs: \(result.answer.ssrcs)

        Next milestone wires the VideoToolbox H.264 encoder to this UDP port.
        """)
        await session.close()
    } catch {
        print("Failed: \(error)")
        Log.flush()
        exit(1)
    }

default:
    usage()
}

Log.flush()

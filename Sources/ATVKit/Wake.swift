import Foundation

/// Wake-on-LAN.
///
/// Matches the decompiled app's behaviour (op.java: DatagramSocket with
/// setBroadcast(true); vm4.java: ports [6466], 500 ms settle, 200 ms between
/// ports). The port is arbitrary — NICs match the magic byte pattern, not the
/// destination port — but we keep theirs so behaviour is identical.
public enum WakeOnLAN {

    /// 6 x 0xFF followed by the target MAC repeated 16 times.
    public static func magicPacket(mac: String) -> Data? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var bytes = [UInt8]()
        for p in parts {
            guard let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Broadcasts the magic packet on every port in the profile.
    ///
    /// Sends to *both* the directed subnet broadcast and the limited broadcast
    /// 255.255.255.255. Verified on macOS: a packet sent to 255.255.255.255 is
    /// delivered to local sockets, while one sent to the directed address
    /// (192.168.1.255) is not — so we cannot confirm the directed send
    /// actually left the machine. Some routers drop one form, some the other.
    /// Two UDP datagrams cost nothing and remove the guesswork.
    @discardableResult
    public static func wake(mac: String,
                            broadcast: String? = nil,
                            profile: WakeProfile = .androidTV) async throws -> Bool {
        guard let packet = magicPacket(mac: mac) else { throw ATVError.noMACAddress }

        var targets: [String] = []
        if let broadcast { targets.append(broadcast) }
        if let directed = MACAddress.localBroadcastAddress(), !targets.contains(directed) {
            targets.append(directed)
        }
        if !targets.contains(limitedBroadcast) { targets.append(limitedBroadcast) }

        var delivered = false
        for (index, port) in profile.ports.enumerated() {
            for target in targets {
                // One unreachable target must not stop the others.
                do { try send(packet, to: target, port: port); delivered = true }
                catch { continue }
            }
            if index < profile.ports.count - 1 {
                try await Task.sleep(nanoseconds: profile.millisBetweenPorts * 1_000_000)
            }
        }
        guard delivered else { throw ATVError.wakeSendFailed }
        try await Task.sleep(nanoseconds: profile.millisAfterWake * 1_000_000)
        return true
    }

    public static let limitedBroadcast = "255.255.255.255"

    private static func send(_ data: Data, to host: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let sent = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { throw POSIXError(.EIO) }
    }

    /// Directed broadcast for a /24, e.g. 192.168.1.42 -> 192.168.1.255.
    /// More reliable than 255.255.255.255 on some routers.
    public static func directedBroadcast(for ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }
}

import Foundation

public enum MACAddress {

    /// Recovers the hardware MAC from an IPv6 link-local address formed with
    /// modified EUI-64.
    ///
    ///   fe80::b6c9:b9ff:fe80:f984%en0  ->  b4:c9:b9:80:f9:84
    ///
    /// The interface identifier is the MAC with `ff:fe` inserted in the middle
    /// and bit 1 of the first octet inverted. Android TV devices here publish
    /// only AAAA records, so this is the practical way to get a MAC for
    /// wake-on-LAN without the device ever appearing in the ARP cache.
    public static func fromIPv6LinkLocal(_ address: String) -> String? {
        var text = address
        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }

        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return nil }

        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        guard bytes.count == 16 else { return nil }
        guard bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 else { return nil }  // fe80::/10

        let iid = Array(bytes[8..<16])
        guard iid[3] == 0xFF, iid[4] == 0xFE else { return nil }               // EUI-64 marker

        let mac = [iid[0] ^ 0x02, iid[1], iid[2], iid[5], iid[6], iid[7]]
        return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The IPv4 broadcast address of this Mac's own /24, e.g. 192.168.21.255.
    /// Use this for wake-on-LAN when the device itself has no known IPv4.
    public static func localBroadcastAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }          // link-local, not useful
            let parts = ip.split(separator: ".")
            if parts.count == 4 { return "\(parts[0]).\(parts[1]).\(parts[2]).255" }
        }
        return nil
    }
}

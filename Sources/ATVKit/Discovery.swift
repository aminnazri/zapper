import Foundation
import Network

/// mDNS discovery for Android TV devices.
///
/// Service types taken from h33.java:8 in the decompiled app:
///   _androidtvremote._tcp.local.  (v1)
///   _androidtvremote2._tcp.local. (v2 — what Mi Box / Google TV use)
public enum ATVDiscovery {

    public static let serviceTypeV2 = "_androidtvremote2._tcp"
    public static let serviceTypeV1 = "_androidtvremote._tcp"

    /// Browses for `duration` seconds and returns everything found.
    public static func discover(serviceType: String = serviceTypeV2,
                                duration: TimeInterval = 5) async -> [DiscoveredDevice] {
        let found = ResultsBox()
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: {
                let p = NWParameters()
                p.includePeerToPeer = true
                return p
            }()
        )

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                found.insert(name: name, endpoint: result.endpoint)
            }
        }

        browser.start(queue: DispatchQueue(label: "atv.browse"))
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        browser.cancel()

        // Resolve each service endpoint to a concrete host:port.
        var devices: [DiscoveredDevice] = []
        for (name, endpoint) in found.snapshot() {
            // Prefer IPv4: wake-on-LAN needs a broadcast address and the ARP
            // cache is IPv4-only, so an IPv6 link-local result is useless for
            // the feature we care about most.
            var candidate = await resolve(endpoint: endpoint, forceIPv4: true)
            if candidate == nil {
                candidate = await resolve(endpoint: endpoint, forceIPv4: false)
            }
            guard let resolved = candidate else { continue }
            devices.append(DiscoveredDevice(name: name,
                                            host: resolved.host,
                                            port: resolved.port,
                                            mac: ARP.lookup(ip: resolved.host)
                                                 ?? MACAddress.fromIPv6LinkLocal(resolved.host)))
        }
        Log.info("Discovery", "found \(devices.count): " +
                 devices.map { "\($0.name)@\($0.host)" }.joined(separator: ", "))
        return devices
    }

    /// NWBrowser hands back a service endpoint, not an address. The standard
    /// trick is to start a connection and read the resolved remote endpoint.
    private static func resolve(endpoint: NWEndpoint,
                               forceIPv4: Bool) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { (k: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            let resumed = LockedBox(false)
            let params = NWParameters.tcp
            if forceIPv4,
               let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let conn = NWConnection(to: endpoint, using: params)
            let queue = DispatchQueue(label: "atv.resolve")

            @Sendable func finish(_ value: (host: String, port: UInt16)?) {
                if resumed.swap(true) == false {
                    conn.cancel()
                    k.resume(returning: value)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint else {
                        finish(nil); return
                    }
                    // Keep any %zone suffix — IPv6 link-local addresses are
                    // unusable without it.
                    finish(("\(host)", port.rawValue))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

private final class ResultsBox: @unchecked Sendable {
    private var map: [String: NWEndpoint] = [:]
    private let lock = NSLock()
    func insert(name: String, endpoint: NWEndpoint) {
        lock.lock(); defer { lock.unlock() }
        map[name] = endpoint
    }
    func snapshot() -> [(String, NWEndpoint)] {
        lock.lock(); defer { lock.unlock() }
        return map.map { ($0.key, $0.value) }
    }
}

/// Reads the MAC for an IP out of the local ARP cache. The device must have
/// been contacted at least once for an entry to exist.
public enum ARP {
    public static func lookup(ip: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-n", ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        // e.g. "? (192.168.1.42) at 1c:9e:46:aa:bb:cc on en0 ifscope [ethernet]"
        let pattern = "([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}"
        guard let range = out.range(of: pattern, options: .regularExpression) else { return nil }
        return normalize(String(out[range]))
    }

    /// macOS prints "1c:9e:46:a:b:c" — pad each octet back to two digits.
    static func normalize(_ mac: String) -> String {
        mac.split(separator: ":")
            .map { $0.count == 1 ? "0" + $0 : String($0) }
            .joined(separator: ":")
            .lowercased()
    }
}

import Foundation
import Network
import Security

/// Android TV remote protocol v2 — any Google TV or Android TV: Chromecast with
/// Google TV, Google TV Streamer, Xiaomi Mi Box / Mi TV, Sony, TCL, Philips,
/// Hisense and other Android TVs, Nvidia Shield. The protocol is Google's, so
/// nothing here is vendor specific.
///
/// Discovery on `_androidtvremote2._tcp`, pairing on 6467 (Polo), commands on
/// 6466. Both ports are TLS with a self-signed client certificate.
public struct AndroidTVAdapter: DeviceAdapter {

    public let kind: AdapterKind = .androidTV
    public let wakeProfile: WakeProfile = .androidTV

    public init() {}

    public func discover(duration: TimeInterval = 5) async -> [DiscoveredDevice] {
        await ATVDiscovery.discover(serviceType: ATVDiscovery.serviceTypeV2,
                                    duration: duration)
    }

    /// Opens a TLS session to the pairing port to check the device is reachable
    /// and accepts our certificate. Does not pair.
    public func probe(_ device: DiscoveredDevice) async throws {
        Log.info("Adapter", "probe \(device.name) at \(device.host)")
        let identity = try ATVIdentity.loadOrCreate()
        let conn = try await ATVTransport.connect(host: device.host,
                                                  port: ATVTransport.pairingPort,
                                                  identity: identity)
        conn.cancel()
    }

    public func pair(_ device: DiscoveredDevice,
                     pinProvider: @Sendable () async -> String) async throws {
        let identity = try ATVIdentity.loadOrCreate()
        try await PoloPairing.pair(host: device.host,
                                   identity: identity,
                                   codeProvider: { await pinProvider() })
    }

    public func connect(_ device: Device) async throws -> DeviceSession {
        Log.info("Adapter", "connect \(device.name) at \(device.host)")
        let identity = try ATVIdentity.loadOrCreate()
        return try await RemoteSession.open(host: device.host, identity: identity)
    }

    /// Wake the device, then wait the profile's settle time.
    ///
    /// Only meaningful over Ethernet — TV Wi-Fi chips almost never implement
    /// pattern-matched wake. Over Wi-Fi, enable Network Standby on the TV so
    /// port 6466 keeps listening in standby and `.power` can be sent instead.
    public func wake(_ device: Device) async throws {
        guard let mac = device.mac else { throw ATVError.noMACAddress }
        // The device's own host may be IPv6 link-local (Android TVs here
        // publish no A record), in which case this yields nil and wake() falls
        // back to our own subnet broadcast plus 255.255.255.255.
        let broadcast = WakeOnLAN.directedBroadcast(for: device.host)
        try await WakeOnLAN.wake(mac: mac, broadcast: broadcast, profile: wakeProfile)
    }
}

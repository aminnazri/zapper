import Foundation

/// A device found on the network but not yet paired.
public struct DiscoveredDevice: Sendable, Hashable {
    public let name: String
    public let host: String
    public let port: UInt16
    public var mac: String?

    public init(name: String, host: String, port: UInt16, mac: String? = nil) {
        self.name = name; self.host = host; self.port = port; self.mac = mac
    }
}

/// A device the user has paired and saved.
public struct Device: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var mac: String?
    public var adapter: AdapterKind
    /// The USB Bluetooth adapter, which stands in for whichever TV is
    /// paired with it. Never saved with the other devices.
    public static let bluetoothBridge = Device(
        id: UUID(uuidString: "5A99E7B1-0000-4000-8000-B10E700711E5")!,
        name: "Bluetooth adapter", host: "bluetooth")

    public var isBluetoothBridge: Bool { id == Device.bluetoothBridge.id }

    /// When a remote session to this TV last came up. Nil for TVs that were
    /// only ever discovered — which usually means not paired yet.
    public var lastConnected: Date?

    public init(id: UUID = UUID(), name: String, host: String,
                mac: String? = nil, adapter: AdapterKind = .androidTV,
                lastConnected: Date? = nil) {
        self.id = id; self.name = name; self.host = host
        self.mac = mac; self.adapter = adapter
        self.lastConnected = lastConnected
    }
}

/// Mirrors the `l71` enum in the decompiled app — the brands the shared
/// codebase supports. Only `.androidTV` is implemented here.
public enum AdapterKind: String, Sendable, Codable, CaseIterable {
    case androidTV      // Xiaomi Mi Box, Chromecast w/ Google TV, Sony, TCL, Nvidia Shield
    case roku
    case tizen          // Samsung
    case webOS          // LG
    case bravia         // Sony network API
    case smartcast      // Vizio
    case vidaa          // Hisense
    case fire           // Amazon
}

/// Semantic commands. Adapters translate these to their own wire encoding —
/// keep brand-specific keycodes out of the UI layer.
public enum RemoteCommand: Sendable, Hashable {
    case power
    case up, down, left, right, select, back, home, menu
    case volumeUp, volumeDown, mute
    case playPause, next, previous, rewind, fastForward
    case settings, guide
    /// One character typed live, mapped to its Android keycode.
    case character(Character)
    case backspace, enter, search
    /// 1…4 = HDMI 1…4, 0 = open the input picker
    case input(Int)
    case launchApp(String)      // package name or deep link
    case text(String)
}

/// Mirrors `rm8` / WakeOnLanProfile in the decompiled app.
public struct WakeProfile: Sendable, Hashable {
    public let ports: [UInt16]
    public let millisAfterWake: UInt64
    public let millisBetweenPorts: UInt64

    public init(ports: [UInt16], millisAfterWake: UInt64, millisBetweenPorts: UInt64 = 200) {
        self.ports = ports
        self.millisAfterWake = millisAfterWake
        self.millisBetweenPorts = millisBetweenPorts
    }

    /// Values taken verbatim from vm4.java:10 in the decompiled app.
    public static let androidTV = WakeProfile(
        ports: [6466], millisAfterWake: 500, millisBetweenPorts: 200
    )
}

public enum ATVError: Error, CustomStringConvertible {
    case certParseFailed
    case keychain(OSStatus)
    case notPaired
    case pairingRejected(String)
    case timeout
    case notImplemented(String)
    case noMACAddress
    case connectionClosed
    case pairingFailed(String)
    case badPairingCode
    case wakeSendFailed
    case opensslMissing
    case opensslFailed(String)
    case screenCapture(String)
    case bridgeNotFound
    case bridgeNoTV
    case bridgeFailed(String)

    public var description: String {
        switch self {
        case .certParseFailed:        return "Could not parse generated certificate DER"
        case .keychain(let s):        return "Keychain error \(s)"
        case .notPaired:              return "Device is not paired"
        case .pairingRejected(let m): return "Pairing rejected: \(m)"
        case .timeout:                return "Timed out"
        case .notImplemented(let m):  return "Not implemented: \(m)"
        case .noMACAddress:           return "No MAC address known for this device (needed for wake)"
        case .connectionClosed:       return "Connection closed by the device"
        case .pairingFailed(let m):   return "Pairing failed: \(m)"
        case .badPairingCode:         return "That code did not match. Check the digits on the TV and try again."
        case .wakeSendFailed:         return "Could not send the wake packet on any broadcast address"
        case .opensslMissing:         return "openssl not found — needed once to mint the client certificate"
        case .opensslFailed(let m):   return "openssl failed: \(m)"
        case .screenCapture(let m):   return "Screen capture: \(m)"
        case .bridgeNotFound:         return "The Zapper Bluetooth adapter isn\u{2019}t plugged in."
        case .bridgeNoTV:             return "No TV is connected to the Bluetooth adapter. On the TV, pair "
                                           + "\u{201C}Zapper Remote\u{201D} in Settings \u{203A} Remotes & Accessories."
        case .bridgeFailed(let m):    return m
        }
    }
}

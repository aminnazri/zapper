import Foundation

/// One brand's transport. Mirrors the `om8` interface in the decompiled app.
///
/// Add a conformance per brand (Tizen / webOS / Bravia / SmartCast) and the
/// UI layer never changes — it only ever deals in `RemoteCommand`.
public protocol DeviceAdapter: Sendable {
    var kind: AdapterKind { get }
    var wakeProfile: WakeProfile { get }

    func discover(duration: TimeInterval) async -> [DiscoveredDevice]

    /// Runs the pairing handshake. `pinProvider` is called when the device
    /// shows its code on screen.
    func pair(_ device: DiscoveredDevice,
              pinProvider: @Sendable () async -> String) async throws

    func connect(_ device: Device) async throws -> DeviceSession
}

/// A live connection you can send commands over.
public protocol DeviceSession: Sendable {
    func send(_ command: RemoteCommand) async throws
    func disconnect() async
}

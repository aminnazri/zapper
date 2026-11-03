import Foundation

/// The app's folder in Application Support: client certificate, its scratch
/// keychain, saved devices.
public enum AppSupport {

    /// The app was called MiRemote before it became Zapper. Its folder holds
    /// the certificate every TV was paired with, so it is moved rather than
    /// left behind — a fresh folder would mean re-pairing every TV.
    private static let legacyName = "MiRemote"
    private static let name = "Zapper"

    public static var directory: URL {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = root.appendingPathComponent(name, isDirectory: true)
        let legacy = root.appendingPathComponent(legacyName, isDirectory: true)
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }
}

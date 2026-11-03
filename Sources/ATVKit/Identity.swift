import Foundation
import Security

/// Creates and stores the TLS client identity the TV pairs against.
///
/// Design notes — both of these were bugs found the hard way:
///
/// 1. **The certificate must be stable across launches.** Pairing binds the TV's
///    trust to *this* certificate, so regenerating it would silently force a
///    re-pair every time the app started. The durable artifact is a PKCS#12
///    file in Application Support; everything else is derived from it.
///
/// 2. **Never import into the login keychain.** `SecPKCS12Import` gives the
///    imported key an ACL trusting only the importing binary. Any rebuild
///    changes the ad-hoc signature, so macOS prompts for the login password
///    every time ("Zapper wants to access key ... in your keychain").
///    Importing into a scratch keychain we create and unlock ourselves avoids
///    the ACL entirely and never prompts.
///
/// macOS has no public API to create a self-signed certificate, so the cert is
/// minted once with `openssl`. That keeps this package dependency-free.
public enum ATVIdentity {

    public static let keychainLabel = "com.miremote.atv.client-identity"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SecIdentity?

    // MARK: - Storage locations

    private static var supportDirectory: URL { AppSupport.directory }

    private static var bundleURL: URL { supportDirectory.appendingPathComponent("identity.p12") }
    private static var passURL: URL { supportDirectory.appendingPathComponent("identity.pass") }

    /// Where the certificate lives, for display in the UI.
    public static var storageDescription: String { bundleURL.path }

    // MARK: - Public API

    /// Returns the stored identity, minting one on first run.
    public static func loadOrCreate() throws -> SecIdentity {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }

        if !FileManager.default.fileExists(atPath: bundleURL.path) {
            try mint()
        }
        let identity = try importBundle()
        cached = identity
        return identity
    }

    /// Deletes the stored certificate. The TV will require re-pairing.
    public static func delete() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        try? FileManager.default.removeItem(at: bundleURL)
        try? FileManager.default.removeItem(at: passURL)
        // The keychain holds the old identity; the next load must rebuild it.
        try? FileManager.default.removeItem(at: keychainURL)
    }

    public static var exists: Bool {
        FileManager.default.fileExists(atPath: bundleURL.path)
    }

    // MARK: - Subject

    /// Mirrors `ju3.b()` in the decompiled app:
    ///   CN=atvremote/<PRODUCT>/<DEVICE>/<MODEL>/<uniqueId>
    ///
    /// The TV uses the same convention — a real Mi TV presents
    /// `CN=atvremote/B4:C9:B9:80:F9:85`.
    public static func subjectCommonName() -> String {
        let model = sanitize(hardwareModel())
        let unique = String(UUID().uuidString.prefix(8))
        return "atvremote/\(model)/\(model)/\(model)/\(unique)"
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: - Minting

    private static func opensslPath() throws -> String {
        for candidate in ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ATVError.opensslMissing
    }

    /// Generates the keypair and self-signed certificate, once.
    private static func mint() throws {
        let openssl = try opensslPath()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zapper-mint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let key = scratch.appendingPathComponent("key.pem").path
        let cert = scratch.appendingPathComponent("cert.pem").path
        let p12 = scratch.appendingPathComponent("identity.p12").path
        let passphrase = UUID().uuidString

        // openssl treats '/' in -subj as a field separator, so escape ours.
        let subject = "/CN=" + subjectCommonName().replacingOccurrences(of: "/", with: "\\/")

        try run(openssl, ["req", "-x509", "-newkey", "rsa:2048",
                          "-keyout", key, "-out", cert,
                          "-days", "3650", "-nodes", "-subj", subject])
        try run(openssl, ["pkcs12", "-export", "-inkey", key, "-in", cert,
                          "-out", p12, "-passout", "pass:\(passphrase)",
                          "-name", "atvremote"])

        let data = try Data(contentsOf: URL(fileURLWithPath: p12))
        try write(data, to: bundleURL)
        try write(Data(passphrase.utf8), to: passURL)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    // MARK: - Importing

    /// Imports the stored PKCS#12 into a throwaway keychain we own.
    ///
    /// Deprecated `SecKeychain*` APIs are the only way to get a keychain that
    /// is not the user's login keychain, and they still work. Marking this
    /// function deprecated silences the warnings for the calls inside it.
    /// Imports the stored PKCS#12 into a keychain we own outright.
    ///
    /// Deliberately a *fixed* path with a *stored* password, recreated from
    /// scratch on every launch:
    ///
    ///  - Fixed, so stale keychains cannot pile up in the user's search list.
    ///  - Stored password, so we can unlock it ourselves at any moment without
    ///    ever asking the user. The key only proves this Mac's identity to a TV
    ///    on the LAN; it is not worth a password dialog per button press.
    ///  - No `SecKeychainSetSettings` — that call raises its own authorisation
    ///    dialog, which is what broke the previous attempt.
    @available(macOS, deprecated: 10.10)
    private static func importBundle() throws -> SecIdentity {
        if let existing = existingIdentity() {
            Log.info("Identity", "identity ready (existing keychain)")
            return existing
        }
        let data = try Data(contentsOf: bundleURL)
        let passphrase = String(decoding: try Data(contentsOf: passURL), as: UTF8.self)
        let keychain = try openScratchKeychain()

        var options: [CFString: Any] = [
            kSecImportExportPassphrase: passphrase,
            kSecImportExportKeychain: keychain,
        ]
        if let access = permissiveAccess() {
            options[kSecImportExportAccess] = access
        }

        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let raw = array.first?[kSecImportItemIdentity as String] else {
            Log.error("Identity", "SecPKCS12Import failed: \(status)")
            throw ATVError.keychain(status)
        }
        Log.info("Identity", "identity ready")
        return (raw as! SecIdentity)
    }

    private static var keychainURL: URL {
        supportDirectory.appendingPathComponent("identity.keychain")
    }
    private static var keychainPassURL: URL {
        supportDirectory.appendingPathComponent("keychain.pass")
    }

    /// The identity from the keychain a previous launch built, if our stored
    /// password still unlocks it.
    ///
    /// Recreating the keychain on every launch broke any *other* process
    /// already using it — the app and the CLI running side by side, or two
    /// launches overlapping — because the file was replaced under it with a
    /// new password, and macOS then asked the user for a password they never
    /// had. Reusing it means only a missing or broken keychain gets rebuilt.
    @available(macOS, deprecated: 10.10)
    private static func existingIdentity() -> SecIdentity? {
        guard FileManager.default.fileExists(atPath: keychainURL.path),
              let password = try? String(contentsOf: keychainPassURL, encoding: .utf8),
              !password.isEmpty else { return nil }
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain,
              SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true) == errSecSuccess
        else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchSearchList: [keychain],
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { return nil }
        return (result as! SecIdentity)
    }

    /// Deletes any previous keychain and creates a fresh unlocked one.
    @available(macOS, deprecated: 10.10)
    private static func openScratchKeychain() throws -> SecKeychain {
        // Drop the old one first; recreating avoids inheriting a locked or
        // half-written keychain from a previous run.
        var previous: SecKeychain?
        if SecKeychainOpen(keychainURL.path, &previous) == errSecSuccess, let previous {
            SecKeychainDelete(previous)
        }
        try? FileManager.default.removeItem(at: keychainURL)

        let password = UUID().uuidString
        try? write(Data(password.utf8), to: keychainPassURL)

        var keychain: SecKeychain?
        let created = SecKeychainCreate(keychainURL.path,
                                        UInt32(password.utf8.count),
                                        password, false, nil, &keychain)
        guard created == errSecSuccess, let keychain else {
            Log.error("Identity", "SecKeychainCreate failed: \(created)")
            throw ATVError.keychain(created)
        }

        let unlocked = SecKeychainUnlock(keychain,
                                         UInt32(password.utf8.count),
                                         password, true)
        guard unlocked == errSecSuccess else {
            Log.error("Identity", "SecKeychainUnlock failed: \(unlocked)")
            throw ATVError.keychain(unlocked)
        }
        return keychain
    }

    /// Re-unlocks the keychain using the password we stored. Cheap, silent, and
    /// safe to call before every connection in case macOS re-locked it.
    @available(macOS, deprecated: 10.10)
    public static func unlockIfNeeded() {
        guard let password = try? String(contentsOf: keychainPassURL, encoding: .utf8),
              !password.isEmpty else { return }
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess,
              let keychain else { return }
        var status = SecKeychainStatus()
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return }
        if status & SecKeychainStatus(kSecUnlockStateStatus) == 0 {
            let result = SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
            Log.debug("Identity", "re-unlocked keychain: \(result)")
        }
    }

    /// SecAccess whose ACLs trust any application, so using the private key
    /// never raises a confirmation dialog.
    @available(macOS, deprecated: 10.10)
    private static func permissiveAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("Zapper client certificate" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }
        for acl in acls {
            _ = SecACLSetContents(acl, nil, "" as CFString, SecKeychainPromptSelector())
        }
        return access
    }

    // MARK: - Process helper

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw ATVError.opensslFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

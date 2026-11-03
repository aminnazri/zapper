import Foundation
import ATVKit

/// Reads the address of the tab in front of a browser window, through the
/// browser's own AppleScript support. macOS asks once per browser whether
/// Zapper may control it. Firefox has no scripting, so it is never found.
enum BrowserTab {

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera",
    ]

    /// The front tab's URL in the window titled `windowTitle`. The window
    /// title is the front tab's title, which is how the two are matched.
    static func url(bundleID: String, windowTitle: String) async -> URL? {
        let tab: String, name: String
        if bundleID.hasPrefix("com.apple.Safari") {
            (tab, name) = ("current tab", "name")
        } else if chromium.contains(bundleID) {
            (tab, name) = ("active tab", "title")
        } else {
            return nil
        }
        let script = """
        tell application id "\(bundleID)"
            set out to ""
            repeat with w in every window
                set t to \(tab) of w
                set out to out & (\(name) of t) & tab & (URL of t) & linefeed
            end repeat
            return out
        end tell
        """
        guard let output = await run(script) else { return nil }

        let tabs = output.split(separator: "\n").compactMap { line -> (title: String, url: URL)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[1]) else { return nil }
            return (parts[0], url)
        }
        // Some browsers add their own name or a profile to the window title.
        let match = tabs.first { $0.title == windowTitle }
            ?? tabs.first { !$0.title.isEmpty && windowTitle.contains($0.title) }
            ?? (tabs.count == 1 ? tabs.first : nil)
        return match?.url
    }

    /// osascript rather than NSAppleScript: it runs off the main thread, and
    /// a browser that hangs cannot freeze the panel.
    private static func run(_ script: String) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                done.resume(returning: finished.terminationStatus == 0
                            ? String(data: data, encoding: .utf8) : nil)
            }
            do { try process.run() } catch {
                Log.warn("UI", "could not run osascript: \(error)")
                done.resume(returning: nil)
                return
            }
            // The first call waits on the permission prompt, so be generous.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

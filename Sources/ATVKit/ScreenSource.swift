import Foundation
import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ScreenCaptureKit

/// What a screen cast shows.
///
/// There is no way to capture one macOS Space: a display shows whichever
/// Space is active on it. A window, by contrast, is followed even when it is
/// covered by others.
public enum ScreenSource: Hashable, Sendable {
    case display(CGDirectDisplayID)
    /// All windows of one app, on the display holding most of them.
    case app(pid_t)
    case window(CGWindowID)
    /// A browser window cropped to its page, so the tab bar and toolbar stay
    /// off the TV. Shows whichever tab is active in that window.
    case tab(CGWindowID)
}

/// One row of the source picker.
public struct ScreenChoice: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case display, app, window, tab }

    public let kind: Kind
    public let source: ScreenSource
    public let title: String
    public let subtitle: String
    /// For the app icon; nil for displays.
    public let pid: pid_t?
    public var bundleID: String?
    /// Where the window was when listed, to find it again through
    /// Accessibility.
    public var frame: CGRect?
    public var id: String { "\(kind.rawValue)-\(source)" }

    /// A window or tab of a browser, whose page address can be looked up.
    public var isBrowserPage: Bool {
        (kind == .window || kind == .tab) && bundleID.map(ScreenSources.browsers.contains) == true
    }

    public static func == (a: ScreenChoice, b: ScreenChoice) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum ScreenSources {

    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    /// System furniture that owns layer-0 windows but is never worth sharing.
    private static let ignored: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.wallpaper.agent",
    ]

    /// Everything that can be shared right now, displays first. Main actor
    /// because display names come from NSScreen.
    @MainActor
    public static func list() async throws -> [ScreenChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = shareable(content.windows)
        var choices: [ScreenChoice] = []

        for display in content.displays {
            choices.append(ScreenChoice(kind: .display, source: .display(display.displayID),
                                        title: displayName(display.displayID),
                                        subtitle: "\(display.width) × \(display.height)",
                                        pid: nil))
        }

        let byApp = Dictionary(grouping: windows) { $0.owningApplication!.processID }
        let apps = byApp.compactMap { pid, list -> ScreenChoice? in
            guard let app = list.first?.owningApplication else { return nil }
            let count = list.count
            return ScreenChoice(kind: .app, source: .app(pid),
                                title: app.applicationName,
                                subtitle: count == 1 ? "1 window" : "\(count) windows",
                                pid: pid)
        }
        choices += apps.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        for window in windows {
            let app = window.owningApplication!
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app.applicationName
            choices.append(ScreenChoice(kind: .window, source: .window(window.windowID),
                                        title: title, subtitle: app.applicationName,
                                        pid: app.processID, bundleID: app.bundleIdentifier,
                                        frame: window.frame))
            if browsers.contains(app.bundleIdentifier) {
                choices.append(ScreenChoice(kind: .tab, source: .tab(window.windowID),
                                            title: title, subtitle: app.applicationName,
                                            pid: app.processID, bundleID: app.bundleIdentifier,
                                            frame: window.frame))
            }
        }
        return choices
    }

    /// Ordinary app windows big enough to be worth a TV, front to back.
    static func shareable(_ windows: [SCWindow]) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.filter { w in
            guard let app = w.owningApplication, app.processID != me,
                  !ignored.contains(app.bundleIdentifier) else { return false }
            return w.windowLayer == 0 && w.isOnScreen
                && w.frame.width >= 160 && w.frame.height >= 120
        }
    }

    static func displayName(_ id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display")
    }
}

// MARK: - Browser page area

/// Finds where the web page sits inside a browser window, through the
/// Accessibility API — the only outside view of a browser's layout.
public final class PageTracker: @unchecked Sendable {

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private let app: AXUIElement
    private let window: AXUIElement

    /// Takes a window out of full-screen mode, back onto its desktop. A
    /// full-screen window is a Space of its own, which macOS stops drawing —
    /// and so stops sharing — whenever another app is in front.
    public static func exitFullScreen(pid: pid_t, windowFrame: CGRect?) -> Bool {
        guard isTrusted else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        let full = windows.filter { value($0, "AXFullScreen") as? Bool == true }
        let target = windowFrame.flatMap { frame in
            full.min { distance(Self.frame($0), frame) < distance(Self.frame($1), frame) }
        } ?? full.first
        guard let target else { return false }
        return AXUIElementSetAttributeValue(target, "AXFullScreen" as CFString, kCFBooleanFalse) == .success
    }

    /// Nil when Accessibility is not allowed or the window cannot be matched.
    public init?(pid: pid_t, windowFrame: CGRect) {
        guard Self.isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // Chromium browsers only build their accessibility tree once an
        // assistive app asks for it; this is the switch for that.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = Self.value(app, kAXWindowsAttribute) as? [AXUIElement],
              let match = windows.min(by: {
                  Self.distance(Self.frame($0), windowFrame) < Self.distance(Self.frame($1), windowFrame)
              }),
              Self.distance(Self.frame(match), windowFrame) < 40
        else { return nil }
        self.app = app
        self.window = match
    }

    /// The page's rectangle relative to the window's top-left, in points.
    /// Looked up afresh each time, since switching tabs swaps the page.
    public func pageRect() -> CGRect? {
        guard let windowFrame = Self.frame(window), let page = largestWebArea() else { return nil }
        let visible = page.intersection(windowFrame)
        guard visible.width > 100, visible.height > 100 else { return nil }
        return CGRect(x: visible.minX - windowFrame.minX, y: visible.minY - windowFrame.minY,
                      width: visible.width, height: visible.height)
    }

    /// Breadth-first, without descending into pages, so a heavy page costs
    /// no more than a blank one. Docked developer tools are a web area too;
    /// the largest one is the page.
    private func largestWebArea() -> CGRect? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var best: CGRect?
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if Self.value(element, kAXRoleAttribute) as? String == "AXWebArea" {
                if let rect = Self.frame(element),
                   rect.width * rect.height > (best.map { $0.width * $0.height } ?? 0) {
                    best = rect
                }
                continue
            }
            guard depth < 16, let children = Self.value(element, kAXChildrenAttribute) as? [AXUIElement]
            else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return best
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Top-left-origin screen coordinates — the same space as SCWindow.frame.
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

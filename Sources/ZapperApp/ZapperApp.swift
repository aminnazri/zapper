import SwiftUI
import AppKit
import Carbon.HIToolbox
import ATVKit

@main
struct ZapperApp: App {

    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Zapper", systemImage: "tv") {
            MenuContent(state: state)
                .onAppear { installHotKeys() }
        }
        .menuBarExtraStyle(.window)
    }

    /// ⌃⌥⌘T anywhere = turn the TV on. Needs `state`, so it is set up when
    /// the panel first appears; the open-panel shortcut is set up at launch.
    private func installHotKeys() {
        guard !AppDelegate.turnOnKeyInstalled else { return }
        AppDelegate.turnOnKeyInstalled = true
        HotKeyCenter.shared.register(
            keyCode: kVK_ANSI_T,
            modifiers: controlKey | optionKey | cmdKey
        ) {
            Task { @MainActor in await state.turnOn() }
        }
    }
}

/// Menu-bar-only: no Dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var turnOnKeyInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installPanelHotKey()
        if let directory = Snapshotter.outputDirectory {
            Task { @MainActor in await Snapshotter.run(to: directory) }
        }
    }
}

// MARK: - Open-panel shortcut

extension AppDelegate {
    /// ⌥Space opens or closes the Zapper panel from anywhere — handy in a
    /// full-screen app, where the menu bar is hidden. If another app (ChatGPT,
    /// Raycast…) already owns ⌥Space, macOS refuses it and we use ⌥Z.
    func installPanelHotKey() {
        let toggle = { DispatchQueue.main.async { AppDelegate.togglePanel() } }
        if HotKeyCenter.shared.register(keyCode: kVK_Space, modifiers: optionKey, action: toggle) {
            Log.info("UI", "panel shortcut: ⌥Space")
        } else if HotKeyCenter.shared.register(keyCode: kVK_ANSI_Z, modifiers: optionKey, action: toggle) {
            Log.info("UI", "⌥Space is taken by another app; panel shortcut: ⌥Z")
        } else {
            Log.warn("UI", "no panel shortcut: ⌥Space and ⌥Z are both taken")
        }
    }

    /// SwiftUI's MenuBarExtra has no API to open its window, so we click its
    /// menu bar button. Clicking again closes it, just like a mouse click.
    static func togglePanel() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = findStatusButton(in: window.contentView) {
                button.performClick(nil)
                // Opened from the keyboard, the panel hangs under where the
                // menu bar would be. In a full-screen app the menu bar is
                // hidden, so its top lands off screen. Pull it back in once
                // SwiftUI has placed it (twice: it can settle a frame late).
                for delay in [0.0, 0.08] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { keepPanelOnScreen() }
                }
                return
            }
        }
        Log.warn("UI", "panel shortcut: couldn't find Zapper's menu bar button")
    }

    /// Moves the open panel so it sits wholly inside its screen's visible area.
    private static func keepPanelOnScreen() {
        for window in NSApp.windows where window.isVisible
            && !window.className.contains("NSStatusBarWindow")
            && window.frame.height > 100 {
            guard let screen = window.screen ?? NSScreen.main else { continue }
            let area = screen.visibleFrame
            var frame = window.frame
            if frame.maxY > area.maxY { frame.origin.y = area.maxY - frame.height }
            if frame.minY < area.minY { frame.origin.y = area.minY }
            if frame.maxX > area.maxX { frame.origin.x = area.maxX - frame.width }
            if frame.minX < area.minX { frame.origin.x = area.minX }
            if frame != window.frame { window.setFrame(frame, display: true) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findStatusButton(in: sub) { return found }
        }
        return nil
    }
}

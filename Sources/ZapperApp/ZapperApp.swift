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

    /// ⌃⌥⌘T anywhere = turn the TV on.
    private func installHotKeys() {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let directory = Snapshotter.outputDirectory {
            Task { @MainActor in await Snapshotter.run(to: directory) }
        }
    }
}

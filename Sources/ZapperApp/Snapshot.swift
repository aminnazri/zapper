import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import ATVKit

/// The panel states shown in the README and the user guide.
enum SnapshotScene: String, CaseIterable {
    case picker, pairing, remote, touchpad
    case input, apps, media, keyboard
    case castIdle = "cast-idle", screen, cast

    /// The drawer open in this scene, if any.
    var drawer: Drawer? {
        switch self {
        case .input: return .input
        case .apps: return .apps
        case .media: return .media
        case .keyboard: return .keyboard
        case .castIdle, .screen, .cast: return .cast
        default: return nil
        }
    }
}

/// Renders the real menu panel into PNGs for the README:
///
///     open build/Zapper.app --args --snapshot docs/images
///
/// Each scene is shown briefly in a borderless window and captured with
/// ScreenCaptureKit, under the Screen Recording permission Zapper already
/// holds for casting. The app quits when done.
@MainActor
enum Snapshotter {
    /// Opens the cast drawer's screen picker on appear, for the `screen` scene.
    static var opensScreenPicker = false

    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scene in SnapshotScene.allCases {
            let state = AppState()
            state.applyShowcase(scene)
            opensScreenPicker = scene == .screen
            let panel = MenuContent(state: state, isSnapshot: true,
                                    snapshotDrawer: scene.drawer,
                                    snapshotTouchpad: scene == .touchpad)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            let host = NSHostingView(rootView: panel)
            let window = NSWindow(contentRect: NSRect(x: 240, y: 120, width: Theme.width, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.contentView = host
            window.orderFrontRegardless()

            // Let layout, the panel's own window fitting, and animations settle.
            try? await Task.sleep(nanoseconds: 1_800_000_000)

            let file = directory.appendingPathComponent("\(scene.rawValue).png")
            if let image = await capture(window) {
                write(image, to: file)
                Log.info("Snapshot", "wrote \(file.path)")
            } else {
                Log.error("Snapshot", "could not capture \(scene.rawValue)")
            }
            window.orderOut(nil)
        }
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow) async -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
            else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.error("Snapshot", "capture failed: \(error)")
            return nil
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

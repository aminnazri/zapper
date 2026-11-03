import SwiftUI
import AppKit

/// Colours and metrics for the remote. The panel is always dark — it is a
/// remote, not a document, and the glow effects only read on a dark ground.
enum Theme {
    static let width: CGFloat = 340
    static let padding: CGFloat = 18
    static let tileRadius: CGFloat = 18

    static let backgroundTop = Color(red: 0.11, green: 0.17, blue: 0.31)
    static let backgroundBottom = Color(red: 0.035, green: 0.055, blue: 0.11)

    static let surface = Color.white.opacity(0.055)
    static let surfaceRaised = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.08)

    static let text = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.36)

    static let accent = Color(red: 0.33, green: 0.55, blue: 1.0)
    static let accentSoft = Color(red: 0.45, green: 0.72, blue: 1.0)
    static let violet = Color(red: 0.66, green: 0.52, blue: 1.0)
    static let online = Color(red: 0.30, green: 0.85, blue: 0.48)
    static let warning = Color(red: 1.0, green: 0.68, blue: 0.30)

    static let volumeGradient = LinearGradient(
        colors: [accent, accentSoft, violet],
        startPoint: .leading, endPoint: .trailing
    )
}

/// Rounded, slightly raised card used by tiles, banners and drawers.
struct Card: ViewModifier {
    var radius: CGFloat = Theme.tileRadius
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(highlighted ? Theme.accent.opacity(0.16) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.accent.opacity(0.55) : Theme.stroke,
                                  lineWidth: 1)
            )
    }
}

extension View {
    func card(radius: CGFloat = Theme.tileRadius, highlighted: Bool = false) -> some View {
        modifier(Card(radius: radius, highlighted: highlighted))
    }
}

/// Round icon key — the "−" / "+" buttons of the reference, used for Back,
/// Home and friends. `lit` makes it glow while its command is being sent.
struct RoundKeyStyle: ButtonStyle {
    var size: CGFloat = 44
    var lit = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let active = configuration.isPressed || lit
        return configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? Color.white : Theme.text)
            .frame(width: size, height: size)
            .background(
                Circle().fill(active ? Theme.accent.opacity(0.45) : Theme.surface)
            )
            .overlay(Circle().strokeBorder(active ? Theme.accent : Theme.stroke, lineWidth: 1))
            .shadow(color: active ? Theme.accent.opacity(0.55) : .clear, radius: 10)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: active)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Circle())
    }
}

/// Pill button for primary and secondary actions in banners and sheets.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Capsule().fill(prominent ? Theme.accent : Theme.surfaceRaised)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .overlay(Capsule().strokeBorder(prominent ? .clear : Theme.stroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Pops a native menu at the pointer. SwiftUI's `Menu` cannot take a custom
/// label on macOS 13, and the device chip needs one.
@MainActor
enum PopupMenu {
    enum Entry {
        case item(String, symbol: String? = nil, checked: Bool = false,
                  enabled: Bool = true, action: () -> Void)
        case header(String)
        case separator
    }

    static func show(_ entries: [Entry]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case let .item(title, symbol, checked, enabled, action):
                let handler = MenuHandler(action)
                let item = NSMenuItem(title: title, action: #selector(MenuHandler.fire), keyEquivalent: "")
                item.target = handler
                item.representedObject = handler     // the target is weak
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                if let symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu.addItem(item)
            case let .header(title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class MenuHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

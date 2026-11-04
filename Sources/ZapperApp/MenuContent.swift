import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ATVKit

struct MenuContent: View {
    @ObservedObject var state: AppState
    /// Rendering for a README screenshot: no scanning, no connection, no
    /// keyboard capture, and `snapshotDrawer` opened from the start.
    var isSnapshot = false
    var snapshotDrawer: Drawer? = nil
    var snapshotTouchpad = false
    @StateObject private var keys = KeyMonitor()
    @State private var drawer: Drawer?
    /// Drives the staggered entrance each time the panel opens.
    @State private var appeared = false
    /// A file is being dragged over the panel.
    @State private var dropTargeted = false
    /// Touchpad instead of the D-pad ring, for a TV browser's cursor.
    /// Remembered between launches.
    @AppStorage("touchpadMode") private var touchpad = false
    @Namespace private var modeSwitch

    /// The saved preference, except in a screenshot, which sets its own.
    private var showsTouchpad: Bool { isSnapshot ? snapshotTouchpad : touchpad }

    private enum Screen { case pairing, empty, picker, remote }

    private var screen: Screen {
        if state.isPairing { return .pairing }
        if state.devices.isEmpty && !state.bridgePlugged && state.selected == nil { return .empty }
        if state.selected == nil { return .picker }
        return .remote
    }

    /// The panel's natural height, measured. Above `maxHeight` it scrolls.
    @State private var contentHeight: CGFloat = 0
    /// The menu bar window hosting this view, for `fitWindow`.
    @State private var window: NSWindow?

    /// Space below the menu bar. A taller panel is clipped by macOS — the
    /// header first, since the panel hangs from the menu bar — which is what
    /// opening a drawer did on a laptop screen.
    private var maxHeight: CGFloat {
        let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return visible - 12
    }

    var body: some View {
        Group {
            if contentHeight > maxHeight {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        measured
                    }
                    .frame(height: maxHeight)
                    // Bring a newly opened drawer into view; it sits at the
                    // bottom, out of sight once the panel scrolls.
                    .onChange(of: drawer) { opened in
                        guard opened != nil else { return }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                }
            } else {
                measured
            }
        }
        .frame(width: Theme.width)
        .background(background)
        .background(WindowReader { window = $0 })
        .environment(\.colorScheme, .dark)
        .onChange(of: contentHeight) { _ in fitWindow() }
        .overlay { if dropTargeted { dropHint } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: castDropped)
        .onAppear {
            if isSnapshot {
                drawer = snapshotDrawer
                appeared = true
                return
            }
            state.scanNearbyIfStale()
            state.startMonitoring()
            keys.start(handle)
            appeared = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
        .onDisappear {
            guard !isSnapshot else { return }
            state.stopMonitoring()
            keys.stop()
            appeared = false
        }
    }

    private static let bottomAnchor = "panel-bottom"

    /// Sizes the menu bar window to the panel.
    ///
    /// The window does not reliably follow its content: opening a drawer
    /// grew the panel while the window kept its old height, so the panel was
    /// cut off at both ends — header and power button included. The top edge
    /// stays put, since the panel hangs from the menu bar.
    private func fitWindow() {
        guard let window, contentHeight > 0 else { return }
        let height = min(contentHeight, maxHeight)
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Theme.width, height: height)).size
        guard abs(window.frame.height - size.height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - size.height
        frame.size.height = size.height
        window.setFrame(frame, display: true, animate: false)
    }

    private var measured: some View {
        panel
            .background(GeometryReader { geo in
                Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
            })
            .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Header(state: state, drawer: $drawer)
                .padding(.bottom, 16)
                .entrance(appeared, delay: 0)

            Group {
                switch screen {
                case .pairing:
                    PairingView(state: state)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                case .empty:
                    EmptyStateView(state: state)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .picker:
                    DevicePicker(state: state)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                case .remote:
                    remote
                        .transition(.opacity)
                }
            }

            Footer(state: state)
                .padding(.top, 14)
                .entrance(appeared, delay: 0.25)
                .id(Self.bottomAnchor)
        }
        .padding(Theme.padding)
        .frame(width: Theme.width)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: screen)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: state.link)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: state.casting?.id)
    }

    private var remote: some View {
        VStack(spacing: 18) {
            if case .offline(let reason) = state.link {
                OfflineBanner(state: state, reason: reason)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(spacing: 12) {
                navigation
                    .opacity(state.isOn == false ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.3), value: state.isOn)
                modePicker
            }
            .entrance(appeared, delay: 0.05)

            VolumePanel(state: state)
                .entrance(appeared, delay: 0.12)

            VStack(spacing: 8) {
                // Keeps the cast in reach while other drawers are in use.
                if let now = state.casting, drawer != .cast {
                    NowCasting(state: state, now: now, compact: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TileRow(state: state, open: $drawer)
                if let drawer {
                    DrawerContent(state: state, drawer: drawer)
                        .id(drawer)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity)
                                .combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity))
                }
            }
            .entrance(appeared, delay: 0.18)
        }
    }

    /// Ring flanked by the four keys a remote cannot do without.
    private var navigation: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                roundKey("arrow.uturn.backward", .back, "Back (Esc or Delete)")
                Spacer()
                roundKey("house.fill", .home, "Home (H)")
            }
            Spacer(minLength: 0)
            ZStack {
                if showsTouchpad {
                    TouchPad(state: state)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    DPadRing(state: state)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: showsTouchpad)
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                roundKey("gearshape.fill", .settings, "TV settings")
                Spacer()
                roundKey("playpause.fill", .playPause, "Play / pause (Space)")
            }
        }
        .frame(height: 188)
    }

    /// D-pad / Touchpad switch, with a highlight that slides between them.
    private var modePicker: some View {
        HStack(spacing: 2) {
            modeOption("D-pad", "dpad.fill", selected: !showsTouchpad) { touchpad = false }
            modeOption("Touchpad", "rectangle.and.hand.point.up.left.fill", selected: showsTouchpad) { touchpad = true }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .help("Touchpad moves the cursor in TV browsers such as TV Bro or Puffin")
    }

    private func modeOption(_ title: String, _ symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background {
                if selected {
                    Capsule().fill(Theme.accent)
                        .matchedGeometryEffect(id: "mode", in: modeSwitch)
                        .shadow(color: Theme.accent.opacity(0.5), radius: 6)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func roundKey(_ symbol: String, _ command: RemoteCommand, _ help: String) -> some View {
        Button { Task { await state.send(command) } } label: { Image(systemName: symbol) }
            .buttonStyle(RoundKeyStyle(size: 46, lit: state.lastPressed == command))
            .disabled(state.selected == nil)
            .help(help)
    }

    // MARK: - Drop to cast

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Theme.backgroundBottom.opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: Drawer.cast.symbol)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.accentSoft)
                    Text("Drop to cast on \(state.selected?.name ?? "the TV")")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func castDropped(_ providers: [NSItemProvider]) -> Bool {
        guard state.selected != nil, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            Task { @MainActor in
                state.cast(file: url)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { drawer = .cast }
            }
        }
        return true
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
            // Faint accent light behind the header, as in the reference.
            RadialGradient(colors: [Theme.accent.opacity(state.isOn == false ? 0.04 : 0.16), .clear],
                           center: UnitPoint(x: 0.85, y: 0.0), startRadius: 0, endRadius: 260)
                .animation(.easeInOut(duration: 0.6), value: state.isOn)
        }
        .ignoresSafeArea()
    }

    // MARK: - Mac keyboard

    /// Mac keys drive the TV while the panel is open.
    ///
    /// A local event monitor rather than `keyboardShortcut`: shortcuts without
    /// modifiers fired even while typing in the text field, so typing "home"
    /// pressed Home and a space paused playback. The monitor steps aside
    /// whenever a text field has focus.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, screen == .remote else { return false }

        if NSApp.keyWindow?.firstResponder is NSTextView {
            // Esc leaves the field so the arrows go back to the TV.
            if event.keyCode == 53 {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        let command: RemoteCommand?
        switch event.keyCode {
        case 126: command = .up
        case 125: command = .down
        case 123: command = .left
        case 124: command = .right
        case 36, 76: command = .select
        case 53, 51: command = .back
        case 49: command = .playPause
        default:
            switch event.charactersIgnoringModifiers {
            case "h": command = .home
            case "m": command = .mute
            case "-", "_": command = .volumeDown
            case "=", "+": command = .volumeUp
            case "/", "k":
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { drawer = .keyboard }
                return true
            default: command = nil
            }
        }
        guard let command else { return false }
        // Only the arrows auto-repeat; a held Space should not toggle play
        // back and forth.
        let isArrow = [123, 124, 125, 126].contains(event.keyCode)
        if event.isARepeat && !isArrow { return true }
        Task { await state.send(command) }
        return true
    }
}

@MainActor
final class KeyMonitor: ObservableObject {
    private var token: Any?

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handler(event) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

// MARK: - Entrance

private struct Entrance: ViewModifier {
    let shown: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(delay), value: shown)
    }
}

private extension View {
    func entrance(_ shown: Bool, delay: Double) -> some View {
        modifier(Entrance(shown: shown, delay: delay))
    }
}

// MARK: - Header

private struct Header: View {
    @ObservedObject var state: AppState
    @Binding var drawer: Drawer?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: showDeviceMenu) {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "tv")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.accentSoft)
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surfaceRaised))
                        LinkDot(link: state.link)
                            .offset(x: 3, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(state.selected.map(state.displayName) ?? "Zapper")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .id(subtitle)
                            .transition(.opacity)
                    }
                    .animation(.easeOut(duration: 0.2), value: subtitle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch TV and more")

            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
                .opacity(state.isBusy ? 1 : 0)
                .animation(.easeOut, value: state.isBusy)

            CastButton(state: state, drawer: $drawer)
            PowerButton(state: state)
        }
    }

    private var subtitle: String {
        guard state.selected != nil else {
            return state.devices.isEmpty ? "Google TV & Android TV remote" : "No TV connected"
        }
        switch state.link {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .offline: return "Unreachable"
        case .online:
            if state.usingBluetooth {
                return state.bridgeTVConnected == true ? "Bluetooth · TV connected"
                                                       : "Bluetooth · pair it on the TV"
            }
            if state.isOn == false { return "Screen off" }
            return state.currentAppLabel.isEmpty ? "Connected" : "Connected · \(state.currentAppLabel)"
        }
    }

    private func showDeviceMenu() {
        var entries: [PopupMenu.Entry] = []
        let nearby = state.devicesNearby
        let elsewhere = state.devicesElsewhere
        func item(_ device: Device, symbol: String) -> PopupMenu.Entry {
            .item(state.displayName(device), symbol: symbol,
                  checked: device.id == state.selected?.id) { [state] in
                state.select(device.id)
            }
        }
        if !state.devices.isEmpty || state.bridgePlugged {
            entries.append(.header(state.isScanning && nearby.isEmpty
                                   ? "On this network (scanning…)" : "On this network"))
            entries += nearby.map { item($0, symbol: "tv") }
            if nearby.isEmpty { entries.append(.header("   None found yet")) }
            if state.bridgePlugged || state.usingBluetooth {
                entries.append(.separator)
                entries.append(.header("Bluetooth"))
                entries.append(.item(Device.bluetoothBridge.name, symbol: "dot.radiowaves.left.and.right",
                                     checked: state.usingBluetooth) { [state] in
                    state.select(Device.bluetoothBridge.id)
                })
            }
            if !elsewhere.isEmpty {
                entries.append(.separator)
                entries.append(.header("Saved, not found here"))
                entries += elsewhere.map { item($0, symbol: "clock.arrow.circlepath") }
            }
            entries.append(.separator)
        }
        let busy = state.isBusy
        entries.append(.item("Find TVs on this network", symbol: "magnifyingglass",
                             enabled: !busy && !state.isScanning) { [state] in
            Task { await state.discover() }
        })
        if let device = state.selected {
            entries.append(.item("Disconnect from \(device.name)", symbol: "xmark.circle") { [state] in
                state.disconnect()
            })
        }
        if let device = state.selected, !device.isBluetoothBridge {
            entries += [
                .item("Pair with this TV…", symbol: "link", enabled: !busy) { [state] in
                    Task { await state.pair() }
                },
                .item("Test connection", symbol: "checkmark.shield", enabled: !busy) { [state] in
                    Task { await state.probe() }
                },
                .item("Wake with Wake-on-LAN", symbol: "bolt.horizontal",
                      enabled: device.mac != nil && !busy) { [state] in
                    Task { await state.wake() }
                },
                .item("Forget \(device.name)", symbol: "trash") { [state] in
                    state.forget(device)
                },
            ]
        }
        entries += [
            .separator,
            .item("Open log", symbol: "doc.text") { [state] in state.openLog() },
            .item("Quit Zapper", symbol: "power") { NSApplication.shared.terminate(nil) },
        ]
        PopupMenu.show(entries)
    }
}

/// Connection light. Breathes while connecting.
private struct LinkDot: View {
    let link: AppState.Link
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(Theme.backgroundTop, lineWidth: 2))
            .shadow(color: color.opacity(0.8), radius: link == .online ? 4 : 0)
            .opacity(link == .connecting && pulse ? 0.35 : 1)
            .onAppear(perform: restart)
            .onChange(of: link) { _ in restart() }
    }

    private var color: Color {
        switch link {
        case .online: return Theme.online
        case .connecting: return Theme.accentSoft
        case .offline: return Theme.warning
        case .idle: return Theme.textTertiary
        }
    }

    private func restart() {
        pulse = false
        guard link == .connecting else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// The reference's glowing power button. Lit while the screen is on, with a
/// slow halo; dim when the TV reports it is off.
private struct PowerButton: View {
    @ObservedObject var state: AppState
    @State private var halo = false

    private var on: Bool { state.isOn == true && state.isOnline }

    var body: some View {
        Button { Task { await state.togglePower() } } label: {
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(on ? 0.5 : 0), lineWidth: 2)
                    .scaleEffect(halo ? 1.35 : 1)
                    .opacity(halo ? 0 : 1)
                Circle()
                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [Theme.accentSoft, Theme.accent],
                                                            startPoint: .top, endPoint: .bottom))
                             : AnyShapeStyle(Theme.surfaceRaised))
                    .overlay(Circle().strokeBorder(on ? Color.white.opacity(0.25) : Theme.stroke))
                    .shadow(color: Theme.accent.opacity(on ? 0.7 : 0), radius: 14)
                Image(systemName: "power")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Theme.accentSoft)
            }
            .frame(width: 50, height: 50)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .disabled(state.selected == nil)
        .help(on ? "Turn the TV off" : "Turn the TV on")
        .animation(.easeInOut(duration: 0.35), value: on)
        .onAppear(perform: restartHalo)
        .onChange(of: on) { _ in restartHalo() }
    }

    private func restartHalo() {
        halo = false
        guard on else { return }
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { halo = true }
    }
}

/// Opens the Cast drawer. Filled while something is casting, as Cast
/// buttons conventionally are.
private struct CastButton: View {
    @ObservedObject var state: AppState
    @Binding var drawer: Drawer?

    private var active: Bool { state.casting != nil }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                drawer = drawer == .cast ? nil : .cast
            }
        } label: {
            Image(systemName: Drawer.cast.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.accentSoft)
                .frame(width: 38, height: 38)
                .background(Circle().fill(active ? AnyShapeStyle(Theme.accent)
                                                 : AnyShapeStyle(Theme.surfaceRaised)))
                .overlay(Circle().strokeBorder(drawer == .cast ? Theme.accent : Theme.stroke))
                .shadow(color: Theme.accent.opacity(active ? 0.6 : 0), radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        // Cast streams over the network; the Bluetooth adapter cannot carry it.
        .disabled(state.selected == nil || state.isPairing || state.usingBluetooth)
        .help(active ? "Casting \(state.casting?.title ?? "")" : "Cast a video, photo or song to the TV")
        .animation(.easeInOut(duration: 0.3), value: active)
    }
}

private struct PressScale: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Offline

private struct OfflineBanner: View {
    @ObservedObject var state: AppState
    let reason: String

    private var needsPairing: Bool { reason.contains("Pair") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: needsPairing ? "link.badge.plus" : "wifi.exclamationmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 20)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if needsPairing {
                    Button("Pair") { Task { await state.pair() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                Button("Retry") { state.reconnect() }
                    .buttonStyle(PillButtonStyle(prominent: !needsPairing))
                if !needsPairing, state.selected?.mac != nil {
                    Button("Wake") { Task { await state.wake() } }
                        .buttonStyle(PillButtonStyle())
                }
                if !needsPairing {
                    Button("Pair again") { Task { await state.pair() } }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .disabled(state.isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.warning.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.warning.opacity(0.35)))
    }
}

// MARK: - Empty

private struct EmptyStateView: View {
    @ObservedObject var state: AppState
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Theme.accent.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 70, height: 70)
                        .scaleEffect(sweep ? 2.1 : 1)
                        .opacity(sweep ? 0 : (state.isBusy ? 0.8 : 0))
                        .animation(state.isBusy
                                   ? .easeOut(duration: 1.8).repeatForever(autoreverses: false)
                                        .delay(Double(i) * 0.6)
                                   : .default,
                                   value: sweep)
                }
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                         center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140)
                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accentSoft)
            }
            .frame(height: 170)

            VStack(spacing: 6) {
                Text(state.isBusy ? "Looking for TVs…" : "No TVs yet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Works with any Google TV or Android TV: Chromecast, Google TV "
                   + "Streamer, Sony, TCL, Philips, Hisense, Xiaomi, Nvidia Shield. "
                   + "Turn the TV on and join this Wi-Fi network.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(state.isBusy ? "Searching…" : "Find TVs") { Task { await state.discover() } }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(state.isBusy)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onChange(of: state.isBusy) { busy in sweep = busy }
    }
}

// MARK: - Pairing

private struct PairingView: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    private var code: [Character] { Array(state.pairingCode) }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accentSoft)
                .padding(.top, 6)

            VStack(spacing: 5) {
                Text("Enter the code on your TV")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(state.selected?.name ?? "The TV") is showing a 6-character code.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                // The real field sits invisibly underneath the boxes.
                TextField("", text: $state.pairingCode)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .focused($focused)
                    .onChange(of: state.pairingCode) { new in
                        // The code is hexadecimal; keep only those characters.
                        let cleaned = String(new.uppercased().filter { $0.isHexDigit }.prefix(6))
                        if cleaned != new { state.pairingCode = cleaned }
                    }
                    .onSubmit { state.submitPairingCode() }
                    .opacity(0.02)

                HStack(spacing: 7) {
                    ForEach(0..<6, id: \.self) { i in box(i) }
                }
                .allowsHitTesting(false)
            }
            .frame(height: 50)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            HStack(spacing: 8) {
                Button("Cancel") { state.cancelPairing() }
                    .buttonStyle(PillButtonStyle())
                Button("Pair") { state.submitPairingCode() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(state.pairingCode.count < 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } }
    }

    private func box(_ i: Int) -> some View {
        let filled = i < code.count
        let current = i == code.count && focused
        return Text(filled ? String(code[i]) : "")
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.text)
            .frame(width: 40, height: 50)
            .background(RoundedRectangle(cornerRadius: 11).fill(filled ? Theme.surfaceRaised : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(current ? Theme.accent : filled ? Theme.accent.opacity(0.35) : Theme.stroke,
                              lineWidth: current ? 1.5 : 1))
            .scaleEffect(filled ? 1 : 0.96)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: filled)
            .animation(.easeOut(duration: 0.15), value: current)
    }
}

// MARK: - Footer

private struct Footer: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(state.status)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(state.status)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity))
            if state.selected != nil && !state.isPairing {
                Text("↑↓←→ ⏎ ⎋ space")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Your Mac keyboard drives the TV while this panel is open. "
                        + "H home, M mute, −/= volume, / keyboard.")
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.status)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private var icon: String {
        state.status.hasPrefix("Sent") ? "checkmark" : "info.circle"
    }
}

/// Carries the panel's natural height up to `MenuContent`.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Hands back the window a view is in, once it has one.
///
/// Reports only changes: storing the window re-renders the view, and
/// reporting on every update would loop.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    final class Coordinator {
        weak var reported: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        report(view, context.coordinator)
    }

    private func report(_ view: NSView, _ coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window, window !== coordinator.reported else { return }
            coordinator.reported = window
            found(window)
        }
    }
}

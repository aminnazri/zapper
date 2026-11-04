import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ATVKit

/// The four feature tiles along the bottom. Each opens a drawer beneath the
/// row rather than a menu, so everything stays in the panel's own style and
/// the keyboard drawer can hold a live text field.
enum Drawer: String, CaseIterable, Identifiable {
    case input, apps, media, keyboard
    /// Opened from the cast button in the header rather than a tile.
    case cast
    var id: String { rawValue }

    static let tiles: [Drawer] = [.input, .apps, .media, .keyboard]

    var title: String {
        switch self {
        case .input: return "Input"
        case .apps: return "Apps"
        case .media: return "Media"
        case .keyboard: return "Keyboard"
        case .cast: return "Cast"
        }
    }

    var symbol: String {
        switch self {
        case .input: return "rectangle.on.rectangle"
        case .apps: return "square.grid.2x2"
        case .media: return "playpause"
        case .keyboard: return "keyboard"
        case .cast: return "tv.badge.wifi"
        }
    }
}

struct TileRow: View {
    @ObservedObject var state: AppState
    @Binding var open: Drawer?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Drawer.tiles) { drawer in
                Tile(drawer: drawer,
                     subtitle: subtitle(for: drawer),
                     badge: drawer == .keyboard && state.textFieldReady,
                     isOpen: open == drawer) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        open = open == drawer ? nil : drawer
                    }
                }
            }
        }
    }

    private func subtitle(for drawer: Drawer) -> String {
        switch drawer {
        case .input: return "Source"
        case .apps: return state.currentAppLabel.isEmpty ? "Launch" : state.currentAppLabel
        case .media: return "Playback"
        case .keyboard: return state.textFieldReady ? "Ready" : "Type"
        case .cast: return ""
        }
    }
}

private struct Tile: View {
    let drawer: Drawer
    let subtitle: String
    let badge: Bool
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: drawer.symbol)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(isOpen ? Color.white : Theme.accentSoft)
                    Spacer(minLength: 0)
                    if badge {
                        Circle().fill(Theme.online)
                            .frame(width: 7, height: 7)
                            .shadow(color: Theme.online, radius: 4)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                Spacer(minLength: 10)
                Text(drawer.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .id(subtitle)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .card(radius: 16, highlighted: isOpen)
            .scaleEffect(hovering && !isOpen ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .animation(.easeOut(duration: 0.2), value: subtitle)
            .animation(.easeOut(duration: 0.2), value: badge)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(drawer.title), \(subtitle)")
    }
}

// MARK: - Drawers

struct DrawerContent: View {
    @ObservedObject var state: AppState
    let drawer: Drawer

    var body: some View {
        Group {
            switch drawer {
            case .input: InputDrawer(state: state)
            case .apps: AppsDrawer(state: state)
            case .media: MediaDrawer(state: state)
            case .keyboard: KeyboardDrawer(state: state)
            case .cast: CastDrawer(state: state)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(ChipStyle(lit: lit))
    }
}

private struct ChipStyle: ButtonStyle {
    var lit = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let active = configuration.isPressed || lit
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.4) : Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(active ? Theme.accent : Theme.stroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: active)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct DrawerCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InputDrawer: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Chip(title: "Input list", symbol: "list.bullet",
                     lit: state.lastPressed == .input(0)) { send(0) }
                ForEach(1...4, id: \.self) { n in
                    Chip(title: "HDMI \(n)", symbol: "cable.connector",
                         lit: state.lastPressed == .input(n)) { send(n) }
                }
            }
            DrawerCaption("Input list opens the TV\u{2019}s own list of inputs; pick one with the "
                        + "arrows and OK. The HDMI keys jump straight there, but many TVs (Xiaomi "
                        + "included) ignore them. Streaming sticks and boxes have no inputs.")
        }
    }

    private func send(_ n: Int) { Task { await state.send(.input(n)) } }
}

private struct AppsDrawer: View {
    @ObservedObject var state: AppState
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(QuickApp.all) { app in
                    Chip(title: app.name, symbol: app.symbol,
                         lit: state.lastPressed == .launchApp(app.link)) {
                        Task { await state.send(.launchApp(app.link)) }
                    }
                }
            }
            DrawerCaption("Opens the app if it is installed on the TV.")
        }
    }
}

private struct MediaDrawer: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                key("backward.end.fill", .previous, "Previous")
                Spacer(minLength: 0)
                key("backward.fill", .rewind, "Rewind")
                Spacer(minLength: 0)
                key("playpause.fill", .playPause, "Play / pause (Space)", size: 52)
                Spacer(minLength: 0)
                key("forward.fill", .fastForward, "Fast forward")
                Spacer(minLength: 0)
                key("forward.end.fill", .next, "Next")
            }
            HStack(spacing: 6) {
                Chip(title: "Guide", symbol: "list.bullet.rectangle",
                     lit: state.lastPressed == .guide) { Task { await state.send(.guide) } }
                Chip(title: "Menu", symbol: "line.3.horizontal",
                     lit: state.lastPressed == .menu) { Task { await state.send(.menu) } }
                Chip(title: "Search", symbol: "magnifyingglass",
                     lit: state.lastPressed == .search) { Task { await state.send(.search) } }
            }
        }
    }

    private func key(_ symbol: String, _ command: RemoteCommand, _ help: String,
                     size: CGFloat = 42) -> some View {
        Button { Task { await state.send(command) } } label: { Image(systemName: symbol) }
            .buttonStyle(RoundKeyStyle(size: size, lit: state.lastPressed == command))
            .help(help)
    }
}

/// Sends a file from this Mac, or a web link, to the TV's Chromecast receiver.
private struct CastDrawer: View {
    @ObservedObject var state: AppState
    @State private var link = ""
    @FocusState private var linkFocused: Bool
    @State private var pickingScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let offer = state.youTubeOffer {
                YouTubeOfferCard(state: state, offer: offer)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let now = state.casting {
                NowCasting(state: state, now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 6) {
                Chip(title: "Screen", symbol: "display",
                     lit: pickingScreen || state.casting?.isMirror == true) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) { pickingScreen.toggle() }
                }
                .help("Share the whole screen, one app, one window or a browser tab")
                Chip(title: "Video", symbol: "film") { CastPicker.choose(.movie, for: state) }
                Chip(title: "Photo", symbol: "photo") { CastPicker.choose(.image, for: state) }
                Chip(title: "Music", symbol: "music.note") { CastPicker.choose(.audio, for: state) }
            }
            .disabled(state.selected == nil)

            if pickingScreen {
                ScreenSourcePicker(state: state) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) { pickingScreen = false }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(linkFocused ? Theme.accentSoft : Theme.textTertiary)
                TextField("Paste a YouTube or video link…", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($linkFocused)
                    .onSubmit(castLink)
                if !link.isEmpty {
                    Button(action: castLink) { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentSoft)
                        .help("Cast this link")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(linkFocused ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: link.isEmpty)
            .animation(.easeOut(duration: 0.15), value: linkFocused)

            DrawerCaption("Or drop a file anywhere on this panel. MP4, WebM, MP3, "
                        + "JPEG and PNG play best. The TV streams from this Mac, so keep it awake.")
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: state.casting?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: state.youTubeOffer)
        .onAppear { if Snapshotter.opensScreenPicker { pickingScreen = true } }
    }

    private func castLink() {
        guard !link.isEmpty else { return }
        state.cast(link: link)
        link = ""
        linkFocused = false
    }
}

/// Chooses what a screen cast shows: a display, an app, a window or a
/// browser tab. Lists afresh each time a section is opened, since windows
/// come and go.
private struct ScreenSourcePicker: View {
    @ObservedObject var state: AppState
    let picked: () -> Void
    @State private var kind: ScreenChoice.Kind = .display
    @State private var choices: [ScreenChoice]?
    @State private var pageCropAllowed = PageTracker.isTrusted
    /// Real-time mirror frame rate, remembered between launches.
    @AppStorage(AppState.mirrorFPSKey) private var mirrorFPS = 60
    /// Real-time mirror picture quality, remembered between launches.
    @AppStorage(AppState.mirrorQualityKey) private var mirrorQuality = ScreenMirror.Quality.balanced.rawValue

    private var shown: [ScreenChoice] { choices?.filter { $0.kind == kind } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(ScreenChoice.Kind.allCases, id: \.self) { segment($0) }
            }
            .padding(3)
            .background(Capsule().fill(Color.black.opacity(0.3)))

            if !ScreenStream.hasPermission {
                HStack(spacing: 8) {
                    Button("Allow Screen Recording\u{2026}") { state.askForScreenRecording() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    Button("Relaunch") { state.relaunch() }
                        .buttonStyle(PillButtonStyle())
                }
                DrawerCaption("Turn Zapper on in System Settings, then press Relaunch: "
                            + "macOS only applies the change to a fresh start.")
            } else if choices == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if shown.isEmpty {
                DrawerCaption(kind == .tab ? "No browser windows are open."
                                           : "Nothing to share on this screen right now.")
            } else {
                ScrollView(.vertical, showsIndicators: shown.count > 4) {
                    VStack(spacing: 4) {
                        ForEach(shown) { row($0) }
                    }
                }
                .frame(maxHeight: 176)
                .fixedSize(horizontal: false, vertical: shown.count <= 4)
            }

            if kind == .display, ScreenStream.hasPermission {
                qualityPicker
                fpsPicker
            }

            caption
        }
        .task(id: kind) {
            pageCropAllowed = PageTracker.isTrusted
            guard ScreenStream.hasPermission else { return }
            choices = (try? await ScreenSources.list()) ?? []
        }
    }

    /// Resolution and data rate for the real-time (Screen) mirror. Takes
    /// effect on the next cast.
    private var qualityPicker: some View {
        settingRow("Quality", symbol: "sparkles.tv",
                   options: ScreenMirror.Quality.allCases.map { ($0.rawValue, $0.label) },
                   selection: $mirrorQuality, width: 46)
            .help("540p is lightest on Wi-Fi; 1080p is sharpest but needs a strong signal. "
                + "Applies to the next Screen cast.")
    }

    /// A labelled row of capsule options, shared by the quality and frame
    /// rate settings.
    private func settingRow(_ title: String, symbol: String, options: [(String, String)],
                            selection: Binding<String>, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { value, label in
                    let selected = value == selection.wrappedValue
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = value }
                    } label: {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                            .frame(width: width, height: 22)
                            .background(Capsule().fill(selected ? Theme.accent : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.black.opacity(0.3)))
        }
    }

    /// Frame-rate choice for the real-time (Screen) mirror. Takes effect on
    /// the next cast.
    private var fpsPicker: some View {
        settingRow("Frame rate", symbol: "speedometer",
                   options: AppState.mirrorFPSOptions.map { ("\($0)", "\($0)") },
                   selection: Binding(get: { "\(mirrorFPS)" },
                                      set: { mirrorFPS = Int($0) ?? 60 }),
                   width: 34)
            .help("Higher is smoother; lower is lighter on Wi-Fi. Applies to the next Screen cast.")
    }

    @ViewBuilder private var caption: some View {
        switch kind {
        case .display:
            DrawerCaption("Shows whichever Space is active on that display. "
                        + "Real-time — about a quarter-second behind.")
        case .app:
            DrawerCaption("Only that app\u{2019}s windows are shown; everything else is black.")
        case .window:
            DrawerCaption("Stays on that window even when others cover it.")
        case .tab:
            if pageCropAllowed {
                DrawerCaption("Shows just the page \u{2014} whichever tab is in front in that window.")
            } else {
                HStack(spacing: 8) {
                    DrawerCaption("Shows the whole browser window. Allow Accessibility to crop it to the page.")
                    Button("Allow") {
                        PageTracker.requestTrust()
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private func segment(_ k: ScreenChoice.Kind) -> some View {
        let selected = k == kind
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { kind = k }
        } label: {
            Text(Self.label(k))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(selected ? Theme.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ choice: ScreenChoice) -> some View {
        Button {
            state.castScreen(choice)
            picked()
        } label: {
            HStack(spacing: 9) {
                icon(choice)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(choice.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accentSoft)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .buttonStyle(ChipStyle())
    }

    @ViewBuilder private func icon(_ choice: ScreenChoice) -> some View {
        if let pid = choice.pid, let image = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "display")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accentSoft)
        }
    }

    private static func label(_ kind: ScreenChoice.Kind) -> String {
        switch kind {
        case .display: return "Screen"
        case .app: return "App"
        case .window: return "Window"
        case .tab: return "Tab"
        }
    }
}

/// Shown when a shared browser page is a YouTube video. The TV's own app
/// plays it far better than a mirror: full quality, no delay, and it keeps
/// going while the Mac does other things.
private struct YouTubeOfferCard: View {
    @ObservedObject var state: AppState
    let offer: YouTubeOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play in the TV\u{2019}s YouTube app?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(offer.choice.title)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            DrawerCaption("Full quality and no delay, and it keeps playing while you use "
                        + "other apps. It starts from the beginning; skip ahead with the remote.")
            HStack(spacing: 8) {
                Button("Play on TV") { state.acceptYouTubeOffer() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("Mirror the tab") { state.declineYouTubeOffer() }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.4)))
    }
}

/// Title, progress and transport controls for the cast in progress.
struct NowCasting: View {
    @ObservedObject var state: AppState
    let now: CastNow
    var compact = false
    /// Where the scrubber is while being dragged; nil follows the TV.
    @State private var scrub: Double?

    private var playing: Bool {
        now.playback?.state == .playing || now.playback?.state == .buffering
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: now.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if now.isStarting {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    if !compact, now.playback?.duration != nil {
                        controlButton("gobackward.10", "Back 10 seconds") { state.skipCast(by: -10) }
                    }
                    if now.symbol != "photo" {
                        controlButton(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play") {
                            state.toggleCastPlayback()
                        }
                    }
                    if !compact, now.playback?.duration != nil {
                        controlButton("goforward.30", "Forward 30 seconds") { state.skipCast(by: 30) }
                    }
                }
                controlButton("stop.fill", "Stop casting") { state.stopCasting() }
            }

            if now.sourceHidden, now.sourceFullScreen {
                HStack(spacing: 8) {
                    Text("Full screen pauses the TV whenever another app is in front.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Exit full screen") { state.exitSharedFullScreen() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            }

            if !compact, let duration = now.playback?.duration {
                VStack(spacing: 3) {
                    Slider(value: Binding(get: { scrub ?? min(now.playback?.position ?? 0, duration) },
                                          set: { scrub = $0 }),
                           in: 0...duration) { editing in
                        if !editing, let target = scrub {
                            state.seekCast(to: target)
                            scrub = nil
                        }
                    }
                    .controlSize(.mini)
                    .tint(Theme.accent)
                    HStack {
                        Text(Self.time(scrub ?? now.playback?.position ?? 0))
                        Spacer()
                        Text(Self.time(duration))
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(compact ? 8 : 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.4)))
    }

    private var subtitle: String {
        if now.isStarting { return "Starting on \(now.deviceName)…" }
        if now.isMirror, now.sourceHidden {
            return "Off this screen \u{2014} TV shows the last picture"
        }
        if now.isMirror {
            return now.playback?.state == .paused ? "Paused on \(now.deviceName)"
                                                  : "Mirroring to \(now.deviceName)"
        }
        switch now.playback?.state {
        case .buffering: return "Loading on \(now.deviceName)…"
        case .paused: return "Paused on \(now.deviceName)"
        default: return "Playing on \(now.deviceName)"
        }
    }

    private func controlButton(_ symbol: String, _ help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(RoundKeyStyle(size: 30))
            .help(help)
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The open panel takes key focus, which closes the menu bar panel. That is
/// fine: casting lives in AppState and carries on without the panel.
@MainActor
enum CastPicker {
    static func choose(_ type: UTType, for state: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Cast to \(state.selected?.name ?? "TV")"
        panel.prompt = "Cast"
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            state.cast(file: url)
        }
    }
}

struct KeyboardDrawer: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    private var query: String { state.typedText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 12))
                    .foregroundStyle(focused ? Theme.accentSoft : Theme.textTertiary)
                TextField("Search or type to the TV…", text: $state.typedText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    // Each edit is forwarded immediately, so the TV's field
                    // tracks this one keystroke by keystroke.
                    .onChange(of: state.typedText) { _ in state.typedTextChanged() }
                    // Return confirms the TV's field when one is open, and
                    // otherwise runs the search.
                    .onSubmit {
                        Task {
                            if state.textFieldReady {
                                await state.submitTypedText()
                            } else {
                                await state.searchYouTube()
                            }
                        }
                    }
                if !state.typedText.isEmpty {
                    Button { state.clearTypedText() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Clear (also erases it on the TV)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: state.typedText.isEmpty)
            .animation(.easeOut(duration: 0.15), value: focused)

            if state.usingBluetooth {
                Button { Task { await state.submitTypedText() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "return")
                        Text("Enter on TV")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .help("Presses Enter on the TV (Return)")
            } else if state.textFieldReady {
                // A box is open on the TV, in whatever app: submit it there.
                HStack(spacing: 6) {
                    Image(systemName: "tv")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.online)
                    Text("On TV:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(state.tvFieldText.map { $0.isEmpty ? "empty" : "\u{201C}\($0)\u{201D}" } ?? "…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .id(state.tvFieldText)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
                .animation(.easeOut(duration: 0.15), value: state.tvFieldText)

                Button { Task { await state.submitTypedText() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                        Text("Search on TV")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .help("Submits the TV\u{2019}s search box, like Enter on its keyboard (Return)")
                .transition(.opacity)
            } else {
                Button { Task { await state.searchYouTube() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.rectangle.fill")
                        Text(query.isEmpty ? "Search YouTube" : "Search YouTube for \u{201C}\(query)\u{201D}")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(query.isEmpty || state.selected == nil)
                .help("No text box is open on the TV, so this opens YouTube with the search instead.")
                .transition(.opacity)
            }

            HStack(spacing: 6) {
                Chip(title: "Delete", symbol: "delete.left",
                     lit: state.lastPressed == .backspace) { Task { await state.send(.backspace) } }
                Chip(title: "Enter", symbol: "return",
                     lit: state.lastPressed == .enter) { Task { await state.submitTypedText() } }
            }

            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(state.textFieldReady ? Theme.online : Theme.textTertiary)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
                DrawerCaption(state.usingBluetooth
                              ? "Typed as real keystrokes over Bluetooth, into whatever is selected "
                                + "on the TV. Digits and symbols work too; other alphabets don\u{2019}t."
                              : state.textFieldReady
                              ? "A text box is open on the TV. What you type here appears in it, "
                                + "typed on the TV\u{2019}s own keyboard if the TV needs that."
                              : "Open any search or text box on the TV and type here: it fills in "
                                + "on the TV. Or press Return to search YouTube.")
            }
            .animation(.easeOut(duration: 0.2), value: state.textFieldReady)
        }
        .onAppear {
            // Give the drawer's spring a moment before taking focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }
}

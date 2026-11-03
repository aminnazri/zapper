import SwiftUI
import ATVKit

// MARK: - D-pad ring

/// Circular D-pad: four arc segments around an OK button.
///
/// One gesture covers the whole ring and the region is worked out from the
/// touch point, so the hit areas are true wedges rather than the rectangles
/// separate buttons would give. Holding a direction repeats it, like a real
/// remote scrolling a long list.
struct DPadRing: View {
    @ObservedObject var state: AppState

    private enum Region: Equatable {
        case up, down, left, right, center
        var command: RemoteCommand {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            case .center: return .select
            }
        }
        /// Angle of the segment's middle, clockwise from 3 o'clock.
        var angle: Double {
            switch self {
            case .right: return 0
            case .down: return 90
            case .left: return 180
            case .up, .center: return 270
            }
        }
    }

    private let diameter: CGFloat = 188
    private let centerDiameter: CGFloat = 78

    @State private var touched: Region?
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Soft glow underneath, like the light spill in the reference.
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.22), .clear],
                                     center: .center, startRadius: 10, endRadius: diameter * 0.75))
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .allowsHitTesting(false)

            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                .frame(width: diameter, height: diameter)

            ForEach([Region.up, .right, .down, .left], id: \.angle) { region in
                segmentHighlight(region)
            }

            chevron("chevron.up").offset(y: -ringRadius)
            chevron("chevron.down").offset(y: ringRadius)
            chevron("chevron.left").offset(x: -ringRadius)
            chevron("chevron.right").offset(x: ringRadius)

            centerButton
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard touched == nil else { return }
                    guard let region = region(at: value.startLocation) else { return }
                    press(region)
                }
                .onEnded { _ in release() }
        )
        .opacity(state.selected == nil ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Direction pad")
    }

    /// Radius of the ring's centre line, where the chevrons sit.
    private var ringRadius: CGFloat { (diameter / 2 + centerDiameter / 2 + 6) / 2 }

    private func isLit(_ region: Region) -> Bool {
        touched == region || state.lastPressed == region.command
    }

    private func segmentHighlight(_ region: Region) -> some View {
        let width = diameter / 2 - centerDiameter / 2 - 8
        return Circle()
            .trim(from: 0, to: 0.25)
            .stroke(
                AngularGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.65),
                                         Theme.accent.opacity(0)],
                                center: .center, startAngle: .degrees(0), endAngle: .degrees(90)),
                lineWidth: width
            )
            .frame(width: diameter - width - 4, height: diameter - width - 4)
            .rotationEffect(.degrees(region.angle - 45))
            .opacity(isLit(region) ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: isLit(region))
            .allowsHitTesting(false)
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .allowsHitTesting(false)
    }

    private var centerButton: some View {
        let lit = isLit(.center)
        return Circle()
            .fill(LinearGradient(colors: [Theme.accentSoft, Theme.accent],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .overlay(Text("OK").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
            .frame(width: centerDiameter, height: centerDiameter)
            .shadow(color: Theme.accent.opacity(lit ? 0.9 : 0.45), radius: lit ? 18 : 10)
            .scaleEffect(lit ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: lit)
            .allowsHitTesting(false)
    }

    private func region(at point: CGPoint) -> Region? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance <= centerDiameter / 2 + 2 { return .center }
        guard distance <= diameter / 2 + 4 else { return nil }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    private func press(_ region: Region) {
        guard state.selected != nil else { return }
        touched = region
        Task { await state.send(region.command) }
        guard region != .center else { return }
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            while !Task.isCancelled {
                await state.send(region.command)
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }

    private func release() {
        repeatTask?.cancel()
        repeatTask = nil
        touched = nil
    }
}

// MARK: - Volume

/// Big readout plus gradient slider — the reference's temperature block,
/// driving the TV's volume.
struct VolumePanel: View {
    @ObservedObject var state: AppState

    /// The slider position while the pointer is down. Kept local so the
    /// device's own reports, arriving mid-drag, cannot yank the thumb back.
    @State private var dragLevel: Int?

    private var known: Bool { state.volumeLevel != nil && (state.volumeMax ?? 0) > 0 }
    private var top: Int { max(state.volumeMax ?? 100, 1) }
    private var shownLevel: Int? { dragLevel ?? state.volumeTarget ?? state.volumeLevel }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                readout
                Spacer(minLength: 8)
                muteToggle
            }

            HStack(spacing: 12) {
                stepButton("minus", .volumeDown)
                if known {
                    slider
                } else {
                    unknownTrack
                }
                stepButton("plus", .volumeUp)
            }

            if known {
                HStack {
                    Text("0")
                    Spacer()
                    Text("\(top)")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 64)
                .padding(.top, -6)
            }
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(shownLevel.map(String.init) ?? "–")
                .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(state.isMuted || shownLevel == nil ? Theme.textTertiary : Theme.text)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: shownLevel)
                .strikethrough(state.isMuted, color: Theme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("VOL")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accentSoft)
                Text(state.isMuted ? "muted" : known ? "of \(top)" : "TV volume")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The reference's "Eco Mode" switch, as mute.
    private var muteToggle: some View {
        Button { Task { await state.send(.mute) } } label: {
            HStack(spacing: 9) {
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.isMuted ? Theme.warning : Theme.textSecondary)
                    .frame(width: 16)
                Text("Mute")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                ZStack(alignment: state.isMuted ? .trailing : .leading) {
                    Capsule().fill(state.isMuted ? Theme.warning.opacity(0.85) : Color.white.opacity(0.14))
                        .frame(width: 34, height: 20)
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.isMuted)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            .card(radius: 14, highlighted: state.lastPressed == .mute)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(state.selected == nil)
        .help("Mute (M)")
    }

    private func stepButton(_ symbol: String, _ command: RemoteCommand) -> some View {
        Button { Task { await state.send(command) } } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(RoundKeyStyle(size: 40, lit: state.lastPressed == command))
        .disabled(state.selected == nil)
        .help(command == .volumeUp ? "Volume up (=)" : "Volume down (−)")
    }

    private var slider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumb: CGFloat = 30
            let fraction = CGFloat(shownLevel ?? 0) / CGFloat(top)
            let x = (width - thumb) * min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                // The gradient spans the whole track and the level reveals
                // it, so loud reads violet rather than squeezing every colour
                // into the filled part.
                Capsule()
                    .fill(Theme.volumeGradient)
                    .mask(alignment: .leading) { Capsule().frame(width: x + thumb) }
                    .shadow(color: Theme.violet.opacity(0.35), radius: 10)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white)
                    .frame(width: thumb, height: 34)
                    .shadow(color: Theme.accentSoft.opacity(0.7), radius: dragLevel == nil ? 6 : 12)
                    .offset(x: x)
            }
            .frame(height: 38)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = (value.location.x - thumb / 2) / max(width - thumb, 1)
                        let level = Int((min(max(f, 0), 1) * CGFloat(top)).rounded())
                        guard level != dragLevel else { return }
                        dragLevel = level
                        state.setVolume(level)
                    }
                    .onEnded { _ in dragLevel = nil }
            )
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(shownLevel.map { "\($0) of \(top)" } ?? "unknown")
        .accessibilityAdjustableAction { direction in
            Task { await state.send(direction == .increment ? .volumeUp : .volumeDown) }
        }
    }

    /// The device has not reported a level — common on streamers whose volume
    /// is the TV's, over CEC. Keys still work; only the slider cannot.
    private var unknownTrack: some View {
        Capsule()
            .fill(Color.black.opacity(0.35))
            .overlay(
                Text(state.isOnline ? "Level not reported by this device" : "Connect to see the level")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            )
            .frame(height: 38)
    }
}

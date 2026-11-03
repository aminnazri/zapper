import SwiftUI
import AppKit
import ATVKit

/// A pad that moves a TV browser's cursor, standing in for a mouse.
///
/// The remote protocol has no pointer messages — only keys. TV browsers with
/// a cursor (TV Bro, Puffin, com.internet.tvbrowser) move it for as long as
/// an arrow is *held*, gliding and speeding up; a tap barely moves it. So the
/// pad holds arrows while the pointer moves and lets go when it stops:
///
///  - Drag: holds the arrows for the drag's direction (two at once for a
///    diagonal) until the drag turns or ends.
///  - Two-finger swipe on the Mac's trackpad, or a scroll wheel: holds the
///    arrows the fingers are moving towards, releasing when they stop.
///  - Click: OK.
///
/// Over the Bluetooth adapter the TV has a real mouse instead, and the pad
/// works like a laptop trackpad: moving over it moves the TV's pointer,
/// clicking clicks, two fingers scroll.
struct TouchPad: View {
    @ObservedObject var state: AppState
    @StateObject private var driver = PointerDriver()
    @StateObject private var mouse = MouseRelay()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(driver.held.isEmpty ? Theme.stroke : Theme.accent.opacity(0.55),
                                      lineWidth: 1)
                )
                .overlay(dots)
                .animation(.easeOut(duration: 0.15), value: driver.held.isEmpty)

            // Rest position of the knob.
            Circle()
                .strokeBorder(Theme.textTertiary.opacity(0.6), lineWidth: 1)
                .frame(width: 34, height: 34)

            knob

            VStack {
                Spacer()
                Text(state.usingBluetooth ? "Move over the pad · click · two fingers scroll"
                     : driver.held.isEmpty ? "Drag or swipe to move · click to select" : "Moving")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 10)
                    .animation(.easeOut(duration: 0.15), value: driver.held.isEmpty)
            }
            .allowsHitTesting(false)

            if state.usingBluetooth {
                PadSurface(
                    onDrag: { _ in },
                    onClick: { Task { await state.clickMouse() } },
                    onSwipe: { mouse.scroll($0.dy) },
                    onSwipeEnd: {},
                    onPointer: { mouse.move($0) }
                )
            } else {
                PadSurface(
                    onDrag: { driver.drag($0) },
                    onClick: { Task { await state.send(.select) } },
                    onSwipe: { driver.swipe($0) },
                    onSwipeEnd: { driver.endSwipe() }
                )
            }
        }
        .frame(width: 204, height: 188)
        .onAppear { driver.state = state; mouse.state = state }
        .onDisappear { driver.stop() }
        .opacity(state.selected == nil ? 0.4 : 1)
        .accessibilityElement()
        .accessibilityLabel("Touchpad")
        .accessibilityHint("Drag or swipe to move the TV cursor, click to select")
    }

    /// Sits in the middle at rest and leans towards the held direction.
    private var knob: some View {
        let lean: CGFloat = 46
        let x: CGFloat = driver.held.contains(.right) ? lean : driver.held.contains(.left) ? -lean : 0
        let y: CGFloat = driver.held.contains(.down) ? lean : driver.held.contains(.up) ? -lean : 0
        return Circle()
            .fill(LinearGradient(colors: [Theme.accentSoft, Theme.accent],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .frame(width: 30, height: 30)
            .shadow(color: Theme.accent.opacity(driver.held.isEmpty ? 0.4 : 0.9),
                    radius: driver.held.isEmpty ? 6 : 14)
            .offset(x: x, y: y)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: driver.held)
            .allowsHitTesting(false)
    }

    /// Faint dot grid, so the surface reads as a pad rather than a panel.
    private var dots: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            var y = step
            while y < size.height {
                var x = step
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                 with: .color(Color.white.opacity(0.07)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Holding keys

/// Keeps the TV's held arrows in step with the pointer.
///
/// Every hold and release goes through one queue, in order, so the TV never
/// sees a release before its hold — that would leave an arrow stuck down and
/// the cursor running on its own.
@MainActor
final class PointerDriver: ObservableObject {
    /// Arrows currently held on the TV, as far as the pad intends.
    @Published private(set) var held: Set<RemoteCommand> = []

    weak var state: AppState?

    private enum Op { case hold(RemoteCommand), release(RemoteCommand) }
    private var ops: [Op] = []
    private var worker: Task<Void, Never>?
    private var swipeIdle: Task<Void, Never>?

    /// Inside this radius a drag holds nothing, so a click with a slight
    /// wobble does not move the cursor.
    private let deadZone: CGFloat = 12

    /// Drag offset from where the press began; nil when the press ends.
    func drag(_ vector: CGVector?) {
        guard let vector else { set([]); return }
        set(arrows(for: vector, threshold: deadZone))
    }

    /// One scroll event's finger motion.
    func swipe(_ motion: CGVector) {
        let wanted = arrows(for: motion, threshold: 0.6)
        if !wanted.isEmpty { set(wanted) }
        // Fingers resting still send no events; let go shortly after.
        swipeIdle?.cancel()
        swipeIdle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.set([])
        }
    }

    func endSwipe() {
        swipeIdle?.cancel()
        set([])
    }

    func stop() {
        swipeIdle?.cancel()
        set([])
    }

    /// The arrows for a direction: the dominant axis always, the other too
    /// when it is at least half as strong, which makes diagonals.
    private func arrows(for v: CGVector, threshold: CGFloat) -> Set<RemoteCommand> {
        let ax = abs(v.dx), ay = abs(v.dy)
        guard max(ax, ay) > threshold else { return [] }
        var keys: Set<RemoteCommand> = []
        if ax >= ay * 0.5 { keys.insert(v.dx > 0 ? .right : .left) }
        if ay >= ax * 0.5 { keys.insert(v.dy > 0 ? .down : .up) }
        return keys
    }

    private func set(_ wanted: Set<RemoteCommand>) {
        guard wanted != held else { return }
        for key in held.subtracting(wanted) { ops.append(.release(key)) }
        for key in wanted.subtracting(held) { ops.append(.hold(key)) }
        held = wanted
        drain()
    }

    private func drain() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.ops.isEmpty {
                let op = self.ops.removeFirst()
                switch op {
                case .hold(let key): await self.state?.holdKey(key)
                case .release(let key): await self.state?.releaseKey(key)
                }
            }
            self?.worker = nil
        }
    }
}

// MARK: - Mouse

/// Turns Mac pointer motion into TV mouse counts. Fractions are carried over
/// so slow, fine movements still add up.
@MainActor
final class MouseRelay: ObservableObject {
    weak var state: AppState?
    /// TV pixels per Mac point. The pad is 204 points wide and the TV 1920
    /// pixels, and Android adds its own acceleration on top.
    private let gain: CGFloat = 2.2
    private var restX: CGFloat = 0, restY: CGFloat = 0, restWheel: CGFloat = 0

    func move(_ delta: CGVector) {
        restX += delta.dx * gain
        restY += delta.dy * gain
        let dx = Int(restX), dy = Int(restY)
        restX -= CGFloat(dx); restY -= CGFloat(dy)
        state?.moveMouse(dx: dx, dy: dy)
    }

    /// Scroll deltas in the Mac's own scroll direction (positive scrolls
    /// up, as a HID wheel does); one notch per 18 points.
    func scroll(_ dy: CGFloat) {
        restWheel += dy / 18
        let notches = Int(restWheel)
        restWheel -= CGFloat(notches)
        state?.scrollMouse(notches)
    }
}

// MARK: - Input

/// The AppKit surface under the pad. SwiftUI on macOS 13 has no scroll
/// gesture, and a trackpad swipe arrives only as scroll events.
private struct PadSurface: NSViewRepresentable {
    let onDrag: (CGVector?) -> Void
    let onClick: () -> Void
    let onSwipe: (CGVector) -> Void
    let onSwipeEnd: () -> Void
    /// Set in mouse mode: relative pointer motion over the pad, pressed or not.
    var onPointer: ((CGVector) -> Void)? = nil

    func makeNSView(context: Context) -> PadSurfaceView {
        let view = PadSurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ view: PadSurfaceView, context: Context) {
        update(view)
    }

    private func update(_ view: PadSurfaceView) {
        view.onDrag = onDrag
        view.onClick = onClick
        view.onSwipe = onSwipe
        view.onSwipeEnd = onSwipeEnd
        view.onPointer = onPointer
    }
}

final class PadSurfaceView: NSView {
    var onDrag: (CGVector?) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onSwipe: (CGVector) -> Void = { _ in }
    var onSwipeEnd: () -> Void = {}
    var onPointer: ((CGVector) -> Void)?

    private var pressStart: NSPoint?
    private var pressTime = Date()
    private var moved = false

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?(CGVector(dx: event.deltaX, dy: event.deltaY))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressStart = convert(event.locationInWindow, from: nil)
        pressTime = Date()
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let onPointer {
            onPointer(CGVector(dx: event.deltaX, dy: event.deltaY))
            moved = true
            return
        }
        guard let start = pressStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let v = CGVector(dx: p.x - start.x, dy: p.y - start.y)
        if v.dx * v.dx + v.dy * v.dy > 36 { moved = true }
        onDrag(v)
    }

    override func mouseUp(with event: NSEvent) {
        pressStart = nil
        onDrag(nil)
        if !moved && Date().timeIntervalSince(pressTime) < 0.5 { onClick() }
    }

    override func scrollWheel(with event: NSEvent) {
        if onPointer != nil {
            // Mouse mode scrolls pages, so momentum is welcome and the Mac's
            // deltas — already in the user's scroll direction — pass as is.
            let gain: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
            onSwipe(CGVector(dx: 0, dy: event.scrollingDeltaY * gain))
            return
        }
        // Momentum after the fingers lift would keep the cursor going with
        // nobody steering it.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .ended || event.phase == .cancelled {
            onSwipeEnd()
            return
        }
        // Turn scroll deltas back into finger motion: with natural scrolling
        // the deltas already follow the fingers, otherwise they are reversed.
        // A notched wheel reports lines, not points.
        let gain: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        onSwipe(CGVector(dx: event.scrollingDeltaX * gain * sign,
                         dy: event.scrollingDeltaY * gain * sign))
    }
}

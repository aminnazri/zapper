import Foundation
import SwiftUI
import ATVKit

@MainActor
final class AppState: ObservableObject {

    /// Where the remote connection to the selected device stands.
    enum Link: Equatable {
        case idle
        case connecting
        case online
        case offline(String)
    }

    @Published var devices: [Device] = []
    /// Nil until the user picks a TV: launching never connects on its own.
    @Published private(set) var selectedID: Device.ID?
    /// Saved TVs that answered the most recent network scan. Everything else
    /// in `devices` is history — another network, unplugged, or renamed.
    @Published private(set) var nearby: Set<Device.ID> = []
    /// A network scan is running (the quiet one included).
    @Published private(set) var isScanning = false
    private var lastScan = Date.distantPast
    @Published var status: String = "Ready"
    @Published var isBusy = false
    @Published var isPairing = false
    @Published var pairingCode = ""
    @Published var typedText = ""
    @Published private(set) var link: Link = .idle
    /// True once the TV reports a focused text field, which is when typing
    /// actually lands somewhere.
    @Published var textFieldReady = false
    /// What the TV's open text field contains, as the TV reports it.
    @Published private(set) var tvFieldText: String?
    /// Friendly name of whatever the TV is showing, for the status line.
    @Published var currentAppLabel = ""
    /// What the device last reported. Nil means it has not said — Google TV
    /// streamers that hand volume to the TV over CEC never report it.
    @Published private(set) var volumeLevel: Int?
    @Published private(set) var volumeMax: Int?
    @Published private(set) var isMuted = false
    @Published private(set) var isOn: Bool?
    /// The level the volume stepper is walking towards, while it runs.
    @Published private(set) var volumeTarget: Int?
    /// The command most recently sent, briefly, so the matching key can light
    /// up — whether it was clicked or pressed on the Mac keyboard.
    @Published private(set) var lastPressed: RemoteCommand?
    /// What is being cast to the TV, while it plays.
    @Published private(set) var casting: CastNow?

    /// Mirrors what has already been delivered, so each edit sends only the
    /// difference rather than resending the whole string.
    private var deliveredText = ""
    private var typingTask: Task<Void, Never>?
    /// Steers the TV's on-screen keyboard when the TV ignores direct text.
    private let keyboard = KeyboardDriver()
    /// Whether the current TV honours the protocol's text edit; nil until
    /// the first attempt shows it.
    private var directTextWorks: Bool?
    private var volumeTask: Task<Void, Never>?
    private var pressTask: Task<Void, Never>?

    private var codeContinuation: CheckedContinuation<String, Never>?

    private let store = DeviceStore()
    private let adapter = AndroidTVAdapter()

    /// One live session, reused across key presses.
    ///
    /// Previously every press called `adapter.connect`, which meant a fresh TCP
    /// connect + TLS handshake + RemoteConfigure exchange per button — roughly a
    /// second each, and the sessions were never closed. Holding the session
    /// makes the first press pay that cost and every later press a single write.
    private var session: DeviceSession?
    private var sessionDeviceID: Device.ID?
    /// A connect in flight. The monitor loop and a key press can both need a
    /// session at the same moment; sharing the attempt avoids two handshakes.
    private var pendingConnect: Task<DeviceSession, Error>?
    private var monitorTask: Task<Void, Never>?
    /// Devices already re-located this run, so an unreachable TV costs one
    /// discovery sweep rather than one per retry.
    private var relocated: Set<Device.ID> = []

    /// Cast is a separate connection (port 8009) from the remote, and outlives
    /// the panel: closing the menu must not stop the video.
    private var castSession: CastSession?
    private var castWatch: Task<Void, Never>?
    private var castChain: Task<Void, Never>?
    /// The live capture behind a screen cast.
    private var screenStream: ScreenStream?
    /// The real-time Cast Streaming mirror (low-latency path), when active.
    private var screenMirror: ScreenMirror?
    private var mirroredChoice: ScreenChoice?

    /// Frame rates the real-time mirror offers, highest first. A higher rate
    /// is smoother and shaves a few milliseconds off the capture interval; a
    /// lower rate asks less of a weak Wi-Fi link.
    static let mirrorFPSOptions = [120, 60, 30, 24]
    static let mirrorFPSKey = "mirrorFPS"
    /// The chosen mirror frame rate, clamped to a supported value.
    static var mirrorFPS: Int {
        let stored = UserDefaults.standard.integer(forKey: mirrorFPSKey)
        return mirrorFPSOptions.contains(stored) ? stored : 60
    }
    /// A shared browser page turned out to be a YouTube video.
    @Published private(set) var youTubeOffer: YouTubeOffer?
    private var lastCatchUp = Date.distantPast

    var selected: Device? {
        if selectedID == Device.bluetoothBridge.id { return .bluetoothBridge }
        return devices.first { $0.id == selectedID }
    }

    /// The Zapper Bluetooth adapter is plugged in (it may not be flashed or
    /// paired yet — connecting finds out).
    @Published private(set) var bridgePlugged = false
    /// Whether a TV is connected to the adapter over Bluetooth; nil unless
    /// the adapter is in use.
    @Published private(set) var bridgeTVConnected: Bool?

    var usingBluetooth: Bool { selected?.isBluetoothBridge == true }

    func checkBridge() {
        update(\.bridgePlugged, !BluetoothBridge.candidatePorts().isEmpty)
    }

    var isOnline: Bool { link == .online }

    init() {
        devices = store.load()
    }


    /// Network.framework surfaces an unreachable-but-present device as either
    /// a timeout or `ENETDOWN`, depending on how fresh the IPv6 neighbour
    /// cache entry is. Both mean the same thing in practice: the TV's network
    /// chip is alive (it is still answering mDNS) but nothing is listening on
    /// the remote port — i.e. it is asleep with its network standby off.
    private func explain(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("may not be paired") || text.contains("certificate")
            || text.contains("-9806") || text.contains("bad_certificate") {
            return "The TV refused this Mac. Pair with it first."
        }
        let unreachable = text.contains("Timed out")
            || text.contains("Network is down")
            || text.contains("No route to host")
            || text.contains("Connection refused")
        guard unreachable else { return text }
        return "Not responding. The TV is probably asleep. To control it while "
             + "it sleeps, turn on its network standby setting (Google TV: "
             + "Settings › System › Power & energy)."
    }

    // MARK: - Discovery

    func discover() async {
        guard !isScanning else { return }
        isBusy = true
        status = "Searching the network…"
        let (found, added) = await scan(duration: 5)
        isBusy = false

        guard found > 0 else {
            status = "No Google TV or Android TV found. Is it on and on this network?"
            return
        }
        status = "Found \(found) TV\(found == 1 ? "" : "s")"
            + (added > 0 ? ", \(added) new" : "")
    }

    /// Refreshes which saved TVs are on this network, without touching the
    /// status line. Runs when the panel opens; skipped if a scan ran lately.
    func scanNearbyIfStale() {
        checkBridge()
        guard !isScanning, Date().timeIntervalSince(lastScan) > 30 else { return }
        Task { _ = await scan(duration: 3) }
    }

    /// Discovers, saves what it finds, and recomputes `nearby`. Returns how
    /// many TVs answered and how many of those were new.
    private func scan(duration: TimeInterval) async -> (found: Int, added: Int) {
        isScanning = true
        checkBridge()
        let found = await adapter.discover(duration: duration)
        isScanning = false
        lastScan = Date()
        let added = found.isEmpty ? 0 : merge(found)
        let names = Set(found.map(\.name))
        nearby = Set(devices.filter { names.contains($0.name) }.map(\.id))
        // The connected TV is on this network whether or not it answered.
        if link == .online, let sessionDeviceID { nearby.insert(sessionDeviceID) }
        return (found.count, added)
    }

    /// Folds discovery results into the saved list.
    ///
    /// The mDNS instance name is the stable identity — DHCP hands TVs new
    /// addresses, so matching on host made a moved TV show up twice and left
    /// the old entry pointing nowhere. Returns how many were new.
    @discardableResult
    private func merge(_ found: [DiscoveredDevice]) -> Int {
        var added = 0
        for d in found {
            if let i = devices.firstIndex(where: { $0.name == d.name || $0.host == d.host }) {
                if devices[i].host != d.host {
                    Log.info("UI", "\(d.name) moved \(devices[i].host) -> \(d.host)")
                    if devices[i].id == sessionDeviceID { invalidateSessionNow() }
                }
                devices[i].host = d.host
                devices[i].name = d.name
                if let mac = d.mac { devices[i].mac = mac }
            } else {
                devices.append(Device(name: d.name, host: d.host, mac: d.mac, adapter: .androidTV))
                added += 1
            }
        }
        store.save(devices)
        return added
    }

    /// Looks the device up again by name after it stopped answering at its
    /// saved address. True if it was found somewhere new.
    private func relocate(_ device: Device) async -> Bool {
        guard !relocated.contains(device.id) else { return false }
        relocated.insert(device.id)
        Log.info("UI", "re-locating \(device.name)")
        let found = await adapter.discover(duration: 3)
        guard let match = found.first(where: { $0.name == device.name }),
              match.host != device.host else { return false }
        merge([match])
        return true
    }

    // MARK: - Power

    /// The power button: toggles when the TV is reachable, and falls back to
    /// Wake-on-LAN when it is not.
    func togglePower() async {
        guard let device = selected else { status = "No TV selected"; return }
        if (try? await activeSession(for: device)) != nil {
            await send(.power)
            // Assume the toggle landed; the TV confirms with RemoteStart.
            if let on = isOn { isOn = !on }
        } else if device.mac != nil {
            await wake()
        }
    }

    /// Turns the TV on without ever turning it off — what the global hotkey
    /// does, since it is pressed blind.
    func turnOn() async {
        if selected == nil,
           let recent = devices.filter({ $0.lastConnected != nil })
                               .max(by: { $0.lastConnected! < $1.lastConnected! }) {
            select(recent.id)
        }
        guard let device = selected else { status = "No TV selected"; return }
        if (try? await activeSession(for: device)) != nil {
            if isOn == true { status = "\(device.name) is already on"; return }
            await send(.power)
            isOn = true
        } else {
            await wake()
        }
    }

    /// Wake-on-LAN. If HDMI-CEC is enabled on the TV, waking a streaming box
    /// also powers the TV on and switches it to the box's input.
    func wake() async {
        guard let device = selected else { status = "No TV selected"; return }
        isBusy = true
        status = "Waking \(device.name)…"
        do {
            try await adapter.wake(device)
            // Wake-on-LAN only works over Ethernet; Wi-Fi chips in TVs almost
            // never implement pattern-matched wake.
            status = "Wake signal sent. Over Wi-Fi this rarely works; turn on "
                   + "network standby on the TV instead."
            relocated.remove(device.id)
            monitorBackoff = 0
        } catch {
            status = explain(error)
        }
        isBusy = false
    }

    func probe() async {
        guard let device = selected else { status = "No TV selected"; return }
        isBusy = true
        status = "Testing the connection…"
        do {
            try await adapter.probe(DiscoveredDevice(name: device.name,
                                                     host: device.host,
                                                     port: ATVTransport.pairingPort,
                                                     mac: device.mac))
            status = "Connection OK. The TV accepts this Mac."
        } catch {
            status = explain(error)
        }
        isBusy = false
    }

    // MARK: - Sending

    func send(_ command: RemoteCommand) async {
        guard let device = selected else { status = "No TV selected"; return }
        if !command.isTyping {
            Log.info("UI", "send \(command) to \(device.name)")
            flash(command)
        }
        switch command {
        case .up, .down, .left, .right, .select, .back, .home:
            // The user may have moved the TV keyboard's highlight.
            keyboard.forgetPosition()
        default:
            break
        }
        do {
            let live = try await activeSession(for: device)
            if command == .settings || command == .input(0) {
                try await openSystemScreen(command, on: device, live)
                return
            }
            try await live.send(command)
            if command.isTyping {
                // Typing updates many times a second; keep the line stable.
                status = textFieldReady
                    ? "Typing into the TV\u{2019}s text field"
                    : "Typing (no text field open on the TV)"
            } else {
                status = "Sent \(label(for: command))"
            }
            await refreshDeviceState()
        } catch {
            // The adapter is fine; the TV is not paired, or the command
            // needs Wi-Fi. Reconnecting would not change that.
            if let bluetooth = session as? BluetoothSession, bluetooth.isLive {
                status = explain(error)
                return
            }
            // The TV drops idle sessions and reboots; one silent retry on a
            // fresh session turns that into a non-event for the user.
            Log.warn("UI", "send failed (\(error)) — reconnecting once")
            await invalidateSession()
            do {
                let live = try await activeSession(for: selected ?? device)
                try await live.send(command)
                status = "Sent \(label(for: command))"
            } catch {
                status = explain(error)
                Log.error("UI", "send failed after reconnect: \(error)")
                await invalidateSession()
                link = .offline(explain(error))
            }
        }
    }

    // MARK: - Settings and inputs

    /// The classic Android TV home screen. Some TVs running it (Xiaomi's
    /// among them) ignore the Settings and Input keys, and app links that
    /// fail make the TV drop the remote connection — so the gear and Inputs
    /// icons in its top bar are reached with the arrow keys instead.
    private static let classicLauncher = "com.google.android.tvlauncher"

    private func launcherKey(_ device: Device) -> String { "launcher.\(device.name)" }

    /// Opens Settings (`.settings`) or the input list (`.input(0)`).
    ///
    /// Google TV and most launchers honour the keys. On the classic launcher
    /// this presses Home, climbs to the top bar, runs right to its end (the
    /// account avatar), then steps left: one for the gear, two for Inputs.
    /// Verified on a Xiaomi MiTV-MSSP3. Which launcher a TV runs is learnt
    /// the first time and remembered.
    private func openSystemScreen(_ command: RemoteCommand, on device: Device,
                                  _ live: DeviceSession) async throws {
        let name = command == .settings ? "settings" : "the input list"
        // The adapter cannot ask the TV which launcher it runs. It exists for
        // TVs like these Xiaomis, so it takes the classic launcher's path.
        var launcher = device.isBluetoothBridge ? Self.classicLauncher
                     : UserDefaults.standard.string(forKey: launcherKey(device))
        var wentHome = false
        if launcher == nil, let remote = live as? RemoteSession {
            status = "Opening \(name)…"
            let start = Date()
            try await remote.send(.home)
            wentHome = true
            launcher = await reportedLauncher(on: remote, since: start)
            if let launcher { UserDefaults.standard.set(launcher, forKey: launcherKey(device)) }
        }
        guard launcher == Self.classicLauncher else {
            try await live.send(command)
            status = "Sent \(label(for: command))"
            return
        }

        status = "Opening \(name)…"
        keyboard.forgetPosition()
        if !wentHome { try await live.send(.home) }
        // The launcher animates back to its first row; presses during that
        // are dropped.
        try await Task.sleep(nanoseconds: 900_000_000)
        let lefts = command == .settings ? 1 : 2
        let path = Array(repeating: RemoteCommand.up, count: 4)
                 + Array(repeating: .right, count: 12)
                 + Array(repeating: .left, count: lefts)
                 + [.select]
        for step in path {
            try await live.send(step)
            try await Task.sleep(nanoseconds: 160_000_000)
        }
        status = command == .settings ? "Opened settings" : "Opened the input list"
    }

    /// The home-screen app the TV reports after Home, or nil if it says
    /// nothing within `timeout`.
    private func reportedLauncher(on remote: RemoteSession, since start: Date,
                                  timeout: TimeInterval = 1.5) async -> String? {
        while Date().timeIntervalSince(start) < timeout {
            let state = await remote.deviceState
            if let app = state.currentApp, let seen = state.currentAppSeen, seen >= start,
               AppState.friendlyName(app) == "Home" {
                return app
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Touchpad arrows: held down while the pointer moves, so a TV browser's
    /// cursor glides. These skip the status line and key flash `send` gives
    /// each press; they change many times a second.
    func holdKey(_ command: RemoteCommand) async {
        keyboard.forgetPosition()
        guard let device = selected, let live = try? await activeSession(for: device) else { return }
        if let bluetooth = live as? BluetoothSession { try? await bluetooth.hold(command) }
        if let remote = live as? RemoteSession { try? await remote.hold(command) }
    }

    func releaseKey(_ command: RemoteCommand) async {
        guard let device = selected, let live = try? await activeSession(for: device) else { return }
        if let bluetooth = live as? BluetoothSession { try? await bluetooth.release(command) }
        if let remote = live as? RemoteSession { try? await remote.release(command) }
    }

    // MARK: - Mouse (Bluetooth adapter)

    /// The open adapter session, if the adapter is the current TV.
    private var bluetoothSession: BluetoothSession? {
        usingBluetooth ? session as? BluetoothSession : nil
    }

    func moveMouse(dx: Int, dy: Int) {
        bluetoothSession?.moveMouse(dx: dx, dy: dy)
    }

    func scrollMouse(_ amount: Int) {
        bluetoothSession?.scroll(amount)
    }

    func clickMouse() async {
        guard let bluetooth = bluetoothSession else { return }
        do { try await bluetooth.click() } catch { status = explain(error) }
    }

    private func flash(_ command: RemoteCommand) {
        lastPressed = command
        pressTask?.cancel()
        pressTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            lastPressed = nil
        }
    }

    // MARK: - Volume

    /// Walks the volume to `target` with volume key presses.
    ///
    /// The protocol has no absolute set-volume message, only keys, and the
    /// step size varies by device (1 on most TVs, coarser on some). So press,
    /// wait for the device to report the new level, and repeat until the
    /// target is reached or crossed. A new target while running just retargets
    /// the same loop, so dragging the slider never queues stale presses.
    func setVolume(_ target: Int) {
        guard let top = volumeMax, top > 0 else { return }
        volumeTarget = min(max(target, 0), top)
        guard volumeTask == nil else { return }
        volumeTask = Task {
            await stepVolume()
            volumeTask = nil
            volumeTarget = nil
        }
    }

    private func stepVolume() async {
        guard let device = selected,
              let remote = (try? await activeSession(for: device)) as? RemoteSession
        else { return }
        var stalls = 0
        var presses = 0
        while let target = volumeTarget, stalls < 3, presses < 120 {
            guard let current = await remote.deviceState.volumeLevel, current != target
            else { break }
            let up = target > current
            do { try await remote.send(up ? .volumeUp : .volumeDown) } catch { break }
            presses += 1
            let now = await waitForVolume(change: current, on: remote)
            stalls = now == current ? stalls + 1 : 0
            await refreshDeviceState()
            // Coarse steps can jump past the target; stop once it is crossed,
            // unless the user has meanwhile dragged somewhere else.
            if let now, volumeTarget == target,
               (up && now >= target) || (!up && now <= target) { break }
        }
        status = volumeLevel.map { "Volume \($0)" } ?? status
    }

    private func waitForVolume(change from: Int, on remote: RemoteSession) async -> Int? {
        for _ in 0..<20 {
            let now = await remote.deviceState.volumeLevel
            if now != from { return now }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return from
    }

    // MARK: - Device state

    /// Reflects what the device reports about itself into the UI.
    func refreshDeviceState() async {
        if let bluetooth = session as? BluetoothSession {
            // The adapter cannot see the TV. Typing always goes straight in
            // as keystrokes, so the keyboard is always ready.
            update(\.bridgeTVConnected, bluetooth.tvConnected)
            update(\.textFieldReady, true)
            update(\.tvFieldText, nil)
            update(\.currentAppLabel, "")
            return
        }
        update(\.bridgeTVConnected, nil)
        guard let remote = session as? RemoteSession else {
            textFieldReady = false
            return
        }
        let reported = await remote.deviceState
        // Assign only what changed: every @Published write redraws the whole
        // panel, and this runs every 0.8 s.
        update(\.textFieldReady, reported.textFieldFocused)
        if !textFieldReady { keyboard.forgetPosition() }
        update(\.tvFieldText, textFieldReady ? reported.fieldValue : nil)
        // Only show the app when the device reported it recently; the TV
        // volunteers this rarely, so an old value would be misleading.
        update(\.currentAppLabel, reported.currentAppIsFresh
            ? AppState.friendlyName(reported.currentApp)
            : "")
        if let app = reported.currentApp, AppState.friendlyName(app) == "Home",
           let device = selected, UserDefaults.standard.string(forKey: launcherKey(device)) != app {
            UserDefaults.standard.set(app, forKey: launcherKey(device))
        }
        update(\.volumeLevel, reported.volumeLevel)
        update(\.volumeMax, reported.volumeMax)
        update(\.isMuted, reported.volumeMuted ?? false)
        if let on = reported.isOn { update(\.isOn, on) }
    }

    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private var monitorBackoff = 0

    /// Keeps a session open and polls the device's state.
    ///
    /// The TV announces a focused text field, volume changes and power changes
    /// asynchronously, so they have to be polled — refreshing only after a key
    /// press meant changing the volume with the physical remote never showed
    /// up here. Also forces the session to exist, since nothing is listening
    /// for those announcements until one does.
    func startMonitoring() {
        guard monitorTask == nil, selected != nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let device = self.selected else { return }
                if let bluetooth = self.session as? BluetoothSession, !bluetooth.isLive {
                    Log.info("UI", "Bluetooth adapter went away — reconnecting")
                    await self.invalidateSession()
                }
                if let remote = self.session as? RemoteSession,
                   self.sessionDeviceID == device.id,
                   await remote.isLive == false {
                    Log.info("UI", "session went stale — reconnecting")
                    await self.invalidateSession()
                }
                let wait: UInt64
                if (try? await self.activeSession(for: device)) != nil {
                    await self.refreshDeviceState()
                    self.monitorBackoff = 0
                    wait = 800
                } else {
                    // An asleep TV would otherwise be hammered with handshakes.
                    self.monitorBackoff = min(self.monitorBackoff + 1, 5)
                    wait = UInt64(self.monitorBackoff) * 2_000
                }
                // Sleep in slices so a wake or a manual retry, which reset the
                // backoff, gets an immediate reconnect attempt.
                let failing = self.monitorBackoff > 0
                var slept: UInt64 = 0
                while slept < wait, !Task.isCancelled, !(failing && self.monitorBackoff == 0) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    slept += 200
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Manual retry from the offline banner.
    func reconnect() {
        relocated.removeAll()
        monitorBackoff = 0
        Task {
            await invalidateSession()
            guard let device = selected else { return }
            _ = try? await activeSession(for: device)
            await refreshDeviceState()
        }
    }

    private func activeSession(for device: Device) async throws -> DeviceSession {
        if let session, sessionDeviceID == device.id { return session }
        if let pendingConnect, sessionDeviceID == device.id {
            return try await pendingConnect.value
        }
        await invalidateSession()
        sessionDeviceID = device.id
        link = .connecting
        let adapter = adapter
        let attempt = Task { () async throws -> DeviceSession in
            device.isBluetoothBridge ? try await BluetoothSession.open()
                                     : try await adapter.connect(device)
        }
        pendingConnect = attempt
        do {
            let fresh = try await attempt.value
            guard pendingConnect == attempt, sessionDeviceID == device.id else {
                // The user switched device while this was connecting.
                await fresh.disconnect()
                throw CancellationError()
            }
            pendingConnect = nil
            session = fresh
            link = .online
            relocated.remove(device.id)
            nearby.insert(device.id)
            if let i = devices.firstIndex(where: { $0.id == device.id }) {
                devices[i].lastConnected = Date()
                store.save(devices)
            }
            return fresh
        } catch {
            guard pendingConnect == attempt else { throw error }
            pendingConnect = nil
            sessionDeviceID = nil
            // A TV that got a new address from DHCP looks exactly like one
            // that is asleep. Check once before calling it offline.
            if !device.isBluetoothBridge, await relocate(device), let moved = devices.first(where: { $0.id == device.id }) {
                return try await activeSession(for: moved)
            }
            link = .offline(explain(error))
            throw error
        }
    }

    private func invalidateSession() async {
        let old = session
        session = nil
        invalidateSessionNow()
        if let old { await old.disconnect() }
    }

    /// Synchronous variant for callers that cannot await; the old session is
    /// closed in the background.
    private func invalidateSessionNow() {
        if let session { Task { await session.disconnect() } }
        session = nil
        sessionDeviceID = nil
        pendingConnect = nil
        textFieldReady = false
        // A new connection may be a different TV, or the same one after a
        // restart; relearn both.
        directTextWorks = nil
        keyboard.forgetPosition()
        volumeLevel = nil
        volumeMax = nil
        isOn = nil
        currentAppLabel = ""
        link = .idle
    }

    // MARK: - Typing

    /// Live typing: sends only what changed since the last keystroke, so the
    /// TV's on-screen field tracks the Mac field character by character.
    ///
    /// One worker drains edits in order. Each edit used to spawn its own task,
    /// and two fast edits could diff against the same delivered text and type
    /// a character twice.
    func typedTextChanged() {
        guard selected != nil, typingTask == nil else { return }
        typingTask = Task {
            while deliveredText != typedText {
                await deliver(typedText)
            }
            typingTask = nil
        }
    }

    /// Makes the TV's open text field match the Mac field.
    ///
    /// First choice is the protocol's own text edit, which sets the whole
    /// field at once. Whether the TV honours it is learnt from its report of
    /// the field: some TVs drop it silently, and for those the on-screen
    /// keyboard is steered instead (see `KeyboardDriver`).
    private func deliver(_ new: String) async {
        if usingBluetooth {
            await deliverOverBluetooth(new)
            return
        }
        // With no TV field open the Mac field is just a compose box for
        // Search YouTube. Forwarding keystrokes then only sends stray key
        // presses, which apps like YouTube read as shortcuts.
        guard textFieldReady, let device = selected,
              let remote = (try? await activeSession(for: device)) as? RemoteSession else {
            deliveredText = new
            return
        }

        if directTextWorks != false, !new.isEmpty, await remote.canEditText {
            let revision = await remote.deviceState.fieldRevision
            try? await remote.send(.text(new))
            var accepted = directTextWorks == true
            if !accepted { accepted = await fieldReport(on: remote, after: revision) == new }
            if accepted {
                directTextWorks = true
                deliveredText = new
                status = "Typing into the TV\u{2019}s text field"
                return
            }
            directTextWorks = false
            Log.info("UI", "TV ignored the text edit; steering its on-screen keyboard instead")
        }

        status = "Typing on the TV\u{2019}s keyboard…"
        do {
            try await keyboard.sync(remote) { [unowned self] in self.typedText }
            status = "Typed on the TV"
        } catch {
            keyboard.forgetPosition()
            status = "Couldn\u{2019}t type on the TV\u{2019}s keyboard. Press OK on any letter "
                   + "of the TV keyboard, then type again."
            Log.warn("UI", "keyboard typing failed: \(error)")
        }
        let skipped = typedText.filter { !KeyboardDriver.canType($0) }
        if directTextWorks == false, !skipped.isEmpty {
            status = "Typed on the TV. Digits and symbols can\u{2019}t be typed on this TV yet."
        }
        deliveredText = typedText
    }

    /// Real keystrokes: erase what changed since the common start, then type
    /// the rest. The TV's field follows the Mac field as if typed on it.
    private func deliverOverBluetooth(_ new: String) async {
        guard let device = selected,
              let bluetooth = (try? await activeSession(for: device)) as? BluetoothSession else {
            deliveredText = new
            return
        }
        let common = deliveredText.commonPrefix(with: new)
        let erase = deliveredText.count - common.count
        let add = String(new.dropFirst(common.count))
        do {
            try await bluetooth.backspace(times: erase)
            try await bluetooth.type(add)
            status = "Typing on the TV"
        } catch {
            status = explain(error)
        }
        deliveredText = new
    }

    /// The TV's next report of its text field, or nil after `timeout`.
    private func fieldReport(on remote: RemoteSession, after revision: Int,
                             timeout: TimeInterval = 0.7) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await remote.deviceState
            if state.fieldRevision != revision { return state.fieldValue }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return nil
    }

    /// Confirms the field — the TV treats this as pressing enter on its keyboard.
    func submitTypedText() async {
        guard selected != nil else { return }
        await typingTask?.value
        deliveredText = ""
        typedText = ""
        await send(.enter)
    }

    /// Opens YouTube on the TV with the typed text as a search.
    ///
    /// Some TVs (a Xiaomi MiTV-MOOR2 on Android 11, remote service 7.00, for
    /// one) drop typed text from remote apps entirely — both ime batch edits
    /// and letter keycodes — while still announcing their text fields. A
    /// search link sidesteps the text field: it is an app-link launch, which
    /// every Google TV / Android TV accepts.
    func searchYouTube() async {
        let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var link = URLComponents(string: "https://www.youtube.com/results")!
        link.queryItems = [URLQueryItem(name: "search_query", value: query)]
        guard let url = link.url?.absoluteString else { return }
        await typingTask?.value
        // Clear without sending backspaces: in YouTube, Delete goes back.
        deliveredText = ""
        typedText = ""
        await send(.launchApp(url))
        status = "Searching YouTube for \u{201C}\(query)\u{201D}"
    }

    /// Clears the Mac field and the same number of characters on the TV.
    func clearTypedText() {
        typedText = ""
        typedTextChanged()
    }

    // MARK: - Casting

    /// Starts serving a file from this Mac and plays it on the selected TV
    /// through its built-in Chromecast receiver.
    func cast(file: URL) {
        startCast(title: file.deletingPathExtension().lastPathComponent,
                  symbol: CastNow.symbol(for: file)) { session in
            try await session.load(file: file, title: file.deletingPathExtension().lastPathComponent)
        }
    }

    /// Plays a web link the TV fetches by itself — a direct .mp4 or .m3u8.
    /// A YouTube link opens in the TV's own YouTube app instead.
    func cast(link text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            status = "That is not a web link. Paste one starting with http:// or https://"
            return
        }
        if let video = AppState.youTubeLink(url) {
            Task { await send(.launchApp(video)) }
            status = "Opening the video in YouTube on \(selected?.name ?? "the TV")"
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        startCast(title: title.isEmpty ? (url.host ?? "Stream") : title,
                  symbol: "link") { session in
            try await session.load(url: trimmed, title: title)
        }
    }

    /// Mirrors a display, an app, a window or a browser tab, with sound, to
    /// the selected TV — unless it is a YouTube page, which is better played
    /// by the TV's own YouTube app, so offer that first.
    func castScreen(_ choice: ScreenChoice) {
        guard ScreenStream.hasPermission else {
            askForScreenRecording()
            return
        }
        // A whole display goes through the low-latency Cast Streaming path
        // (~0.3 s instead of ~2 s). It falls back to HLS if the TV's mirroring
        // receiver won't negotiate. Window / app / tab sources stay on HLS for
        // now — the real-time path captures a whole display only.
        if choice.kind == .display {
            mirrorRealtime(choice)
            return
        }
        guard choice.isBrowserPage, let bundleID = choice.bundleID else {
            mirror(choice)
            return
        }
        youTubeOffer = nil
        status = "Checking what \(choice.title) is showing\u{2026}"
        Task {
            if let url = await BrowserTab.url(bundleID: bundleID, windowTitle: choice.title),
               let link = AppState.youTubeLink(url) {
                youTubeOffer = YouTubeOffer(choice: choice, link: link)
                status = "That is a YouTube video. Play it in the TV\u{2019}s YouTube app?"
            } else {
                mirror(choice)
            }
        }
    }

    /// Hands the video to the TV's YouTube app: full quality, no delay, and
    /// it carries on whatever the Mac does next.
    func acceptYouTubeOffer() {
        guard let offer = youTubeOffer else { return }
        youTubeOffer = nil
        if casting != nil { stopCasting() }
        Task { await send(.launchApp(offer.link)) }
        status = "Playing in YouTube on \(selected?.name ?? "the TV"). Pause the video on the Mac."
    }

    func declineYouTubeOffer() {
        guard let offer = youTubeOffer else { return }
        youTubeOffer = nil
        mirror(offer.choice)
    }

    /// The shared window went dark because it is full screen and another app
    /// is in front; put it back on the desktop, where it stays live.
    func exitSharedFullScreen() {
        guard let choice = mirroredChoice, let pid = choice.pid else { return }
        guard PageTracker.isTrusted else {
            PageTracker.requestTrust()
            status = "Allow Zapper under Accessibility in System Settings, then press Exit full screen again."
            return
        }
        if PageTracker.exitFullScreen(pid: pid, windowFrame: choice.frame) {
            status = "\(choice.title) is back on the desktop and stays live behind other windows."
        } else {
            status = "Could not take \(choice.title) out of full screen. Press \u{2303}\u{2318}F in it."
        }
    }

    /// Low-latency mirroring over Cast Streaming (UDP/RTP), for a whole
    /// display. Unlike `mirror`, this does not go through the media
    /// `CastSession` — `ScreenMirror` negotiates its own mirroring session.
    /// If the TV's mirroring receiver refuses, it falls back to HLS.
    private func mirrorRealtime(_ choice: ScreenChoice) {
        guard let device = selected else { status = "No TV selected"; return }
        var displayID: CGDirectDisplayID?
        if case .display(let id) = choice.source { displayID = id }
        mirroredChoice = choice

        castWatch?.cancel(); castWatch = nil
        stopScreenStream()
        castSession?.close(); castSession = nil

        let attempt = CastNow(title: choice.title, symbol: CastNow.symbol(for: choice.kind),
                              deviceName: device.name, isMirror: true)
        casting = attempt
        status = "Starting real-time mirror to \(device.name)…"
        Log.info("UI", "real-time mirror \(choice.title) to \(device.name)")

        let fps = AppState.mirrorFPS
        Task {
            do {
                let m = try await ScreenMirror.start(host: device.host, displayID: displayID, fps: fps)
                guard casting?.id == attempt.id else { m.stop(); return }
                screenMirror = m
                m.onStop = { [weak self, weak m] in
                    Task { @MainActor in
                        guard let self, let m, self.screenMirror === m else { return }
                        self.castEnded("Mirroring stopped")
                    }
                }
                casting?.isStarting = false
                status = "Mirroring \(choice.title) to \(device.name) — real-time"
            } catch {
                Log.error("UI", "real-time mirror failed, falling back to HLS: \(error)")
                guard casting?.id == attempt.id else { return }
                casting = nil
                status = "Real-time mirroring isn't available on this TV — using standard cast."
                mirror(choice)
            }
        }
    }

    private func mirror(_ choice: ScreenChoice) {
        mirroredChoice = choice
        let symbol = CastNow.symbol(for: choice.kind)
        startCast(title: choice.title, symbol: symbol, mirror: true) { [self] session in
            let stream = try await ScreenStream.start(choice.source)
            screenStream = stream
            stream.onStop = { [weak self, weak stream] in
                Task { @MainActor in
                    guard let self, let stream, self.screenStream === stream else { return }
                    self.castEnded("\(choice.title) closed, so casting stopped")
                }
            }
            stream.onVisibilityChange = { [weak self, weak stream] visible, fullScreen in
                Task { @MainActor in
                    guard let self, let stream, self.screenStream === stream else { return }
                    self.casting?.sourceHidden = !visible
                    self.casting?.sourceFullScreen = fullScreen
                    if visible {
                        self.status = "Casting \(choice.title)"
                    } else if fullScreen {
                        // Full screen is its own Space: any other app in front
                        // means macOS stops drawing it at all.
                        self.status = "That window is full screen, so it pauses whenever another "
                                    + "app is in front. Press Exit full screen to keep it live."
                    } else {
                        self.status = "\(choice.title) is on another desktop, minimised or hidden. "
                                    + "The TV holds the last picture until it is back on this screen."
                    }
                }
            }
            try await stream.waitUntilReady(segments: 4)
            try await session.load(url: stream.playlistURL,
                                   contentType: "application/x-mpegurl",
                                   kind: "MOVIE",
                                   title: choice.title,
                                   fragmentedHLS: true)
        }
    }

    /// The TV's YouTube app opens watch links handed to it as an app link, at
    /// full quality and with no delay — far better than mirroring a browser.
    /// Short, mobile and music links are rewritten to the plain watch form.
    static func youTubeLink(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var id: String?
        if host == "youtu.be" {
            id = url.pathComponents.dropFirst().first
        } else if host.hasSuffix("youtube.com") {
            if url.path == "/watch" {
                id = parts?.queryItems?.first { $0.name == "v" }?.value
            } else if ["shorts", "live", "embed"].contains(url.pathComponents.dropFirst().first ?? "") {
                id = url.pathComponents.dropFirst(2).first
            }
        }
        guard let id, !id.isEmpty else { return nil }
        var link = "https://www.youtube.com/watch?v=\(id)"
        if let t = parts?.queryItems?.first(where: { $0.name == "t" })?.value {
            link += "&t=\(t.trimmingCharacters(in: CharacterSet(charactersIn: "s")))"
        }
        return link
    }

    /// macOS shows its own prompt once; after that the switch lives only in
    /// System Settings, so go straight there.
    func askForScreenRecording() {
        let key = "askedForScreenRecording"
        if UserDefaults.standard.bool(forKey: key),
           let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(settings)
        } else {
            UserDefaults.standard.set(true, forKey: key)
            ScreenStream.requestPermission()
        }
        status = "Allow Zapper under Screen Recording in System Settings, "
               + "then press Relaunch."
    }

    /// A Screen Recording grant only takes effect in a fresh process.
    func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApplication.shared.terminate(nil)
    }

    private func stopScreenStream() {
        screenStream?.stop()
        screenStream = nil
        screenMirror?.stop()
        screenMirror = nil
    }

    private func startCast(title: String, symbol: String, mirror: Bool = false,
                           load: @escaping @MainActor (CastSession) async throws -> Void) {
        guard let device = selected else { status = "No TV selected"; return }
        castWatch?.cancel()
        castWatch = nil
        stopScreenStream()
        // The receiver relaunches cleanly, so the old connection can simply
        // go; stopping it first would flash the TV back to its previous app.
        castSession?.close()
        castSession = nil
        let attempt = CastNow(title: title, symbol: symbol, deviceName: device.name, isMirror: mirror)
        casting = attempt
        status = "Sending \(title) to \(device.name)…"
        Log.info("UI", "cast \(title) to \(device.name)")

        Task {
            await onCastChannel { [self] in
                // A newer cast, or Stop, may have superseded this one while it
                // waited for the channel or connected.
                // Any screen stream still running here was started by an
                // attempt that was superseded before it could be stopped.
                stopScreenStream()
                var opened: CastSession?
                do {
                    guard casting?.id == attempt.id else { return }
                    let session = try await CastSession.open(host: device.host)
                    opened = session
                    guard casting?.id == attempt.id else { session.close(); return }
                    castSession = session
                    try await load(session)
                    guard casting?.id == attempt.id else { stopScreenStream(); return }
                    casting?.isStarting = false
                    status = "Casting \(title) to \(device.name)"
                    watchCast(session)
                } catch {
                    Log.error("UI", "cast failed: \(error)")
                    opened?.close()
                    stopScreenStream()
                    guard casting?.id == attempt.id else { return }
                    castSession = nil
                    casting = nil
                    status = explainCast(error)
                }
            }
        }
    }

    func toggleCastPlayback() {
        guard let session = castSession, let now = casting else { return }
        let playing = now.playback?.state == .playing || now.playback?.state == .buffering
        casting?.playback?.state = playing ? .paused : .playing
        Task {
            await onCastChannel { [self] in
                do { try await playing ? session.pause() : session.play() }
                catch { castEnded("Casting stopped. The TV closed the stream.") }
            }
        }
    }

    func seekCast(to seconds: Double) {
        guard let session = castSession else { return }
        casting?.playback?.position = seconds
        Task {
            await onCastChannel { try? await session.seek(to: seconds) }
        }
    }

    func skipCast(by seconds: Double) {
        guard let position = casting?.playback?.position else { return }
        let end = casting?.playback?.duration ?? .greatestFiniteMagnitude
        seekCast(to: min(max(position + seconds, 0), end))
    }

    func stopCasting() {
        castWatch?.cancel()
        castWatch = nil
        stopScreenStream()
        let session = castSession
        castSession = nil
        casting = nil
        status = "Stopped casting"
        // Also catches a screen stream an attempt still in flight starts.
        Task {
            await onCastChannel { [self] in
                await session?.stop()
                stopScreenStream()
            }
        }
    }

    /// Follows playback once a second, for the progress bar, and notices when
    /// the video ends or someone presses Home on the TV.
    private func watchCast(_ session: CastSession) {
        castWatch = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.castSession === session else { return }
                if session.isClosed {
                    self.castEnded("Casting stopped. The TV closed the stream.")
                    return
                }
                var reply: Result<CastSession.Playback?, Error> = .success(nil)
                await self.onCastChannel {
                    do { reply = .success(try await session.status()) }
                    catch { reply = .failure(error) }
                }
                guard !Task.isCancelled, self.castSession === session else { return }
                switch reply {
                case .success(let playback?):
                    misses = 0
                    if playback.state == .idle, let reason = playback.idleReason {
                        self.castEnded(reason == "ERROR"
                                       ? "The TV could not play this file. MP4 (H.264) works best."
                                       : reason == "FINISHED" ? "Finished casting" : "Casting stopped")
                        return
                    }
                    if self.casting?.isMirror == true {
                        // A mirror has no progress bar; its position ticks
                        // every second and would redraw the panel for nothing.
                        if self.casting?.playback?.state != playback.state { self.casting?.playback = playback }
                        self.catchUp(playback)
                    } else {
                        self.casting?.playback = playback
                    }
                case .success(nil):
                    // A photo has no running media on some receivers; only a
                    // video that disappears means playback ended.
                    if self.casting?.symbol != "photo" {
                        misses += 1
                    }
                case .failure:
                    misses += 1
                }
                if misses >= 3 {
                    self.castEnded("Casting stopped")
                    return
                }
            }
        }
    }

    /// The receiver's player starts, and after any stall resumes, further
    /// behind live than it needs to. A seek to the end of its live range
    /// takes a mirrored screen back to about 2 s behind the Mac.
    private func catchUp(_ playback: CastSession.Playback) {
        guard playback.state == .playing, let end = playback.liveEnd,
              // The player settles about 0.8 s behind its live edge on its
              // own; seeking at that distance only made it hiccup every few
              // seconds. Only a real backlog, after a stall, is worth a seek.
              end - playback.position > 1.6,
              Date().timeIntervalSince(lastCatchUp) > 10 else { return }
        lastCatchUp = Date()
        Log.info("UI", String(format: "mirror %.1fs behind its live edge, catching up",
                              end - playback.position))
        seekCast(to: end)
    }

    private func castEnded(_ message: String) {
        castWatch?.cancel()
        castWatch = nil
        castSession?.close()
        castSession = nil
        stopScreenStream()
        guard casting != nil else { return }
        casting = nil
        status = message
    }

    /// Runs cast traffic one exchange at a time. The status poll and the
    /// controls share one channel, and a reply meant for one would otherwise
    /// be consumed by the other.
    private func onCastChannel(_ work: @escaping @MainActor () async -> Void) async {
        let previous = castChain
        let next = Task { @MainActor in
            await previous?.value
            await work()
        }
        castChain = next
        await next.value
    }

    private func explainCast(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("rejected the media") {
            return "The TV could not play this. MP4 (H.264), WebM, MP3, JPEG and PNG work best."
        }
        if text.contains("Timed out") || text.contains("refused") || text.contains("No route") {
            return "The TV did not answer on its Cast port. Turn it on and check "
                 + "that Chromecast built-in is enabled."
        }
        if text.contains("never reported") {
            return "The TV did not open its media player. Try again."
        }
        return "Could not cast: \(text)"
    }


    // MARK: - Devices

    func select(_ id: Device.ID) {
        guard id != selectedID else { return }
        relocated.remove(id)
        monitorBackoff = 0
        selectedID = id
        stopMonitoring()
        typedText = ""
        deliveredText = ""
        Task {
            await invalidateSession()
            startMonitoring()
        }
    }

    func forget(_ device: Device) {
        if device.id == sessionDeviceID { invalidateSessionNow() }
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        nearby.remove(device.id)
        if selectedID == device.id {
            selectedID = nil
            stopMonitoring()
        }
        status = "Removed \(device.name)"
    }

    /// Saved TVs that answered on this network, most recently used first.
    var devicesNearby: [Device] { sortedDevices.filter { nearby.contains($0.id) } }
    /// Saved TVs not seen on this network.
    var devicesElsewhere: [Device] { sortedDevices.filter { !nearby.contains($0.id) } }

    private var sortedDevices: [Device] {
        devices.sorted {
            switch ($0.lastConnected, $1.lastConnected) {
            case let (a?, b?): return a > b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// The TV's name, plus its address when another saved TV has the same
    /// name — several TVs call themselves just "TV".
    func displayName(_ device: Device) -> String {
        guard !device.isBluetoothBridge else { return device.name }
        guard devices.contains(where: { $0.id != device.id && $0.name == device.name }) else {
            return device.name
        }
        var host = device.host
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.contains(":") { host = "…" + host.split(separator: ":").suffix(2).joined(separator: ":") }
        return "\(device.name) · \(host)"
    }

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Back to the TV list. Casting runs on its own connection and keeps going.
    func disconnect() {
        guard let device = selected else { return }
        stopMonitoring()
        selectedID = nil
        typedText = ""
        deliveredText = ""
        Task { await invalidateSession() }
        status = "Disconnected from \(device.name)"
    }

    #if PREVIEW
    /// Offscreen render harness only: pretend these TVs answered a scan.
    func previewBridge() { bridgePlugged = true }

    func previewNearby(_ names: Set<String>) {
        nearby = Set(devices.filter { names.contains($0.name) }.map(\.id))
    }
    /// Offscreen render harness only: a connected TV without the network.
    func previewConnected() {
        link = .online; isOn = true; volumeLevel = 28; volumeMax = 100
        currentAppLabel = "YouTube"; textFieldReady = true
    }
    #endif

    func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    /// Package names are meaningless to a user; map the common ones.
    static func friendlyName(_ package: String?) -> String {
        guard let package, !package.isEmpty else { return "" }
        switch package {
        case "com.google.android.backdrop":                  return "Ambient mode"
        case "com.google.android.katniss",
             "com.google.android.apps.tv.search":            return "Search"
        case "com.google.android.tvlauncher",
             "com.google.android.apps.tv.launcherx",
             "com.google.android.leanbacklauncher",
             "com.mitv.tvhome.atv", "com.mitv.tvhome.michannel",
             "com.sony.dtv.bravialauncher":                  return "Home"
        case "com.android.tv.settings",
             "com.google.android.tv.settings":               return "Settings"
        case "com.google.android.youtube.tv",
             "com.google.android.youtube.tvkids":            return "YouTube"
        case "com.google.android.youtube.tvmusic":           return "YouTube Music"
        case "com.netflix.ninja":                            return "Netflix"
        case "com.amazon.amazonvideo.livingroom":            return "Prime Video"
        case "com.disney.disneyplus":                        return "Disney+"
        case "com.spotify.tv.android":                       return "Spotify"
        case "com.plexapp.android":                          return "Plex"
        case "org.xbmc.kodi":                                return "Kodi"
        case "com.apple.atve.androidtv.appletv":             return "Apple TV"
        case "com.hbo.hbonow", "com.wbd.stream":             return "Max"
        case "com.google.android.videos":                    return "Google TV"
        case "com.google.android.tv":                        return "Live TV"
        default:
            return package.split(separator: ".").last.map(String.init)?.capitalized ?? package
        }
    }

    private func label(for command: RemoteCommand) -> String {
        switch command {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .select: return "OK"
        case .back: return "back"
        case .home: return "home"
        case .menu: return "menu"
        case .volumeUp: return "volume up"
        case .volumeDown: return "volume down"
        case .mute: return "mute"
        case .playPause: return "play/pause"
        case .next: return "next"
        case .previous: return "previous"
        case .rewind: return "rewind"
        case .fastForward: return "fast forward"
        case .power: return "power"
        case .settings: return "settings"
        case .guide: return "guide"
        case .input(let n): return n == 0 ? "input picker" : "HDMI \(n)"
        case .character(let c): return "\u{201C}\(c)\u{201D}"
        case .backspace: return "backspace"
        case .enter: return "enter"
        case .search: return "search"
        case .launchApp(let link): return "open \(QuickApp.all.first { $0.link == link }?.name ?? link)"
        case .text(let t): return "\u{201C}\(t)\u{201D}"
        }
    }

    // MARK: - Pairing

    /// Starts pairing. The TV shows a 6-character code; `submitPairingCode`
    /// hands it back to the waiting handshake.
    func pair() async {
        guard let device = selected else { status = "No TV selected"; return }
        await invalidateSession()
        stopMonitoring()
        isBusy = true
        isPairing = true
        pairingCode = ""
        status = "Pairing with \(device.name)…"
        Log.info("UI", "pairing started for \(device.name) at \(device.host)")

        do {
            try await adapter.pair(
                DiscoveredDevice(name: device.name,
                                 host: device.host,
                                 port: ATVTransport.pairingPort,
                                 mac: device.mac),
                pinProvider: { [weak self] in
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in self?.codeContinuation = continuation }
                    }
                })
            status = "Paired with \(device.name)"
            Log.info("UI", "pairing succeeded")
        } catch {
            if status != "Pairing cancelled" { status = explain(error) }
            Log.error("UI", "pairing failed: \(error)")
        }
        codeContinuation = nil
        isPairing = false
        isBusy = false
        relocated.remove(device.id)
        monitorBackoff = 0
        startMonitoring()
    }

    func submitPairingCode() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, let continuation = codeContinuation else { return }
        codeContinuation = nil
        isPairing = false
        status = "Checking the code…"
        continuation.resume(returning: code)
    }

    func cancelPairing() {
        status = "Pairing cancelled"
        if let continuation = codeContinuation {
            codeContinuation = nil
            continuation.resume(returning: "")
        }
        isPairing = false
    }
}

struct YouTubeOffer: Equatable {
    let choice: ScreenChoice
    let link: String
}

/// The cast in progress, as the Cast drawer shows it.
struct CastNow: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var deviceName: String
    /// A live screen share rather than a file or link.
    var isMirror = false
    /// The shared window or app is off screen; the TV holds its last picture.
    var sourceHidden = false
    /// …because it is in full-screen mode, on a Space of its own.
    var sourceFullScreen = false
    /// True until the TV has accepted the media.
    var isStarting = true
    var playback: CastSession.Playback?

    static func symbol(for kind: ScreenChoice.Kind) -> String {
        switch kind {
        case .display: return "display"
        case .app: return "square.on.square"
        case .window: return "macwindow"
        case .tab: return "globe"
        }
    }

    static func symbol(for file: URL) -> String {
        switch MediaServer.mediaKind(for: file) {
        case "PHOTO": return "photo"
        case "MUSIC_TRACK": return "music.note"
        default: return "film"
        }
    }
}

/// Apps the Apps drawer can open. Launching goes through the remote
/// protocol's app-link message, which every Google TV / Android TV accepts.
/// `market://launch?id=` opens an installed app by package name, which works
/// for any app; the https links are the ones the apps register themselves.
struct QuickApp: Identifiable {
    let name: String
    let symbol: String
    let link: String
    var id: String { link }

    static let all: [QuickApp] = [
        QuickApp(name: "YouTube", symbol: "play.rectangle.fill", link: "https://www.youtube.com"),
        QuickApp(name: "Netflix", symbol: "n.square.fill", link: "https://www.netflix.com/title"),
        QuickApp(name: "Prime Video", symbol: "film.fill", link: "https://app.primevideo.com"),
        QuickApp(name: "Disney+", symbol: "star.circle.fill", link: "https://www.disneyplus.com"),
        QuickApp(name: "Spotify", symbol: "music.note", link: "market://launch?id=com.spotify.tv.android"),
        QuickApp(name: "Plex", symbol: "play.circle.fill", link: "market://launch?id=com.plexapp.android"),
    ]
}

private extension RemoteCommand {
    /// Keystrokes from the keyboard drawer, which should not light up keys or
    /// fill the status line with one entry per character.
    var isTyping: Bool {
        switch self {
        case .character, .text: return true
        default: return false
        }
    }
}

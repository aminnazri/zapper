import Foundation
import Security

/// Android TV keycodes, from `remotemessage.proto` (they match Android's
/// `KeyEvent` constants).
public enum KeyCode: UInt64 {
    case home = 3
    case back = 4
    case dpadUp = 19
    case dpadDown = 20
    case dpadLeft = 21
    case dpadRight = 22
    case dpadCenter = 23
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case menu = 82
    case mediaPlayPause = 85
    case mediaNext = 87
    case mediaPrevious = 88
    case mediaRewind = 89
    case mediaFastForward = 90
    /// KEYCODE_MUTE is the *microphone* mute; Google TV and most Android TVs
    /// ignore it. Speaker mute is KEYCODE_VOLUME_MUTE.
    case micMute = 91
    case volumeMute = 164
    case guide = 172
    case settings = 176
    case tvPower = 177
    case tvInput = 178
    case tvAntennaCable = 242
    case tvInputHDMI1 = 243
    case tvInputHDMI2 = 244
    case tvInputHDMI3 = 245
    case tvInputHDMI4 = 246
    case tvInputComposite1 = 247
    case tvInputComponent1 = 249

    case comma = 55
    case period = 56
    case space = 62
    case enter = 66
    case del = 67
    case minus = 69
    case at = 77
    case search = 84
}

/// Raw Android keycodes for printable characters.
///
/// These are deliberately *not* `KeyCode` cases: a Swift enum only accepts raw
/// values it declares, so `KeyCode(rawValue: 30)` for 'b' returned nil and
/// characters were silently dropped. A…Z and 0…9 are contiguous ranges, so they
/// are computed instead.
public enum CharacterKey {
    public static func code(for character: Character) -> UInt64? {
        let lower = Character(character.lowercased())
        if let ascii = lower.asciiValue {
            switch ascii {
            case 97...122: return UInt64(29 + (ascii - 97))   // a…z -> 29…54
            case 48...57:  return UInt64(7 + (ascii - 48))    // 0…9 -> 7…16
            default: break
            }
        }
        switch lower {
        case " ": return 62
        case ",": return 55
        case ".": return 56
        case "-": return 69
        case "@": return 77
        case "+": return 81
        case "=": return 70
        case "/": return 76
        default:  return nil
        }
    }
}

/// A live connection on port 6466. Schema from `remotemessage.proto`.
///
/// Handshake: the device speaks first with `remote_configure`, we answer with
/// our own device info, it sends `remote_set_active`, we echo it back. After
/// that the session is live and the device pings every few seconds — an
/// unanswered ping drops the connection, so the read loop must keep running
/// for as long as the session is held.
public actor RemoteSession: DeviceSession {

    private enum F {
        static let configure = 1, setActive = 2, error = 3
        static let pingRequest = 8, pingResponse = 9
        static let keyInject = 10
        static let imeKeyInject = 20
        static let imeBatchEdit = 21
        static let imeShowRequest = 22
        static let start = 40
        static let setVolumeLevel = 50
        static let appLinkLaunchRequest = 90
    }

    /// What the device reports back about itself.
    public struct DeviceState: Sendable, Equatable {
        public var currentApp: String?
        public var volumeLevel: Int?
        public var volumeMax: Int?
        public var volumeMuted: Bool?
        /// From RemoteStart: whether the screen is on. Nil until reported.
        public var isOn: Bool?
        public var textFieldFocused = false
        /// The focused field's contents as the TV last reported them, and a
        /// count of reports so a caller can wait for the next one. The TV
        /// reports after every change, which makes this the only way to
        /// confirm that a key press actually typed something.
        public var fieldValue: String?
        public var fieldRevision = 0
        public var imeCounter: UInt64 = 0
        public var imeFieldCounter: UInt64 = 0
        /// When the device last volunteered its foreground app. The TV only
        /// reports this on IME events, so a stale value must not be shown as
        /// if it were current.
        public var currentAppSeen: Date?

        public var currentAppIsFresh: Bool {
            guard let currentAppSeen else { return false }
            return Date().timeIntervalSince(currentAppSeen) < 20
        }
    }

    /// Feature bits announced in RemoteConfigure / RemoteSetActive.
    ///
    /// PING(1) | KEY(2) | IME(4) | POWER(32) | VOLUME(64) | APP_LINK(512)
    ///
    /// IME matters: without that bit the device never sends RemoteImeBatchEdit
    /// or announces a focused text field, so typing has nowhere to go. That was
    /// exactly why live typing did nothing.
    private static let activeFeatures: UInt64 = 1 | 2 | 4 | 32 | 64 | 512

    private static let directionStartLong: UInt64 = 1
    private static let directionEndLong: UInt64 = 2
    private static let directionShort: UInt64 = 3

    private let channel: Channel
    private var pumpTask: Task<Void, Never>?
    private var live = false
    private var state = DeviceState()

    // The device hands these out when a text field takes focus; a batch edit is
    // rejected unless it echoes the current pair back.
    private var imeCounter: UInt64 = 0
    private var imeFieldCounter: UInt64 = 0

    /// Last state the device reported. Useful as a feedback channel: send a
    /// volume key and watch `volumeLevel` move, which proves a command landed
    /// without needing to look at the screen.
    public var deviceState: DeviceState { state }

    /// True once the TV has issued ime counters — a text field is open and
    /// `.text` can set its contents directly.
    public var canEditText: Bool { imeCounter != 0 || imeFieldCounter != 0 }

    private init(channel: Channel) {
        self.channel = channel
    }

    // MARK: - Lifecycle

    public static func open(host: String, identity: SecIdentity) async throws -> RemoteSession {
        let channel = try await Channel.connect(host: host,
                                                port: ATVTransport.remotePort,
                                                identity: identity)
        let session = RemoteSession(channel: channel)
        try await session.handshake()
        await session.startPump()
        return session
    }

    private func handshake() async throws {
        Log.info("Session", "handshake: waiting for RemoteConfigure")
        // Device speaks first.
        let first = Proto.Reader(try await channel.receive())
        guard first.has(F.configure) else {
            Log.error("Session", "expected RemoteConfigure, got fields \(first.presentFields)")
            throw ATVError.pairingFailed("expected RemoteConfigure, device may not be paired")
        }
        try await channel.send(Proto.encode { w in
            w.message(F.configure) { m in
                m.varint(1, Self.activeFeatures)       // code1
                m.message(2) { info in                 // device_info
                    info.string(1, Self.hardwareModel())
                    info.string(2, "Apple")
                    info.varint(3, 1)
                    info.string(4, "1")
                    info.string(5, "atvremote")
                    info.string(6, "1.0.0")
                }
            }
        })

        Log.info("Session", "sent our RemoteConfigure")
        let second = Proto.Reader(try await channel.receive())
        if second.has(F.setActive) {
            try await channel.send(Proto.encode { w in
                w.message(F.setActive) { m in m.varint(1, Self.activeFeatures) }
            })
        }
        live = true
        Log.info("Session", "handshake complete — session live")
    }

    /// Keeps answering pings and tracks whatever state the device volunteers.
    private func startPump() {
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                guard let payload = try? await self.channel.receive(timeout: 30) else {
                    // The device stopped pinging: it went to sleep, rebooted or
                    // dropped us. Mark the session dead so callers reconnect
                    // instead of writing into a closed socket.
                    await self.markDead()
                    break
                }
                await self.handle(Proto.Reader(payload))
            }
        }
    }

    private func markDead() {
        guard live else { return }
        Log.warn("Session", "read loop ended — session no longer live")
        live = false
    }

    /// False once the read loop has ended or `disconnect` was called.
    public var isLive: Bool { live }

    private func handle(_ message: Proto.Reader) async {
        if let ping = message.message(F.pingRequest) {
            let value = ping.varint(1) ?? 0
            let response = Proto.encode { w in
                w.message(F.pingResponse) { m in m.varint(1, value) }
            }
            try? await channel.send(response)
            return
        }

        // Everything except pings, so the log shows what a given TV actually
        // announces — devices differ in which IME messages they send.
        Log.debug("Session", "message fields \(message.presentFields)")
        if message.has(F.imeKeyInject) || message.has(F.imeBatchEdit) || message.has(F.imeShowRequest) {
            Log.bytes("Session", "ime message", message.raw, limit: 160)
        }

        // RemoteImeShowRequest { RemoteTextFieldStatus remote_text_field_status = 2 }
        if let show = message.message(F.imeShowRequest) {
            state.textFieldFocused = true
            adoptFieldStatus(show.message(2))
            Log.info("Session", "device opened a text field (field counter \(imeFieldCounter))")
        }

        // RemoteImeKeyInject { RemoteAppInfo app_info = 1;
        //                      RemoteTextFieldStatus text_field_status = 2 }
        if let ime = message.message(F.imeKeyInject) {
            if let package = ime.message(1)?.string(12) {   // RemoteAppInfo.app_package
                if state.currentApp != package {
                    Log.info("Session", "foreground app: \(package)")
                }
                state.currentApp = package
                state.currentAppSeen = Date()
            }
            // Some TVs announce a focused field only this way, never with a
            // show request.
            if let status = ime.message(2) {
                state.textFieldFocused = true
                adoptFieldStatus(status)
                Log.info("Session", "text field focused via key inject (field counter \(imeFieldCounter))")
            }
        }

        if message.has(F.imeShowRequest) == false, message.has(F.setActive) {
            // Device re-armed the session; assume no field until it says otherwise.
            state.textFieldFocused = false
        }

        if let edit = message.message(F.imeBatchEdit) {
            let ime = edit.varint(1) ?? 0
            let field = edit.varint(2) ?? 0
            if ime == 0 && field == 0 {
                // The TV sends 0/0 when the field closes.
                imeCounter = 0
                imeFieldCounter = 0
                state.textFieldFocused = false
                state.fieldValue = nil
                state.fieldRevision += 1
            } else {
                imeCounter = ime
                // The field counter that edits must echo is the one from the
                // focus announcement (show request / key inject). The TV
                // follows that with a batch edit carrying field 0, and
                // adopting that 0 made it silently drop every edit we sent.
                if field != 0 { imeFieldCounter = field }
                state.textFieldFocused = true
            }
            state.imeCounter = imeCounter
            state.imeFieldCounter = imeFieldCounter
            Log.debug("Session", "ime counters \(ime)/\(field) -> using \(imeCounter)/\(imeFieldCounter)")
        }

        if let volume = message.message(F.setVolumeLevel) {
            state.volumeLevel = volume.varint(7).map(Int.init)
            state.volumeMax = volume.varint(6).map(Int.init)
            state.volumeMuted = volume.varint(8).map { $0 != 0 }
            Log.info("Session", "volume \(state.volumeLevel ?? -1)/\(state.volumeMax ?? -1)" +
                                (state.volumeMuted == true ? " (muted)" : ""))
        }

        if let start = message.message(F.start), let started = start.varint(1) {
            state.isOn = started != 0
            Log.info("Session", "device reports started=\(started != 0)")
        }
    }

    /// RemoteTextFieldStatus { int32 counter_field = 1; string value = 2;
    /// int32 start = 3; int32 end = 4; ... string label = 6; }
    private func adoptFieldStatus(_ status: Proto.Reader?) {
        guard let status else { return }
        state.fieldValue = status.string(2) ?? ""
        state.fieldRevision += 1
        guard let counter = status.varint(1) else { return }
        imeFieldCounter = counter
        state.imeFieldCounter = counter
    }

    /// Waits briefly for the device to announce a focused text field.
    ///
    /// The TV sends its IME counters shortly *after* the handshake, so typing
    /// immediately on connect starts on the keycode path and switches to batch
    /// edits mid-word. Give it a moment so the whole string takes one route.
    @discardableResult
    public func waitForTextField(timeout: TimeInterval = 1.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.textFieldFocused { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return state.textFieldFocused
    }

    public func disconnect() {
        Log.info("Session", "disconnect")
        pumpTask?.cancel()
        pumpTask = nil
        live = false
        channel.close()
    }

    // MARK: - Sending

    public func send(_ command: RemoteCommand) async throws {
        guard live else { throw ATVError.connectionClosed }

        switch command {
        case .launchApp(let link):
            try await channel.send(Proto.encode { w in
                w.message(F.appLinkLaunchRequest) { m in m.string(1, link) }
            })
        case .text(let value):
            try await sendText(value)
        case .character(let character):
            // A batch edit is the device's own text-entry path and handles any
            // character. It is only valid once the TV has issued ime counters,
            // which it does when a text field takes focus — fall back to a raw
            // keycode otherwise.
            if imeCounter != 0 || imeFieldCounter != 0 {
                try await sendText(String(character))
            } else if let code = CharacterKey.code(for: character) {
                Log.debug("Session", "char '\(character)' -> keycode \(code) (no ime counters)")
                try await send(code, direction: Self.directionShort)
            } else {
                Log.warn("Session", "no keycode for '\(character)'")
            }
        case .backspace:
            try await press(.del)
        case .enter:
            try await press(.enter)
        case .search:
            try await press(.search)
        case .input(let index):
            // 1…4 jump straight to that HDMI port; 0 opens the input picker.
            switch index {
            case 1: try await press(.tvInputHDMI1)
            case 2: try await press(.tvInputHDMI2)
            case 3: try await press(.tvInputHDMI3)
            case 4: try await press(.tvInputHDMI4)
            default: try await press(.tvInput)
            }
        default:
            guard let key = Self.keyCode(for: command) else {
                throw ATVError.notImplemented("\(command)")
            }
            try await press(key)
        }
    }

    /// Sets the focused TV text field's contents to `text`.
    ///
    /// `value` is the field's whole contents, not an insertion: sending one
    /// character at a time left only the last character in the field.
    ///
    /// RemoteImeObject carries start/end as `len - 1`, matching the reference
    /// implementation. The counters must mirror the last batch edit the device
    /// sent us, which is why they are tracked in the read loop.
    public func sendText(_ text: String) async throws {
        guard live else { throw ATVError.connectionClosed }
        guard !text.isEmpty else { return }
        let caret = UInt64(max(text.count - 1, 0))
        Log.info("Session", "type \"\(text)\" (counters \(imeCounter)/\(imeFieldCounter))")

        try await channel.send(Proto.encode { w in
            w.message(F.imeBatchEdit) { m in
                m.varint(1, imeCounter)
                m.varint(2, imeFieldCounter)
                m.message(3) { edit in            // edit_info
                    edit.varint(1, 1)             // insert
                    edit.message(2) { obj in      // RemoteImeObject
                        obj.varint(1, caret)      // start
                        obj.varint(2, caret)      // end
                        obj.string(3, text)       // value
                    }
                }
            }
        })
    }

    private func press(_ key: KeyCode) async throws {
        Log.info("Session", "key \(key)")
        try await send(key, direction: Self.directionShort)
    }

    /// Holds a key down until `release` is called for it.
    ///
    /// TV browsers move their cursor for as long as an arrow is held, gliding
    /// and speeding up; an instant tap barely moves it. So the touchpad holds
    /// arrows rather than tapping them.
    public func hold(_ command: RemoteCommand) async throws {
        guard live else { throw ATVError.connectionClosed }
        guard let key = Self.keyCode(for: command) else { throw ATVError.notImplemented("\(command)") }
        try await send(key, direction: Self.directionStartLong)
    }

    public func release(_ command: RemoteCommand) async throws {
        guard live else { throw ATVError.connectionClosed }
        guard let key = Self.keyCode(for: command) else { throw ATVError.notImplemented("\(command)") }
        try await send(key, direction: Self.directionEndLong)
    }

    /// Press and hold. Android TV surfaces different behaviour on a long press —
    /// holding Home opens the quick-settings/input panel on many devices, which
    /// is the only route to input switching when the HDMI keycodes are ignored.
    public func longPress(_ key: KeyCode, milliseconds: UInt64 = 1200) async throws {
        guard live else { throw ATVError.connectionClosed }
        Log.info("Session", "long press \(key) for \(milliseconds)ms")
        try await send(key, direction: Self.directionStartLong)
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        try await send(key, direction: Self.directionEndLong)
    }

    private func send(_ key: KeyCode, direction: UInt64) async throws {
        try await send(key.rawValue, direction: direction)
    }

    private func send(_ rawKeyCode: UInt64, direction: UInt64) async throws {
        try await channel.send(Proto.encode { w in
            w.message(F.keyInject) { m in
                m.varint(1, rawKeyCode)
                m.varint(2, direction)
            }
        })
    }

    public static func keyCode(for command: RemoteCommand) -> KeyCode? {
        switch command {
        case .power:        return .power
        case .up:           return .dpadUp
        case .down:         return .dpadDown
        case .left:         return .dpadLeft
        case .right:        return .dpadRight
        case .select:       return .dpadCenter
        case .back:         return .back
        case .home:         return .home
        case .menu:         return .menu
        case .volumeUp:     return .volumeUp
        case .volumeDown:   return .volumeDown
        case .mute:         return .volumeMute
        case .playPause:    return .mediaPlayPause
        case .next:         return .mediaNext
        case .previous:     return .mediaPrevious
        case .rewind:       return .mediaRewind
        case .fastForward:  return .mediaFastForward
        case .settings:     return .settings
        case .guide:        return .guide
        case .backspace:    return .del
        case .enter:        return .enter
        case .search:       return .search
        case .character: return nil
        case .input, .launchApp, .text: return nil
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

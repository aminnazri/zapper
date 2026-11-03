import Foundation
import Darwin

/// The Zapper Bluetooth bridge: an ESP32 running `Firmware/zapper-bridge`,
/// plugged into this Mac by USB.
///
/// macOS will not let an app present itself as a Bluetooth keyboard or mouse
/// (CoreBluetooth refuses the HID service), so the board does it: the TV pairs
/// with it as "Zapper Remote", and this class drives it over USB serial. That
/// needs no network at all, gives TV browsers a real mouse pointer, and types
/// real keystrokes in every app.
///
/// Commands are one line each; the board answers OK / ERR in order, except
/// mouse moves, which stream unanswered. See the firmware for the protocol.
public final class BluetoothBridge: @unchecked Sendable {

    /// Serial devices an ESP32 board can show up as: CP210x, CH34x and FTDI
    /// bridge chips, and native USB on the S3 / C3.
    public static func candidatePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let prefixes = ["cu.usbserial", "cu.usbmodem", "cu.SLAB_USBtoUART", "cu.wchusbserial"]
        return names.filter { name in prefixes.contains { name.hasPrefix($0) } }
                    .sorted()
                    .map { "/dev/" + $0 }
    }

    /// Opens the first port that answers like a bridge — of `ports`, or of
    /// every candidate port.
    public static func open(ports: [String]? = nil) async throws -> BluetoothBridge {
        let ports = ports ?? candidatePorts()
        guard !ports.isEmpty else { throw ATVError.bridgeNotFound }
        for port in ports {
            guard let bridge = try? BluetoothBridge(path: port) else { continue }
            if await bridge.handshake() {
                Log.info("Bridge", "bridge on \(port), TV \(bridge.tvConnected ? "connected" : "not connected")")
                return bridge
            }
            bridge.close()
        }
        throw ATVError.bridgeFailed("A USB serial device is plugged in, but it isn\u{2019}t running "
                                  + "the Zapper firmware. Run Scripts/flash-bridge.sh.")
    }

    public let path: String
    private let fd: Int32
    private let queue = DispatchQueue(label: "zapper.bridge")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var pongWaiter: CheckedContinuation<Bool, Never>?
    private var connectedToTV = false
    private var open = true

    /// Whether a TV is connected to the board over Bluetooth.
    public var tvConnected: Bool { lock.withLock { connectedToTV } }
    /// False once the board was unplugged or the port closed.
    public var isOpen: Bool { lock.withLock { open } }

    private init(path: String) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ATVError.bridgeFailed("Could not open \(path): \(String(cString: strerror(errno)))") }

        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &options)
        // Both lines released: on boards with auto-reset, asserting them
        // holds the chip in reset or in its bootloader.
        var lines: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &lines)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// Pings until the board answers. A board that resets when the port
    /// opens needs about a second to boot.
    private func handshake() async -> Bool {
        for _ in 0..<10 {
            let answered = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
                lock.withLock { pongWaiter = k }
                write("PING")
                queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    let pending = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                        defer { self.pongWaiter = nil }
                        return self.pongWaiter
                    }
                    pending?.resume(returning: false)
                }
            }
            if answered { return true }
        }
        return false
    }

    /// Sends a command and waits for the board's answer.
    public func command(_ line: String, timeout: TimeInterval = 1.5) async throws {
        guard isOpen else { throw ATVError.bridgeFailed("The Bluetooth adapter was unplugged.") }
        let reply = await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            lock.withLock { waiters.append(k) }
            write(line)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                // Timed out: drop this waiter if it is still the oldest.
                guard let self else { return }
                let stale = self.lock.withLock { () -> CheckedContinuation<String?, Never>? in
                    self.waiters.isEmpty ? nil : self.waiters.removeFirst()
                }
                stale?.resume(returning: nil)
            }
        }
        guard let reply else { throw ATVError.bridgeFailed("The Bluetooth adapter stopped answering.") }
        if reply == "ERR no-tv" { throw ATVError.bridgeNoTV }
        if reply.hasPrefix("ERR") { throw ATVError.bridgeFailed(reply) }
    }

    /// Sends without waiting — for mouse moves, which arrive at drag rate.
    public func stream(_ line: String) {
        guard isOpen else { return }
        write(line)
    }

    public func close() {
        let wasOpen = lock.withLock { () -> Bool in defer { open = false }; return open }
        guard wasOpen else { return }
        write("R")
        queue.async { [source] in source?.cancel() }
        failWaiters()
    }

    // MARK: - Port I/O

    private func write(_ line: String) {
        let data = Array((line + "\n").utf8)
        queue.async { [fd] in
            var offset = 0
            var spins = 0
            while offset < data.count, spins < 200 {
                let n = data[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 { offset += n; continue }
                if n < 0 && errno != EAGAIN { break }
                spins += 1
                usleep(1_000)
            }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                Log.info("Bridge", "port closed (unplugged?)")
                lock.withLock { open = false }
                source?.cancel()
                failWaiters()
            }
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handle(line) }
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("PONG") {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                connectedToTV = line.hasSuffix("1")
                defer { pongWaiter = nil }
                return pongWaiter
            }
            pending?.resume(returning: true)
        } else if line.hasPrefix("STATE") {
            let now = line.hasSuffix("1")
            lock.withLock { connectedToTV = now }
            Log.info("Bridge", now ? "TV connected over Bluetooth" : "TV disconnected")
        } else if line == "OK" || line.hasPrefix("ERR") {
            let waiter = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
            waiter?.resume(returning: line)
        } else {
            Log.debug("Bridge", "board: \(line)")
        }
    }

    private func failWaiters() {
        let (pending, pong) = lock.withLock { () -> ([CheckedContinuation<String?, Never>], CheckedContinuation<Bool, Never>?) in
            defer { waiters = []; pongWaiter = nil }
            return (waiters, pongWaiter)
        }
        pending.forEach { $0.resume(returning: nil) }
        pong?.resume(returning: false)
    }
}

/// A remote session over the bridge: Zapper's commands as Bluetooth
/// keyboard, consumer-control and mouse input.
public final class BluetoothSession: DeviceSession, @unchecked Sendable {

    public let bridge: BluetoothBridge

    private init(bridge: BluetoothBridge) { self.bridge = bridge }

    public static func open(ports: [String]? = nil) async throws -> BluetoothSession {
        BluetoothSession(bridge: try await BluetoothBridge.open(ports: ports))
    }

    public var tvConnected: Bool { bridge.tvConnected }
    public var isLive: Bool { bridge.isOpen }

    /// Keyboard usages (HID page 0x07) and consumer usages (page 0x0C), as
    /// Android maps them: AC Home and AC Back are Home and Back, Escape would
    /// also be Back but some apps read it as a key.
    private enum Usage {
        case key(UInt16)
        case consumer(UInt16)
    }

    private static func usage(for command: RemoteCommand) -> Usage? {
        switch command {
        case .up: return .key(0x52)
        case .down: return .key(0x51)
        case .left: return .key(0x50)
        case .right: return .key(0x4F)
        case .select, .enter: return .key(0x28)
        case .backspace: return .key(0x2A)
        case .menu: return .key(0x65)
        case .back: return .consumer(0x0224)
        case .home: return .consumer(0x0223)
        case .search: return .consumer(0x0221)
        case .volumeUp: return .consumer(0x00E9)
        case .volumeDown: return .consumer(0x00EA)
        case .mute: return .consumer(0x00E2)
        case .playPause: return .consumer(0x00CD)
        case .next: return .consumer(0x00B5)
        case .previous: return .consumer(0x00B6)
        case .rewind: return .consumer(0x00B4)
        case .fastForward: return .consumer(0x00B3)
        case .power: return .consumer(0x0030)
        case .guide: return .consumer(0x008D)
        case .settings: return .consumer(0x019F)
        case .input, .character, .launchApp, .text: return nil
        }
    }

    public func send(_ command: RemoteCommand) async throws {
        switch command {
        case .character(let c):
            try await type(String(c))
        case .text(let text):
            try await type(text)
        case .launchApp:
            throw ATVError.bridgeFailed("Opening apps needs the Wi-Fi connection. "
                                      + "Over Bluetooth, use Home and the arrows.")
        case .input:
            throw ATVError.bridgeFailed("Switching inputs needs the Wi-Fi connection.")
        default:
            switch Self.usage(for: command) {
            case .key(let u)?: try await bridge.command("K \(String(u, radix: 16))")
            case .consumer(let u)?: try await bridge.command("C \(String(u, radix: 16))")
            case nil: throw ATVError.notImplemented("\(command) over Bluetooth")
            }
        }
    }

    /// Holds a key down, for arrows that should repeat or glide.
    public func hold(_ command: RemoteCommand) async throws {
        switch Self.usage(for: command) {
        case .key(let u)?: try await bridge.command("KD \(String(u, radix: 16))")
        case .consumer(let u)?: try await bridge.command("CD \(String(u, radix: 16))")
        case nil: break
        }
    }

    public func release(_ command: RemoteCommand) async throws {
        switch Self.usage(for: command) {
        case .key(let u)?: try await bridge.command("KU \(String(u, radix: 16))")
        case .consumer?: try await bridge.command("CU")
        case nil: break
        }
    }

    /// Types ASCII text as keystrokes. Other characters have no key on a US
    /// keyboard and are skipped.
    public func type(_ text: String) async throws {
        let typable = String(text.filter { $0.isASCII && ($0 == " " || !$0.isWhitespace || $0 == "\n") })
        // The board's line buffer holds 255 bytes; it taps each key ~25 ms.
        var rest = Substring(typable)
        while !rest.isEmpty {
            let chunk = rest.prefix(200)
            rest = rest.dropFirst(chunk.count)
            try await bridge.command("T \(chunk)", timeout: 1 + Double(chunk.count) * 0.06)
        }
    }

    public func backspace(times: Int) async throws {
        for _ in 0..<times { try await bridge.command("K 2a") }
    }

    // MARK: - Mouse

    public func moveMouse(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        bridge.stream("M \(dx) \(dy)")
    }

    public func scroll(_ amount: Int) {
        guard amount != 0 else { return }
        bridge.stream("M 0 0 \(amount)")
    }

    public func click() async throws {
        try await bridge.command("B 1")
        try await bridge.command("B 0")
    }

    public func disconnect() async {
        bridge.close()
    }
}

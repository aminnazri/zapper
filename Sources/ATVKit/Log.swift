import Foundation

/// File + console logging, so failures are diagnosable after the fact.
///
/// Writes to ~/Library/Logs/Zapper/zapper.log, rotating at 2 MB. The GUI
/// has no console, so without this a failed connection is just a one-line
/// status string with no context.
public enum Log {

    public enum Level: Int, Comparable, Sendable {
        case debug = 0, info = 1, warn = 2, error = 3

        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO "
            case .warn:  return "WARN "
            case .error: return "ERROR"
            }
        }
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Set to `.debug` to capture protocol traffic.
    nonisolated(unsafe) public static var level: Level = .debug

    /// Also mirror to stdout. On for the CLI, off for the GUI.
    nonisolated(unsafe) public static var echoToConsole = false

    public static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Zapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zapper.log")
    }

    private static let queue = DispatchQueue(label: "atv.log")
    private static let maxBytes = 2 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        write(.debug, tag, message())
    }
    public static func info(_ tag: String, _ message: @autoclosure () -> String) {
        write(.info, tag, message())
    }
    public static func warn(_ tag: String, _ message: @autoclosure () -> String) {
        write(.warn, tag, message())
    }
    public static func error(_ tag: String, _ message: @autoclosure () -> String) {
        write(.error, tag, message())
    }

    /// Hex dump for protocol bytes, truncated so the log stays readable.
    public static func bytes(_ tag: String, _ label: String, _ data: Data, limit: Int = 64) {
        guard level <= .debug else { return }
        let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        let suffix = data.count > limit ? " … (\(data.count) bytes)" : " (\(data.count) bytes)"
        debug(tag, "\(label): \(shown)\(suffix)")
    }

    private static func write(_ level: Level, _ tag: String, _ message: String) {
        guard level >= self.level else { return }
        let line = "\(stamp.string(from: Date())) \(level.label) [\(tag)] \(message)\n"
        if echoToConsole { FileHandle.standardError.write(Data(line.utf8)) }

        queue.async {
            let url = fileURL
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes else { return }
        let previous = url.deletingLastPathComponent()
            .appendingPathComponent("zapper.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    /// Last `count` lines, for showing in the UI.
    public static func tail(_ count: Int = 200) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "(no log yet)"
        }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    /// Blocks until every queued line is on disk.
    ///
    /// Writes are asynchronous, so a short-lived process (the CLI) would
    /// otherwise exit with its log lines still in the queue — which made CLI
    /// failures invisible in the log, exactly when they were most needed.
    public static func flush() {
        queue.sync { }
    }

    public static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}

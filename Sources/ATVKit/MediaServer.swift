import Foundation
import Network

/// Minimal HTTP file server.
///
/// A Cast receiver plays from a URL, so a local file has to be reachable over
/// HTTP from the TV. Supports Range requests, which video seeking on the
/// receiver depends on.
public final class MediaServer: @unchecked Sendable {

    private let listener: NWListener
    private let file: URL
    private let mimeType: String
    private let fileSize: Int
    public private(set) var port: UInt16 = 0

    /// URL to hand the receiver. Uses this Mac's LAN address, not localhost.
    public var url: String? { url(preferIPv6: false) }

    /// - Parameter preferIPv6: serve over this Mac's link-local IPv6 instead.
    ///   Needed when the receiver has no IPv4 address reachable from here —
    ///   these Mi TVs sit on the same L2 segment but share no IPv4 subnet, so
    ///   link-local is the only address family both ends hold.
    public func url(preferIPv6: Bool) -> String? {
        let name = file.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media"
        if preferIPv6, let v6 = MediaServer.linkLocalIPv6() {
            return "http://[\(v6)]:\(port)/\(name)"
        }
        guard let host = MediaServer.localAddress() else { return nil }
        return "http://\(host):\(port)/\(name)"
    }

    /// This Mac's fe80:: address, without the %zone suffix (a zone is only
    /// meaningful locally and would be rejected inside a URL by the receiver).
    public static func linkLocalIPv6() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: host)
            guard ip.hasPrefix("fe80:") else { continue }
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
            return ip
        }
        return nil
    }

    public init(file: URL) throws {
        self.file = file
        self.mimeType = MediaServer.mimeType(for: file)
        self.fileSize = (try? FileManager.default
            .attributesOfItem(atPath: file.path)[.size] as? Int) .flatMap { $0 } ?? 0

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)

        // All stored properties are set above, so `self` may now be captured.
        // NWListener assigns the port asynchronously, hence the wait.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: DispatchQueue(label: "media.server"))
        _ = ready.wait(timeout: .now() + 5)
        Log.info("MediaServer", "serving \(file.lastPathComponent) (\(fileSize) bytes) on port \(port)")
    }

    public func stop() {
        listener.cancel()
        Log.info("MediaServer", "stopped")
    }

    // MARK: - Serving

    private func serve(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "media.conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let isHead = request.hasPrefix("HEAD")
            let range = MediaServer.parseRange(request, fileSize: self.fileSize)
            Log.debug("MediaServer", "request \(request.split(separator: "\r\n").first ?? "") range=\(range?.description ?? "none")")
            self.respond(on: connection, range: range, headOnly: isHead)
        }
    }

    private func respond(on connection: NWConnection, range: Range<Int>?, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        let effective = range ?? 0..<fileSize
        let length = effective.count
        var header = range == nil
            ? "HTTP/1.1 200 OK\r\n"
            : "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(effective.lowerBound)-\(effective.upperBound - 1)/\(fileSize)\r\n"
        header += "Content-Type: \(mimeType)\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"

        // The file handle must outlive the async sends. An earlier version used
        // `defer { handle.close() }`, which fired when this function returned —
        // before the completion callback read anything — so every response was
        // a valid 200 with an empty body.
        try? handle.seek(toOffset: UInt64(effective.lowerBound))

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            guard !headOnly else {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.stream(handle: handle,
                         remaining: length,
                         on: connection)
        })
    }

    /// Sends the body in chunks so a multi-gigabyte video never lands in memory.
    private func stream(handle: FileHandle, remaining: Int, on connection: NWConnection) {
        guard remaining > 0 else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let chunkSize = min(remaining, 256 * 1024)
        guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.stream(handle: handle, remaining: remaining - chunk.count, on: connection)
        })
    }

    private static func parseRange(_ request: String, fileSize: Int) -> Range<Int>? {
        guard let line = request.split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") }) else { return nil }
        guard let spec = line.split(separator: "=").last else { return nil }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let startText = parts.first, let start = Int(startText) else { return nil }
        let end = parts.count > 1 ? Int(parts[1]) : nil
        let upper = min((end ?? fileSize - 1) + 1, fileSize)
        guard start < upper else { return nil }
        return start..<upper
    }

    // MARK: - Helpers

    static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        case "mkv":        return "video/x-matroska"
        case "webm":       return "video/webm"
        case "mp3":        return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac":       return "audio/flac"
        case "wav":        return "audio/wav"
        case "jpg", "jpeg":return "image/jpeg"
        case "png":        return "image/png"
        case "gif":        return "image/gif"
        case "heic":       return "image/heic"
        default:           return "application/octet-stream"
        }
    }

    /// This Mac's IPv4 LAN address — the receiver must be able to reach it, so
    /// localhost is useless here.
    public static func localAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            return ip
        }
        return nil
    }

    public static func mediaKind(for file: URL) -> String {
        let type = mimeType(for: file)
        if type.hasPrefix("image/") { return "PHOTO" }
        if type.hasPrefix("audio/") { return "MUSIC_TRACK" }
        return "MOVIE"
    }
}

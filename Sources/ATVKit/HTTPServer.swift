import Foundation
import Network

/// Minimal HTTP server for content generated on the fly, such as the live
/// screen stream's playlist and segments. `MediaServer` covers single files.
///
/// Every response carries `Access-Control-Allow-Origin: *`: the Cast receiver
/// is a web page, and its HLS player fetches over XHR, which CORS blocks
/// without it.
public final class HTTPServer: @unchecked Sendable {

    public typealias Handler = @Sendable (_ path: String) -> (data: Data, contentType: String)?

    private let listener: NWListener
    private let handler: Handler
    public private(set) var port: UInt16 = 0

    public init(handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)

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
        listener.start(queue: DispatchQueue(label: "http.server"))
        _ = ready.wait(timeout: .now() + 5)
        Log.info("HTTPServer", "listening on port \(port)")
    }

    /// Base URL the TV can reach, e.g. `http://192.168.1.15:50123`.
    public func baseURL(preferIPv6: Bool) -> String? {
        if preferIPv6, let v6 = MediaServer.linkLocalIPv6() {
            return "http://[\(v6)]:\(port)"
        }
        guard let host = MediaServer.localAddress() else { return nil }
        return "http://\(host):\(port)"
    }

    public func stop() {
        listener.cancel()
        Log.info("HTTPServer", "stopped")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "http.conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel(); return
            }
            let parts = line.split(separator: " ")
            let isHead = parts.first == "HEAD"
            let rawPath = parts.count > 1 ? String(parts[1]) : "/"
            let path = String(rawPath.split(separator: "?").first ?? "/")

            let head: String
            var body = Data()
            if let found = self.handler(path) {
                head = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: \(found.contentType)\r\n"
                    + "Content-Length: \(found.data.count)\r\n"
                    + "Cache-Control: no-cache\r\n"
                if !isHead { body = found.data }
            } else {
                head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
            }
            var response = Data((head
                + "Access-Control-Allow-Origin: *\r\n"
                + "Connection: close\r\n\r\n").utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

import Foundation

/// The private channel between OpenTraffic and its own command-line tool and MCP bridge: the local API's
/// HTTP over a Unix socket in OpenTraffic's Application Support folder. The app checks each caller's
/// code signature (only its own signed tools are let in), so they need no token and nothing asks first.
public enum AppSocket {
    public static let fileName = "opentraffic.sock"

    /// `~/Library/Application Support/OpenTraffic/opentraffic.sock`; `OPENTRAFFIC_SOCKET` overrides it.
    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["OPENTRAFFIC_SOCKET"], !path.isEmpty { return (path as NSString).expandingTildeInPath }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "OpenTraffic/\(fileName)").path
    }

    public struct Response: Sendable {
        public let status: Int
        public let body: Data
    }

    public enum Failure: Error, Equatable {
        /// Nothing is listening (OpenTraffic isn't running, or is an older version without the socket).
        case unavailable
        /// Connected, but the exchange broke off (the app quit, or refused this caller).
        case broken(String)
    }

    /// Sends one request on its own connection and waits for the answer. Blocking; call it off the main thread.
    public static func send(
        _ method: String,
        _ target: String,
        body: Data? = nil,
        client: String,
        timeout: TimeInterval = 330,
        socketPath: String = path()
    ) throws -> Response {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure.unavailable }

        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        // A client name is a header value: keep it to one printable line.
        let name = String(client.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(40))
        var request = Data("\(method) \(target) HTTP/1.1\r\nHost: opentraffic\r\nConnection: close\r\nX-OpenTraffic-Client: \(name)\r\nContent-Type: application/json\r\nContent-Length: \(body?.count ?? 0)\r\n\r\n".utf8)
        if let body { request.append(body) }
        try request.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw Failure.broken("OpenTraffic closed the connection.") }
                offset += written
            }
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { received.append(contentsOf: buffer[0..<count]) } else { break }
        }
        return try parse(received)
    }

    /// The status and body of an HTTP/1.1 response (the app always sends a Content-Length).
    static func parse(_ data: Data) throws -> Response {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.broken("OpenTraffic didn't answer.") }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw Failure.broken("OpenTraffic sent an answer this tool doesn't understand.")
        }
        var body = data[end.upperBound...]
        if let length = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") })
            .flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }) {
            body = body.prefix(length)
        }
        return Response(status: status, body: Data(body))
    }
}

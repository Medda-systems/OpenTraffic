import Darwin
import Foundation

/// OpenTunnel (opentunnel.xyz): one tunnel per profile with a stable `<id>.opentunnel.xyz` hostname,
/// and each shared app is a route on it, `<route>.<id>.opentunnel.xyz`. A background service started
/// by the `opentunnel` CLI keeps it connected. OpenTraffic uses its own profile so it never touches
/// routes or the service someone runs by hand.
public enum OpenTunnel {
    /// Debug builds can use another profile (`OPENTRAFFIC_OPENTUNNEL_PROFILE`), e.g. a throwaway
    /// one for demo captures.
    public static let profile: String = {
        #if DEBUG
        if let profile = ProcessInfo.processInfo.environment["OPENTRAFFIC_OPENTUNNEL_PROFILE"], !profile.isEmpty { return profile }
        #endif
        return "opentraffic"
    }()

    /// `brew install` command shown when the CLI is missing.
    public static let installCommand = "brew install anomalyco/tap/opentunnel"

    /// The URL of a route on a tunnel hostname.
    public static func url(route: String, hostname: String) -> String {
        route == "@" ? "https://\(hostname)" : "https://\(route).\(hostname)"
    }

    /// A route name for a share: one lowercase DNS label made from its name, not in `taken`.
    public static func routeName(for name: String, taken: Set<String>) -> String {
        var label = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                label.unicodeScalars.append(scalar)
            } else if !label.isEmpty, label.last != "-" {
                label.append("-")
            }
        }
        label = String(label.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(56))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if label.isEmpty { label = "site" }
        guard taken.contains(label) else { return label }
        var number = 2
        while taken.contains("\(label)-\(number)") { number += 1 }
        return "\(label)-\(number)"
    }

    public static func isValidRoute(_ name: String) -> Bool {
        name == "@" || (1...63).contains(name.utf8.count)
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-") }
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }

    /// The `host:port` target a route forwards to. OpenTunnel ends TLS on this Mac and passes the
    /// plain bytes on, so only `http://` origins work.
    public static func target(for localURL: String) -> String? {
        guard let url = URL(string: localURL), url.scheme?.lowercased() == "http", let host = url.host else { return nil }
        let port = url.port ?? 80
        let mapped = host.lowercased() == "localhost" ? "127.0.0.1" : host
        return mapped.contains(":") ? "[\(mapped)]:\(port)" : "\(mapped):\(port)"
    }

    // MARK: Files

    /// OpenTunnel's directories, worked out the way the CLI does (XDG variables, then `$HOME`) from
    /// the environment OpenTraffic runs it with, so both always look in the same place.
    public struct Paths: Sendable {
        public let data: URL
        public let config: URL
        public let state: URL
        public let runtime: URL

        public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            let home = environment["HOME"].flatMap(\.nilIfBlank).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            func xdg(_ variable: String, _ fallback: String) -> URL {
                environment[variable].flatMap(\.nilIfBlank).map { URL(fileURLWithPath: $0) } ?? home.appending(path: fallback)
            }
            data = xdg("XDG_DATA_HOME", ".local/share").appending(path: "opentunnel")
            config = xdg("XDG_CONFIG_HOME", ".config").appending(path: "opentunnel")
            state = xdg("XDG_STATE_HOME", ".local/state").appending(path: "opentunnel")
            if let runtime = environment["XDG_RUNTIME_DIR"].flatMap(\.nilIfBlank) {
                self.runtime = URL(fileURLWithPath: runtime).appending(path: "opentunnel")
            } else {
                let temporary = environment["TMPDIR"].flatMap(\.nilIfBlank).map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.temporaryDirectory
                self.runtime = temporary.appending(path: "opentunnel-\(getuid())")
            }
        }

        public var identity: URL { data.appending(path: "\(OpenTunnel.profile)/tunnel.json") }
        public var routes: URL { config.appending(path: "\(OpenTunnel.profile).toml") }
        public var log: URL { state.appending(path: "\(OpenTunnel.profile)/daemon.log") }
        /// The service's control socket.
        public var socket: URL { runtime.appending(path: "\(OpenTunnel.profile).sock") }
    }

    public static func identityURL() -> URL { Paths().identity }
    public static func logURL() -> URL { Paths().log }
    public static func configURL() -> URL { Paths().routes }
    public static func socketURL() -> URL { Paths().socket }

    /// The routes in the profile's config file (`[routes]`, one `name = "host:port"` per line), which
    /// is what `route add` and `route remove` edit, whether or not the service is running.
    public static func configuredRoutes(at url: URL = configURL()) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parseRoutes(text)
    }

    static func parseRoutes(_ text: String) -> [String: String] {
        var routes: [String: String] = [:]
        var inRoutes = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRoutes = line == "[routes]"
                continue
            }
            guard inRoutes, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let unquote = { (value: Substring) in value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            let name = unquote(line[..<equals])
            let target = unquote(line[line.index(after: equals)...])
            if !name.isEmpty, !target.isEmpty { routes[name] = target }
        }
        return routes
    }

    /// The tunnel's hostname, once it has been created.
    public static func hostname(identityAt url: URL = identityURL()) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["hostname"] as? String)?.nilIfBlank
    }

    /// The URL printed by `opentunnel route add`.
    public static func publicURL(inOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("https://") && !$0.contains(" ") }
    }
}

/// The service's answer to `{"command":"status"}` on its control socket.
public struct OpenTunnelStatus: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case noTunnel = "no-tunnel"
        case provisioning
        case running
        case stopped
    }

    public let phase: Phase
    public let version: String?
    /// `connected`, `connecting`, `waiting-routes`, `reconnecting`, …
    public let state: String?
    public let hostname: String?
    public let routes: [String: String]
    public let connections: Int
    public let lastError: String?

    public init(phase: Phase, version: String? = nil, state: String? = nil, hostname: String? = nil, routes: [String: String] = [:], connections: Int = 0, lastError: String? = nil) {
        self.phase = phase
        self.version = version
        self.state = state
        self.hostname = hostname
        self.routes = routes
        self.connections = connections
        self.lastError = lastError
    }

    public var isConnected: Bool { phase == .running && state == "connected" }

    public static func parse(_ data: Data) -> OpenTunnelStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              let status = object["status"] as? [String: Any],
              let phase = (status["phase"] as? String).flatMap(Phase.init(rawValue:)) else { return nil }
        let tunnel = status["tunnel"] as? [String: Any] ?? [:]
        return OpenTunnelStatus(
            phase: phase,
            version: status["version"] as? String,
            state: tunnel["state"] as? String,
            hostname: tunnel["hostname"] as? String,
            routes: tunnel["routes"] as? [String: String] ?? [:],
            connections: tunnel["connections"] as? Int ?? 0,
            lastError: (tunnel["last_error"] as? String) ?? (status["last_error"] as? String)
        )
    }

    /// Asks the running service; nil when it isn't running.
    public static func query(socket: URL = OpenTunnel.socketURL(), timeout: TimeInterval = 2) -> OpenTunnelStatus? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = Array(#"{"command":"status"}"#.utf8) + [10]
        guard write(fd, request, request.count) == request.count else { return nil }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 256 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(contentsOf: buffer[..<count])
            if buffer[..<count].contains(10) { break }
        }
        return parse(response)
    }
}

/// A route OpenTraffic added to its OpenTunnel profile, remembered so it can be removed exactly,
/// even after a crash.
public struct OpenTunnelRouteRecord: Codable, Hashable, Sendable {
    public let tunnelID: UUID
    public let route: String
    public let target: String

    public init(tunnelID: UUID, route: String, target: String) {
        self.tunnelID = tunnelID
        self.route = route
        self.target = target
    }
}

public struct OpenTunnelRouteRecordPersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTraffic", isDirectory: true)
            .appendingPathComponent("opentunnel-routes.json")
    }

    public func load() -> [OpenTunnelRouteRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([OpenTunnelRouteRecord].self, from: data)) ?? []
    }

    public func save(_ records: [OpenTunnelRouteRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }
}

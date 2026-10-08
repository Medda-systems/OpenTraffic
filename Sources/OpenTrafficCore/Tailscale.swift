import Foundation

/// What `tailscale status --json` says about this Mac.
public struct TailscaleStatus: Equatable, Sendable {
    public let backendState: String
    /// This Mac's MagicDNS name without the trailing dot, e.g. `macbook.tail1234.ts.net`.
    public let dnsName: String?
    public let httpsEnabled: Bool
    public let funnelEnabled: Bool

    public init(backendState: String, dnsName: String?, httpsEnabled: Bool, funnelEnabled: Bool) {
        self.backendState = backendState
        self.dnsName = dnsName
        self.httpsEnabled = httpsEnabled
        self.funnelEnabled = funnelEnabled
    }

    public var isRunning: Bool { backendState == "Running" }

    public static func parse(_ data: Data) -> TailscaleStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let backend = object["BackendState"] as? String ?? "Unknown"
        let me = object["Self"] as? [String: Any] ?? [:]
        let dnsName = (me["DNSName"] as? String)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .nilIfBlank
        let capabilities = Set((me["CapMap"] as? [String: Any] ?? [:]).keys)
        let certDomains = object["CertDomains"] as? [String] ?? []
        return TailscaleStatus(
            backendState: backend,
            dnsName: dnsName,
            httpsEnabled: capabilities.contains("https") || !certDomains.isEmpty,
            funnelEnabled: capabilities.contains { $0 == "funnel" || $0.hasPrefix("https://tailscale.com/cap/funnel") }
        )
    }
}

/// The node's current Serve/Funnel configuration from `tailscale serve status --json`.
public struct TailscaleServeConfig: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let port: Int
        public let proxy: String?
        public let isFunnel: Bool

        public init(port: Int, proxy: String?, isFunnel: Bool) {
            self.port = port
            self.proxy = proxy
            self.isFunnel = isFunnel
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var portsInUse: Set<Int> { Set(entries.map(\.port)) }

    public func entry(port: Int) -> Entry? {
        entries.first { $0.port == port }
    }

    public static func parse(_ data: Data) -> TailscaleServeConfig? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var proxies: [Int: String] = [:]
        for (hostPort, value) in object["Web"] as? [String: Any] ?? [:] {
            guard let port = Self.port(fromHostPort: hostPort),
                  let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any],
                  let root = handlers["/"] as? [String: Any] else { continue }
            proxies[port] = root["Proxy"] as? String
        }
        let funnelPorts = Set((object["AllowFunnel"] as? [String: Any] ?? [:]).compactMap { key, value in
            (value as? Bool) == true ? Self.port(fromHostPort: key) : nil
        })
        let ports = Set((object["TCP"] as? [String: Any] ?? [:]).keys.compactMap(Int.init)).union(proxies.keys)
        return TailscaleServeConfig(entries: ports.sorted().map {
            Entry(port: $0, proxy: proxies[$0], isFunnel: funnelPorts.contains($0))
        })
    }

    private static func port(fromHostPort value: String) -> Int? {
        value.split(separator: ":").last.flatMap { Int($0) }
    }
}

public enum TailscaleShare {
    /// Funnel only accepts these HTTPS ports.
    public static let funnelPorts = [443, 8443, 10000]
    /// Private shares prefer the clean port 443, then the Funnel ports, then a quiet range.
    public static let privatePorts = funnelPorts + Array(9443...9499)

    /// Picks the port for a share: the previously used port when it's free, otherwise the first free allowed one.
    public static func choosePort(isPublic: Bool, preferred: Int?, inUse: Set<Int>) -> Int? {
        let allowed = isPublic ? funnelPorts : privatePorts
        if let preferred, allowed.contains(preferred), !inUse.contains(preferred) { return preferred }
        return allowed.first { !inUse.contains($0) }
    }

    public static func url(dnsName: String, port: Int) -> String {
        port == 443 ? "https://\(dnsName)" : "https://\(dnsName):\(port)"
    }

    public static func shareArguments(port: Int, target: String, isPublic: Bool) -> [String] {
        [isPublic ? "funnel" : "serve", "--bg", "--yes", "--https=\(port)", target]
    }

    public static func stopArguments(port: Int, isPublic: Bool) -> [String] {
        [isPublic ? "funnel" : "serve", "--https=\(port)", "off"]
    }

    /// Tailscale only proxies to `127.0.0.1`/`localhost`; anything else needs OpenTraffic's local forwarder.
    public static func needsForwarder(host: String) -> Bool {
        !["127.0.0.1", "localhost"].contains(host.lowercased())
    }

    /// The Serve target for a loopback port, keeping HTTPS origins (self-signed dev certs) working.
    public static func target(scheme: String?, port: Int) -> String {
        scheme?.lowercased() == "https" ? "https+insecure://127.0.0.1:\(port)" : "http://127.0.0.1:\(port)"
    }
}

/// A share OpenTraffic applied to the Tailscale node, remembered so it can be removed exactly —
/// even after a crash — without touching shares created by anything else.
public struct TailscaleShareRecord: Codable, Hashable, Sendable {
    public let tunnelID: UUID
    public let port: Int
    public let isPublic: Bool
    public let target: String

    public init(tunnelID: UUID, port: Int, isPublic: Bool, target: String) {
        self.tunnelID = tunnelID
        self.port = port
        self.isPublic = isPublic
        self.target = target
    }

    /// Only remove a port if it still points where OpenTraffic left it.
    public func stillOwned(in config: TailscaleServeConfig) -> Bool {
        config.entry(port: port)?.proxy == target
    }
}

public struct TailscaleShareRecordPersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTraffic", isDirectory: true)
            .appendingPathComponent("tailscale-shares.json")
    }

    public func load() -> [TailscaleShareRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TailscaleShareRecord].self, from: data)) ?? []
    }

    public func save(_ records: [TailscaleShareRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }
}

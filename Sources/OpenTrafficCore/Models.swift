import Foundation

/// The service that publishes a tunnel. Each provider has its own tool, account model, and edge.
public enum TunnelProvider: String, Codable, Sendable, CaseIterable {
    case cloudflare
    case ngrok
    case tailscale
    case opentunnel

    public var title: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .ngrok: "ngrok"
        case .tailscale: "Tailscale"
        case .opentunnel: "OpenTunnel"
        }
    }

    /// The executable OpenTraffic drives for this provider.
    public var executableName: String {
        switch self {
        case .cloudflare: "cloudflared"
        case .ngrok: "ngrok"
        case .tailscale: "tailscale"
        case .opentunnel: "opentunnel"
        }
    }

    /// The network stop between this Mac and the public, as shown on the connection path.
    public var edgeTitle: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .ngrok: "ngrok"
        case .tailscale: "Tailnet"
        case .opentunnel: "OpenTunnel"
        }
    }
}

/// What a saved tunnel is. The raw values are persisted, so existing cases must never be renamed.
public enum TunnelKind: String, Codable, Sendable, CaseIterable {
    case quick
    case remote
    case tailscale
    case ngrok
    case opentunnel

    public var title: String {
        switch self {
        case .quick: "Quick Tunnel"
        case .remote: "Custom Domain"
        case .tailscale: "Tailscale"
        case .ngrok: "ngrok"
        case .opentunnel: "OpenTunnel"
        }
    }

    /// Plural heading for grouping tunnels of this kind.
    public var sectionTitle: String {
        switch self {
        case .quick: "Quick Tunnels"
        case .remote: "Custom Domains"
        case .tailscale: "Tailscale"
        case .ngrok: "ngrok"
        case .opentunnel: "OpenTunnel"
        }
    }

    public var provider: TunnelProvider {
        switch self {
        case .quick, .remote: .cloudflare
        case .tailscale: .tailscale
        case .ngrok: .ngrok
        case .opentunnel: .opentunnel
        }
    }

    /// Backed by a remotely managed tunnel in the user's Cloudflare account: needs the API token,
    /// has account-side status, ingress and DNS that OpenTraffic can check and repair.
    public var usesCloudflareAccount: Bool {
        switch self {
        case .quick, .tailscale, .ngrok, .opentunnel: false
        case .remote: true
        }
    }

    /// The connector reports the public URL at runtime (it can change between starts), so it's
    /// unknown until the tunnel is up.
    public var hasEphemeralURL: Bool {
        switch self {
        case .quick, .ngrok: true
        case .remote, .tailscale, .opentunnel: false
        }
    }

    /// Whether the provider's network reports its own status (an `edge` health check).
    /// Without one, the edge is considered up exactly when the connector is.
    public var reportsEdgeStatus: Bool {
        switch self {
        case .quick, .ngrok: false
        case .remote, .tailscale, .opentunnel: true
        }
    }

    /// Whether OpenTraffic can make the tunnel send the local host as the Host header. OpenTunnel
    /// shares get it from OpenTraffic's own proxy.
    public var supportsHostHeaderRewrite: Bool {
        switch self {
        case .quick, .remote, .ngrok, .opentunnel: true
        case .tailscale: false
        }
    }

    /// Live collaboration runs the share through OpenTraffic's proxy (see specs/collab-plan.md for
    /// the other kinds).
    public var supportsCollaboration: Bool {
        self == .quick || self == .opentunnel
    }

    /// Whether the connector exposes request and traffic metrics.
    public var reportsTraffic: Bool {
        switch self {
        case .quick, .remote, .ngrok: true
        case .tailscale, .opentunnel: false
        }
    }

    /// Placeholder for the public host before a URL is known.
    public var publicHostPlaceholder: String {
        switch self {
        case .quick: "trycloudflare.com"
        case .remote: "Public site"
        case .tailscale: "ts.net"
        case .ngrok: "ngrok-free.dev"
        case .opentunnel: "opentunnel.xyz"
        }
    }
}

public struct TunnelDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TunnelKind
    public var localURL: String
    public var hostname: String?
    public var cloudflareTunnelID: String?
    public var accountID: String?
    public var setupIncomplete: Bool
    /// Tailscale only: shared publicly through Funnel instead of privately on the tailnet.
    public var tailscalePublic: Bool
    /// Tailscale only: the HTTPS port last used, reused so the URL stays the same across restarts.
    public var tailscalePort: Int?
    /// Send the local service's own host (e.g. `localhost:5173`) as the Host header, for dev servers
    /// that reject unknown hostnames. Supported by Quick Tunnels, custom domains, and ngrok.
    public var rewriteHostHeader: Bool
    /// Paths worth copying with the public URL, such as `/api/webhooks/stripe`.
    public var savedPaths: [String]
    /// Start this tunnel whenever its local service is running.
    public var autoStart: Bool
    /// Tunnels with the same project name start and stop together.
    public var project: String?
    /// Who can open the public URL.
    public var protection: ShareProtection
    /// Custom domains: the Cloudflare Access application OpenTraffic created for `protection`.
    public var accessApplicationID: String?
    /// Live collaboration: visitors see each other's cursors and can follow the host.
    public var collaboration: Bool
    /// Other local ports the shared app uses that may be reached through the tunnel (localhost bridge).
    public var bridgedPorts: [Int]
    /// Collect visitors' browser errors during collaboration.
    public var captureErrors: Bool
    /// OpenTunnel only: the route (subdomain) on OpenTraffic's tunnel, kept so the URL stays the same.
    public var openTunnelRoute: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case localURL
        case hostname
        case cloudflareTunnelID
        case accountID
        case setupIncomplete
        case tailscalePublic
        case tailscalePort
        case rewriteHostHeader
        case savedPaths
        case autoStart
        case project
        case protection
        case accessApplicationID
        case collaboration
        case bridgedPorts
        case captureErrors
        case openTunnelRoute
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TunnelKind,
        localURL: String,
        hostname: String? = nil,
        cloudflareTunnelID: String? = nil,
        accountID: String? = nil,
        setupIncomplete: Bool = false,
        tailscalePublic: Bool = false,
        tailscalePort: Int? = nil,
        rewriteHostHeader: Bool = false,
        savedPaths: [String] = [],
        autoStart: Bool = false,
        project: String? = nil,
        protection: ShareProtection = .none,
        accessApplicationID: String? = nil,
        collaboration: Bool = false,
        bridgedPorts: [Int] = [],
        captureErrors: Bool = false,
        openTunnelRoute: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localURL = localURL
        self.hostname = hostname
        self.cloudflareTunnelID = cloudflareTunnelID
        self.accountID = accountID
        self.setupIncomplete = setupIncomplete
        self.tailscalePublic = tailscalePublic
        self.tailscalePort = tailscalePort
        self.rewriteHostHeader = rewriteHostHeader
        self.savedPaths = savedPaths
        self.autoStart = autoStart
        self.project = project?.nilIfBlank
        self.protection = protection
        self.accessApplicationID = accessApplicationID
        self.collaboration = collaboration
        self.bridgedPorts = bridgedPorts
        self.captureErrors = captureErrors
        self.openTunnelRoute = openTunnelRoute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(TunnelKind.self, forKey: .kind)
        localURL = try container.decode(String.self, forKey: .localURL)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        cloudflareTunnelID = try container.decodeIfPresent(String.self, forKey: .cloudflareTunnelID)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        setupIncomplete = try container.decodeIfPresent(Bool.self, forKey: .setupIncomplete) ?? false
        tailscalePublic = try container.decodeIfPresent(Bool.self, forKey: .tailscalePublic) ?? false
        tailscalePort = try container.decodeIfPresent(Int.self, forKey: .tailscalePort)
        rewriteHostHeader = try container.decodeIfPresent(Bool.self, forKey: .rewriteHostHeader) ?? false
        savedPaths = try container.decodeIfPresent([String].self, forKey: .savedPaths) ?? []
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        project = try container.decodeIfPresent(String.self, forKey: .project)?.nilIfBlank
        protection = (try? container.decodeIfPresent(ShareProtection.self, forKey: .protection)) ?? ShareProtection.none
        accessApplicationID = try container.decodeIfPresent(String.self, forKey: .accessApplicationID)
        collaboration = try container.decodeIfPresent(Bool.self, forKey: .collaboration) ?? false
        bridgedPorts = (try container.decodeIfPresent([Int].self, forKey: .bridgedPorts) ?? []).filter { (1...65_535).contains($0) }
        captureErrors = try container.decodeIfPresent(Bool.self, forKey: .captureErrors) ?? false
        openTunnelRoute = try container.decodeIfPresent(String.self, forKey: .openTunnelRoute)
    }

    /// The Host header a rewrite sends: the local service's `host[:port]`.
    public var originHostHeader: String? {
        guard let url = URL(string: localURL), let host = url.host else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

public enum LocalTunnelState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed

    public var title: String { rawValue.capitalized }
}

public enum RemoteTunnelStatus: String, Codable, Sendable {
    case inactive
    case degraded
    case healthy
    case down
    case unknown

    public init(apiValue: String?) {
        self = RemoteTunnelStatus(rawValue: apiValue ?? "") ?? .unknown
    }
}

public struct TunnelRuntime: Sendable, Equatable {
    public var state: LocalTunnelState
    public var publicURL: String?
    public var lastError: String?
    public var generation: UInt64
    public var startedAt: Date?
    public var metricsPort: UInt16?
    public var statistics: TunnelStatistics?
    /// What a starting tunnel is waiting on, when it isn't obvious (e.g. a Keychain prompt).
    public var startupNote: String?

    public init(
        state: LocalTunnelState = .stopped,
        publicURL: String? = nil,
        lastError: String? = nil,
        generation: UInt64 = 0,
        startedAt: Date? = nil,
        metricsPort: UInt16? = nil,
        statistics: TunnelStatistics? = nil
    ) {
        self.state = state
        self.publicURL = publicURL
        self.lastError = lastError
        self.generation = generation
        self.startedAt = startedAt
        self.metricsPort = metricsPort
        self.statistics = statistics
    }
}

public struct TunnelLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: String
    public let message: String
    public let stream: String
    public let rawLine: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: String = "info",
        message: String,
        stream: String = "stdout",
        rawLine: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.stream = stream
        self.rawLine = rawLine
    }
}

public struct CloudflareTunnel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let status: String?
    public let configSource: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case configSource = "config_src"
    }
}

/// Any JSON value, kept so remote configuration OpenTraffic doesn't manage is written back unchanged.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public struct CloudflareIngress: Codable, Hashable, Sendable {
    public let hostname: String?
    public let service: String
    /// Every other field of the rule (`path`, `originRequest`, …), preserved verbatim.
    public var additional: [String: JSONValue]

    public init(hostname: String? = nil, service: String, additional: [String: JSONValue] = [:]) {
        self.hostname = hostname
        self.service = service
        self.additional = additional
    }

    public var path: String? {
        if case .string(let value) = additional["path"] { return value.nilIfBlank }
        return nil
    }

    /// The `originRequest.httpHostHeader` override, if any.
    public var httpHostHeader: String? {
        if case .string(let value) = additional["originRequest"]?.objectValue?["httpHostHeader"] { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var hostname: String?
        var service = ""
        var additional: [String: JSONValue] = [:]
        for key in container.allKeys {
            switch key.stringValue {
            case "hostname": hostname = try container.decodeIfPresent(String.self, forKey: key)
            case "service": service = try container.decodeIfPresent(String.self, forKey: key) ?? ""
            default: additional[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
        self.init(hostname: hostname, service: service, additional: additional)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        if let hostname { try container.encode(hostname, forKey: DynamicCodingKey("hostname")) }
        try container.encode(service, forKey: DynamicCodingKey("service"))
        for (key, value) in additional where key != "hostname" && key != "service" {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

public struct CloudflareTunnelConfiguration: Codable, Sendable {
    public let ingress: [CloudflareIngress]
    /// Config-level settings besides ingress (`warp-routing`, global `originRequest`, …), preserved verbatim.
    public var additional: [String: JSONValue]

    public init(ingress: [CloudflareIngress], additional: [String: JSONValue] = [:]) {
        self.ingress = ingress
        self.additional = additional
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var ingress: [CloudflareIngress] = []
        var additional: [String: JSONValue] = [:]
        for key in container.allKeys {
            if key.stringValue == "ingress" {
                ingress = try container.decodeIfPresent([CloudflareIngress].self, forKey: key) ?? []
            } else {
                additional[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
        self.init(ingress: ingress, additional: additional)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(ingress, forKey: DynamicCodingKey("ingress"))
        for (key, value) in additional where key != "ingress" {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

public enum RemoteIngressMetadataResolver {
    public static func matching(
        hostname: String?,
        in configuration: CloudflareTunnelConfiguration
    ) -> CloudflareIngress? {
        guard let hostname else { return nil }
        let expected = normalize(hostname)
        let matches = configuration.ingress.filter { ingress in
            guard let candidate = ingress.hostname else { return false }
            return normalize(candidate) == expected
        }
        if !matches.isEmpty {
            let services = Set(matches.map(\.service))
            guard services.count == 1 else { return nil }
            return matches.first
        }
        // No rule names the hostname: Cloudflare then uses the first `*.zone` wildcard or catch-all
        // (`*` or no hostname) that covers it. Only ones that forward to a web service count.
        return configuration.ingress.first { ingress in
            guard isWebService(ingress.service) else { return false }
            guard let candidate = ingress.hostname.map(normalize), candidate != "*" else { return true }
            return candidate.hasPrefix("*.") && expected.hasSuffix(String(candidate.dropFirst()))
        }
    }

    /// Whether a rule matched `hostname` by name rather than through a wildcard or catch-all.
    public static func namesHostname(_ ingress: CloudflareIngress, _ hostname: String?) -> Bool {
        guard let hostname, let candidate = ingress.hostname else { return false }
        return normalize(candidate) == normalize(hostname)
    }

    private static func isWebService(_ service: String) -> Bool {
        guard let scheme = URL(string: service)?.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    private static func normalize(_ hostname: String) -> String {
        hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

public struct CloudflareZone: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public enum OpenTrafficError: LocalizedError, Sendable {
    case invalidLocalURL
    case cloudflaredMissing
    case accountNotConfigured
    case remoteTunnelMissingID
    case api(String)
    case process(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocalURL:
            "Enter a valid http:// or https:// local URL."
        case .cloudflaredMissing:
            "cloudflared was not found. Install it with Homebrew (`brew install cloudflared`) or from developers.cloudflare.com, or choose its executable in Settings."
        case .accountNotConfigured:
            "Add your Cloudflare account ID and API token in Settings."
        case .remoteTunnelMissingID:
            "This imported tunnel has no Cloudflare tunnel ID."
        case .api(let message), .process(let message):
            message
        }
    }
}

extension OpenTrafficError {
    /// Whether Cloudflare answered that the resource doesn't exist (for example, deleted in the dashboard).
    public var isNotFound: Bool {
        guard case .api(let message) = self else { return false }
        return message.contains("HTTP 404") || message.localizedCaseInsensitiveContains("not found")
    }
}

public extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

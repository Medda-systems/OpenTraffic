import Foundation

public enum EffectiveOriginSource: String, Codable, Sendable {
    case savedConfiguration
    case liveConnector
    case lastKnownLiveConnector
    case cloudflareConfiguration

    public var title: String {
        switch self {
        case .savedConfiguration: "Saved configuration"
        case .liveConnector: "Live connector"
        case .lastKnownLiveConnector: "Last known live connector"
        case .cloudflareConfiguration: "Cloudflare configuration"
        }
    }
}

public struct EffectiveOrigin: Equatable, Sendable {
    public let url: String
    public let source: EffectiveOriginSource
    public let updatedAt: Date?

    public init(url: String, source: EffectiveOriginSource, updatedAt: Date? = nil) {
        self.url = url
        self.source = source
        self.updatedAt = updatedAt
    }
}

public enum EffectiveOriginResolver {
    public static func resolve(savedURL: String, cached: EffectiveOrigin?) -> EffectiveOrigin {
        cached ?? EffectiveOrigin(url: savedURL, source: .savedConfiguration)
    }

    public static func markUnavailable(_ current: EffectiveOrigin?) -> EffectiveOrigin? {
        guard let current else { return nil }
        guard current.source == .liveConnector else { return current }
        return EffectiveOrigin(
            url: current.url,
            source: .lastKnownLiveConnector,
            updatedAt: current.updatedAt
        )
    }
}

public enum ManagedIngressResolver {
    public static func origin(
        kind: TunnelKind,
        hostname: String?,
        configuration: CloudflareTunnelConfiguration
    ) -> String? {
        switch kind {
        case .remote:
            return RemoteIngressMetadataResolver.matching(hostname: hostname, in: configuration)?.service
        case .quick:
            let applicable = configuration.ingress.filter { ingress in
                let service = ingress.service.lowercased()
                return !service.hasPrefix("http_status:") && !service.hasPrefix("hello_world")
            }
            guard applicable.count == 1 else { return nil }
            return applicable[0].service
        case .tailscale, .ngrok, .opentunnel:
            return nil
        }
    }
}

public struct OwnedConnectorIdentity: Equatable, Sendable {
    public let process: ProcessIdentity
    public let generation: UInt64

    public init(process: ProcessIdentity, generation: UInt64) {
        self.process = process
        self.generation = generation
    }
}

public struct ManagedConnectorInspection: Sendable {
    public let identity: OwnedConnectorIdentity
    public let metricsPort: UInt16
    public let configuration: CloudflareTunnelConfiguration?
    public let statistics: TunnelStatistics?

    public init(
        identity: OwnedConnectorIdentity,
        metricsPort: UInt16,
        configuration: CloudflareTunnelConfiguration?,
        statistics: TunnelStatistics?
    ) {
        self.identity = identity
        self.metricsPort = metricsPort
        self.configuration = configuration
        self.statistics = statistics
    }
}

public protocol ProcessSocketOwnershipChecking: Sendable {
    func loopbackHost(pid: Int32, port: UInt16) -> String?
}

public protocol ConnectorLoopbackFetching: Sendable {
    func data(host: String, port: UInt16, path: String) async -> Data?
}

public protocol ManagedConnectorInspecting: Sendable {
    func inspect(identity: OwnedConnectorIdentity, metricsPort: UInt16) async -> ManagedConnectorInspection?
}

public struct ManagedConnectorInspector: ManagedConnectorInspecting, Sendable {
    private let processProvider: any ProcessSnapshotProviding
    private let socketChecker: any ProcessSocketOwnershipChecking
    private let fetcher: any ConnectorLoopbackFetching
    private let socketCache = VerifiedSocketCache()

    public init(
        processProvider: any ProcessSnapshotProviding = MacProcessSnapshotProvider(),
        socketChecker: any ProcessSocketOwnershipChecking = MacProcessSocketInspector(),
        fetcher: any ConnectorLoopbackFetching = LoopbackHTTPFetcher()
    ) {
        self.processProvider = processProvider
        self.socketChecker = socketChecker
        self.fetcher = fetcher
    }

    public func inspect(identity: OwnedConnectorIdentity, metricsPort: UInt16) async -> ManagedConnectorInspection? {
        guard isAlive(identity.process), let host = verifiedHost(identity.process, port: metricsPort) else { return nil }
        async let configData = fetcher.data(host: host, port: metricsPort, path: "config")
        async let metricsData = fetcher.data(host: host, port: metricsPort, path: "metrics")
        let (rawConfig, rawMetrics) = await (configData, metricsData)
        // Re-verify after fetching: the data only counts if the connector still owns the listener.
        guard isAlive(identity.process),
              let current = socketChecker.loopbackHost(pid: identity.process.pid, port: metricsPort) else {
            socketCache.forget(identity.process)
            return nil
        }
        socketCache.remember(current, for: identity.process, port: metricsPort)

        let configuration = rawConfig.flatMap(Self.decodeConfiguration)
        let statistics = rawMetrics.flatMap { data in
            String(data: data, encoding: .utf8).map(TunnelStatisticsParser.parse)
        }
        guard configuration != nil || statistics != nil else { return nil }
        return ManagedConnectorInspection(
            identity: identity,
            metricsPort: metricsPort,
            configuration: configuration,
            statistics: statistics
        )
    }

    /// The exact process (PID and start time) is still running — a targeted lookup, not a full scan.
    private func isAlive(_ process: ProcessIdentity) -> Bool {
        processProvider.snapshot(pid: process.pid)?.identity == process
    }

    /// Which loopback address to fetch from: the one verified after the previous fetch, or a fresh
    /// lsof check the first time. Ownership is always re-checked after fetching.
    private func verifiedHost(_ process: ProcessIdentity, port: UInt16) -> String? {
        if let host = socketCache.host(for: process, port: port) { return host }
        guard let host = socketChecker.loopbackHost(pid: process.pid, port: port) else { return nil }
        socketCache.remember(host, for: process, port: port)
        return host
    }

    private static func decodeConfiguration(_ data: Data) -> CloudflareTunnelConfiguration? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let config = object["config"] as? [String: Any] ?? object
        guard let ingress = config["ingress"],
              JSONSerialization.isValidJSONObject(["ingress": ingress]),
              let configData = try? JSONSerialization.data(withJSONObject: ["ingress": ingress]) else { return nil }
        return try? JSONDecoder().decode(CloudflareTunnelConfiguration.self, from: configData)
    }
}

public struct MacProcessSocketInspector: ProcessSocketOwnershipChecking, Sendable {
    public init() {}

    public func loopbackHost(pid: Int32, port: UInt16) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return nil }
        guard completed.wait(timeout: .now() + 1) == .success else {
            process.terminate()
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in output.split(separator: "\n") where line.first == "n" {
            guard let separator = line.lastIndex(of: ":"), UInt16(line[line.index(after: separator)...]) == port else { continue }
            var boundHost = String(line[line.index(after: line.startIndex)..<separator])
            if boundHost.hasPrefix("[") && boundHost.hasSuffix("]") {
                boundHost.removeFirst(); boundHost.removeLast()
            }
            switch boundHost.lowercased() {
            case "*", "0.0.0.0", "localhost": return "127.0.0.1"
            case "::", "::1": return "::1"
            default:
                if boundHost.hasPrefix("127.") { return boundHost }
            }
        }
        return nil
    }
}

public struct LoopbackHTTPFetcher: ConnectorLoopbackFetching, Sendable {
    public init() {}

    public func data(host: String, port: UInt16, path: String) async -> Data? {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(urlHost):\(port)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.75
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.75
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration, delegate: LoopbackNoRedirectDelegate.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 2 * 1024 * 1024 else { return nil }
        return data
    }
}

private final class LoopbackNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LoopbackNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Loopback listeners already verified with lsof, keyed by process identity and port.
private final class VerifiedSocketCache: @unchecked Sendable {
    private struct Key: Hashable {
        let process: ProcessIdentity
        let port: UInt16
    }

    private let lock = NSLock()
    private var hosts: [Key: String] = [:]

    func host(for process: ProcessIdentity, port: UInt16) -> String? {
        lock.withLock { hosts[Key(process: process, port: port)] }
    }

    func remember(_ host: String, for process: ProcessIdentity, port: UInt16) {
        lock.withLock {
            // Keep it small: only live connectors matter, and dead ones are forgotten on use.
            if hosts.count > 64 { hosts.removeAll() }
            hosts[Key(process: process, port: port)] = host
        }
    }

    func forget(_ process: ProcessIdentity) {
        lock.withLock { hosts = hosts.filter { $0.key.process != process } }
    }
}

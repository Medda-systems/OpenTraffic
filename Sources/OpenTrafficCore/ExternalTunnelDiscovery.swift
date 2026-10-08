import Darwin
import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct ProcessSnapshot: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let uid: UInt32
    public let executablePath: String
    public let arguments: [String]
    public let parentPID: Int32

    public init(identity: ProcessIdentity, uid: UInt32, executablePath: String, arguments: [String], parentPID: Int32 = 0) {
        self.identity = identity
        self.uid = uid
        self.executablePath = executablePath
        self.arguments = arguments
        self.parentPID = parentPID
    }
}

/// Connectors a previous OpenTraffic run started and then lost (it crashed or was force-quit).
/// They're recognizable by the private per-run config folder in their arguments, and by having
/// been re-parented to launchd. Processes started any other way never match.
public enum OrphanedConnectorDetector {
    public static func orphans(in snapshots: [ProcessSnapshot], currentRunDirectory: String) -> [ProcessSnapshot] {
        snapshots.filter { snapshot in
            guard snapshot.parentPID == 1 else { return false }
            let folders = snapshot.arguments
                .flatMap { $0.split(separator: ",").map(String.init) }
                .compactMap(runDirectory(in:))
            return !folders.isEmpty && !folders.contains(currentRunDirectory)
        }
    }

    /// The `…/OpenTraffic-<UUID>` folder a config path lives in, if any. Runs from before the app was
    /// renamed used `TunnelBar-<UUID>`.
    static func runDirectory(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.lastIndex(where: { component in
            ["OpenTraffic-", "TunnelBar-"].contains { prefix in
                component.hasPrefix(prefix) && UUID(uuidString: String(component.dropFirst(prefix.count))) != nil
            }
        }) else { return nil }
        return components[...index].joined(separator: "/")
    }
}

public struct QuickTunnelCandidate: Equatable, Sendable {
    public let snapshot: ProcessSnapshot
    public let localURL: String?
    public let logFilePath: String?
}

public struct ExternalTunnelMetadata: Sendable {
    public let publicURL: String?
    public let metricsPort: UInt16?
    public let configuredOriginURL: String?
    public let logEntries: [TunnelLogEntry]
    public let statistics: TunnelStatistics?

    public init(
        publicURL: String?,
        metricsPort: UInt16? = nil,
        configuredOriginURL: String? = nil,
        logEntries: [TunnelLogEntry] = [],
        statistics: TunnelStatistics? = nil
    ) {
        self.publicURL = publicURL
        self.metricsPort = metricsPort
        self.configuredOriginURL = configuredOriginURL
        self.logEntries = logEntries
        self.statistics = statistics
    }
}

public struct DiscoveredQuickTunnel: Identifiable, Sendable {
    public let id: UUID
    public let identity: ProcessIdentity
    public let executablePath: String
    public let localURL: String?
    public let publicURL: String
    public let logFilePath: String?
    public let logEntries: [TunnelLogEntry]
    public let metricsPort: UInt16?
    public let statistics: TunnelStatistics?
    public let lastSeen: Date

    public init(
        id: UUID,
        identity: ProcessIdentity,
        executablePath: String,
        localURL: String?,
        publicURL: String,
        logFilePath: String?,
        logEntries: [TunnelLogEntry],
        metricsPort: UInt16?,
        lastSeen: Date,
        statistics: TunnelStatistics? = nil
    ) {
        self.id = id
        self.identity = identity
        self.executablePath = executablePath
        self.localURL = localURL
        self.publicURL = publicURL
        self.logFilePath = logFilePath
        self.logEntries = logEntries
        self.metricsPort = metricsPort
        self.lastSeen = lastSeen
        self.statistics = statistics
    }
}

public enum ExternalTunnelClassifier {
    public static func classify(_ snapshot: ProcessSnapshot) -> QuickTunnelCandidate? {
        guard URL(fileURLWithPath: snapshot.executablePath).lastPathComponent == "cloudflared" else { return nil }
        let arguments = Array(snapshot.arguments.dropFirst())
        guard arguments.contains("tunnel") else { return nil }

        let forbiddenFlags = ["--token", "--token-file", "--credentials-file", "--name", "-n"]
        guard !arguments.contains("run") else { return nil }
        guard !arguments.contains(where: { argument in
            forbiddenFlags.contains(argument) || forbiddenFlags.contains(where: { argument.hasPrefix("\($0)=") })
        }) else { return nil }

        let localURL = optionValue("--url", in: arguments).flatMap(validOriginURL)
        let logFile = optionValue("--logfile", in: arguments).flatMap { value -> String? in
            value.hasPrefix("/") ? value : nil
        }
        return QuickTunnelCandidate(snapshot: snapshot, localURL: localURL, logFilePath: logFile)
    }

    private static func optionValue(_ name: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(name)=") { return String(argument.dropFirst(name.count + 1)) }
            if argument == name, arguments.indices.contains(index + 1) { return arguments[index + 1] }
        }
        return nil
    }

    private static func validOriginURL(_ value: String) -> String? {
        guard
            let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil
        else { return nil }
        return value
    }
}

public protocol ProcessSnapshotProviding: Sendable {
    func snapshots() -> [ProcessSnapshot]
    /// One process by PID; providers that can look it up directly avoid a full scan.
    func snapshot(pid: Int32) -> ProcessSnapshot?
}

extension ProcessSnapshotProviding {
    public func snapshot(pid: Int32) -> ProcessSnapshot? {
        snapshots().first { $0.identity.pid == pid }
    }
}

public protocol ExternalTunnelMetadataProviding: Sendable {
    func metadata(for candidate: QuickTunnelCandidate) async -> ExternalTunnelMetadata
}

public protocol ProcessSignaling: Sendable {
    func sendTerminate(to pid: Int32) throws
}

public struct SystemProcessSignaler: ProcessSignaling {
    public init() {}

    public func sendTerminate(to pid: Int32) throws {
        guard Darwin.kill(pid, SIGTERM) == 0 else {
        throw OpenTrafficError.process("Could not stop external cloudflared process \(pid): \(String(cString: strerror(errno))).")
        }
    }
}

public actor ExternalTunnelDiscovery {
    private let processProvider: any ProcessSnapshotProviding
    private let metadataProvider: any ExternalTunnelMetadataProviding
    private let signaler: any ProcessSignaling
    private var stableIDs: [ProcessIdentity: UUID] = [:]

    public init(
        processProvider: any ProcessSnapshotProviding = MacProcessSnapshotProvider(),
        metadataProvider: any ExternalTunnelMetadataProviding = MacExternalTunnelMetadataProvider(),
        signaler: any ProcessSignaling = SystemProcessSignaler()
    ) {
        self.processProvider = processProvider
        self.metadataProvider = metadataProvider
        self.signaler = signaler
    }

    public func scan(excludingProcessIDs: Set<Int32>) async -> [DiscoveredQuickTunnel] {
        var seenIdentities = Set<ProcessIdentity>()
        let candidates = processProvider.snapshots()
        .filter { !excludingProcessIDs.contains($0.identity.pid) }
        .compactMap(ExternalTunnelClassifier.classify)
        .filter { seenIdentities.insert($0.snapshot.identity).inserted }

        var results: [DiscoveredQuickTunnel] = []
        let currentIdentities = Set(candidates.map { $0.snapshot.identity })
        for candidate in candidates {
        let metadata = await metadataProvider.metadata(for: candidate)
        guard let publicURL = metadata.publicURL else { continue }
        let id = stableIDs[candidate.snapshot.identity] ?? UUID()
        stableIDs[candidate.snapshot.identity] = id
        results.append(DiscoveredQuickTunnel(
            id: id,
            identity: candidate.snapshot.identity,
            executablePath: candidate.snapshot.executablePath,
            localURL: candidate.localURL ?? metadata.configuredOriginURL,
            publicURL: publicURL,
            logFilePath: candidate.logFilePath,
            logEntries: metadata.logEntries,
            metricsPort: metadata.metricsPort,
            lastSeen: Date(),
            statistics: metadata.statistics
        ))
        }
        stableIDs = stableIDs.filter { currentIdentities.contains($0.key) }
        return results.sorted { $0.identity.pid < $1.identity.pid }
    }

    public func stopVerified(_ identity: ProcessIdentity) async throws {
        guard
        let snapshot = processProvider.snapshots().first(where: { $0.identity == identity }),
        let candidate = ExternalTunnelClassifier.classify(snapshot)
        else {
        throw OpenTrafficError.process("The external tunnel process changed or already exited. Nothing was stopped.")
        }
        guard (await metadataProvider.metadata(for: candidate)).publicURL != nil else {
        throw OpenTrafficError.process("The process no longer exposes confirmed Quick Tunnel metadata. Nothing was stopped.")
        }
        try signaler.sendTerminate(to: identity.pid)
        for _ in 0..<50 {
        try await Task.sleep(for: .milliseconds(100))
        if !processProvider.snapshots().contains(where: { $0.identity == identity }) { return }
        }
        throw OpenTrafficError.process("The external tunnel did not stop after five seconds. OpenTraffic left it running and did not force-quit it.")
    }
}

public struct MacProcessSnapshotProvider: ProcessSnapshotProviding, Sendable {
    private let executableNames: Set<String>
    private let shortNames: Set<String>

    public init(executableNames: Set<String> = ["cloudflared"]) {
        self.executableNames = executableNames
        self.shortNames = Set(executableNames.map { String($0.utf8.prefix(Int(MAXCOMLEN))) ?? $0 })
    }

    public func snapshots() -> [ProcessSnapshot] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(requiredBytes) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }

        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { snapshot(pid: $0) }
    }

    public func snapshot(pid: Int32) -> ProcessSnapshot? {
        let currentUID = getuid()
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize))
        guard read == infoSize, info.pbi_uid == currentUID else { return nil }
        // Cheap prefilter on the kernel's short process name (first 16 characters of the
        // executable name) before the more expensive path lookup; the full path is still checked.
        let shortName = withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard shortNames.contains(shortName) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let executable = String(
            decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard executableNames.contains(URL(fileURLWithPath: executable).lastPathComponent) else { return nil }
        guard let arguments = arguments(for: pid) else { return nil }
        let start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        return ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startTimeMicroseconds: start),
            uid: info.pbi_uid,
            executablePath: executable,
            arguments: arguments,
            parentPID: Int32(info.pbi_ppid)
        )
    }

    private func arguments(for pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return bytes.withUnsafeBytes { rawBuffer -> [String]? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let argumentCount = Int(base.load(as: Int32.self))
            guard argumentCount > 0 else { return nil }
            var index = MemoryLayout<Int32>.size
            while index < size, bytes[index] != 0 { index += 1 }
            while index < size, bytes[index] == 0 { index += 1 }

            var result: [String] = []
            while index < size, result.count < argumentCount {
                let start = index
                while index < size, bytes[index] != 0 { index += 1 }
                guard index < size else { return nil }
                result.append(String(decoding: bytes[start..<index], as: UTF8.self))
                index += 1
            }
            return result.count == argumentCount ? result : nil
        }
    }
}

public struct MacExternalTunnelMetadataProvider: ExternalTunnelMetadataProviding, Sendable {
    public init() {}

    public func metadata(for candidate: QuickTunnelCandidate) async -> ExternalTunnelMetadata {
        for endpoint in Self.listeningEndpoints(pid: candidate.snapshot.identity.pid) {
            guard let hostname = await Self.fetchHostname(endpoint: endpoint) else { continue }
            async let metrics = TunnelMetricsFetcher.fetch(host: endpoint.host, port: endpoint.port)
            let origin = candidate.localURL == nil ? await Self.fetchConfiguredOrigin(endpoint: endpoint) : nil
            let logEntries = Self.readLogTail(candidate.logFilePath, expectedUID: candidate.snapshot.uid)
            return ExternalTunnelMetadata(
                publicURL: "https://\(hostname)",
                metricsPort: endpoint.port,
                configuredOriginURL: origin,
                logEntries: logEntries,
                statistics: await metrics
            )
        }
        guard candidate.localURL != nil else { return ExternalTunnelMetadata(publicURL: nil) }
        let logEntries = Self.readLogTail(candidate.logFilePath, expectedUID: candidate.snapshot.uid)
        let logURL = logEntries.reversed().lazy.compactMap { Self.quickTunnelURL(in: $0.rawLine ?? $0.message) }.first
        return ExternalTunnelMetadata(publicURL: logURL, logEntries: logEntries)
    }

    private struct ListenerEndpoint: Hashable {
        let host: String
        let port: UInt16

        var urlHost: String { host.contains(":") ? "[\(host)]" : host }
    }

    private static func listeningEndpoints(pid: Int32) -> [ListenerEndpoint] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return [] }
        guard completed.wait(timeout: .now() + 1) == .success else {
            process.terminate()
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let endpoints = output.split(separator: "\n").flatMap { line -> [ListenerEndpoint] in
            guard line.first == "n", let separator = line.lastIndex(of: ":") else { return [] }
            guard let port = UInt16(line[line.index(after: separator)...]) else { return [] }
            var boundHost = String(line[line.index(after: line.startIndex)..<separator])
            if boundHost.hasPrefix("[") && boundHost.hasSuffix("]") {
                boundHost.removeFirst()
                boundHost.removeLast()
            }
            switch boundHost.lowercased() {
            case "*", "localhost":
                return [ListenerEndpoint(host: "127.0.0.1", port: port), ListenerEndpoint(host: "::1", port: port)]
            case "0.0.0.0":
                return [ListenerEndpoint(host: "127.0.0.1", port: port)]
            case "::", "::1":
                return [ListenerEndpoint(host: "::1", port: port)]
            default:
                guard boundHost.hasPrefix("127.") else { return [] }
                return [ListenerEndpoint(host: "127.0.0.1", port: port)]
            }
        }
        return Array(Set(endpoints)).sorted { ($0.port, $0.host) < ($1.port, $1.host) }
    }

    private static func fetchHostname(endpoint: ListenerEndpoint) async -> String? {
        guard let object = await fetchJSON(path: "quicktunnel", endpoint: endpoint),
              let hostname = (object["hostname"] as? String)?.nilIfBlank,
              hostname.range(of: #"^[a-z0-9-]+\.trycloudflare\.com$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return hostname
    }

    private static func fetchConfiguredOrigin(endpoint: ListenerEndpoint) async -> String? {
        guard let object = await fetchJSON(path: "config", endpoint: endpoint) else { return nil }
        let config = object["config"] as? [String: Any] ?? object
        guard let ingress = config["ingress"] as? [[String: Any]] else { return nil }
        return ingress.lazy.compactMap { item -> String? in
            guard let service = item["service"] as? String,
                  let url = URL(string: service),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return service
        }.first
    }

    private static func fetchJSON(path: String, endpoint: ListenerEndpoint) async -> [String: Any]? {
        guard let url = URL(string: "http://\(endpoint.urlHost):\(endpoint.port)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.75
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.75
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func readLogTail(_ path: String?, expectedUID: UInt32) -> [TunnelLogEntry] {
        guard let path else { return [] }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == expectedUID else { return [] }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let maximumBytes: UInt64 = 128 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maximumBytes ? size - maximumBytes : 0
        try? handle.seek(toOffset: offset)
        var data = (try? handle.read(upToCount: Int(maximumBytes))) ?? Data()
        if offset > 0, let newline = data.firstIndex(of: 0x0A) { data.removeSubrange(...newline) }
        var parser = CloudflaredLogParser()
        let entries = parser.append(data, stream: "logfile") + parser.finish(stream: "logfile")
        return Array(entries.suffix(200))
    }

    private static func quickTunnelURL(in text: String) -> String? {
        let pattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()

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

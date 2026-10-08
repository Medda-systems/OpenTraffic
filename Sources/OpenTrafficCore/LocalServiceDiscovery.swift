import Foundation
import os

public struct ListeningSocket: Sendable, Equatable, Hashable {
    public let pid: Int32?
    public let processName: String?
    public let host: String
    public let port: Int

    public init(pid: Int32? = nil, processName: String? = nil, host: String, port: Int) {
        self.pid = pid
        self.processName = processName
        self.host = host
        self.port = port
    }
}

public enum LocalListenerParser {
    public static func parseLsof(_ output: String) -> [ListeningSocket] {
        var sockets: [ListeningSocket] = []
        var pid: Int32?
        var process: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p":
                pid = Int32(value)
                process = nil
            case "c":
                process = value.nilIfBlank
            case "n":
                if let socket = parseEndpoint(value, pid: pid, processName: process) {
                    sockets.append(socket)
                }
            default:
                continue
            }
        }
        return sockets
    }

    private static func parseEndpoint(_ value: String, pid: Int32?, processName: String?) -> ListeningSocket? {
        let endpoint = value.replacingOccurrences(of: " (LISTEN)", with: "")
        guard let separator = endpoint.range(of: ":", options: .backwards) else { return nil }
        let host = String(endpoint[..<separator.lowerBound])
        guard let port = Int(endpoint[separator.upperBound...]), (1...65535).contains(port) else { return nil }
        return ListeningSocket(pid: pid, processName: processName, host: host, port: port)
    }
}

public struct DiscoveredLocalService: Sendable, Equatable, Identifiable {
    public let port: Int
    public let processName: String?
    public let title: String?
    public let statusCode: Int?
    /// When the server's process started.
    public let startedAt: Date?
    public let pid: Int32?
    /// Since when it has been answering without interruption (see `LocalServiceUptimeTracker`).
    public var upSince: Date?

    public init(port: Int, processName: String? = nil, title: String? = nil, statusCode: Int? = nil, startedAt: Date? = nil, pid: Int32? = nil, upSince: Date? = nil) {
        self.port = port
        self.processName = processName
        self.title = title
        self.statusCode = statusCode
        self.startedAt = startedAt
        self.pid = pid
        self.upSince = upSince
    }

    public var id: String { "localhost:\(port)" }
    public var url: String { "http://localhost:\(port)" }

    public var displayName: String {
        if let title = title?.nilIfBlank { return title }
        return "\(friendlyProcessName) :\(port)"
    }

    private var friendlyProcessName: String {
        switch (processName ?? "").lowercased() {
        case "node": "Node.js"
        case "python", "python3": "Python"
        case "ruby": "Ruby"
        case "php": "PHP"
        case "java": "Java"
        case "dotnet": ".NET"
        case "nginx": "nginx"
        case "httpd", "apache2": "Apache"
        case "caddy": "Caddy"
        case "docker": "Docker"
        case "": "Service"
        default: processName ?? "Service"
        }
    }
}

public enum LocalServiceTitle {
    public static func extract(from data: Data) -> String? {
        let text = String(decoding: data.prefix(16 * 1024), as: UTF8.self)
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let titleRange = Range(match.range(at: 1), in: text) else { return nil }
        let collapsed = String(text[titleRange])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.nilIfBlank
    }
}

public enum ProcessStartTimeParser {
    static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }

    public static func parsePs(_ output: String) -> [Int32: Date] {
        var starts: [Int32: Date] = [:]
        for line in output.split(separator: "\n") {
            let collapsed = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            let parts = collapsed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            if let date = dateFormatter.date(from: String(parts[1])) {
                starts[pid] = date
            }
        }
        return starts
    }

    public static func lookup(pids: [Int32]) -> [Int32: Date] {
        let unique = Array(Set(pids)).prefix(128)
        guard !unique.isEmpty else { return [:] }
        let output = ToolOutput.run("/bin/ps", ["-o", "pid=,lstart=", "-p", unique.map(String.init).joined(separator: ",")])
        return output.map(parsePs) ?? [:]
    }
}

enum ToolOutput {
    /// A tool's standard output, or nil if it fails or runs longer than `timeout` (it's then terminated).
    /// The pipe is read to the end before waiting, so output larger than the pipe buffer can't deadlock.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard !timedOut.withLock({ $0 }), process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Listeners whose owner answered the HTTP probe with something that isn't HTTP, keyed by pid and port,
/// so they aren't probed again while that process still owns the port.
public final class LocalServiceProbeMemo: Sendable {
    public static let shared = LocalServiceProbeMemo()

    private struct Owner: Hashable {
        let pid: Int32
        let port: Int
    }

    private let failed = OSAllocatedUnfairLock(initialState: Set<Owner>())

    public init() {}

    func contains(_ socket: ListeningSocket) -> Bool {
        guard let pid = socket.pid else { return false }
        return failed.withLock { $0.contains(Owner(pid: pid, port: socket.port)) }
    }

    func insert(_ socket: ListeningSocket) {
        guard let pid = socket.pid else { return }
        failed.withLock { failed in
            guard failed.count < 256 else { return }
            failed.insert(Owner(pid: pid, port: socket.port))
        }
    }

    /// Forgets pairs that aren't listening anymore (the process exited or gave up the port).
    func keep(only sockets: [ListeningSocket]) {
        let current = Set(sockets.compactMap { socket in socket.pid.map { Owner(pid: $0, port: socket.port) } })
        failed.withLock { $0.formIntersection(current) }
    }
}

public struct LocalServiceScanner: Sendable {
    private static let systemProcesses: Set<String> = [
        "rapportd", "controlcenter", "airplayxpchelper", "sharingd",
    ]
    /// Databases, brokers and the like: a `GET /` only fills their logs.
    private static let nonHTTPProcesses: Set<String> = [
        "postgres", "mysqld", "mariadbd", "redis-server", "mongod", "memcached",
        "rabbitmq-server", "beam.smp", "epmd", "sshd",
    ]
    /// Their usual ports: Postgres, MySQL, Redis, MongoDB, memcached, AMQP, epmd, SSH.
    private static let nonHTTPPorts: Set<Int> = [5432, 3306, 6379, 27017, 11211, 5672, 4369, 22]

    private let transport: any HTTPTransport
    private let listeners: @Sendable () async -> [ListeningSocket]
    private let startTimes: @Sendable ([Int32]) async -> [Int32: Date]
    private let probeMemo: LocalServiceProbeMemo

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        listeners: (@Sendable () async -> [ListeningSocket])? = nil,
        startTimes: (@Sendable ([Int32]) async -> [Int32: Date])? = nil,
        probeMemo: LocalServiceProbeMemo = .shared
    ) {
        self.transport = transport
        self.listeners = listeners ?? LocalServiceScanner.liveListeners
        self.startTimes = startTimes ?? { ProcessStartTimeParser.lookup(pids: $0) }
        self.probeMemo = probeMemo
    }

    public func scan() async -> [DiscoveredLocalService] {
        var byPort: [Int: ListeningSocket] = [:]
        let sockets = await listeners()
        probeMemo.keep(only: sockets)
        for socket in sockets {
            guard Self.isLocallyReachable(socket.host), !Self.nonHTTPPorts.contains(socket.port) else { continue }
            if let process = socket.processName?.lowercased(),
               Self.systemProcesses.contains(process) || Self.nonHTTPProcesses.contains(process) { continue }
            if let existing = byPort[socket.port] {
                if existing.processName == nil, socket.processName != nil {
                    byPort[socket.port] = socket
                }
            } else {
                byPort[socket.port] = socket
            }
        }
        let transport = self.transport
        let probeMemo = self.probeMemo
        byPort = byPort.filter { !probeMemo.contains($0.value) }
        let starts = await startTimes(byPort.values.compactMap(\.pid))
        var found: [DiscoveredLocalService] = []
        await withTaskGroup(of: DiscoveredLocalService?.self) { group in
            for socket in byPort.values {
                group.addTask {
                    await Self.probe(socket: socket, startedAt: starts[socket.pid ?? -1], transport: transport, memo: probeMemo)
                }
            }
            for await service in group {
                if let service { found.append(service) }
            }
        }
        return found.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (lhs?, rhs?): lhs != rhs ? lhs > rhs : $0.port < $1.port
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.port < $1.port
            }
        }
    }

    static func isLocallyReachable(_ host: String) -> Bool {
        switch host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) {
        case "127.0.0.1", "::1", "0.0.0.0", "::", "*", "localhost": true
        default: false
        }
    }

    /// Errors meaning something answered, but not with HTTP. Timeouts and refused connections aren't
    /// among them: a dev server busy rebuilding can miss a probe and should be tried again.
    private static let notHTTPErrors: Set<URLError.Code> = [.badServerResponse, .cannotParseResponse, .networkConnectionLost]

    private static func probe(socket: ListeningSocket, startedAt: Date?, transport: any HTTPTransport, memo: LocalServiceProbeMemo) async -> DiscoveredLocalService? {
        guard let url = URL(string: "http://localhost:\(socket.port)/") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            if let code = (error as? URLError)?.code, notHTTPErrors.contains(code) { memo.insert(socket) }
            return nil
        }
        return DiscoveredLocalService(
            port: socket.port,
            processName: socket.processName,
            title: LocalServiceTitle.extract(from: data),
            statusCode: response.statusCode,
            startedAt: startedAt,
            pid: socket.pid
        )
    }

    private static func liveListeners() async -> [ListeningSocket] {
        LocalListenerParser.parseLsof(runLsof())
    }

    private static func runLsof() -> String {
        for path in ["/usr/sbin/lsof", "/usr/bin/lsof"] {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            // Full command names (`+c 0`), so names like redis-server aren't cut to 9 characters.
            if let output = ToolOutput.run(path, ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) { return output }
        }
        return ""
    }
}

/// Keeps track of how long each local server has been answering, across repeated scans.
///
/// A server missing from `missesAllowed + 1` scans in a row counts as down and leaves the list;
/// one miss is tolerated (a dev server busy rebuilding can miss a probe) and it stays listed meanwhile.
/// When a server comes back, or its process is replaced, its uptime starts again.
public struct LocalServiceUptimeTracker: Sendable {
    public let missesAllowed: Int

    private struct Record {
        var service: DiscoveredLocalService
        var misses = 0
    }

    private var records: [Int: Record] = [:]
    private var lastScan: Date?

    public init(missesAllowed: Int = 1) {
        self.missesAllowed = missesAllowed
    }

    /// Takes one scan's results; returns the services to show, most recently up first.
    public mutating func update(with scan: [DiscoveredLocalService], now: Date = Date()) -> [DiscoveredLocalService] {
        let seen = Set(scan.map(\.port))
        for (port, record) in records where !seen.contains(port) {
            if record.misses >= missesAllowed {
                records[port] = nil
            } else {
                records[port]?.misses += 1
            }
        }
        for var service in scan {
            if let record = records[service.port], record.service.pid == service.pid || service.pid == nil {
                service.upSince = record.service.upSince
            } else if let lastScan, records[service.port] == nil {
                // Came up (or back) since the last scan: no earlier than that scan, or than its process.
                service.upSince = max(service.startedAt ?? lastScan, lastScan)
            } else {
                // Running before OpenTraffic started watching, or its process was replaced: the
                // process's start time is the best guess.
                service.upSince = service.startedAt.map { min($0, now) } ?? now
            }
            records[service.port] = Record(service: service)
        }
        lastScan = now
        return records.values.map(\.service).sorted {
            switch ($0.upSince, $1.upSince) {
            case let (lhs?, rhs?): lhs != rhs ? lhs > rhs : $0.port < $1.port
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.port < $1.port
            }
        }
    }
}

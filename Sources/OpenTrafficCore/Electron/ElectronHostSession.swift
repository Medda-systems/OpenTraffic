import Darwin
import Foundation

/// The sandboxed copy of one shared Electron app's main process: electron-host.js running on the
/// app's own Electron binary (Node mode) under `sandbox-exec`, with its own copy of the app's data.
/// It always listens on the same port, so a restart (a code change, a newly allowed local service,
/// a reset) is invisible to the share's proxy. Thread-safe.
public final class ElectronHostSession: @unchecked Sendable {
    public struct Window: Sendable, Equatable, Decodable {
        public var id: Int
        public var title: String?
        public var url: String?
        public var file: String?
        public var preload: String?
    }

    public enum Event: Sendable {
        /// The app's main script ran; `windows` are the ones it opened so far.
        case ready([Window])
        case windows([Window])
        /// The app tried to reach a local service it isn't allowed to: allow (restart with it) or deny.
        case wants(port: Int, host: String)
        case viewers(Int)
        case log(String)
        case failed(String)
        /// It stopped by itself (not through `stop`/`restart`).
        case exited(Int32)
    }

    public enum DataSource: String, Sendable, Codable {
        /// A copy of the app's own data (instant on APFS).
        case copy
        /// No data: a first launch.
        case empty
    }

    public struct Options: Sendable {
        public var app: ElectronApp
        public var hostScript: URL
        public var shimScript: URL
        public var sessionDirectory: URL
        public var port: Int
        public var allowedPorts: Set<Int>
        public var dataSource: DataSource
        public var path: String
        /// Off only in tests that run without `sandbox-exec`.
        public var sandboxed: Bool
        /// The Electron to run on, when not the app's own (see ElectronRuntime).
        public var runtime: URL?

        public init(app: ElectronApp, hostScript: URL, shimScript: URL, sessionDirectory: URL, port: Int,
                    allowedPorts: Set<Int>, dataSource: DataSource, path: String, sandboxed: Bool = true, runtime: URL? = nil) {
            self.runtime = runtime
            self.app = app
            self.hostScript = hostScript
            self.shimScript = shimScript
            self.sessionDirectory = sessionDirectory
            self.port = port
            self.allowedPorts = allowedPorts
            self.dataSource = dataSource
            self.path = path
            self.sandboxed = sandboxed
        }
    }

    public let port: Int
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    private let lock = NSLock()
    private var options: Options
    private var handler: (@Sendable (Event) -> Void)?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var generation = 0
    private var windows: [Window] = []
    private var readyWaiters: [UUID: CheckedContinuation<[Window], any Error>] = [:]
    private var isReady = false
    private var preparedData = false

    public init(options: Options) {
        self.options = options
        self.port = options.port
    }

    public var allowedPorts: Set<Int> { lock.withLock { options.allowedPorts } }
    public var currentWindows: [Window] { lock.withLock { windows } }
    public var sessionDirectory: URL { options.sessionDirectory }

    /// A free port on 127.0.0.1 for a new session.
    public static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    // MARK: Lifecycle

    public func start() throws {
        try lock.withLock { try launchLocked() }
    }

    /// Waits for the app's main script to run and open its first window.
    public func waitUntilReady(timeout: Duration = .seconds(20)) async throws -> [Window] {
        let id = UUID()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self else { return }
            let waiter = self.lock.withLock { self.readyWaiters.removeValue(forKey: id) }
            waiter?.resume(throwing: OpenTrafficError.process("The app's main process didn't open a window within \(timeout.components.seconds) seconds."))
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if isReady, !windows.isEmpty { continuation.resume(returning: windows) }
                else { readyWaiters[id] = continuation }
            }
        }
    }

    /// Starts again (same port, same data), e.g. with more local services allowed or new code.
    public func restart(allowedPorts: Set<Int>? = nil) throws {
        try lock.withLock {
            if let allowedPorts { options.allowedPorts = allowedPorts }
            stopLocked()
            try launchLocked()
        }
    }

    /// Starts again from the original data.
    public func reset() throws {
        try lock.withLock {
            stopLocked()
            try? FileManager.default.removeItem(at: options.sessionDirectory.appendingPathComponent("home"))
            preparedData = false
            try launchLocked()
        }
    }

    public func deny(port: Int) {
        lock.withLock { write(["type": "deny", "port": port]) }
    }

    /// Stops it and deletes its session folder.
    public func stop(deletingData: Bool = true) {
        lock.withLock { stopLocked() }
        if deletingData { try? FileManager.default.removeItem(at: options.sessionDirectory) }
    }

    deinit { lock.withLock { stopLocked() } }

    // MARK: Internals (lock held)

    private func launchLocked() throws {
        let fm = FileManager.default
        let session = options.sessionDirectory
        try fm.createDirectory(at: session.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        if !preparedData {
            try prepareData()
            preparedData = true
        }
        let profileURL = session.appendingPathComponent("sandbox.sb")
        let binary = options.runtime ?? options.app.electronBinary
        // The whole Electron.app it runs on: its frameworks load from there.
        let electronBundle = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profile = ElectronSandbox.profile(.init(
            homeDirectory: ElectronSandbox.realHomeDirectory,
            readable: Array(Set([options.app.projectRoot.path, options.app.appDirectory.path, electronBundle.path, options.hostScript.deletingLastPathComponent().path, options.shimScript.deletingLastPathComponent().path])).sorted(),
            session: session.path,
            allowedPorts: Array(options.allowedPorts) + [options.port]
        ))
        try profile.write(to: profileURL, atomically: true, encoding: .utf8)

        var config: [String: Any] = [
            "appDir": options.app.appDirectory.path,
            "dataDir": session.path,
            "name": options.app.name,
            "port": options.port,
            "allowedPorts": Array(options.allowedPorts).sorted(),
            "shimPath": options.shimScript.path,
            "packaged": options.app.isPackaged,
        ]
        if let bundle = options.app.bundle {
            // The main entry is found in app.asar's own package.json; extra resources sit next to it.
            config["resourcesPath"] = bundle.appendingPathComponent("Contents/Resources").path
        } else {
            config["main"] = options.app.mainEntry.path
        }
        let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)

        let process = Process()
        if options.sandboxed {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", profileURL.path, binary.path, options.hostScript.path, configJSON]
        } else {
            process.executableURL = binary
            process.arguments = [options.hostScript.path, configJSON]
        }
        // A finished app's code is an archive, not a folder: it runs from its Resources.
        process.currentDirectoryURL = options.app.bundle.map { $0.appendingPathComponent("Contents/Resources") } ?? options.app.appDirectory
        var environment = options.app.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        environment["PATH"] = options.path
        environment["HOME"] = session.appendingPathComponent("home").path
        environment["TMPDIR"] = session.appendingPathComponent("tmp").path + "/"
        environment["LANG"] = ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        environment["ELECTRON_NO_ATTACH_CONSOLE"] = "1"
        process.environment = environment

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        generation += 1
        let generation = generation
        isReady = false
        windows = []
        let reader = LineReader { [weak self] line in self?.received(line, generation: generation) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.feed(data) }
        }
        process.terminationHandler = { [weak self] finished in
            self?.terminated(status: finished.terminationStatus, generation: generation)
        }
        try process.run()
        self.process = process
        self.stdinPipe = input
    }

    private func prepareData() throws {
        let fm = FileManager.default
        let support = options.sessionDirectory.appendingPathComponent("home/Library/Application Support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let target = support.appendingPathComponent(options.app.name)
        // A finished app's data holds real logins: it always starts empty.
        guard options.dataSource == .copy, !options.app.isPackaged, fm.fileExists(atPath: options.app.userDataDirectory.path), !fm.fileExists(atPath: target.path) else { return }
        // A clone on APFS: instant, and the app's real data is never touched.
        try fm.copyItem(at: options.app.userDataDirectory, to: target)
        // The renderer's caches and storage belong to the real app's own windows; viewers have their browsers'.
        for name in ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "ShaderCache", "Service Worker", "SingletonLock", "SingletonSocket", "SingletonCookie", "Crashpad"] {
            try? fm.removeItem(at: target.appendingPathComponent(name))
        }
    }

    private func stopLocked() {
        generation += 1
        guard let process else { return }
        self.process = nil
        stdinPipe = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // Its port is reused right away by the next start: wait for it to go (then force it).
        for _ in 0..<40 where process.isRunning { usleep(50_000) }
        if process.isRunning { kill(pid, SIGKILL); for _ in 0..<20 where process.isRunning { usleep(25_000) } }
    }

    private func write(_ message: [String: Any]) {
        guard let pipe = stdinPipe, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func received(_ line: String, generation: Int) {
        let marker = "\u{1}OT "
        guard line.hasPrefix(marker) else {
            emit(.log(line), generation: generation)
            return
        }
        guard let data = line.dropFirst(marker.count).data(using: .utf8),
              let message = try? JSONDecoder().decode(HostMessage.self, from: data) else { return }
        switch message.type {
        case "ready", "windows":
            let waiters: [CheckedContinuation<[Window], any Error>] = lock.withLock {
                guard generation == self.generation else { return [] }
                if let windows = message.windows { self.windows = windows }
                if message.type == "ready" { isReady = true }
                guard isReady, !windows.isEmpty else { return [] }
                defer { readyWaiters = [:] }
                return Array(readyWaiters.values)
            }
            let current = currentWindows
            for waiter in waiters { waiter.resume(returning: current) }
            emit(message.type == "ready" ? .ready(current) : .windows(current), generation: generation)
        case "want":
            if let port = message.port { emit(.wants(port: port, host: message.host ?? "localhost"), generation: generation) }
        case "viewers":
            emit(.viewers(message.count ?? 0), generation: generation)
        case "failed":
            emit(.failed(message.message ?? "The app's main script failed."), generation: generation)
        default:
            break
        }
    }

    private func terminated(status: Int32, generation: Int) {
        let waiters: [CheckedContinuation<[Window], any Error>] = lock.withLock {
            guard generation == self.generation else { return [] }
            process = nil
            defer { readyWaiters = [:] }
            return Array(readyWaiters.values)
        }
        for waiter in waiters { waiter.resume(throwing: OpenTrafficError.process("The app's main process stopped (exit status \(status)).")) }
        emit(.exited(status), generation: generation)
    }

    private func emit(_ event: Event, generation: Int) {
        let handler: (@Sendable (Event) -> Void)? = lock.withLock { generation == self.generation ? self.handler : nil }
        handler?(event)
    }

    private struct HostMessage: Decodable {
        var type: String
        var windows: [Window]?
        var port: Int?
        var host: String?
        var count: Int?
        var message: String?
    }
}

/// Splits a byte stream into lines. Thread-safe.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let line: (String) -> Void

    init(_ line: @escaping (String) -> Void) { self.line = line }

    func feed(_ data: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > 1_000_000 { buffer.removeAll() }
            return out
        }
        lines.forEach(line)
    }
}

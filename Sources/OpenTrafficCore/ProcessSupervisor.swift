import Darwin
import Foundation

@MainActor
public final class ProcessSupervisor {
    public var onLogs: ((UUID, UInt64, [TunnelLogEntry]) -> Void)?
    public var onPublicURL: ((UUID, UInt64, String) -> Void)?
    public var onTermination: ((UUID, UInt64, Int32) -> Void)?

    private final class Session: @unchecked Sendable {
        struct Chunk {
            let data: Data
            let stream: String
        }

        let id: UUID
        let generation: UInt64
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
        var stdoutParser: CloudflaredLogParser
        var stderrParser: CloudflaredLogParser
        var processIdentity: ProcessIdentity?
        private let lock = NSLock()
        private var chunks: [Chunk] = []
        private var activeReaders = 0
        private var terminationStatus: Int32?
        private var finished = false

        init(id: UUID, generation: UInt64, process: Process, stdout: Pipe, stderr: Pipe, secrets: [String]) {
            self.id = id
            self.generation = generation
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
            self.stdoutParser = CloudflaredLogParser(secrets: secrets)
            self.stderrParser = CloudflaredLogParser(secrets: secrets)
        }

        func beginRead() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            activeReaders += 1
            return true
        }

        func endRead(_ data: Data, stream: String) {
            lock.lock()
            if !data.isEmpty { chunks.append(Chunk(data: data, stream: stream)) }
            activeReaders -= 1
            lock.unlock()
        }

        func markTerminated(status: Int32, stdout: Data, stderr: Data) {
            lock.lock()
            if !stdout.isEmpty { chunks.append(Chunk(data: stdout, stream: "stdout")) }
            if !stderr.isEmpty { chunks.append(Chunk(data: stderr, stream: "stderr")) }
            terminationStatus = status
            lock.unlock()
        }

        func takeDrain() -> (chunks: [Chunk], finalStatus: Int32?) {
            lock.lock()
            defer { lock.unlock() }
            let pending = chunks
            chunks.removeAll(keepingCapacity: true)
            let canFinish = terminationStatus != nil && activeReaders == 0
            if canFinish { finished = true }
            return (pending, canFinish ? terminationStatus : nil)
        }
    }

    private var sessions: [UUID: Session] = [:]
    private var shutdownCompletion: (() -> Void)?
    private var isShuttingDown = false
    private let isolatedConfigURL: URL
    private static let quickURLPattern = try! NSRegularExpression(
        pattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
        options: [.caseInsensitive]
    )

    /// This run's private folder for connector configs; orphans from other runs are detected by it.
    public var runDirectory: String { isolatedConfigURL.deletingLastPathComponent().path }

    public init() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenTraffic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appending(path: "empty.yml")
        try? Data("{}\n".utf8).write(to: config, options: .atomic)
        self.isolatedConfigURL = config
    }

    public func startQuick(id: UUID, generation: UInt64, executable: URL, localURL: String, hostHeader: String? = nil) throws {
        try start(
            id: id,
            generation: generation,
            executable: executable,
            arguments: commonArguments + ["--url", localURL] + (hostHeader.map { ["--http-host-header", $0] } ?? []),
            token: nil
        )
    }

    public func startRemote(id: UUID, generation: UInt64, executable: URL, token: String) throws {
        try start(
            id: id,
            generation: generation,
            executable: executable,
            arguments: commonArguments + ["run"],
            token: token
        )
    }

    /// Starts an ngrok agent for one share. The user's own config (with their authtoken) is layered
    /// with a per-agent overlay that gives this agent a private inspection port.
    public func startNgrok(
        id: UUID,
        generation: UInt64,
        executable: URL,
        localURL: String,
        domain: String?,
        apiPort: UInt16,
        userConfig: URL?,
        trafficPolicy: String? = nil
    ) throws {
        let directory = isolatedConfigURL.deletingLastPathComponent()
        let overlay = directory.appending(path: "ngrok-\(id.uuidString).yml")
        try Data(NgrokAgent.overlayConfig(apiPort: apiPort).utf8).write(to: overlay, options: .atomic)
        let configs = [userConfig?.path, overlay.path].compactMap { $0 }
        var arguments = NgrokAgent.arguments(localURL: localURL, domain: domain, configPaths: configs)
        let policyURL = directory.appending(path: "ngrok-policy-\(id.uuidString).yml")
        if let trafficPolicy {
            // May hold basic-auth credentials: owner-only, inside this run's private folder.
            FileManager.default.createFile(atPath: policyURL.path, contents: Data(trafficPolicy.utf8), attributes: [.posixPermissions: 0o600])
            arguments += ["--traffic-policy-file", policyURL.path]
        } else {
            try? FileManager.default.removeItem(at: policyURL)
        }
        do {
            try start(id: id, generation: generation, executable: executable, arguments: arguments, token: nil)
        } catch {
            removeAgentFiles(for: id)
            throw error
        }
    }

    /// The ngrok overlay and policy (which may hold a share password) are only needed while the
    /// agent runs; remove them as soon as it exits.
    private func removeAgentFiles(for id: UUID) {
        let directory = isolatedConfigURL.deletingLastPathComponent()
        for name in ["ngrok-\(id.uuidString).yml", "ngrok-policy-\(id.uuidString).yml"] {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    public func stop(id: UUID) {
        guard let session = sessions[id] else { return }
        session.process.terminate()
        let process = session.process
        Task {
            try? await Task.sleep(for: .seconds(6))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    public func shutdown(completion: @escaping () -> Void) {
        shutdownCompletion = completion
        isShuttingDown = true
        for session in sessions.values where session.process.isRunning {
            session.process.terminate()
        }
        if sessions.isEmpty {
            shutdownCompletion = nil
            try? FileManager.default.removeItem(at: isolatedConfigURL.deletingLastPathComponent())
            completion()
            return
        }
        let processes = sessions.values.map(\.process)
        Task {
            try? await Task.sleep(for: .seconds(6))
            for process in processes where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    public func isRunning(id: UUID) -> Bool {
        sessions[id]?.process.isRunning == true
    }

    public var ownedProcessIDs: Set<Int32> {
        Set(sessions.values.compactMap { session in
            session.process.isRunning ? session.process.processIdentifier : nil
        })
    }

    public func ownedConnectorIdentity(id: UUID) -> OwnedConnectorIdentity? {
        guard let session = sessions[id], session.process.isRunning, let process = session.processIdentity else { return nil }
        return OwnedConnectorIdentity(process: process, generation: session.generation)
    }

    private var commonArguments: [String] {
        ["tunnel", "--config", isolatedConfigURL.path, "--no-autoupdate", "--grace-period", "5s", "--loglevel", "info", "--output", "json"]
    }

    private func start(
        id: UUID,
        generation: UInt64,
        executable: URL,
        arguments: [String],
        token: String?
    ) throws {
        guard !isShuttingDown else {
            throw OpenTrafficError.process("OpenTraffic is quitting.")
        }
        if sessions[id]?.process.isRunning == true {
            throw OpenTrafficError.process("This tunnel already has a connector running.")
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.uppercased().hasPrefix("TUNNEL_")
                && !$0.key.uppercased().hasPrefix("CLOUDFLARED_")
        }
        if let token { environment["TUNNEL_TOKEN"] = token }
        process.environment = environment

        let session = Session(
            id: id,
            generation: generation,
            process: process,
            stdout: stdout,
            stderr: stderr,
            secrets: token.map { [$0] } ?? []
        )
        sessions[id] = session
        installReader(for: session, stream: "stdout")
        installReader(for: session, stream: "stderr")

        process.terminationHandler = { [weak self, weak session] process in
            guard let session else { return }
            session.stdout.fileHandleForReading.readabilityHandler = nil
            session.stderr.fileHandleForReading.readabilityHandler = nil
            let stdout = session.stdout.fileHandleForReading.readDataToEndOfFile()
            let stderr = session.stderr.fileHandleForReading.readDataToEndOfFile()
            session.markTerminated(status: process.terminationStatus, stdout: stdout, stderr: stderr)
            Task { @MainActor in
                self?.drain(session: session)
            }
        }

        do {
            try process.run()
            session.processIdentity = Self.processIdentity(pid: process.processIdentifier)
        } catch {
            sessions[id] = nil
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw OpenTrafficError.process("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func processIdentity(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        )
    }

    private func installReader(for session: Session, stream: String) {
        let handle = stream == "stdout" ? session.stdout.fileHandleForReading : session.stderr.fileHandleForReading
        handle.readabilityHandler = { [weak self, weak session] handle in
            guard let session, session.beginRead() else { return }
            let data = handle.availableData
            session.endRead(data, stream: stream)
            Task { @MainActor in
                self?.drain(session: session)
            }
        }
    }

    private func drain(session: Session) {
        guard sessions[session.id] === session else { return }
        let drain = session.takeDrain()
        var entries: [TunnelLogEntry] = []
        for chunk in drain.chunks {
            if chunk.stream == "stdout" {
                entries.append(contentsOf: session.stdoutParser.append(chunk.data, stream: chunk.stream))
            } else {
                entries.append(contentsOf: session.stderrParser.append(chunk.data, stream: chunk.stream))
            }
        }
        if !entries.isEmpty { onLogs?(session.id, session.generation, entries) }
        for entry in entries {
            if let url = Self.extractQuickURL(entry.message)
                ?? NgrokAgent.publicURL(fromLogMessage: entry.message, rawLine: entry.rawLine) {
                onPublicURL?(session.id, session.generation, url)
            }
        }
        guard let status = drain.finalStatus else { return }
        let trailing = session.stdoutParser.finish(stream: "stdout") + session.stderrParser.finish(stream: "stderr")
        if !trailing.isEmpty { onLogs?(session.id, session.generation, trailing) }
        // A newer session for the same tunnel may already have replaced this one; leave it alone.
        if sessions[session.id] === session {
            sessions[session.id] = nil
            removeAgentFiles(for: session.id)
        }
        onTermination?(session.id, session.generation, status)
        if sessions.isEmpty, let completion = shutdownCompletion {
            shutdownCompletion = nil
            try? FileManager.default.removeItem(at: isolatedConfigURL.deletingLastPathComponent())
            completion()
        }
    }

    private static func extractQuickURL(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = quickURLPattern.firstMatch(in: text, range: range),
            let swiftRange = Range(match.range, in: text)
        else { return nil }
        return String(text[swiftRange])
    }
}

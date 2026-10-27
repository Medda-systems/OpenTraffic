import AppKit
import Foundation
import OpenTrafficCore

/// Sharing an Electron app being developed: viewers get its windows in their browser, with the
/// collaboration overlay, and its main process runs as a sandboxed copy on this Mac
/// (electron-host.js, see ElectronHostSession) with a throwaway copy of the app's data.
extension AppStore {
    static let electronHostScript = Bundle.main.url(forResource: "electron-host", withExtension: "js")
    static let electronShimScript = Bundle.main.url(forResource: "electron-preload-shim", withExtension: "js")

    /// Local ports databases usually listen on: allowing one lets viewers change real data.
    static let databasePorts: Set<Int> = [5432, 3306, 33060, 27017, 6379, 9200, 5984, 8529, 7687, 26257, 1433, 1521]

    // MARK: Discovery

    /// Finds Electron apps in development, and which local servers belong to each.
    func scanElectronApps() async {
        let services = detectedLocalServices
        let (apps, ports) = await Task.detached(priority: .utility) { () -> ([ElectronApp], [String: Set<Int>]) in
            let apps = ElectronDiscovery.scan()
            var ports: [String: Set<Int>] = [:]
            for app in apps {
                var owned = Set(app.environmentPorts)
                for service in services {
                    guard app.bundle == nil, let pid = service.pid, let folder = ProcessDirectory.of(pid) else { continue }
                    if ElectronDiscovery.isInside(folder, app.projectRoot) { owned.insert(service.port) }
                }
                ports[app.id] = owned
            }
            return (apps, ports)
        }.value
        if apps != detectedElectronApps { detectedElectronApps = apps }
        if ports != electronAppPorts { electronAppPorts = ports }
    }

    /// Detected Electron apps that aren't shared right now.
    var shareableElectronApps: [ElectronApp] {
        let shared = Set(definitions.filter { isActive($0.id) || runtime(for: $0.id).state == .stopping }.compactMap(\.electronApp))
        return detectedElectronApps.filter { !shared.contains($0.id) }
    }

    /// The local address viewers' pages come from: the app's dev server when it has one.
    func rendererURL(for app: ElectronApp) -> String? {
        if let url = app.environment["ELECTRON_RENDERER_URL"] ?? app.environment["ELECTRON_START_URL"] ?? app.environment["VITE_DEV_SERVER_URL"],
           URL(string: url)?.host != nil {
            return url
        }
        let ports = electronAppPorts[app.id] ?? Set(app.environmentPorts)
        return detectedLocalServices.first { ports.contains($0.port) }?.url
    }

    // MARK: Sharing

    /// One-step sharing of an Electron app, like a web server: reuse its saved share or create one.
    /// `name` names a new share (default: the app's); a share of the app that exists keeps its own.
    func share(_ app: ElectronApp, kind: TunnelKind = .quick, data: ElectronHostSession.DataSource = .copy, name: String? = nil) {
        let kind: TunnelKind = kind == .opentunnel ? .opentunnel : .quick
        // A finished app's data holds real logins: its copy always starts empty.
        let data: ElectronHostSession.DataSource = app.isPackaged ? .empty : data
        guard Self.electronHostScript != nil, Self.electronShimScript != nil else {
            notice = AppNotice(.error, "OpenTraffic's Electron support is missing from the app. Reinstall OpenTraffic.")
            return
        }
        // Apps that load files rather than a dev server get their files from the sandboxed copy;
        // the address is decided when it starts.
        let localURL = rendererURL(for: app) ?? "http://127.0.0.1/"
        if let index = definitions.firstIndex(where: { $0.electronApp == app.id && $0.kind == kind }) {
            definitions[index].localURL = localURL
            definitions[index].electronData = data
            definitions[index].collaboration = true
            saveDefinitions()
            startSharing(definitions[index])
            return
        }
        do {
            var definition = switch kind {
            case .opentunnel: try addOpenTunnel(name: name ?? app.name, localURL: localURL, collaboration: true)
            default: try addQuick(name: name ?? app.name, localURL: localURL, collaboration: true)
            }
            guard let index = definitions.firstIndex(where: { $0.id == definition.id }) else { return }
            definitions[index].electronApp = app.id
            definitions[index].electronData = data
            definitions[index].collaboration = true
            // Comments get fixed in the project: a finished app's is the one it was built from, if known.
            definitions[index].agentDirectory = definitions[index].agentDirectory
                ?? (app.bundle.map { ElectronDiscovery.sourceFolder(of: $0)?.path } ?? app.appDirectory.path)
            definition = definitions[index]
            saveDefinitions()
            startSharing(definition)
        } catch {
            notice = AppNotice(.error, error.localizedDescription)
        }
    }

    /// Starts the sandboxed copy of the share's app and returns where its pages come from.
    func startElectronSession(for definition: TunnelDefinition) async throws -> (host: String, port: Int, hostPort: Int) {
        guard let folder = definition.electronApp,
              let hostScript = Self.electronHostScript, let shimScript = Self.electronShimScript else { throw OpenTrafficError.invalidLocalURL }
        stopElectronSession(definition.id)
        let id = definition.id
        let app = detectedElectronApps.first { $0.id == folder }
            ?? (folder.hasSuffix(".app") || folder.hasSuffix(".app/")
                ? ElectronDiscovery.finishedApp(bundle: URL(fileURLWithPath: folder))
                : ElectronDiscovery.app(atDirectory: URL(fileURLWithPath: folder), environment: savedEnvironment(for: definition)))
        guard let app else {
            throw OpenTrafficError.process("Couldn't find the Electron app in \(folder). Is its node_modules installed?")
        }
        guard let port = ElectronHostSession.freePort() else { throw OpenTrafficError.process("No free local port for the app's main process.") }
        var runtime: URL?
        if let bundle = app.bundle, !ElectronRuntime.runsAsNode(bundle) {
            let version = ElectronRuntime.version(of: bundle) ?? "?"
            appendElectronLog("\(app.name) turned off Electron's Node mode: running its copy on a stock Electron \(version) (downloaded once, about 100 MB).", for: id)
            runtime = try await ElectronRuntime.binary(for: bundle, executable: app.electronBinary)
        }
        let session = ElectronHostSession(options: .init(
            app: app,
            hostScript: hostScript,
            shimScript: shimScript,
            sessionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("OpenTraffic-Electron/\(id.uuidString)"),
            port: port,
            allowedPorts: allowedElectronPorts(for: definition, app: app),
            dataSource: app.isPackaged ? .empty : definition.electronData ?? .copy,
            path: await electronShellPath(),
            runtime: runtime
        ))
        session.onEvent = { [weak self, weak session] event in
            Task { @MainActor in
                guard let self, let session, self.electronSessions[id] === session else { return }
                self.electronEvent(event, for: id)
            }
        }
        electronSessions[id] = session
        appendElectronLog("Starting \(app.name)'s main process, sandboxed, with \(app.isPackaged || definition.electronData == .empty ? "empty data" : "a copy of its data").", for: id)
        try session.start()
        let windows = try await session.waitUntilReady()
        watchElectronCode(app, windows: windows, for: id)
        guard let window = windows.first else { throw OpenTrafficError.process("\(app.name) didn't open a window.") }
        if let file = window.file, !file.isEmpty { return ("127.0.0.1", port, port) }
        // Its own scheme (app://): the sandboxed copy answers through the app's protocol handler.
        if let raw = window.url, let scheme = URL(string: raw)?.scheme?.lowercased(), !["http", "https"].contains(scheme) {
            return ("127.0.0.1", port, port)
        }
        guard let raw = window.url, let url = URL(string: raw), let host = url.host,
              ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host.lowercased()) else {
            throw OpenTrafficError.process("\(app.name)'s window opens \(window.url ?? "nothing"); OpenTraffic can share apps whose windows load a local dev server or the app's own files.")
        }
        let upstreamPort = url.port ?? 80
        // "localhost" may be IPv6 or IPv4, and another app may hold the other one on the same port.
        let root = app.bundle == nil ? app.projectRoot : nil
        let upstreamHost = host == "localhost" || host == "0.0.0.0"
            ? await Task.detached { ElectronDiscovery.loopbackHost(forPort: upstreamPort, projectRoot: root) }.value
            : host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (upstreamHost, upstreamPort, port)
    }

    func stopElectronSession(_ id: UUID) {
        electronWatchers.removeValue(forKey: id)?.forEach { $0.stop() }
        electronViewers[id] = nil
        guard let session = electronSessions.removeValue(forKey: id) else { return }
        Task.detached { session.stop() }
    }

    /// Ports the sandboxed copy may reach: the ones the share allowed, plus the app's own (its dev
    /// server and anything else its project runs, and what its environment and .env files name).
    func allowedElectronPorts(for definition: TunnelDefinition, app: ElectronApp) -> Set<Int> {
        var ports = Set(definition.bridgedPorts).union(app.environmentPorts).union(electronAppPorts[app.id] ?? [])
        ports.formUnion(ElectronDiscovery.envFilePorts(in: app.appDirectory))
        if app.projectRoot != app.appDirectory { ports.formUnion(ElectronDiscovery.envFilePorts(in: app.projectRoot)) }
        if let url = URL(string: definition.localURL), let port = url.port { ports.insert(port) }
        return ports.subtracting(Set(collabProxies.values.compactMap(\.port))).subtracting([apiPort])
    }

    /// What the app's dev script would set when the app isn't running: its renderer address.
    private func savedEnvironment(for definition: TunnelDefinition) -> [String: String] {
        guard let url = URL(string: definition.localURL), url.port != nil else { return ["NODE_ENV": "development"] }
        return ["ELECTRON_RENDERER_URL": definition.localURL, "NODE_ENV": "development"]
    }

    private func electronShellPath() async -> String {
        if agentShellPath == nil {
            agentShellPath = Task.detached(priority: .userInitiated) { LoginShell.pathOrFallback() }
        }
        return await agentShellPath?.value ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    // MARK: While it runs

    private func electronEvent(_ event: ElectronHostSession.Event, for id: UUID) {
        switch event {
        case .log(let line):
            appendElectronLog(line, for: id)
        case .viewers(let count):
            electronViewers[id] = count
        case .wants(let port, _):
            electronWants(port, for: id)
        case .failed(let message):
            appendElectronLog("The app's main process failed: \(message)", for: id, error: true)
            notice = AppNotice(.error, "\(shareName(id))'s main process failed: \(message)")
        case .exited(let status):
            appendElectronLog("The app's main process stopped (status \(status)).", for: id, error: true)
            restartAfterCrash(id)
        case .ready, .windows:
            break
        }
    }

    /// The app's main process tried to reach a local service it may not: its own project's are
    /// allowed right away, anything else is the host's call (the share's Live Collaboration card).
    private func electronWants(_ port: Int, for id: UUID) {
        guard let definition = definitions.first(where: { $0.id == id }) else { return }
        let reserved = Set(collabProxies.values.compactMap(\.port)).union([apiPort])
        let ownPorts = definition.electronApp.flatMap { electronAppPorts[$0] } ?? []
        if ownPorts.contains(port), !reserved.contains(port) {
            allowBridgedPort(port, for: id)
            return
        }
        guard !reserved.contains(port) else {
            electronSessions[id]?.deny(port: port)
            return
        }
        if collabBridgeCandidates[id, default: []].insert(port).inserted {
            notice = AppNotice(.info, "\(shareName(id))'s main process wants to reach localhost:\(port). Allow it in the share's Live Collaboration card.")
        }
    }

    /// A newly allowed local service reaches the sandboxed copy after a quick restart (calls in flight are retried).
    func electronAllowedPortsChanged(for id: UUID) {
        guard let session = electronSessions[id], let definition = definitions.first(where: { $0.id == id }) else { return }
        let app = detectedElectronApps.first { $0.id == definition.electronApp }
        let ports = app.map { allowedElectronPorts(for: definition, app: $0) } ?? session.allowedPorts.union(definition.bridgedPorts)
        guard ports != session.allowedPorts else { return }
        Task.detached { try? session.restart(allowedPorts: ports) }
    }

    func denyElectronPort(_ port: Int, for id: UUID) {
        electronSessions[id]?.deny(port: port)
    }

    /// Starts the share's app over from its original data.
    func resetElectronData(_ id: UUID) {
        guard let session = electronSessions[id] else { return }
        appendElectronLog("Resetting the app's data.", for: id)
        Task.detached { try? session.reset() }
    }

    func restartElectronApp(_ id: UUID) {
        guard let session = electronSessions[id] else { return }
        appendElectronLog("Restarting the app's main process.", for: id)
        Task.detached { try? session.restart() }
    }

    /// Started again by itself after a crash, up to three times a minute.
    private func restartAfterCrash(_ id: UUID) {
        guard let session = electronSessions[id] else { return }
        let recent = (electronCrashes[id] ?? []).filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        electronCrashes[id] = recent
        guard recent.count <= 3 else {
            notice = AppNotice(.error, "\(shareName(id))'s main process keeps stopping. Check the share's log, then restart it.")
            return
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            try? session.restart()
        }
    }

    /// Restarts the sandboxed copy when the app's main-process code changes (the page keeps
    /// running; a changed preload reloads it). Watches the built code (out/, .vite/build/, a finished
    /// app's app.asar); when only the sources change and the dev tool doesn't rebuild them (electron-vite
    /// without --watch), OpenTraffic runs the project's build itself.
    private func watchElectronCode(_ app: ElectronApp, windows: [ElectronHostSession.Window], for id: UUID) {
        electronWatchers.removeValue(forKey: id)?.forEach { $0.stop() }
        let roots = app.bundle.map { [$0.appendingPathComponent("Contents/Resources")] }
            ?? [app.mainEntry.deletingLastPathComponent()] + windows.compactMap { $0.preload.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } }
        let built: @Sendable () -> [String: Date] = { ElectronCodeFingerprint.of(roots) }
        let builtBaseline = LockedValue(built())
        var watchers: [ProjectWatcher] = []
        // Build folders often start with a dot (.vite/build), which a project-wide watcher skips: watch each.
        for root in Set(roots.map { $0.standardizedFileURL }) {
            let watcher = ProjectWatcher(directory: root) { [weak self] in
                let current = built()
                guard builtBaseline.exchange(current) != current else { return }
                Task { @MainActor in
                    guard let self, let session = self.electronSessions[id] else { return }
                    self.appendElectronLog("The app's code changed: restarting its main process.", for: id)
                    Task.detached { try? session.restart() }
                }
            }
            if watcher.start() { watchers.append(watcher) }
        }
        if app.bundle == nil, let build = ElectronBuild.command(for: app.appDirectory) {
            let sources: @Sendable () -> [String: Date] = { ElectronCodeFingerprint.of([app.appDirectory.appendingPathComponent("src")], extensions: ElectronCodeFingerprint.sourceExtensions) }
            let sourceBaseline = LockedValue(sources())
            let watcher = ProjectWatcher(directory: app.appDirectory) { [weak self] in
                let current = sources()
                guard sourceBaseline.exchange(current) != current else { return }
                let builtBefore = built()
                Task { @MainActor in
                    // Give the dev tool's own watch mode a moment; build only if it didn't.
                    try? await Task.sleep(for: .seconds(2.5))
                    guard let self, self.electronSessions[id] != nil, built() == builtBefore else { return }
                    await self.rebuildElectronApp(app, command: build, for: id)
                }
            }
            if watcher.start() { watchers.append(watcher) }
        }
        electronWatchers[id] = watchers
    }

    /// Builds the app's main and preload code with its own tool, so a change to them reaches the
    /// sandboxed copy (the build output's change then restarts it).
    private func rebuildElectronApp(_ app: ElectronApp, command: [String], for id: UUID) async {
        appendElectronLog("The app's main-process sources changed: building them (\(command.joined(separator: " "))).", for: id)
        let path = await electronShellPath()
        let result = await Task.detached { ElectronBuild.run(command, in: app.appDirectory, path: path) }.value
        if let failure = result {
            appendElectronLog("The build failed: \(failure)", for: id, error: true)
        }
    }

    private func shareName(_ id: UUID) -> String {
        definitions.first { $0.id == id }?.name ?? "The app"
    }

    private func appendElectronLog(_ line: String, for id: UUID, error: Bool = false) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if logs[id] == nil { logs[id] = BoundedLogBuffer() }
        logs[id]?.append(contentsOf: [TunnelLogEntry(level: error ? "error" : "info", message: text, stream: "app")])
    }

    // MARK: Icons

    /// The app's icon: the project's own, or Electron's.
    static func icon(for app: ElectronApp) -> NSImage {
        if let file = app.iconFile, let image = NSImage(contentsOf: file) { return image }
        let bundle = app.electronBinary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSWorkspace.shared.icon(forFile: bundle.path)
    }
}

/// When a shared Electron app's main-process code last changed: its .js/.json files' dates.
enum ElectronCodeFingerprint {
    static let builtExtensions: Set<String> = ["js", "cjs", "mjs", "json", "node", "asar"]
    static let sourceExtensions: Set<String> = ["ts", "mts", "cts", "tsx", "js", "mjs", "cjs", "jsx", "json"]

    static func of(_ roots: [URL], extensions: Set<String> = builtExtensions) -> [String: Date] {
        var result: [String: Date] = [:]
        let skipped = ProjectWatcher.ignoredFolders.union(["renderer", "public", "static"])
        for root in Set(roots.map(\.standardizedFileURL)) {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 4 || skipped.contains(url.lastPathComponent) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()),
                      let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                result[url.path] = date
                if result.count > 5_000 { return result }
            }
        }
        return result
    }
}

/// A value shared with a background callback.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    /// Stores `new` and returns what was there.
    func exchange(_ new: Value) -> Value {
        lock.withLock {
            defer { value = new }
            return value
        }
    }
}

/// The project's own build, for dev tools that don't rebuild the main process by themselves.
enum ElectronBuild {
    /// electron-vite: `electron-vite build`, in development mode so dev-only paths (the dev server) stay.
    static func command(for directory: URL) -> [String]? {
        let configs = ["electron.vite.config.ts", "electron.vite.config.mts", "electron.vite.config.js", "electron.vite.config.mjs", "electron.vite.config.cjs"]
        guard configs.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }),
              FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("node_modules/.bin/electron-vite").path) else { return nil }
        return ["node_modules/.bin/electron-vite", "build", "--mode", "development"]
    }

    /// Runs it; nil when it worked, otherwise the end of its output.
    static func run(_ command: [String], in directory: URL, path: String) -> String? {
        let process = Process()
        process.executableURL = directory.appendingPathComponent(command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment["NODE_ENV"] = "development"
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return error.localizedDescription }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(decoding: data.suffix(600), as: UTF8.self)
    }
}

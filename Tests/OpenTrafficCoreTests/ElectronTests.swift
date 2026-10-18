import Foundation
import Testing
@testable import OpenTrafficCore

// Electron app sharing: finding apps, the sandbox, and (with the fixture's Electron installed:
// `npm install` in Examples/electron-orbit) the sandboxed host end to end through the proxy.

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repository.appendingPathComponent("Examples/electron-orbit")
private let fixtureElectron = fixture.appendingPathComponent("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
private let resources = repository.appendingPathComponent("Sources/OpenTraffic/Resources")
private let hasFixtureElectron = FileManager.default.isExecutableFile(atPath: fixtureElectron.path)

@Test func processArgumentsSplitArgumentsFromEnvironment() throws {
    var bytes = withUnsafeBytes(of: Int32(2)) { Array($0) }
    bytes += Array("/x/Electron".utf8) + [0, 0, 0]
    bytes += Array("/x/Electron".utf8) + [0] + Array(".".utf8) + [0]
    bytes += Array("ELECTRON_RENDERER_URL=http://localhost:5173".utf8) + [0] + Array("A=b=c".utf8) + [0, 0]
    let (arguments, environment) = try #require(ProcessArguments.parse(bytes))
    #expect(arguments == ["/x/Electron", "."])
    #expect(environment == ["ELECTRON_RENDERER_URL": "http://localhost:5173", "A": "b=c"])
}

@Test func theSandboxedCopyKeepsDevSettingsButNoSecrets() {
    let kept = ElectronDiscovery.sandboxEnvironment([
        "ELECTRON_RENDERER_URL": "http://localhost:5173",
        "NODE_ENV": "development",
        "VITE_API_URL": "http://127.0.0.1:8080/api",
        "ORBIT_API_PORT": "5198",
        "OPENAI_API_KEY": "sk-123",
        "GITHUB_TOKEN": "ghp_1",
        "DATABASE_URL": "postgres://user:pw@db.example.com/x",
        "AUTH_URL": "http://localhost:3000",
        "PATH": "/usr/bin",
        "HOME": "/Users/me",
    ])
    #expect(kept == [
        "ELECTRON_RENDERER_URL": "http://localhost:5173",
        "NODE_ENV": "development",
        "VITE_API_URL": "http://127.0.0.1:8080/api",
        "ORBIT_API_PORT": "5198",
    ])
    #expect(ElectronDiscovery.localPorts(in: kept) == [5173, 5198, 8080])
}

@Test func envFilesNameTheLocalServicesAnAppUses() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "# local\nexport API_URL=\"http://localhost:8000/v1\"\nOLLAMA_HOST=http://127.0.0.1:11434\nREMOTE_URL=https://example.com\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "WORKER_PORT=7001\n".write(to: folder.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    #expect(ElectronDiscovery.envFilePorts(in: folder) == [7001, 8000, 11434])
}

@Test func anElectronProcessResolvesToItsProject() throws {
    let app = try #require(ElectronDiscovery.resolve(
        pid: 42,
        executable: fixtureElectron.path,
        arguments: [fixtureElectron.path, "."],
        environment: ["ELECTRON_RENDERER_URL": "http://localhost:5199", "ORBIT_API_PORT": "5198", "SECRET_TOKEN": "x"],
        workingDirectory: fixture,
        homeDirectory: NSHomeDirectory()
    ))
    #expect(app.name == "Orbit")
    #expect(app.version == "0.1.0")
    #expect(app.appDirectory.standardizedFileURL == fixture.standardizedFileURL)
    #expect(app.mainEntry.lastPathComponent == "main.js")
    #expect(app.environmentPorts == [5198, 5199])
    #expect(app.environment["SECRET_TOKEN"] == nil)
    #expect(app.userDataDirectory.path.hasSuffix("Library/Application Support/Orbit"))
    #expect(ElectronDiscovery.isDevelopmentElectron(fixtureElectron.path))
    #expect(!ElectronDiscovery.isDevelopmentElectron("/Applications/Slack.app/Contents/MacOS/Slack"))
}

@Test func theSandboxProfileOnlyOpensWhatItMust() {
    let profile = ElectronSandbox.profile(.init(
        homeDirectory: "/Users/me",
        readable: ["/Users/me/code/orbit"],
        session: "/private/tmp/ot-session",
        allowedPorts: [5199, 5198, 5199],
        allowedSockets: [],
        privateFolders: ["/private/tmp"]
    ))
    #expect(profile.contains(#"(deny file-read* (subpath "/private/tmp"))"#))
    // The session is inside a private folder: allowed after it.
    #expect(profile.range(of: #"(deny file-read* (subpath "/private/tmp"))"#)!.lowerBound < profile.range(of: #"(allow file-read* (subpath "/private/tmp/ot-session"))"#)!.lowerBound)
    #expect(profile.contains(#"(deny file-read* (subpath "/Users") (subpath "/Volumes") (subpath "/Users/me"))"#))
    #expect(profile.contains(#"(allow file-read* (subpath "/Users/me/code/orbit"))"#))
    #expect(profile.contains(#"(allow file-read-metadata (literal "/Users/me/code"))"#))
    #expect(!profile.contains(#"(allow file-read* (subpath "/Users/me/code"))"#))
    #expect(profile.contains(#"(deny file-write* (subpath "/"))"#))
    #expect(profile.contains(#"(allow file-write* (subpath "/private/tmp/ot-session"))"#))
    #expect(profile.contains(#"(global-name "com.apple.securityd")"#))
    #expect(profile.components(separatedBy: #"(allow network-outbound (remote ip "localhost:5199"))"#).count == 2)
    // TCP rules come after the unix-socket ones, or those would close localhost too.
    let unix = profile.range(of: "(deny network-outbound (remote unix-socket))")!
    let tcp = profile.range(of: #"(deny network-outbound (remote ip "localhost:*"))"#)!
    #expect(unix.lowerBound < tcp.lowerBound)
}

// MARK: End to end

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ElectronHostSession.Event] = []
    func add(_ event: ElectronHostSession.Event) { lock.withLock { items.append(event) } }
    var wanted: [Int] { lock.withLock { items.compactMap { if case .wants(let port, _) = $0 { return port } else { return nil } } } }
    var logs: [String] { lock.withLock { items.compactMap { if case .log(let line) = $0 { return line } else { return nil } } } }
}

private func call(_ task: URLSessionWebSocketTask, _ message: [String: Any], until id: String) async throws -> [String: Any] {
    try await task.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
    while true {
        guard case .string(let text) = try await task.receive(),
              let reply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
        if reply["t"] as? String == "result", reply["id"] as? String == id { return reply }
    }
}

@Test(.enabled(if: hasFixtureElectron, "npm install in Examples/electron-orbit"), .timeLimit(.minutes(1)))
func aSharedElectronAppRunsSandboxedBehindTheProxy() async throws {
    let app = try #require(ElectronDiscovery.resolve(
        pid: 1, executable: fixtureElectron.path, arguments: [fixtureElectron.path, "."],
        environment: ["ELECTRON_RENDERER_URL": "http://localhost:5199"], workingDirectory: fixture, homeDirectory: NSHomeDirectory()
    ))
    let sessionFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-electron-\(UUID().uuidString)")
    let port = try #require(ElectronHostSession.freePort())
    let session = ElectronHostSession(options: .init(
        app: app, hostScript: resources.appendingPathComponent("electron-host.js"), shimScript: resources.appendingPathComponent("electron-preload-shim.js"),
        sessionDirectory: sessionFolder, port: port, allowedPorts: [5199], dataSource: .empty, path: "/usr/bin:/bin"
    ))
    let events = Events()
    session.onEvent = { event in
        events.add(event)
        if case .wants(let wanted, _) = event { session.deny(port: wanted) }
    }
    try session.start()
    defer { session.stop() }
    let windows = try await session.waitUntilReady()
    #expect(windows.first?.url == "http://localhost:5199")
    #expect(windows.first?.preload?.hasSuffix("preload.js") == true)

    let proxy = CollabProxy(configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: 5199, overlayScript: Data(), electronHostPort: port))
    let proxyPort = try await proxy.start()
    defer { Task { await proxy.stop() } }
    let urlSession = URLSession(configuration: .ephemeral)

    // The preload, with Electron's renderer modules, through the proxy.
    let (preload, _) = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/__opentraffic/electron/preload.js")!)
    let preloadText = String(decoding: preload, as: UTF8.self)
    #expect(preloadText.contains("__opentrafficElectronRunPreload"))
    #expect(preloadText.contains(#"contextBridge.exposeInMainWorld("orbit""#))

    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(proxyPort)/__opentraffic/electron/ipc?client=test&page=/")!)
    request.setValue("http://127.0.0.1:\(proxyPort)", forHTTPHeaderField: "Origin")
    let socket = urlSession.webSocketTask(with: request)
    socket.resume()
    defer { socket.cancel() }

    // IPC reaches the app's handlers, and its data lands in the session, not the real app's folder.
    let added = try await call(socket, ["t": "invoke", "id": "1", "channel": "notes:add", "args": ["hello"]], until: "1")
    #expect(added["ok"] as? Bool == true)
    #expect((added["value"] as? [[String: Any]])?.first?["text"] as? String == "hello")
    let notes = sessionFolder.appendingPathComponent("home/Library/Application Support/Orbit/notes.json")
    #expect(FileManager.default.fileExists(atPath: notes.path))

    // The sandbox: no reading the home folder, no writing the project, no unallowed local services.
    let home = try await call(socket, ["t": "invoke", "id": "2", "channel": "probe:read", "args": [NSHomeDirectory() + "/.zshrc"]], until: "2")
    #expect(home["ok"] as? Bool == false)
    let temporary = try await call(socket, ["t": "invoke", "id": "5", "channel": "probe:read", "args": ["/private/etc/hosts"]], until: "5")
    #expect(temporary["ok"] as? Bool == true) // system files are fine
    let project = try await call(socket, ["t": "invoke", "id": "3", "channel": "probe:read", "args": [fixture.appendingPathComponent("package.json").path]], until: "3")
    #expect(project["ok"] as? Bool == true)
    let local = try await call(socket, ["t": "invoke", "id": "4", "channel": "probe:fetch", "args": ["http://127.0.0.1:\(proxyPort)/"]], until: "4")
    #expect(local["ok"] as? Bool == false)
    #expect(events.wanted == [proxyPort])

    // Allowed, it restarts with the port open (same port, same data) and the call goes through.
    try session.restart(allowedPorts: [5199, proxyPort])
    _ = try await session.waitUntilReady()
    let again = urlSession.webSocketTask(with: request)
    again.resume()
    defer { again.cancel() }
    let allowed = try await call(again, ["t": "invoke", "id": "6", "channel": "probe:fetch", "args": ["http://127.0.0.1:\(proxyPort)/__opentraffic/electron/state"]], until: "6")
    #expect(allowed["ok"] as? Bool == true)
    let kept = try await call(again, ["t": "invoke", "id": "7", "channel": "notes:list", "args": []], until: "7")
    #expect((kept["value"] as? [Any])?.count == 1)

    // Reset: back to the data it started with (empty here), on the same port.
    try session.reset()
    _ = try await session.waitUntilReady()
    let afterReset = urlSession.webSocketTask(with: request)
    afterReset.resume()
    defer { afterReset.cancel() }
    let emptied = try await call(afterReset, ["t": "invoke", "id": "8", "channel": "notes:list", "args": []], until: "8")
    #expect((emptied["value"] as? [Any])?.isEmpty == true)

    // Another site can't open the app's socket from a visitor's browser.
    var foreign = URLRequest(url: URL(string: "ws://127.0.0.1:\(proxyPort)/__opentraffic/electron/ipc?client=evil")!)
    foreign.setValue("https://evil.example", forHTTPHeaderField: "Origin")
    let evil = urlSession.webSocketTask(with: foreign)
    evil.resume()
    await #expect(throws: (any Error).self) { _ = try await evil.receive() }
}

// MARK: Finished apps (`npm run package` in Examples/electron-orbit builds dist/Orbit.app)

private let finishedBundle = fixture.appendingPathComponent("dist/Orbit.app")
private let hasFinishedApp = FileManager.default.fileExists(atPath: finishedBundle.appendingPathComponent("Contents/Resources/app.asar").path)

@Test func onlyAnAppsMainExecutableCountsAsTheApp() {
    #expect(ElectronDiscovery.appBundle(forExecutable: "/Users/me/code/orbit/dist/Orbit.app/Contents/MacOS/Orbit")?.path == "/Users/me/code/orbit/dist/Orbit.app")
    #expect(ElectronDiscovery.appBundle(forExecutable: "/Applications/Orbit.app/Contents/Frameworks/Orbit Helper (Renderer).app/Contents/MacOS/Orbit Helper (Renderer)") == nil)
    #expect(ElectronDiscovery.appBundle(forExecutable: "/usr/local/bin/node") == nil)
}

@Test func yourOwnSigningTeamsComeFromYourIdentities() {
    let output = """
      1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: me@example.com (ABCDE12345)"
      2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Developer ID Application: Example AB (Z9Y8X7W6V5)"
         2 valid identities found
    """
    #expect(CodeSignature.parseTeams(output) == ["ABCDE12345", "Z9Y8X7W6V5"])
}

@Test(.enabled(if: hasFinishedApp, "npm run package in Examples/electron-orbit"))
func aFinishedAppIsFoundFromItsBundle() throws {
    let app = try #require(ElectronDiscovery.finishedApp(bundle: finishedBundle))
    #expect(app.name == "Orbit")
    #expect(app.isPackaged)
    #expect(app.id == finishedBundle.path)
    #expect(app.appDirectory.lastPathComponent == "app.asar")
    #expect(ElectronDiscovery.isElectronBundle(finishedBundle))
    // Built in the project's dist/ folder, signed ad hoc: yours.
    #expect(ElectronDiscovery.isOwnBuild(finishedBundle, ownTeams: []))
    #expect(ElectronDiscovery.sourceFolder(of: finishedBundle)?.standardizedFileURL == fixture.standardizedFileURL)
    #expect(ElectronRuntime.version(of: finishedBundle)?.isEmpty == false)
}

@Test(.enabled(if: hasFinishedApp, "npm run package in Examples/electron-orbit"))
func theRunAsNodeFuseIsReadFromTheFramework() throws {
    let fuse = try #require(ElectronRuntime.fuses(inFramework: ElectronRuntime.frameworkBinary(of: finishedBundle))?.first)
    #expect(ElectronRuntime.runsAsNode(finishedBundle) == (fuse == UInt8(ascii: "1")))
    // A copy with the fuse flipped (off is how Forge's template ships apps).
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ot-fuse-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: copy) }
    let binary = copy.appendingPathComponent("Electron Framework")
    try FileManager.default.copyItem(at: ElectronRuntime.frameworkBinary(of: finishedBundle).resolvingSymlinksInPath(), to: binary)
    var data = try Data(contentsOf: binary)
    let range = try #require(data.range(of: ElectronRuntime.fuseSentinel))
    let flipped = fuse == UInt8(ascii: "1") ? UInt8(ascii: "0") : UInt8(ascii: "1")
    data[range.upperBound + 2] = flipped
    try data.write(to: binary)
    #expect(ElectronRuntime.fuses(inFramework: binary)?.first == flipped)
}

@Test(.enabled(if: hasFinishedApp && ElectronRuntime.runsAsNode(finishedBundle), "npm run package in Examples/electron-orbit (with Node mode on)"), .timeLimit(.minutes(1)))
func aFinishedAppRunsSandboxedFromItsAsar() async throws {
    let app = try #require(ElectronDiscovery.finishedApp(bundle: finishedBundle))
    let sessionFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-electron-\(UUID().uuidString)")
    let port = try #require(ElectronHostSession.freePort())
    let session = ElectronHostSession(options: .init(
        app: app, hostScript: resources.appendingPathComponent("electron-host.js"), shimScript: resources.appendingPathComponent("electron-preload-shim.js"),
        sessionDirectory: sessionFolder, port: port, allowedPorts: [], dataSource: .copy, path: "/usr/bin:/bin"
    ))
    try session.start()
    defer { session.stop() }
    let windows = try await session.waitUntilReady()
    #expect(windows.first?.file?.hasSuffix("app.asar/renderer/index.html") == true)

    // Its windows' files come from the sandboxed copy, through the proxy, with the preload added.
    let proxy = CollabProxy(configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: port, overlayScript: Data(), electronHostPort: port))
    let proxyPort = try await proxy.start()
    defer { Task { await proxy.stop() } }
    let urlSession = URLSession(configuration: .ephemeral)
    let (page, _) = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/")!)
    let html = String(decoding: page, as: UTF8.self)
    #expect(html.contains("<title>Orbit</title>"))
    #expect(html.contains("/__opentraffic/electron/preload.js"))
    let (css, cssResponse) = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/style.css")!)
    #expect((cssResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: css, as: UTF8.self).contains("font"))

    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(proxyPort)/__opentraffic/electron/ipc?client=test&page=/")!)
    request.setValue("http://127.0.0.1:\(proxyPort)", forHTTPHeaderField: "Origin")
    let socket = urlSession.webSocketTask(with: request)
    socket.resume()
    defer { socket.cancel() }
    // Its data starts empty even when a copy was asked for: a finished app's holds real logins.
    let listed = try await call(socket, ["t": "invoke", "id": "1", "channel": "notes:list", "args": []], until: "1")
    #expect((listed["value"] as? [Any])?.isEmpty == true)
    let version = try await call(socket, ["t": "invoke", "id": "2", "channel": "notes:add", "args": ["packaged"]], until: "2")
    #expect(version["ok"] as? Bool == true)
    let home = try await call(socket, ["t": "invoke", "id": "3", "channel": "probe:read", "args": [ElectronSandbox.realHomeDirectory + "/.zshrc"]], until: "3")
    #expect(home["ok"] as? Bool == false)
}

@Test func localhostMeansTheServerFromTheAppsProject() {
    let sockets = [
        ListeningSocket(pid: 10, processName: "node", host: "127.0.0.1", port: 5173), // another app's server
        ListeningSocket(pid: 20, processName: "node", host: "[::1]", port: 5173),     // the app's Vite
    ]
    let folders: [Int32: URL] = [10: URL(fileURLWithPath: "/Users/me/other"), 20: URL(fileURLWithPath: "/Users/me/code/app")]
    #expect(ElectronDiscovery.pickLoopbackHost(sockets, projectRoot: URL(fileURLWithPath: "/Users/me/code/app"), directory: { folders[$0] }) == "::1")
    #expect(ElectronDiscovery.pickLoopbackHost(sockets, projectRoot: URL(fileURLWithPath: "/Users/me/elsewhere"), directory: { folders[$0] }) == "127.0.0.1")
    #expect(ElectronDiscovery.pickLoopbackHost([ListeningSocket(pid: 1, host: "*", port: 3000)], projectRoot: nil, directory: { _ in nil }) == "127.0.0.1")
    #expect(ElectronDiscovery.pickLoopbackHost([ListeningSocket(pid: 1, host: "[::1]", port: 3000)], projectRoot: nil, directory: { _ in nil }) == "::1")
}

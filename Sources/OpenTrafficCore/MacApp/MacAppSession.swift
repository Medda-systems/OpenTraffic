import AppKit
import CoreGraphics
import Darwin
import Foundation
import os
import Security

/// One shared Mac app: an isolated copy of the .app running hidden on the off-screen display,
/// mirrored to browsers by a MirrorServer on one loopback port that stays the same across restarts.
///
/// The copy is the user's .app cloned into the session folder with its own bundle identifier
/// (`<id>.opentraffic`) and signed again ad hoc, so its preferences, saved state, single-instance
/// checks and TCC identity are its own. It runs with `CFFIXED_USER_HOME` and `HOME` set to the
/// session's home folder, where its Application Support, caches and temporary files go; its
/// preferences go to its own defaults domain (cfprefsd ignores `CFFIXED_USER_HOME`). The user's real
/// app and data are only read, never written.
///
///     let session = MacAppSession(options: .init(app: app, data: .copy, assets: assets))
///     let port = try await session.start()      // http://127.0.0.1:<port>/
///     try await session.restart()               // same port, same data, a rebuilt app is copied again
///     try await session.resetData()             // same port, data as at the start
///     await session.stop()                      // quits it and deletes the session folder
///
/// When the app quits by itself, viewers see `crashed` and it is started again once (again after
/// it has run `stableRun` since). Start, restart, reset and stop run one after another, in call order.
@MainActor
public final class MacAppSession {
    public enum DataSource: String, Sendable, Codable {
        /// A copy of the app's own Application Support folder and preferences (instant on APFS).
        case copy
        /// Nothing: a first launch.
        case empty
    }

    public enum State: Sendable, Equatable {
        /// Made, not started yet.
        case idle
        case starting
        case running
        case restarting
        /// It quit by itself (the message says so). An automatic restart may follow.
        case crashed(String)
        /// Starting or restarting failed (the message says why). After a failed restart the server
        /// still answers, and `restart`/`resetData` may try again.
        case failed(String)
        case stopped
    }

    /// A permission the share needs and doesn't have.
    public enum Permission: String, Sendable, Equatable {
        case accessibility
        case screenRecording

        public var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .screenRecording: "Screen & System Audio Recording"
            }
        }

        /// The pane of System Settings where it is granted.
        public var settingsURL: URL {
            switch self {
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    public struct LogLine: Sendable, Equatable {
        public enum Source: String, Sendable, Codable {
            /// The app's standard output and error (with its os_log messages, as Xcode shows them).
            case app
            /// What the session did and what went wrong.
            case session
        }
        public var date: Date
        public var source: Source
        public var text: String

        public init(date: Date = Date(), source: Source, text: String) {
            self.date = date; self.source = source; self.text = text
        }
    }

    /// A viewer action as it arrived, for the agent's context and for replaying after a rebuild.
    public struct RecordedAction: Sendable, Equatable {
        public var date: Date
        public var viewer: Int
        /// The launch it was sent to (`MirrorServer.App.boot`; it changes with every launch).
        public var boot: String
        /// `act`, `pointer` (not moves), `text`, `key`, `setText` or `menuAction`.
        public var message: MirrorProtocol.ClientMessage
    }

    public enum Event: Sendable {
        case state(State)
        case viewers(Int)
        /// Something worth showing on the share's card: dropped entitlements, another OpenTraffic's
        /// virtual display, an action the app refused. Also in the log.
        case warning(String)
        /// Every message a viewer sent, as it arrived (viewport, menuAction and requestControl are
        /// only reported here; the rest are also applied by the server and recorded).
        case message(viewer: Int, MirrorProtocol.ClientMessage, at: Date)
    }

    public struct Options: Sendable {
        public var app: MacApp
        public var data: DataSource
        public var assets: MirrorServer.Assets
        /// The appearance viewers get in `hello`; nil means this Mac's.
        public var appearance: MirrorProtocol.Appearance?
        /// Where the copy, its home folder and its logs live; deleted by `stop`.
        public var sessionDirectory: URL
        /// How long the app may take to open its first window.
        public var windowTimeout: Duration
        /// Start the app again once when it quits by itself.
        public var restartsAutomatically: Bool
        /// The home folder the app's real data is read from for `.copy`.
        public var realHomeDirectory: String

        public init(app: MacApp, data: DataSource, assets: MirrorServer.Assets, appearance: MirrorProtocol.Appearance? = nil,
                    sessionDirectory: URL? = nil, windowTimeout: Duration = .seconds(20), restartsAutomatically: Bool = true,
                    realHomeDirectory: String = ElectronSandbox.realHomeDirectory) {
            self.app = app
            self.data = data
            self.assets = assets
            self.appearance = appearance
            self.sessionDirectory = sessionDirectory ?? MacAppSession.sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.windowTimeout = windowTimeout
            self.restartsAutomatically = restartsAutomatically
            self.realHomeDirectory = realHomeDirectory
        }
    }

    /// Where sessions live by default: OpenTraffic's Application Support folder.
    nonisolated public static var sessionsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTraffic/Mac App Sessions", isDirectory: true)
    }

    /// How many viewer actions `recentActions` keeps.
    nonisolated public static let actionLimit = 200
    /// How many log lines `recentLog` keeps.
    nonisolated public static let logLimit = 2000
    /// How long a quitting app gets before it is killed.
    nonisolated public static let stopGrace: Duration = .seconds(3)
    /// An app that ran this long after an automatic restart gets another one when it quits.
    nonisolated public static let stableRun: Duration = .seconds(60)

    public let options: Options
    /// The copy's bundle identifier: `<id>.opentraffic`.
    public let bundleIdentifier: String
    /// The app's log, line by line, as it comes (one consumer). `recentLog` keeps the last lines.
    public let log: AsyncStream<LogLine>
    /// State changes, viewer counts, warnings and viewer messages (one consumer).
    public let events: AsyncStream<Event>

    public private(set) var state: State = .idle
    /// The mirror server's port on 127.0.0.1, once started; it stays the same until `stop`.
    public private(set) var port: Int?
    /// The mirror server (for the share: `setAllowedOrigins`, `viewerCount`, `setStatus`).
    public private(set) var server: MirrorServer?
    /// The running copy's process, while it runs.
    public var pid: pid_t? { launch?.pid }

    public var name: String { options.app.name }
    public var url: URL? { port.map { URL(string: "http://127.0.0.1:\($0)/")! } }
    public var viewerCount: Int { server?.viewerCount ?? 0 }
    public var sessionDirectory: URL { options.sessionDirectory }
    /// The isolated copy of the .app that runs.
    public var appCopy: URL { options.sessionDirectory.appendingPathComponent("app", isDirectory: true).appendingPathComponent(options.app.bundle.lastPathComponent) }
    /// The app's home folder (`CFFIXED_USER_HOME`).
    public var homeDirectory: URL { options.sessionDirectory.appendingPathComponent("home", isDirectory: true) }
    /// The running copy's windows (on the off-screen display).
    public var windows: [HiddenWindow] { launch.map { hider.windows(pid: $0.pid) } ?? [] }
    /// The last `actionLimit` viewer actions, oldest first.
    nonisolated public var recentActions: [RecordedAction] { actions.items }
    /// The last `logLimit` log lines, oldest first.
    nonisolated public var recentLog: [LogLine] { logLines.items }

    private let hider: MacAppWindowHider
    private let logSink: AsyncStream<LogLine>.Continuation
    private let eventSink: AsyncStream<Event>.Continuation
    private let actions = Ring<RecordedAction>(limit: MacAppSession.actionLimit)
    private let logLines = Ring<LogLine>(limit: MacAppSession.logLimit)

    /// One launch of the copy.
    private struct Launch {
        var pid: pid_t
        var generation: Int
        var boot: String
        var started: ContinuousClock.Instant
        var automatic: Bool
        var tail: LogTail
        var exit: DispatchSourceProcess
    }
    private var launch: Launch?
    /// Bumped by every launch and every intended quit: an exit of an older generation is expected.
    private var generation = 0
    private var bundleStamp: BundleStamp?
    private var dataPrepared = false
    /// Whether the sandbox of the original app means its data lives in its container.
    private var originalIsSandboxed = false
    private var lastAutomaticRestart: ContinuousClock.Instant?
    private var serverEvents: Task<Void, Never>?
    private var queueTail: Task<Void, Never>?

    public init(options: Options, hider: MacAppWindowHider = MacAppWindowHider()) {
        self.options = options
        self.hider = hider
        bundleIdentifier = Self.copyIdentifier(for: options.app)
        (log, logSink) = AsyncStream.makeStream(of: LogLine.self, bufferingPolicy: .bufferingNewest(Self.logLimit))
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Makes a session and starts it.
    public static func start(_ options: Options) async throws -> MacAppSession {
        let session = MacAppSession(options: options)
        try await session.start()
        return session
    }

    // MARK: Lifecycle

    /// Copies the app, prepares its data, launches it hidden, waits for its first window and serves
    /// it. Returns the mirror server's port. On failure everything is cleaned up (the session folder
    /// too) and `MacAppSessionError` says why; the session is then `failed` and can't be started again.
    @discardableResult
    public func start() async throws -> Int {
        try await serially { try await self.startNow() }
    }

    /// Quits the app and starts it again on the same port with the same data. A rebuilt .app is
    /// copied again first. Viewers stay connected and get a new `hello`.
    public func restart() async throws {
        try await serially { try await self.relaunch(resetting: false, automatic: false) }
    }

    /// Quits the app, puts its data back as it was at the start (a new copy, or empty), and starts
    /// it again on the same port.
    public func resetData() async throws {
        try await serially { try await self.relaunch(resetting: true, automatic: false) }
    }

    /// Stops serving, quits the app (killing it after `stopGrace`), removes its preferences and
    /// deletes the session folder.
    public func stop() async {
        try? await serially { await self.stopNow() }
    }

    /// Runs lifecycle work one call at a time, in call order.
    private func serially<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        queueTail = Task { @MainActor in _ = await task.result }
        return try await task.value
    }

    private func startNow() async throws -> Int {
        switch state {
        case .idle: break
        case .stopped, .failed: throw MacAppSessionError.stopped
        default: if let port { return port } else { throw MacAppSessionError.stopped }
        }
        setState(.starting)
        do {
            try Self.checkPermissions()
            await warnAboutOtherDisplays()
            try FileManager.default.createDirectory(at: options.sessionDirectory, withIntermediateDirectories: true)
            try writeManifest()
            try await prepareBundle()
            try await prepareData()
            let mirrored = try await launchApp(automatic: false)
            let server = MirrorServer(configuration: .init(app: mirrored, assets: options.assets,
                                                           appearance: options.appearance ?? MirrorServer.hostAppearance()))
            self.server = server
            watch(server)
            let port = try await server.start()
            self.port = port
            note("Serving \(name) on 127.0.0.1:\(port).")
            setState(.running)
            return port
        } catch {
            let failure = Self.failure(error, name: name)
            note("Couldn't start \(name): \(failure.localizedDescription)")
            await tearDown()
            setState(.failed(failure.localizedDescription))
            finishStreams()
            throw failure
        }
    }

    private func relaunch(resetting: Bool, automatic: Bool) async throws {
        guard let server else { throw MacAppSessionError.stopped }
        switch state {
        case .running, .crashed, .failed: break
        default: throw MacAppSessionError.stopped
        }
        setState(.restarting)
        server.setStatus(.init(state: .restarting, message: resetting ? "\(name) is starting again with fresh data." : "\(name) is restarting."))
        note(resetting ? "Resetting \(name)'s data and starting it again." : automatic ? "Starting \(name) again after it quit." : "Restarting \(name).")
        await quitApp()
        do {
            if resetting {
                try clearHome()
                dataPrepared = false
            }
            try await prepareBundle()
            try await prepareData()
            let mirrored = try await launchApp(automatic: automatic)
            try await server.replace(app: mirrored)
            if !automatic { lastAutomaticRestart = nil }
            setState(.running)
        } catch {
            let failure = Self.failure(error, name: name)
            note("Couldn't start \(name) again: \(failure.localizedDescription)")
            await quitApp()
            server.setStatus(.init(state: .crashed, message: failure.localizedDescription))
            setState(.failed(failure.localizedDescription))
            throw failure
        }
    }

    private func stopNow() async {
        guard state != .stopped else { return }
        note("Stopping \(name).")
        await tearDown()
        setState(.stopped)
        finishStreams()
    }

    /// Stops the server, quits the app, removes its preferences and the session folder.
    private func tearDown() async {
        serverEvents?.cancel()
        serverEvents = nil
        if let server {
            server.setStatus(.init(state: .stopped))
            await server.stop()
        }
        await quitApp()
        Self.removePreferences(bundleIdentifier, realHome: options.realHomeDirectory, followUp: true)
        try? FileManager.default.removeItem(at: options.sessionDirectory)
    }

    private func finishStreams() {
        logSink.finish()
        eventSink.finish()
    }

    // MARK: Launching and quitting

    /// Launches the copy hidden with its log going to a file of this launch, and returns the
    /// bridges for the mirror server.
    private func launchApp(automatic: Bool) async throws -> MirrorServer.App {
        generation += 1
        let generation = generation
        let logs = options.sessionDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logFile = logs.appendingPathComponent("launch-\(generation).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let tail = try LogTail(url: logFile) { [logSink, logLines] text in
            let line = LogLine(source: .app, text: text)
            logLines.append(line)
            logSink.yield(line)
        }
        let environment = [
            "CFFIXED_USER_HOME": homeDirectory.path,
            "HOME": homeDirectory.path,
            "TMPDIR": options.sessionDirectory.appendingPathComponent("tmp").path + "/",
            // os_log and Logger messages on standard error too, as Xcode's console shows them.
            "OS_ACTIVITY_DT_MODE": "1",
        ]
        let running: NSRunningApplication
        do {
            running = try await hider.launch(bundle: appCopy, environment: environment,
                                             arguments: ["-ApplePersistenceIgnoreState", "YES"],
                                             windowTimeout: options.windowTimeout, output: logFile)
        } catch {
            tail.finish()
            throw error
        }
        let pid = running.processIdentifier
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.exited(pid: pid, generation: generation) }
        }
        exit.resume()
        let boot = UUID().uuidString
        launch = Launch(pid: pid, generation: generation, boot: boot, started: .now, automatic: automatic, tail: tail, exit: exit)
        guard Self.isAlive(pid) else {
            throw MacAppSessionError.failed("\(name) quit while starting.\(lastAppLines())")
        }
        guard !hider.windows(pid: pid).isEmpty else {
            throw MacAppSessionError.failed("\(name) didn't open a window within \(options.windowTimeout.components.seconds) seconds.\(lastAppLines())")
        }
        note("Launched \(name) (pid \(pid)).")
        return try MirrorServer.App.live(pid: pid, name: name, boot: boot)
    }

    /// The app's last few log lines, for an error message.
    private func lastAppLines(_ count: Int = 5) -> String {
        let lines = recentLog.filter { $0.source == .app }.suffix(count).map(\.text)
        return lines.isEmpty ? "" : " Its last output:\n" + lines.joined(separator: "\n")
    }

    /// Quits the running copy: asks it to quit, kills it after `stopGrace`, stops hiding it.
    private func quitApp() async {
        guard let launch else { return }
        self.launch = nil
        generation += 1
        launch.exit.cancel()
        let pid = launch.pid
        if Self.isAlive(pid) {
            NSRunningApplication(processIdentifier: pid)?.terminate()
            let deadline = ContinuousClock.now + Self.stopGrace
            while Self.isAlive(pid), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if Self.isAlive(pid) {
                note("\(name) didn't quit within \(Self.stopGrace.components.seconds) seconds; killing it.")
                kill(pid, SIGKILL)
                for _ in 0..<40 where Self.isAlive(pid) { try? await Task.sleep(for: .milliseconds(25)) }
            }
        }
        await hider.release(pid: pid, terminate: false)
        launch.tail.finish()
    }

    /// The copy's process went away. When nobody asked it to, viewers learn it crashed and it is
    /// started again once.
    private func exited(pid: pid_t, generation: Int) {
        guard generation == self.generation, let launch, launch.pid == pid else { return }
        let ran = ContinuousClock.now - launch.started
        let message = "\(name) quit unexpectedly."
        note(message + lastAppLines())
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.serially {
                // A restart or stop may have come first.
                guard generation == self.generation, self.launch?.pid == pid else { return }
                await self.quitApp()
                self.server?.setStatus(.init(state: .crashed, message: message))
                self.setState(.crashed(message))
                let again = self.options.restartsAutomatically
                    && (self.lastAutomaticRestart == nil || (launch.automatic && ran >= Self.stableRun))
                guard again else {
                    self.note("Not starting \(self.name) again by itself: it already quit after an automatic restart.")
                    return
                }
                self.lastAutomaticRestart = .now
                try? await self.relaunch(resetting: false, automatic: true)
            }
        }
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Server events

    private func watch(_ server: MirrorServer) {
        serverEvents = Task { @MainActor [weak self, events = server.events] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .viewerConnected(_, let viewers), .viewerDisconnected(_, let viewers):
                    self.eventSink.yield(.viewers(viewers))
                case .message(let viewer, let message, let date):
                    if Self.isRecorded(message) {
                        self.actions.append(RecordedAction(date: date, viewer: viewer, boot: self.launch?.boot ?? "", message: message))
                    }
                    self.eventSink.yield(.message(viewer: viewer, message, at: date))
                case .failed(let reason):
                    self.warn(reason)
                }
            }
        }
    }

    /// The viewer actions `recentActions` keeps: everything that changes the app (menu commands
    /// too). Pointer moves would push the rest out of the buffer within seconds and change nothing
    /// a replay needs; the window size and control requests aren't actions on the app.
    nonisolated static func isRecorded(_ message: MirrorProtocol.ClientMessage) -> Bool {
        switch message {
        case .act, .text, .key, .setText, .menuAction: true
        case .pointer(let pointer): pointer.kind != .move
        case .viewport, .requestControl: false
        }
    }

    // MARK: State and log

    private func setState(_ state: State) {
        self.state = state
        eventSink.yield(.state(state))
    }

    private func note(_ text: String) {
        let line = LogLine(source: .session, text: text)
        logLines.append(line)
        logSink.yield(line)
    }

    private func warn(_ text: String) {
        note(text)
        eventSink.yield(.warning(text))
    }

    // MARK: Preparing the copy

    /// Copies the .app (again when it was rebuilt since the last copy).
    private func prepareBundle() async throws {
        let source = options.app.bundle
        let stamp = BundleStamp(source)
        if stamp == bundleStamp, FileManager.default.fileExists(atPath: appCopy.path) { return }
        note(bundleStamp == nil ? "Copying \(name) to its session folder." : "\(name) was rebuilt; copying it again.")
        let target = appCopy
        let identifier = bundleIdentifier
        let prepared = try await Task.detached { try Self.makeIsolatedCopy(of: source, at: target, bundleIdentifier: identifier) }.value
        originalIsSandboxed = prepared.wasSandboxed
        for warning in prepared.warnings { warn(warning) }
        bundleStamp = stamp
    }

    /// Fills the home folder once (and again after a reset).
    private func prepareData() async throws {
        guard !dataPrepared else { return }
        let app = options.app
        let home = homeDirectory
        let tmp = options.sessionDirectory.appendingPathComponent("tmp", isDirectory: true)
        let source = options.data
        let identifier = bundleIdentifier
        let realHome = options.realHomeDirectory
        let sandboxed = originalIsSandboxed
        let warnings = try await Task.detached {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return try Self.prepareHome(home, data: source, app: app, copyIdentifier: identifier, realHome: realHome, sandboxed: sandboxed)
        }.value
        for warning in warnings { warn(warning) }
        dataPrepared = true
    }

    private func clearHome() throws {
        try? FileManager.default.removeItem(at: homeDirectory)
        try? FileManager.default.removeItem(at: options.sessionDirectory.appendingPathComponent("tmp", isDirectory: true))
        Self.removePreferences(bundleIdentifier, realHome: options.realHomeDirectory)
    }

    /// What `removeLeftovers` needs to clean up after a session OpenTraffic didn't stop.
    private struct Manifest: Codable {
        var bundleIdentifier: String
        var app: String
    }

    private func writeManifest() throws {
        let data = try JSONEncoder().encode(Manifest(bundleIdentifier: bundleIdentifier, app: options.app.bundle.path))
        try data.write(to: options.sessionDirectory.appendingPathComponent("session.json"))
    }

    /// Quits copies still running from sessions OpenTraffic didn't stop (it crashed or was killed;
    /// their windows are then on the user's screen) and deletes those sessions' folders and
    /// preferences. Call once at launch, before any session starts.
    public static func removeLeftovers(in directory: URL = MacAppSession.sessionsDirectory,
                                       realHome: String = ElectronSandbox.realHomeDirectory) async {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let prefix = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            for app in NSWorkspace.shared.runningApplications {
                guard let bundle = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path, bundle.hasPrefix(prefix) else { continue }
                app.terminate()
                for _ in 0..<60 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
                if !app.isTerminated { app.forceTerminate() }
            }
            if let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
               let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                removePreferences(manifest.bundleIdentifier, realHome: realHome, followUp: true)
            }
            try? fm.removeItem(at: folder)
        }
    }

    // MARK: Permissions and failures

    nonisolated static func checkPermissions() throws {
        guard AccessibilityTree.isTrusted else { throw MacAppSessionError.permission(.accessibility) }
        guard WindowCapture.isPermitted else { throw MacAppSessionError.permission(.screenRecording) }
    }

    /// Any error of the bridges, as one the share's card can show.
    nonisolated static func failure(_ error: any Error, name: String) -> MacAppSessionError {
        switch error {
        case let error as MacAppSessionError:
            return error
        case MacAppWindowHider.Failure.notTrusted, AccessibilityTreeError.notTrusted:
            return .permission(.accessibility)
        case WindowCaptureError.notPermitted:
            return .permission(.screenRecording)
        case MacAppWindowHider.Failure.launchFailed(let message):
            return .failed("macOS couldn't open \(name): \(message)")
        case MacAppWindowHider.Failure.observerFailed(_, let code):
            return .failed("Couldn't watch \(name)'s windows (accessibility error \(code)).")
        case OffscreenDisplay.Failure.unavailable(let reason):
            return .failed("Couldn't make the off-screen display \(name) runs on: \(reason)")
        case OffscreenDisplay.Failure.timedOut(let call), OffscreenDisplay.Failure.windowServerNotResponding(let call):
            return .failed("The window server isn't answering (\(call)). Try again in a moment; if it keeps happening, restart the Mac.")
        case MirrorServerError.noWindow:
            return .failed("\(name) has no window to show.")
        case MirrorServerError.captureFailed(let reason):
            if !WindowCapture.isPermitted { return .permission(.screenRecording) }
            return .failed("Couldn't capture \(name)'s window: \(reason)")
        case let error as AccessibilityTreeError:
            return .failed("Couldn't read \(name) through Accessibility (\(error)).")
        case let error as LocalizedError:
            return .failed(error.localizedDescription)
        default:
            return .failed(String(describing: error))
        }
    }

    /// Another process's OpenTraffic virtual display (a test run, a second OpenTraffic) slows
    /// ScreenCaptureKit down badly; say so.
    private func warnAboutOtherDisplays() async {
        let own = OffscreenDisplay.liveDisplayIDs
        let others = (try? await OffscreenDisplay.calls.run("listing displays", timeout: OffscreenDisplay.callTimeout) { () -> Int in
            var ids = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return 0 }
            return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) == OffscreenDisplay.vendorID && !own.contains($0) }.count
        }) ?? 0
        if others > 0 {
            warn("Another OpenTraffic (or a test run) has its own off-screen display too; capturing \(name) may be slow until it quits.")
        }
    }
}

/// Why a Mac app share couldn't start or restart, said for the share's card.
public enum MacAppSessionError: Error, LocalizedError, Equatable, Sendable {
    /// A permission is missing: the card offers to open `permission.settingsURL`.
    case permission(MacAppSession.Permission)
    case failed(String)
    /// The session was stopped (or failed to start) and can't do this any more.
    case stopped

    public var errorDescription: String? {
        switch self {
        case .permission(let permission):
            "OpenTraffic needs \(permission.title) permission to share Mac apps. Turn it on in System Settings > Privacy & Security > \(permission.title), then try again."
        case .failed(let message):
            message
        case .stopped:
            "This share has stopped."
        }
    }
}

// MARK: - The isolated copy

extension MacAppSession {
    /// The copy's bundle identifier.
    nonisolated static func copyIdentifier(for app: MacApp) -> String {
        if let identifier = app.bundleIdentifier, !identifier.isEmpty { return identifier + ".opentraffic" }
        let name = app.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "se.medda.opentraffic.shared." + String(name)
    }

    struct PreparedCopy: Sendable {
        var warnings: [String]
        var wasSandboxed: Bool
    }

    /// Clones `source` to `target` (APFS clonefile: instant, no extra space), gives it
    /// `bundleIdentifier`, and signs it again ad hoc with the original's entitlements minus those
    /// that need the developer's team (and the App Sandbox, so the copy's data stays in its
    /// session's home folder).
    nonisolated static func makeIsolatedCopy(of source: URL, at target: URL, bundleIdentifier: String) throws -> PreparedCopy {
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: source, to: target)
        } catch {
            throw MacAppSessionError.failed("Couldn't copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
        // A provisioning profile names the original identifier and team; the copy has neither.
        try? fm.removeItem(at: target.appendingPathComponent("Contents/embedded.provisionprofile"))

        let infoURL = target.appendingPathComponent("Contents/Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: infoURL),
              var info = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? [String: Any]
        else { throw MacAppSessionError.failed("\(source.lastPathComponent) has no readable Info.plist.") }
        info["CFBundleIdentifier"] = bundleIdentifier
        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: infoURL)

        let original = entitlements(of: source)
        let (kept, dropped) = sharedEntitlements(original)
        var warnings: [String] = []
        let restricted = dropped.filter { $0 != sandboxEntitlement }
        if !restricted.isEmpty {
            warnings.append("The shared copy runs without \(restricted.sorted().joined(separator: ", ")): they need your team's signature. Features that use them may not work.")
        }
        let sandboxed = (original[sandboxEntitlement] as? Bool) == true

        // Nested code first (frameworks, helpers keep their entitlements), then the app itself.
        try codesign(["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", target.path])
        if kept.isEmpty {
            try codesign(["--force", "--sign", "-", target.path])
        } else {
            let file = target.deletingLastPathComponent().appendingPathComponent("entitlements.plist")
            try PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0).write(to: file)
            try codesign(["--force", "--sign", "-", "--entitlements", file.path, target.path])
        }
        return PreparedCopy(warnings: warnings, wasSandboxed: sandboxed)
    }

    nonisolated static let sandboxEntitlement = "com.apple.security.app-sandbox"

    /// The entitlements an ad hoc signed copy keeps, and the ones it drops: those only a team's
    /// signature (and provisioning profile) may carry, and the App Sandbox, whose container would
    /// put the copy's data in the user's Library instead of the session's home folder.
    nonisolated static func sharedEntitlements(_ entitlements: [String: Any]) -> (kept: [String: Any], dropped: [String]) {
        var kept: [String: Any] = [:]
        var dropped: [String] = []
        for (key, value) in entitlements {
            let needsTeam = key.hasPrefix("com.apple.developer.") || key == "keychain-access-groups"
                || key == "com.apple.security.application-groups" || key == "com.apple.application-identifier"
                || key == "application-identifier" || key == "com.apple.team-identifier"
            if needsTeam || key == sandboxEntitlement { dropped.append(key) } else { kept[key] = value }
        }
        return (kept, dropped.sorted())
    }

    /// The entitlements `bundle` is signed with (empty when unsigned or unreadable).
    nonisolated static func entitlements(of bundle: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return [:] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return [:] }
        return info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }

    nonisolated private static func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timer)
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacAppSessionError.failed("Couldn't sign the shared copy: \(message.isEmpty ? "codesign failed" : message)")
        }
    }

    // MARK: The home folder and preferences

    /// Makes the copy's home folder. For `.copy` it clones the app's Application Support folders
    /// (named after the app and after its bundle identifier) and copies its preferences into the
    /// copy's own defaults domain; for `.empty` it starts bare. Anything that can't be copied is
    /// skipped with a warning. Leftover preferences of the copy's domain are always removed first.
    nonisolated static func prepareHome(_ home: URL, data: DataSource, app: MacApp, copyIdentifier: String,
                                        realHome: String, sandboxed: Bool) throws -> [String] {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        for folder in [support, library.appendingPathComponent("Preferences"), library.appendingPathComponent("Caches")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        removePreferences(copyIdentifier, realHome: realHome)
        guard data == .copy else { return [] }

        var warnings: [String] = []
        // A sandboxed app keeps its data in its container.
        var realLibrary = URL(fileURLWithPath: realHome, isDirectory: true).appendingPathComponent("Library", isDirectory: true)
        if sandboxed, let identifier = app.bundleIdentifier {
            realLibrary = realLibrary.appendingPathComponent("Containers/\(identifier)/Data/Library", isDirectory: true)
        }
        let names = Array(Set([app.name, app.bundleIdentifier].compactMap { $0 }.filter { !$0.isEmpty && !$0.contains("/") })).sorted()
        for name in names {
            let source = realLibrary.appendingPathComponent("Application Support", isDirectory: true).appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = support.appendingPathComponent(name)
            do {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
            } catch {
                warnings.append("Couldn't copy \(app.name)'s data (\(source.path)): \(error.localizedDescription). It starts without it.")
            }
        }
        if let identifier = app.bundleIdentifier {
            var values: [String: Any] = [:]
            if sandboxed {
                let file = realLibrary.appendingPathComponent("Preferences/\(identifier).plist")
                if let data = try? Data(contentsOf: file),
                   let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    values = dictionary
                }
            } else if let keys = CFPreferencesCopyKeyList(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String], !keys.isEmpty {
                values = CFPreferencesCopyMultiple(keys as CFArray, identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
            }
            if !values.isEmpty {
                CFPreferencesSetMultiple(values as CFDictionary, nil, copyIdentifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                if !CFPreferencesAppSynchronize(copyIdentifier as CFString) {
                    warnings.append("Couldn't copy \(app.name)'s preferences. It starts without them.")
                }
            }
        }
        return warnings
    }

    /// Removes every preference of the copy's defaults domain and its file.
    ///
    /// cfprefsd writes an emptied domain back to its file a few seconds later (7.5 s measured), even
    /// after the file was deleted; with `followUp` the file is deleted again 10 and 30 seconds later
    /// unless the domain holds preferences again by then (a new session of the same app). If
    /// OpenTraffic quits before that, an empty `<id>.opentraffic.plist` stays (no data in it; the next
    /// session of the app reuses it).
    nonisolated static func removePreferences(_ identifier: String, realHome: String, followUp: Bool = false) {
        // Only ever the copy's own domain.
        guard identifier.hasSuffix(".opentraffic") || identifier.hasPrefix("se.medda.opentraffic.shared.") else { return }
        func isEmpty() -> Bool {
            (CFPreferencesCopyKeyList(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []).isEmpty
        }
        if !isEmpty(), let keys = CFPreferencesCopyKeyList(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            CFPreferencesSetMultiple(nil, keys as CFArray, identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesAppSynchronize(identifier as CFString)
        }
        let library = URL(fileURLWithPath: realHome, isDirectory: true).appendingPathComponent("Library", isDirectory: true)
        let file = library.appendingPathComponent("Preferences/\(identifier).plist")
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Saved Application State/\(identifier).savedState"))
        guard followUp else { return }
        for delay in [10.0, 30.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                if isEmpty() { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
}

/// What identifies a build of an .app: its executable's and Info.plist's sizes and dates.
struct BundleStamp: Equatable, Sendable {
    var executable: String
    var parts: [Double]

    init?(_ bundle: URL) {
        let fm = FileManager.default
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        let name = (NSDictionary(contentsOf: info)?["CFBundleExecutable"] as? String) ?? bundle.deletingPathExtension().lastPathComponent
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(name)")
        func numbers(_ url: URL) -> [Double] {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return [0, 0] }
            return [(attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, Double((attributes[.size] as? NSNumber)?.int64Value ?? 0)]
        }
        guard fm.fileExists(atPath: executable.path) else { return nil }
        self.executable = executable.path
        parts = numbers(executable) + numbers(info)
    }
}

/// The last `limit` items, oldest first. Thread-safe.
final class Ring<Element: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<[Element]>
    let limit: Int

    init(limit: Int) {
        self.limit = limit
        state = OSAllocatedUnfairLock(initialState: [])
    }

    func append(_ element: Element) {
        state.withLock { items in
            items.append(element)
            if items.count > limit { items.removeFirst(items.count - limit) }
        }
    }

    var items: [Element] { state.withLock { $0 } }
}

/// Follows a file another process appends to (the app's standard output and error) and hands on
/// each complete line. Thread-safe.
final class LogTail: @unchecked Sendable {
    private let queue = DispatchQueue(label: "se.medda.opentraffic.macapp-log")
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private let reader: LineReader
    private var finished = false

    init(url: URL, line: @escaping @Sendable (String) -> Void) throws {
        descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MacAppSessionError.failed("Couldn't open the log \(url.path).") }
        reader = LineReader { text in if !text.isEmpty { line(text) } }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.extend, .write], queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    private func drain() {
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            reader.feed(Data(buffer[0..<count]))
        }
    }

    /// Reads what is left and stops following.
    func finish() {
        queue.sync {
            guard !finished else { return }
            drain()
            // The last line, if it didn't end with a newline.
            reader.feed(Data([0x0A]))
            finished = true
            source.cancel()
        }
    }

    deinit { source.cancel() }
}

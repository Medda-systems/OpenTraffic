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
///
/// An iPhone app in the Simulator (`app.simulator`) runs the same way, with the differences
/// SimulatorSession describes: no copy of the app (simctl starts it in your device, or in OpenTraffic's
/// own erased one for `.empty`), and the Simulator's window for its device is what viewers see.
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
    public enum Permission: String, Sendable, Equatable, CaseIterable {
        case accessibility
        case screenRecording

        public var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .screenRecording: "Screen & System Audio Recording"
            }
        }

        /// The list in System Settings > Privacy & Security where it is switched on, as this Mac names
        /// it: macOS 27 calls the Accessibility list "Device Control and Data Access".
        public var settingsListName: String {
            switch self {
            case .accessibility:
                ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
                    ? "Device Control and Data Access" : "Accessibility"
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
        /// Its window and element when it arrived, to find them again in a later launch.
        public var target: MacAppReplay.Target?
    }

    /// How far a replay after a rebuild got.
    public struct ReplayReport: Sendable, Equatable {
        /// Actions sent again.
        public var replayed: Int
        /// Actions there were to replay.
        public var total: Int
        /// The action it stopped at, because its window or element isn't in the new build.
        public var stoppedAt: String?
    }

    /// Building the app from its sources (`watchSources`).
    public enum BuildState: Sendable, Equatable {
        /// No build running; the last one (if any) succeeded.
        case idle
        case building
        /// The last build failed; the copy runs the previous build.
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        case viewers(Int)
        /// Something worth showing on the share's card: dropped entitlements, another OpenTraffic's
        /// virtual display, an action the app refused. Also in the log.
        case warning(String)
        /// Every message the server took from a viewer, as it arrived: input it applies (and the session
        /// records), and viewport and control requests. Input from viewers without control isn't here.
        case message(viewer: Int, MirrorProtocol.ClientMessage, at: Date)
        /// Who may control the app now: the mode, who has control, who asks for it.
        case control(MirrorServer.ControlState)
        /// The appearance the running copy shows (it changes with a relaunch).
        case appearance(MirrorProtocol.Appearance)
        /// A build of the app from its sources started, failed or ended (`watchSources`).
        case build(BuildState)
    }

    public struct Options: Sendable {
        public var app: MacApp
        public var data: DataSource
        public var assets: MirrorServer.Assets
        /// The host's choices: who may control the app, its appearance and its window size
        /// (`setViewerOptions` changes them while it runs).
        public var viewerOptions: MacAppViewerOptions
        /// Where the copy, its home folder and its logs live; deleted by `stop`.
        public var sessionDirectory: URL
        /// How long the app may take to open its first window.
        public var windowTimeout: Duration
        /// Start the app again once when it quits by itself.
        public var restartsAutomatically: Bool
        /// The home folder the app's real data is read from for `.copy`.
        public var realHomeDirectory: String
        /// How long a build from the sources may take (`watchSources`).
        public var buildTimeout: Duration = MacAppBuild.defaultTimeout

        public init(app: MacApp, data: DataSource, assets: MirrorServer.Assets, viewerOptions: MacAppViewerOptions = .init(),
                    sessionDirectory: URL? = nil, windowTimeout: Duration = .seconds(20), restartsAutomatically: Bool = true,
                    realHomeDirectory: String = ElectronSandbox.realHomeDirectory) {
            self.app = app
            self.data = data
            self.assets = assets
            self.viewerOptions = viewerOptions
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
    /// Replaying after a rebuild: the gap between actions...
    nonisolated public static let replayGap: Duration = .milliseconds(150)
    /// ...how long an action's window or element may take to appear (a sheet opening) before the
    /// replay stops there...
    nonisolated public static let replayElementWait: Duration = .seconds(2)
    /// ...and how long the new launch's first tree may take.
    nonisolated public static let replayTreeWait: Duration = .seconds(10)

    public let options: Options
    /// The host's choices in force (`options.viewerOptions` at first).
    public private(set) var viewerOptions: MacAppViewerOptions
    /// The appearance the copy runs with now.
    public private(set) var appearance: MirrorProtocol.Appearance = MirrorServer.hostAppearance()
    /// The first viewer's color scheme, once one said; the app keeps it for the session.
    public private(set) var viewerAppearance: MirrorProtocol.Appearance?
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
    /// Every window viewers see now, as the mirror sends them (main first; second windows, sheets,
    /// alerts, popovers and an open menu with their kind, parent and position).
    public func mirroredWindows() async -> [MirrorProtocol.WindowInfo] { await server?.currentWindows() ?? [] }
    /// The last `actionLimit` viewer actions, oldest first.
    nonisolated public var recentActions: [RecordedAction] { actions.items }
    /// The last `logLimit` log lines, oldest first.
    nonisolated public var recentLog: [LogLine] { logLines.items }
    /// How the app is built from its sources, once `watchSources` was called.
    public private(set) var buildPlan: MacAppBuild.Plan?
    public private(set) var buildState: BuildState = .idle
    /// The full output of the latest build from the sources (Show Log on the card), once one ran.
    public private(set) var buildLog: URL?
    /// How the last replay after a rebuild went.
    public private(set) var lastReplay: ReplayReport?

    private let hider: MacAppWindowHider
    /// The simulator side, for an iPhone app.
    private let simulator: SimulatorSession?
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
    /// Whether the card was told that dark needs this Mac in Dark.
    private var warnedAboutDark = false
    private var queueTail: Task<Void, Never>?
    /// The actions that brought the running launch to where viewers are: the ones replayed into it,
    /// then what viewers did in it. Replayed after a rebuild; cleared by every other relaunch.
    private var replayPath: [RecordedAction] = []
    private var sourceWatcher: MacAppSourceWatcher?
    private var builds: Task<Void, Never>?
    /// Sources changed again while a build ran: build once more after it.
    private var buildAgain = false
    /// The latest finished build failed (it stays so while the next one runs).
    private var lastBuildFailed = false
    private var buildCount = 0

    public init(options: Options, hider: MacAppWindowHider = MacAppWindowHider(), simulator environment: SimulatorEnvironment = .live()) {
        self.options = options
        self.viewerOptions = options.viewerOptions
        self.hider = hider
        simulator = options.app.simulator == nil ? nil : SimulatorSession(app: options.app, data: options.data, environment: environment, hider: hider)
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
        try await restart(replaying: false)
    }

    /// `restart()`; with `replaying`, the viewer actions that led to the current screen are then sent
    /// to the new launch (each element found again by its key, 150 ms apart, stopping at the first
    /// one that is gone) while viewers see `restarting`, so they end up where they were.
    public func restart(replaying: Bool) async throws {
        try await serially { try await self.relaunch(resetting: false, automatic: false, replaying: replaying) }
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
            if simulator == nil {
                try Self.checkPermissions()
                await warnAboutOtherDisplays()
            }
            try FileManager.default.createDirectory(at: options.sessionDirectory, withIntermediateDirectories: true)
            try writeManifest()
            if simulator == nil {
                try await prepareBundle()
                try await prepareData()
            }
            let mirrored = try await launchApp(automatic: false)
            // The Simulator's window is never resized, so it is never placed anywhere.
            let isOnScreen: @Sendable (CGRect) -> Bool
            if simulator == nil {
                isOnScreen = { OffscreenDisplay.isVisible($0) }
            } else {
                isOnScreen = { _ in false }
            }
            let server = MirrorServer(configuration: .init(app: mirrored, assets: options.assets, appearance: appearance,
                                                           options: viewerOptions, isOnScreen: isOnScreen))
            self.server = server
            watch(server)
            let port = try await server.start()
            self.port = port
            note("Serving \(name) on 127.0.0.1:\(port).")
            setState(.running)
            // A viewer may have said its color scheme while the start finished.
            followAppearance()
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

    private func relaunch(resetting: Bool, automatic: Bool, because reason: String? = nil, replaying: Bool = false) async throws {
        guard let server else { throw MacAppSessionError.stopped }
        switch state {
        case .running, .crashed, .failed: break
        default: throw MacAppSessionError.stopped
        }
        setState(.restarting)
        server.setStatus(.init(state: .restarting, message: reason ?? (resetting ? "\(name) is starting again with fresh data." : "\(name) is restarting.")))
        note(reason ?? (resetting ? "Resetting \(name)'s data and starting it again." : automatic ? "Starting \(name) again after it quit." : "Restarting \(name)."))
        let path = replaying ? replayPath : []
        replayPath = []
        await quitApp()
        do {
            if let simulator {
                if resetting, simulator.usesRealData {
                    note("\(name) runs on your simulator's own data, which OpenTraffic can't put back; starting it again as it is.")
                }
            } else {
                if resetting {
                    try clearHome()
                    dataPrepared = false
                }
                try await prepareBundle()
                try await prepareData()
            }
            let mirrored = try await launchApp(automatic: automatic, fresh: resetting)
            server.setAppearance(appearance)
            try await server.replace(app: mirrored)
            if !automatic { lastAutomaticRestart = nil }
            if replaying {
                // A new launch shows its first screen: viewers keep seeing `restarting` until they're back.
                server.setStatus(.init(state: .restarting, message: "Putting \(name) back where you were."))
                let report = await replay(path, on: server)
                lastReplay = report
                server.setStatus(.init(state: .running))
            }
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
        sourceWatcher?.stop()
        sourceWatcher = nil
        builds?.cancel()
        builds = nil
        serverEvents?.cancel()
        serverEvents = nil
        if let server {
            server.setStatus(.init(state: .stopped))
            await server.stop()
        }
        await quitApp()
        if let simulator {
            await simulator.stop()
        } else {
            Self.removePreferences(bundleIdentifier, realHome: options.realHomeDirectory, followUp: true)
        }
        try? FileManager.default.removeItem(at: options.sessionDirectory)
    }

    private func finishStreams() {
        logSink.finish()
        eventSink.finish()
    }

    // MARK: Launching and quitting

    /// Launches the copy hidden with its log going to a file of this launch, and returns the
    /// bridges for the mirror server.
    private func launchApp(automatic: Bool, fresh: Bool = false) async throws -> MirrorServer.App {
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
        if let simulator {
            return try await launchInSimulator(simulator, automatic: automatic, fresh: fresh, generation: generation, logFile: logFile, tail: tail)
        }
        let environment = [
            "CFFIXED_USER_HOME": homeDirectory.path,
            "HOME": homeDirectory.path,
            "TMPDIR": options.sessionDirectory.appendingPathComponent("tmp").path + "/",
            // os_log and Logger messages on standard error too, as Xcode's console shows them.
            "OS_ACTIVITY_DT_MODE": "1",
        ]
        let appearance = wantedAppearance()
        if appearance != requestedAppearance(), !warnedAboutDark {
            warnedAboutDark = true
            warn("\(name) can only look dark while this Mac uses the Dark appearance, so it shows light.")
        }
        let running: NSRunningApplication
        do {
            running = try await hider.launch(bundle: appCopy, environment: environment,
                                             arguments: ["-ApplePersistenceIgnoreState", "YES"] + Self.appearanceArguments(appearance),
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
        note("Launched \(name) (pid \(pid)) in the \(appearance.rawValue) appearance.")
        if appearance != self.appearance {
            self.appearance = appearance
            eventSink.yield(.appearance(appearance))
        }
        return try MirrorServer.App.live(pid: pid, name: name, boot: boot)
    }

    /// Starts the iPhone app in the Simulator (see SimulatorSession) and watches its process like a
    /// Mac app's; returns the bridges for its device's window.
    private func launchInSimulator(_ simulator: SimulatorSession, automatic: Bool, fresh: Bool, generation: Int,
                                   logFile: URL, tail: LogTail) async throws -> MirrorServer.App {
        let boot = UUID().uuidString
        let launched: SimulatorSession.Launched
        do {
            launched = try await simulator.start(fresh: fresh, appearance: wantedAppearance(), output: logFile, boot: boot)
        } catch {
            tail.finish()
            throw error
        }
        let pid = launched.pid
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.exited(pid: pid, generation: generation) }
        }
        exit.resume()
        launch = Launch(pid: pid, generation: generation, boot: boot, started: .now, automatic: automatic, tail: tail, exit: exit)
        guard Self.isAlive(pid) else {
            throw MacAppSessionError.failed("\(name) quit while starting.\(lastAppLines())")
        }
        let device = simulator.launch?.device.label ?? "Simulator"
        note("Launched \(name) (pid \(pid)) in the \(device)\(simulator.usesRealData ? " with its own data" : ", empty")"
             + (launched.openedSimulator ? "; the Simulator runs hidden." : "; the Simulator window stays where it is."))
        if launched.app.device?.screen == nil {
            warn("OpenTraffic couldn't find \(device)'s screen in its window, so viewers see the whole Simulator window.")
        }
        if launched.appearance != appearance {
            appearance = launched.appearance
            eventSink.yield(.appearance(launched.appearance))
        }
        return launched.app
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
        if let simulator {
            if Self.isAlive(pid) {
                await simulator.terminate()
                let deadline = ContinuousClock.now + Self.stopGrace
                while Self.isAlive(pid), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                if Self.isAlive(pid) { kill(pid, SIGKILL) }
            }
            launch.tail.finish()
            return
        }
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

    // MARK: Rebuilding from the sources

    /// Watches the project's sources (`plan.project`, debounced 1 s) and, when they change, builds the
    /// app with `plan` while the running copy keeps serving; after a successful build the new build is
    /// copied and started on the same port, and viewers are put back on the screen they were on
    /// (`restart(replaying: true)`). A failed build is logged and shown as a warning; the copy keeps
    /// running the previous build. False when the folder can't be watched.
    @discardableResult
    public func watchSources(_ plan: MacAppBuild.Plan, delay: TimeInterval = 1) -> Bool {
        sourceWatcher?.stop()
        buildPlan = plan
        let watcher = MacAppSourceWatcher(directory: plan.project, delay: delay) { [weak self] in
            Task { @MainActor in self?.rebuild(because: "The sources changed.") }
        }
        guard watcher.start() else {
            sourceWatcher = nil
            note("Couldn't watch \(plan.project.path) for changes.")
            return false
        }
        sourceWatcher = watcher
        note("Watching \(plan.project.path): a change builds \(name) (\(plan.summary)) and restarts it.")
        return true
    }

    /// Builds and restarts now if the sources changed since the last build (an agent finished its
    /// work; the watcher may not have fired yet).
    public func sourcesMayHaveChanged() {
        guard let sourceWatcher else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard sourceWatcher.takeChange() else { return }
            await self?.rebuild(because: "The sources changed.")
        }
    }

    /// Builds the app with `buildPlan` and restarts it with a replay; a build already running is
    /// followed by one more.
    public func rebuild(because reason: String) {
        guard buildPlan != nil, isServing else { return }
        if builds != nil {
            buildAgain = true
            return
        }
        builds = Task { @MainActor [weak self] in
            var reason = reason
            while let self {
                self.buildAgain = false
                await self.buildAndRestart(because: reason)
                guard self.buildAgain, !Task.isCancelled, self.isServing else { break }
                reason = "The sources changed again while it was building."
            }
            self?.builds = nil
        }
    }

    /// The server answers (running, or after a failed or crashed launch): a build can restart it.
    private var isServing: Bool {
        switch state {
        case .running, .restarting, .crashed, .failed: server != nil
        default: false
        }
    }

    private func buildAndRestart(because reason: String) async {
        guard let plan = buildPlan else { return }
        buildCount += 1
        let logs = options.sessionDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logFile = logs.appendingPathComponent("build-\(buildCount).log")
        note("\(reason) Building \(name): \(plan.summary)")
        buildLog = logFile
        setBuildState(.building)
        let started = ContinuousClock.now
        let outcome = await MacAppBuild.run(plan, log: logFile, timeout: options.buildTimeout) { [logSink, logLines] text in
            guard MacAppBuild.isNotable(text) else { return }
            let line = LogLine(source: .session, text: "build: " + text.trimmingCharacters(in: .whitespaces))
            logLines.append(line)
            logSink.yield(line)
        }
        guard isServing, !Task.isCancelled else { return setBuildState(.idle) }
        let took = (ContinuousClock.now - started).components.seconds
        switch outcome {
        case .succeeded:
            note("Built \(name) in \(took) s (log: \(logFile.path)).")
            setBuildState(.idle)
            // Copied again even when only resources changed (the executable's stamp may not).
            bundleStamp = nil
            do {
                try await serially { [self] in
                    guard isServing else { return }
                    try await relaunch(resetting: false, automatic: false, because: "\(name) was rebuilt: starting the new version.", replaying: true)
                }
            } catch {
                // relaunch logged it and set the state; the viewers see the failure.
            }
        case .failed(_, let lines):
            // The card shows it as a warning of its own (`buildState`), and viewers a banner.
            for line in lines { note("build: " + line) }
            note("\(name) didn't build, so viewers still see the previous version. \(outcome.message) (log: \(logFile.path))")
            setBuildState(.failed(outcome.message))
        case .timedOut, .cancelled:
            note("\(outcome.message) Viewers still see the previous version of \(name).")
            setBuildState(.failed(outcome.message))
        }
    }

    private func setBuildState(_ state: BuildState) {
        guard state != buildState else { return }
        let failedBefore = if case .failed = buildState { true } else { lastBuildFailed }
        buildState = state
        switch state {
        case .building: lastBuildFailed = failedBefore
        case .failed: lastBuildFailed = true
        case .idle: lastBuildFailed = false
        }
        // Viewers: a banner while they see the version from before a failed build.
        server?.setBuild(MirrorProtocol.Build(building: state == .building, failed: lastBuildFailed))
        eventSink.yield(.build(state))
    }

    // MARK: Replaying

    /// A viewer action in the running launch: part of the way to the current screen.
    private func appendToReplayPath(_ action: RecordedAction) {
        replayPath.append(action)
        if replayPath.count > Self.actionLimit { replayPath.removeFirst(replayPath.count - Self.actionLimit) }
    }

    /// Sends `path` to the new launch through the server as the host (`MacAppReplay.run`), and keeps
    /// what was replayed as the start of the new launch's replay path.
    private func replay(_ path: [RecordedAction], on server: MirrorServer) async -> ReplayReport {
        let boot = launch?.boot ?? ""
        let count = path.filter { MacAppReplay.replays($0.message) }.count
        if count > 0 { note("Putting viewers back: replaying \(count) action\(count == 1 ? "" : "s").") }
        let result = await MacAppReplay.run(
            path, gap: Self.replayGap, elementWait: Self.replayElementWait, treeWait: Self.replayTreeWait,
            windows: { await server.replayWindows() },
            send: { [weak self] action in
                server.replay(action.message)
                // In order with what viewers do meanwhile.
                self?.appendToReplayPath(RecordedAction(date: Date(), viewer: action.viewer, boot: boot, message: action.message, target: action.target))
            },
            isCurrent: { [weak self] in self?.launch?.boot == boot }
        )
        let report = result.report
        if let step = report.stoppedAt {
            note("Stopped putting viewers back after \(report.replayed) of \(report.total) actions: \(step) has nothing to act on in the new build.")
        } else if report.total > 0 {
            note("Viewers are back where they were (\(report.total) action\(report.total == 1 ? "" : "s") replayed).")
        }
        return report
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
                        let boot = self.launch?.boot ?? ""
                        // Where it was aimed, read before the server applies it (the message comes first).
                        let target = await server.replayTarget(for: message)
                        let action = RecordedAction(date: date, viewer: viewer, boot: boot, message: message, target: target)
                        self.actions.append(action)
                        if self.launch?.boot == boot { self.appendToReplayPath(action) }
                    }
                    self.eventSink.yield(.message(viewer: viewer, message, at: date))
                case .failed(let reason):
                    self.warn(reason)
                case .control(let control):
                    self.eventSink.yield(.control(control))
                case .viewerAppearance(let appearance):
                    // The first viewer's color scheme decides; later viewers see the same app.
                    guard self.viewerAppearance == nil else { break }
                    self.viewerAppearance = appearance
                    self.followAppearance()
                }
            }
        }
    }

    // MARK: Viewer options

    /// Applies the host's new choices: control and window size at once (through the server), the
    /// appearance with a relaunch of the app (same data, same address) when it changes what shows.
    public func setViewerOptions(_ options: MacAppViewerOptions) {
        guard options != viewerOptions else { return }
        viewerOptions = options
        server?.setViewerOptions(options)
        followAppearance()
    }

    /// The appearance the host or the first viewer asked for (this Mac's when nobody did).
    func requestedAppearance() -> MirrorProtocol.Appearance {
        switch viewerOptions.appearance {
        case .light: .light
        case .dark: .dark
        case .mac: MirrorServer.hostAppearance()
        case .viewer: viewerAppearance ?? MirrorServer.hostAppearance()
        }
    }

    /// The appearance the copy can have: the requested one, except that dark needs this Mac in Dark.
    func wantedAppearance() -> MirrorProtocol.Appearance {
        if let simulator {
            // OpenTraffic's own device takes either (`simctl ui`); your own simulator keeps its own.
            return simulator.usesRealData ? appearance : requestedAppearance()
        }
        return Self.achievableAppearance(requestedAppearance(), host: MirrorServer.hostAppearance())
    }

    /// An app can be made light whatever the Mac uses (`NSRequiresAquaSystemAppearance`), but no
    /// launch argument or per-app preference makes it dark: AppKit takes the dark appearance from the
    /// account's global preferences only (cfprefsd doesn't follow the copy's own home). So dark is
    /// only possible while this Mac is in Dark.
    nonisolated static func achievableAppearance(_ requested: MirrorProtocol.Appearance, host: MirrorProtocol.Appearance) -> MirrorProtocol.Appearance {
        requested == .dark && host == .light ? .light : requested
    }

    /// Relaunches the copy when it shows another appearance than it should (an app's appearance is
    /// read at launch). Queued behind other lifecycle work, and checked again when its turn comes.
    private func followAppearance() {
        guard state == .running, wantedAppearance() != appearance else { return }
        if let simulator {
            // A simulated device switches while the app runs: no restart.
            Task { @MainActor [weak self] in
                try? await self?.serially {
                    guard let self, self.state == .running, let device = simulator.launch?.device else { return }
                    let wanted = self.wantedAppearance()
                    guard wanted != self.appearance else { return }
                    await simulator.environment.setAppearance(device, wanted)
                    self.note("Switched \(device.name) to the \(wanted.rawValue) appearance.")
                    self.appearance = wanted
                    self.server?.setAppearance(wanted)
                    self.eventSink.yield(.appearance(wanted))
                }
            }
            return
        }
        Task { @MainActor [weak self] in
            try? await self?.serially {
                guard let self, self.state == .running else { return }
                let wanted = self.wantedAppearance()
                guard wanted != self.appearance else { return }
                try await self.relaunch(resetting: false, automatic: false, because: "Switching \(self.name) to the \(wanted.rawValue) appearance.")
            }
        }
    }

    /// Launch arguments for this appearance (the app's argument domain comes before its own
    /// preferences): light always is (`NSRequiresAquaSystemAppearance` YES keeps it in Aqua), dark
    /// follows a Mac in Dark (NO undoes an app's own opt-out).
    nonisolated static func appearanceArguments(_ appearance: MirrorProtocol.Appearance) -> [String] {
        switch appearance {
        case .light: ["-NSRequiresAquaSystemAppearance", "YES"]
        case .dark: ["-NSRequiresAquaSystemAppearance", "NO"]
        }
    }

    /// The viewer actions `recentActions` keeps: everything that changes the app (menu commands
    /// too). Pointer moves would push the rest out of the buffer within seconds and change nothing
    /// a replay needs; the window size and control requests aren't actions on the app.
    nonisolated static func isRecorded(_ message: MirrorProtocol.ClientMessage) -> Bool {
        switch message {
        case .act, .text, .key, .setText, .menuAction, .windowAction: true
        case .pointer(let pointer): pointer.kind != .move
        case .viewport, .requestControl, .releaseControl: false
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

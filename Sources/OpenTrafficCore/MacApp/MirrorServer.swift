import CoreGraphics
import Foundation
import ImageIO
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import os
import UniformTypeIdentifiers

// MARK: - The bridges, as the server sees them

/// The accessibility side of a shared app (`AccessibilityTree` in the product; stubs in tests).
public protocol MirrorAccessibility: AnyObject, Sendable {
    func windows() async throws -> [AccessibilityTree.Window]
    func snapshot(window: AccessibilityTree.WindowSelector) async throws -> AXSnapshot
    func perform(key: String, action: MirrorProtocol.Action, window: UInt32?) async throws
    func changes() -> AsyncStream<AXChange>
}

/// One window's pixels (`WindowCapture` in the product). `frames` has a single reader: the server.
public protocol MirrorCapture: AnyObject, Sendable {
    var frames: AsyncStream<CapturedFrame> { get }
    func start() async throws
    func stop() async
    func fullFrame() async -> CapturedFrame?
}

/// Synthesized input for the app (`InputSynthesizer` in the product).
public protocol MirrorInput: Sendable {
    func send(_ pointer: MirrorProtocol.Pointer, in window: InputSynthesizer.Window) throws
    func type(text: String) throws
    func send(_ key: MirrorProtocol.Key) throws
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws
}

/// The app's menus (`MenuBridge` in the product): the menu bar, and a menu it has popped up.
public protocol MirrorMenus: AnyObject, Sendable {
    func bar() async throws -> [MirrorProtocol.MenuItem]
    func perform(path: [String]) async throws
    func openMenu() async throws -> MenuBridge.OpenMenu?
    func performOpen(path: [String]) async throws
    func closeOpen() async throws
    @discardableResult func showMenu(at point: CGPoint) async throws -> Bool
}

extension AccessibilityTree: MirrorAccessibility {}
extension WindowCapture: MirrorCapture {}
extension InputSynthesizer: MirrorInput {}
extension MenuBridge: MirrorMenus {}

public enum MirrorServerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The app has no window to mirror.
    case noWindow
    /// The main window's pixels couldn't be captured (after retries).
    case captureFailed(String)
    case stopped

    public var description: String {
        switch self {
        case .noWindow: "The app has no window to show."
        case .captureFailed(let reason): "Couldn't capture the app's window: \(reason)"
        case .stopped: "The mirror server has stopped."
        }
    }
}

// MARK: - MirrorServer

/// Serves one shared Mac app to any number of browsers over one loopback port, as
/// docs/macapp-mirror-protocol.md describes: the viewer page and its assets over HTTP, and on the
/// WebSocket `hello`, the windows' accessibility trees (pushed on change), their pixels as tiles,
/// the cursor and the run state; viewer input goes back to the app in arrival order.
///
/// The server never reads files: the viewer page, script, styles and icon are handed in as Data
/// (the app bundle owns them). The app itself is an `App` (its accessibility tree, input and a
/// capture per window), which `replace(app:)` swaps after a restart while the port, and with it
/// the share's upstream, stays the same; viewers then get a new `hello` with a new `boot`.
///
/// Threading: connections, viewers and what they were sent live on one event loop (like
/// CollabProxy); bridge calls run in tasks and hop back to it. Inbound `act`, `pointer`, `text`,
/// `key` and `setText` messages from every viewer go through one queue and are applied one after
/// another; keys resolve against the window's latest snapshot.
///
/// v1 mirrors the app's main window (protocol kind `main`); sheets, alerts, popovers and second
/// windows come with the extra-windows work (`mirroredWindows`).
///
/// Menus (when the app has `menus`): the menu bar and any popped-up menu go out as `menu`, read on
/// connect, on menu notifications, every `treePollInterval` and often for a moment after a right
/// click; `menuAction` chooses items through the menus bridge, so Cmd shortcuts reach an app that
/// isn't frontmost.
public final class MirrorServer: @unchecked Sendable {
    /// The viewer files, read from the app bundle by the caller.
    public struct Assets: Sendable {
        public var page: Data
        public var script: Data
        public var style: Data
        public var icon: Data?

        public init(page: Data, script: Data, style: Data, icon: Data? = nil) {
            self.page = page; self.script = script; self.style = style; self.icon = icon
        }
    }

    /// One launch of the shared app: what the server reads and drives.
    public struct App: Sendable {
        public var name: String
        /// Changes with every launch; viewers clear everything when it does.
        public var boot: String
        public var accessibility: any MirrorAccessibility
        public var input: any MirrorInput
        /// A capture for a window (by its window server number), made when the window is mirrored.
        public var makeCapture: @Sendable (CGWindowID) -> any MirrorCapture
        /// The app's menus; nil sends no `menu` message and ignores `menuAction`.
        public var menus: (any MirrorMenus)?

        public init(name: String, boot: String = UUID().uuidString, accessibility: any MirrorAccessibility, input: any MirrorInput,
                    menus: (any MirrorMenus)? = nil, makeCapture: @escaping @Sendable (CGWindowID) -> any MirrorCapture) {
            self.name = name; self.boot = boot; self.accessibility = accessibility; self.input = input; self.menus = menus
            self.makeCapture = makeCapture
        }

        /// The real bridges for the process `pid`: AccessibilityTree, InputSynthesizer, MenuBridge and a
        /// WindowCapture per window. Needs Accessibility and Screen Recording permission to work.
        public static func live(pid: pid_t, name: String, boot: String = UUID().uuidString,
                                background: CGColor = CGColor(gray: 1, alpha: 1)) throws -> App {
            let tree = try AccessibilityTree(pid: pid)
            return App(name: name, boot: boot, accessibility: tree, input: InputSynthesizer(pid: pid), menus: try MenuBridge(pid: pid),
                       makeCapture: { WindowCapture(windowID: $0, background: background) })
        }
    }

    public struct Configuration: Sendable {
        public var app: App
        public var assets: Assets
        public var appearance: MirrorProtocol.Appearance
        /// The frames' backing scale for `hello` until the first frame tells; nil means 2.
        public var scale: Double?
        /// Origins (`https://name.example`) besides loopback and the request's own host whose pages may
        /// open the WebSocket; see `acceptsOrigin` and `setAllowedOrigins`.
        public var allowedOrigins: Set<String>

        public init(app: App, assets: Assets, appearance: MirrorProtocol.Appearance = MirrorServer.hostAppearance(),
                    scale: Double? = nil, allowedOrigins: Set<String> = []) {
            self.app = app; self.assets = assets; self.appearance = appearance; self.scale = scale; self.allowedOrigins = allowedOrigins
        }
    }

    /// What happens on the server, for the session (logs, the recent-actions record, viewer counts).
    public enum Event: Sendable {
        case viewerConnected(id: Int, viewers: Int)
        case viewerDisconnected(id: Int, viewers: Int)
        /// A message a viewer sent, as it arrived (before it is applied).
        case message(viewer: Int, MirrorProtocol.ClientMessage, at: Date)
        /// Something the server tried failed: an action the app refused, a capture that didn't start.
        case failed(String)
    }

    /// Menu reads start at most this often (the bar is read whole, so less often than trees)...
    public static let menuInterval: Duration = .milliseconds(100)
    /// ...and after a right click, this often for `menuWatch`, until the app's context menu shows.
    static let menuWatchStep: Duration = .milliseconds(100)
    static let menuWatch: Duration = .milliseconds(1500)
    /// Extra tree reads after a menu action (each delay counted from the one before).
    static let menuActionRefreshes: [Duration] = [.milliseconds(150), .milliseconds(350)]
    /// Tree refreshes start at most this often...
    public static let treeInterval: Duration = .milliseconds(50)
    /// ...and, while viewers are connected, at least this often (for changes AX doesn't announce).
    public static let treePollInterval: Duration = .seconds(2)
    /// How long `start` waits for the main window's first frame (to tell viewers the right scale).
    public static let firstFrameWait: Duration = .seconds(5)
    /// ScreenCaptureKit can time out or decline (-3801) right after launch; tries per window.
    static let captureAttempts = 3
    static let captureAttemptLimit: Duration = .seconds(15)
    /// How long stopping one capture may take before the server goes on without it.
    static let captureStopLimit: Duration = .seconds(5)
    /// A capture that failed or ended isn't started again for this long.
    static let captureRetryDelay: Duration = .seconds(2)
    static let pingInterval: TimeAmount = .seconds(30)
    static let maximumClientMessageBytes = 1 << 20
    /// Waiting for setText's field to take the focus.
    static let setTextTimeout: Duration = .seconds(1)

    /// One thread serves every mirror server; frames are encoded on the capture queues.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public let configuration: Configuration
    public let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    let loop: EventLoop

    /// Viewer messages to apply, in arrival order, from every viewer.
    private let inbox: AsyncStream<(viewer: Int, message: MirrorProtocol.ClientMessage)>
    private let inboxSink: AsyncStream<(viewer: Int, message: MirrorProtocol.ClientMessage)>.Continuation

    private struct Shared {
        var port: Int?
        var viewers = 0
        var runtime: Runtime?
        var applier: Task<Void, Never>?
        var stopped = false
        var allowedOrigins: Set<String> = []
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    // Event-loop confined.
    private var serverChannel: Channel?
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var clients: [Int: Client] = [:]
    private var nextClientID = 1
    /// Bumped by every launch; work for an older launch is dropped.
    private var generation = 0
    /// False while an app launch is being set up: nothing is broadcast, and viewers are greeted when it goes live.
    private var live = false
    private var app: App
    private var windows: [MirrorProtocol.WindowInfo] = []
    private var snapshots: [MirrorProtocol.WindowID: AXSnapshot] = [:]
    /// The latest `tree` message per window, encoded once.
    private var treeTexts: [MirrorProtocol.WindowID: String] = [:]
    private var captures: [MirrorProtocol.WindowID: any MirrorCapture] = [:]
    private var scale: Double?
    private var status = MirrorProtocol.Status(state: .running)
    /// The latest `menu` message, encoded once (nil until the menus were read, or without menus).
    private var menuText: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
        app = configuration.app
        shared.withLock { $0.allowedOrigins = configuration.allowedOrigins }
        loop = Self.group.next()
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(1024))
        (inbox, inboxSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }

    // MARK: Lifecycle

    /// The port on 127.0.0.1, once started.
    public var port: Int? { shared.withLock { $0.port } }
    public var url: URL? { port.map { URL(string: "http://127.0.0.1:\($0)/")! } }
    public var viewerCount: Int { shared.withLock { $0.viewers } }

    /// Starts serving: reads the app's windows and trees, starts capturing the main window (waiting
    /// a little for its first frame), and listens on a random loopback port, which it returns.
    /// Throws when the app has no window (`noWindow`), Accessibility refuses (`AccessibilityTreeError`),
    /// or the main window can't be captured (`captureFailed`).
    @discardableResult
    public func start() async throws -> Int {
        let runtime = try await launch(configuration.app)
        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 256 * 1024, high: 2 * 1024 * 1024))
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture { try self.configurePipeline(channel) }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            await runtime.stop()
            throw error
        }
        let port = channel.localAddress?.port ?? 0
        try await loop.submit { self.serverChannel = channel }.get()
        let applier = Task { [self] in
            for await (viewer, message) in inbox {
                await apply(message, from: viewer)
            }
        }
        let stopped = shared.withLock { state -> Bool in
            state.port = port
            state.runtime = runtime
            state.applier = applier
            return state.stopped
        }
        if stopped { await stop() }
        return port
    }

    /// Mirrors a new launch of the app (after a restart) on the same port. Viewers stay connected
    /// and get a new `hello` (with the new app's `boot`), its trees and frames.
    public func replace(app: App) async throws {
        let old = shared.withLock { state -> Runtime? in defer { state.runtime = nil }; return state.runtime }
        await old?.stop()
        let runtime = try await launch(app)
        let stopped = shared.withLock { state -> Bool in
            if !state.stopped { state.runtime = runtime }
            return state.stopped
        }
        if stopped { await runtime.stop() }
    }

    /// Stops capturing and serving and closes every connection.
    public func stop() async {
        let (runtime, applier) = shared.withLock { state -> (Runtime?, Task<Void, Never>?) in
            defer { state.runtime = nil; state.applier = nil; state.stopped = true }
            return (state.runtime, state.applier)
        }
        applier?.cancel()
        inboxSink.finish()
        await runtime?.stop()
        let channels: [Channel] = (try? await loop.submit { () -> [Channel] in
            let all = Array(self.connections.values) + [self.serverChannel].compactMap { $0 }
            self.serverChannel = nil
            self.live = false
            return all
        }.get()) ?? []
        for channel in channels { try? await channel.close() }
        eventSink.finish()
    }

    /// Tells every viewer how the app is doing (`restarting`, `crashed`, ...); new viewers get it too.
    public func setStatus(_ status: MirrorProtocol.Status) {
        loop.execute {
            self.status = status
            guard self.live, let text = try? MirrorProtocol.ServerMessage.status(status).jsonString() else { return }
            for client in self.clients.values { client.sendText(text, flush: true) }
        }
    }

    /// Replaces the origins allowed to open the WebSocket besides loopback and same-host pages (the
    /// share's public origin once the tunnel is up, e.g. `https://orbit.example.dev`).
    public func setAllowedOrigins(_ origins: Set<String>) {
        shared.withLock { $0.allowedOrigins = origins }
    }

    var allowedOrigins: Set<String> { shared.withLock { $0.allowedOrigins } }

    /// Reads the windows and trees again soon (coalesced like change notifications).
    public func refreshSoon() {
        shared.withLock { $0.runtime }?.requestRefresh()
    }

    /// The app's appearance on this Mac's account, for `hello` when the session doesn't say.
    public static func hostAppearance() -> MirrorProtocol.Appearance {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark" ? .dark : .light
    }

    // MARK: One launch of the app

    /// Everything that belongs to one launch: its tasks and captures.
    private final class Runtime: @unchecked Sendable {
        let app: App
        let generation: Int
        let signals: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        /// Requests to read the menus again (coalesced like tree refreshes).
        let menuSignals: AsyncStream<Void>
        private let menuSignal: AsyncStream<Void>.Continuation

        struct State {
            var tasks: [Task<Void, Never>] = []
            var captures: [MirrorProtocol.WindowID: any MirrorCapture] = [:]
            var failedAt: [MirrorProtocol.WindowID: ContinuousClock.Instant] = [:]
            var mainID: MirrorProtocol.WindowID?
            var sentV: [MirrorProtocol.WindowID: String] = [:]
            /// The main window's global frame, for placing a popped-up menu relative to it.
            var mainFrame: CGRect?
            /// Where the last right click was (window, window-relative point), for a menu without a frame.
            var rightClick: (window: MirrorProtocol.WindowID, point: CGPoint)?
            /// Until when menu reads are requested often (after a right click or showMenu).
            var menuWatchUntil: ContinuousClock.Instant?
            var stopped = false
        }
        let state = OSAllocatedUnfairLock(initialState: State())

        init(app: App, generation: Int) {
            self.app = app
            self.generation = generation
            (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            (menuSignals, menuSignal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        }

        func requestRefresh() { signal.yield() }
        func requestMenuRefresh() { menuSignal.yield() }

        /// Reads the menus often for a while: a menu the app is about to pop up shows within it.
        func watchMenus() {
            let start = state.withLock { state -> Bool in
                let watching = state.menuWatchUntil.map { $0 > .now } ?? false
                state.menuWatchUntil = ContinuousClock.now.advanced(by: MirrorServer.menuWatch)
                return !watching
            }
            requestMenuRefresh()
            guard start else { return }
            add(Task { [weak self] in
                while let self, !Task.isCancelled, let until = self.state.withLock({ $0.menuWatchUntil }), until > .now {
                    try? await Task.sleep(for: MirrorServer.menuWatchStep)
                    self.requestMenuRefresh()
                }
            })
        }

        func add(_ task: Task<Void, Never>) {
            let keep = state.withLock { state -> Bool in
                if !state.stopped { state.tasks.append(task) }
                return !state.stopped
            }
            if !keep { task.cancel() }
        }

        var isStopped: Bool { state.withLock { $0.stopped } }

        func stop() async {
            let (tasks, captures) = state.withLock { state -> ([Task<Void, Never>], [any MirrorCapture]) in
                defer { state.stopped = true; state.tasks = []; state.captures = [:] }
                return (state.tasks, Array(state.captures.values))
            }
            signal.finish()
            menuSignal.finish()
            for task in tasks { task.cancel() }
            // Bounded: ending a share must not wait on a capture that hangs.
            for capture in captures { _ = try? await WindowCapture.within(MirrorServer.captureStopLimit) { await capture.stop() } }
        }
    }

    /// Sets up a launch: windows, trees and the main window's capture, then lets viewers see it.
    private func launch(_ app: App) async throws -> Runtime {
        let generation = try await loop.submit { () -> Int in
            self.generation += 1
            self.live = false
            self.app = app
            self.windows = []
            self.snapshots = [:]
            self.treeTexts = [:]
            self.captures = [:]
            self.scale = nil
            self.status = MirrorProtocol.Status(state: .running)
            self.menuText = nil
            for client in self.clients.values { client.resetFrames() }
            return self.generation
        }.get()
        let runtime = Runtime(app: app, generation: generation)
        do {
            let mirrored = try await refresh(runtime)
            guard let main = mirrored.first else { throw MirrorServerError.noWindow }
            for window in mirrored {
                do {
                    try await startCapture(window.info.id, in: runtime)
                } catch where window.info.id != main.info.id {
                    eventSink.yield(.failed("Couldn't capture window \(window.info.id): \(error)"))
                }
            }
            // The first frame tells the backing scale, which `hello` carries.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.firstFrameWait)
            while clock.now < deadline, try await loop.submit({ self.scale }).get() == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            await runtime.stop()
            throw error
        }

        runtime.add(Task { [weak runtime] in
            guard let changes = runtime?.app.accessibility.changes() else { return }
            for await change in changes {
                runtime?.requestRefresh()
                if change.kind == .menuOpened || change.kind == .menuClosed { runtime?.requestMenuRefresh() }
            }
        })
        runtime.add(Task { [weak self, weak runtime] in
            guard let runtime else { return }
            await self?.refreshLoop(runtime)
        })
        if app.menus != nil {
            runtime.add(Task { [weak self, weak runtime] in
                guard let runtime else { return }
                await self?.menuLoop(runtime)
            })
            runtime.requestMenuRefresh()
        }
        runtime.add(Task { [weak self, weak runtime] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MirrorServer.treePollInterval)
                if let self, self.viewerCount > 0 {
                    runtime?.requestRefresh()
                    runtime?.requestMenuRefresh()
                }
            }
        })
        try await loop.submit {
            guard self.generation == generation else { return }
            self.live = true
            for client in self.clients.values { self.greet(client) }
        }.get()
        return runtime
    }

    /// Refreshes on request, at most one start per `treeInterval`; requests made during a refresh
    /// make one more right after it.
    private func refreshLoop(_ runtime: Runtime) async {
        let clock = ContinuousClock()
        var last = clock.now.advanced(by: .seconds(-1))
        for await _ in runtime.signals {
            let wait = last.advanced(by: Self.treeInterval) - clock.now
            if wait > .zero { try? await Task.sleep(for: wait) }
            if Task.isCancelled || runtime.isStopped { return }
            last = clock.now
            do {
                let mirrored = try await refresh(runtime)
                syncCaptures(Set(mirrored.map(\.info.id)), in: runtime)
            } catch {
                // The app is busy, quitting or gone; the session watches the process.
            }
        }
    }

    struct MirroredWindow: Equatable, Sendable {
        var info: MirrorProtocol.WindowInfo
        /// Global frame in points (Accessibility's coordinates).
        var frame: CGRect
    }

    /// The windows the viewers see, the main one first. v1: the main window only (kind `main`),
    /// kept while it exists even when another window becomes main.
    static func mirroredWindows(_ windows: [AccessibilityTree.Window], current: MirrorProtocol.WindowID?) -> [MirroredWindow] {
        let candidates = windows.filter { window in
            window.number != nil && !window.isMinimized && window.frame.width > 0 && window.frame.height > 0
                && (window.role.isEmpty || window.role == "AXWindow")
        }
        guard let main = candidates.first(where: { current != nil && $0.number == current })
            ?? candidates.first(where: \.isMain) ?? candidates.first(where: \.isFocused) ?? candidates.first,
            let id = main.number else { return [] }
        let info = MirrorProtocol.WindowInfo(id: id, title: main.title, w: main.frame.width, h: main.frame.height, x: 0, y: 0, kind: .main)
        return [MirroredWindow(info: info, frame: main.frame)]
    }

    /// Reads the window list and every mirrored window's tree, and hands what changed to the viewers.
    @discardableResult
    private func refresh(_ runtime: Runtime) async throws -> [MirroredWindow] {
        let accessibility = runtime.app.accessibility
        let current = runtime.state.withLock { $0.mainID }
        let mirrored = Self.mirroredWindows(try await accessibility.windows(), current: current)
        runtime.state.withLock { state in
            state.mainID = mirrored.first?.info.id
            state.mainFrame = mirrored.first?.frame
        }
        var trees: [(MirrorProtocol.WindowID, AXSnapshot, String?)] = []
        for window in mirrored {
            let id = window.info.id
            guard let snapshot = try? await accessibility.snapshot(window: .number(id)) else { continue }
            let changed = runtime.state.withLock { state -> Bool in
                defer { state.sentV[id] = snapshot.v }
                return state.sentV[id] != snapshot.v
            }
            let text = changed ? try? MirrorProtocol.ServerMessage.tree(snapshot.tree(window: id)).jsonString() : nil
            trees.append((id, snapshot, text))
        }
        let generation = runtime.generation
        let windows = mirrored.map(\.info)
        let read = trees
        try await loop.submit { self.update(generation: generation, windows: windows, trees: read) }.get()
        return mirrored
    }

    /// On the loop: takes a refresh's results and sends viewers the window list and trees that changed.
    private func update(generation: Int, windows: [MirrorProtocol.WindowInfo], trees: [(MirrorProtocol.WindowID, AXSnapshot, String?)]) {
        guard generation == self.generation else { return }
        var texts: [String] = []
        if windows != self.windows {
            self.windows = windows
            let ids = Set(windows.map(\.id))
            snapshots = snapshots.filter { ids.contains($0.key) }
            treeTexts = treeTexts.filter { ids.contains($0.key) }
            if let text = try? MirrorProtocol.ServerMessage.windows(windows).jsonString() { texts.append(text) }
        }
        for (id, snapshot, text) in trees {
            snapshots[id] = snapshot
            if let text {
                treeTexts[id] = text
                texts.append(text)
            }
        }
        guard live, !texts.isEmpty else { return }
        for client in clients.values {
            for text in texts { client.sendText(text, flush: false) }
            client.flush()
        }
    }

    // MARK: Menus

    /// Reads the menus on request, at most one start per `menuInterval`, and sends viewers the
    /// `menu` message when it changed.
    private func menuLoop(_ runtime: Runtime) async {
        guard let menus = runtime.app.menus else { return }
        let clock = ContinuousClock()
        var last = clock.now.advanced(by: .seconds(-1))
        var bar: [MirrorProtocol.MenuItem]?
        var sent: MirrorProtocol.Menu?
        for await _ in runtime.menuSignals {
            let wait = last.advanced(by: Self.menuInterval) - clock.now
            if wait > .zero { try? await Task.sleep(for: wait) }
            if Task.isCancelled || runtime.isStopped { return }
            last = clock.now
            // A failed read (the app busy or quitting) keeps what viewers have.
            if let read = try? await menus.bar() { bar = read }
            guard let bar else { continue }
            let open = try? await menus.openMenu()
            let (mainID, mainFrame, click) = runtime.state.withLock { ($0.mainID, $0.mainFrame, $0.rightClick) }
            let context = Self.contextMenu(open, mainID: mainID, mainFrame: mainFrame, rightClick: click)
            if context != nil { runtime.state.withLock { $0.menuWatchUntil = nil } } // it showed
            // Compared as values: JSON key order isn't stable from one encoding to the next.
            let menu = MirrorProtocol.Menu(bar: bar, context: context)
            guard menu != sent, let text = try? MirrorProtocol.ServerMessage.menu(menu).jsonString() else { continue }
            sent = menu
            let generation = runtime.generation
            loop.execute {
                guard generation == self.generation else { return }
                self.menuText = text
                guard self.live else { return }
                for client in self.clients.values { client.sendText(text, flush: true) }
            }
        }
    }

    /// The protocol's context menu for a popped-up menu: placed relative to the main window, at the
    /// menu's own top-left (or the right click when the menu has no frame).
    static func contextMenu(_ open: MenuBridge.OpenMenu?, mainID: MirrorProtocol.WindowID?, mainFrame: CGRect?,
                            rightClick: (window: MirrorProtocol.WindowID, point: CGPoint)?) -> MirrorProtocol.ContextMenu? {
        guard let open, !open.items.isEmpty, let window = mainID ?? rightClick?.window else { return nil }
        if let mainFrame, open.frame.width > 0, open.frame.height > 0 {
            return .init(window: window, x: (open.frame.minX - mainFrame.minX).rounded(), y: (open.frame.minY - mainFrame.minY).rounded(),
                         items: open.items)
        }
        let point = rightClick?.point ?? .zero
        return .init(window: rightClick?.window ?? window, x: point.x, y: point.y, items: open.items)
    }

    // MARK: Captures

    /// Starts captures for newly mirrored windows and stops those of windows that went away.
    private func syncCaptures(_ wanted: Set<MirrorProtocol.WindowID>, in runtime: Runtime) {
        let now = ContinuousClock.now
        let (start, gone) = runtime.state.withLock { state -> ([MirrorProtocol.WindowID], [(MirrorProtocol.WindowID, any MirrorCapture)]) in
            let start = wanted.filter { id in
                state.captures[id] == nil && (state.failedAt[id].map { now - $0 >= MirrorServer.captureRetryDelay } ?? true)
            }
            let gone = state.captures.filter { !wanted.contains($0.key) }.map { ($0.key, $0.value) }
            for (id, _) in gone { state.captures[id] = nil }
            return (Array(start), gone)
        }
        for (id, capture) in gone {
            loop.execute { if self.captures[id] === capture { self.captures[id] = nil } }
            Task { _ = try? await WindowCapture.within(Self.captureStopLimit) { await capture.stop() } }
        }
        for id in start {
            runtime.add(Task { [weak self] in
                do {
                    try await self?.startCapture(id, in: runtime)
                } catch {
                    self?.eventSink.yield(.failed("Couldn't capture window \(id): \(error)"))
                }
            })
        }
    }

    /// Makes and starts a window's capture (retrying ScreenCaptureKit's start-up hiccups) and
    /// forwards its frames to the viewers until it ends.
    private func startCapture(_ id: MirrorProtocol.WindowID, in runtime: Runtime) async throws {
        let capture = runtime.app.makeCapture(id)
        let registered = runtime.state.withLock { state -> Bool in
            guard !state.stopped, state.captures[id] == nil else { return false }
            state.captures[id] = capture
            return true
        }
        guard registered else { return }
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await WindowCapture.within(Self.captureAttemptLimit) { try await capture.start() }
                break
            } catch {
                guard attempt < Self.captureAttempts, !runtime.isStopped, Self.isTransient(error) else {
                    runtime.state.withLock { state in
                        if state.captures[id] === capture { state.captures[id] = nil }
                        state.failedAt[id] = .now
                    }
                    _ = try? await WindowCapture.within(Self.captureStopLimit) { await capture.stop() }
                    throw MirrorServerError.captureFailed(String(describing: error))
                }
                try? await Task.sleep(for: .milliseconds(500 * attempt))
            }
        }
        let generation = runtime.generation
        try await loop.submit {
            guard self.generation == generation else { return }
            self.captures[id] = capture
            // Viewers already here get this window's frames from its first (full) frame on.
        }.get()
        runtime.add(Task { [weak self, weak runtime] in
            for await frame in capture.frames {
                guard let server = self else { break }
                server.loop.execute { server.deliver(frame, generation: generation) }
            }
            // The window closed or capture stopped.
            runtime?.state.withLock { state in
                if state.captures[id] === capture { state.captures[id] = nil }
                state.failedAt[id] = .now
            }
            if let server = self {
                server.loop.execute { if server.captures[id] === capture { server.captures[id] = nil } }
            }
            runtime?.requestRefresh()
        })
    }

    /// Errors worth another try: timeouts, ScreenCaptureKit declining (-3801) or not finding a window
    /// that was just shown.
    static func isTransient(_ error: Error) -> Bool {
        switch error as? WindowCaptureError {
        case .timedOut, .windowNotFound: return true
        case .notPermitted, .snapshotFailed: return false
        case nil: return (error as NSError).code == -3801
        }
    }

    /// On the loop: sends a frame and its tiles to every viewer that is in step with that window.
    private func deliver(_ frame: CapturedFrame, generation: Int) {
        guard generation == self.generation else { return }
        if scale != frame.scale {
            let known = scale != nil
            scale = frame.scale
            // The frames' scale changed (the window moved to another display): tell the viewers.
            if known, live, let text = helloText() { for client in clients.values { client.sendText(text, flush: true) } }
        }
        guard live, !clients.isEmpty else { return }
        let encoded = EncodedFrame(frame)
        for client in clients.values {
            if client.pending[frame.window] != nil {
                client.pending[frame.window]?.append(frame)
            } else if client.stale.contains(frame.window) {
                continue
            } else if !client.channel.isWritable {
                // Falling behind (a slow link): skip frames, and catch up with a full one once writable.
                client.stale.insert(frame.window)
            } else {
                client.send(encoded)
            }
        }
    }

    /// On the loop: a viewer's window stream restarts from a full frame of what the others have now.
    /// Frames arriving meanwhile are held, and those newer than the full frame follow it.
    private func syncFrames(_ client: Client, window: MirrorProtocol.WindowID) {
        guard let capture = captures[window] else { return }
        client.pending[window] = []
        let generation = generation
        let id = client.id
        Task {
            let full = await capture.fullFrame()
            self.loop.execute {
                guard generation == self.generation, let client = self.clients[id],
                      let held = client.pending.removeValue(forKey: window) else { return }
                if let full { client.send(EncodedFrame(full), flush: false) }
                for frame in held where full.map({ frame.seq > $0.seq }) ?? true {
                    client.send(EncodedFrame(frame), flush: false)
                }
                client.flush()
            }
        }
    }

    // MARK: Viewers (on the loop)

    final class Client {
        let id: Int
        let channel: Channel
        /// Windows whose frames are held until their full frame is sent.
        var pending: [MirrorProtocol.WindowID: [CapturedFrame]] = [:]
        /// Windows whose frames are skipped until the viewer catches up.
        var stale: Set<MirrorProtocol.WindowID> = []
        var cursor: MirrorProtocol.CursorShape?

        init(id: Int, channel: Channel) { self.id = id; self.channel = channel }

        func resetFrames() { pending = [:]; stale = []; cursor = nil }

        func sendText(_ text: String, flush: Bool) {
            let frame = WebSocketFrame(fin: true, opcode: .text, data: channel.allocator.buffer(string: text))
            if flush { channel.writeAndFlush(frame, promise: nil) } else { channel.write(frame, promise: nil) }
        }

        func send(_ frame: EncodedFrame, flush: Bool = true) {
            sendText(frame.header, flush: false)
            for tile in frame.tiles { channel.write(WebSocketFrame(fin: true, opcode: .binary, data: tile), promise: nil) }
            if flush { channel.flush() }
        }

        func flush() { channel.flush() }
    }

    /// A frame as WebSocket payloads, encoded once for every viewer.
    struct EncodedFrame {
        var header: String
        var tiles: [ByteBuffer]

        init(_ frame: CapturedFrame) {
            header = (try? MirrorProtocol.ServerMessage.frame(frame.header).jsonString()) ?? ""
            tiles = frame.tiles.map { ByteBuffer(bytes: $0.encoded()) }
        }
    }

    private func helloText() -> String? {
        let hello = MirrorProtocol.Hello(boot: app.boot, scale: scale ?? configuration.scale ?? 2, appearance: configuration.appearance,
                                         app: .init(name: app.name), windows: windows)
        return try? MirrorProtocol.ServerMessage.hello(hello).jsonString()
    }

    /// `hello`, the run state when it isn't `running`, every window's tree, then every window's full frame.
    private func greet(_ client: Client) {
        guard live, let hello = helloText() else { return }
        client.resetFrames()
        client.sendText(hello, flush: false)
        if status.state != .running, let text = try? MirrorProtocol.ServerMessage.status(status).jsonString() {
            client.sendText(text, flush: false)
        }
        for window in windows {
            if let text = treeTexts[window.id] { client.sendText(text, flush: false) }
        }
        if let menuText { client.sendText(menuText, flush: false) }
        client.flush()
        for window in windows { syncFrames(client, window: window.id) }
    }

    fileprivate func clientConnected(_ channel: Channel) -> Int {
        loop.preconditionInEventLoop()
        let id = nextClientID
        nextClientID += 1
        let client = Client(id: id, channel: channel)
        clients[id] = client
        greet(client)
        let (count, runtime) = shared.withLock { state -> (Int, Runtime?) in
            state.viewers = clients.count
            return (state.viewers, state.runtime)
        }
        // The cached trees are as new as the last change notification; make sure.
        runtime?.requestRefresh()
        runtime?.requestMenuRefresh()
        eventSink.yield(.viewerConnected(id: id, viewers: count))
        return id
    }

    fileprivate func clientDisconnected(_ id: Int) {
        loop.preconditionInEventLoop()
        guard clients.removeValue(forKey: id) != nil else { return }
        let count = clients.count
        shared.withLock { $0.viewers = count }
        eventSink.yield(.viewerDisconnected(id: id, viewers: count))
    }

    /// The viewer's connection drained: windows it fell behind on restart from a full frame.
    fileprivate func clientWritable(_ id: Int) {
        loop.preconditionInEventLoop()
        guard let client = clients[id], !client.stale.isEmpty else { return }
        let windows = client.stale
        client.stale = []
        for window in windows { syncFrames(client, window: window) }
    }

    /// A text message from a viewer: decoded here, applied in order by the applier.
    fileprivate func clientSent(_ id: Int, _ data: Data) {
        guard let message = try? MirrorProtocol.ClientMessage.decode(data) else { return } // unknown `t` or not JSON: ignored
        eventSink.yield(.message(viewer: id, message, at: Date()))
        if case .pointer(let pointer) = message, pointer.kind == .move { updateCursor(id, pointer) }
        inboxSink.yield((id, message))
    }

    /// Cursor feedback from the tree: an I-beam over enabled text fields, a hand over links.
    private func updateCursor(_ id: Int, _ pointer: MirrorProtocol.Pointer) {
        guard let client = clients[id], let snapshot = snapshots[pointer.window] else { return }
        let shape = Self.cursorShape(at: CGPoint(x: pointer.x, y: pointer.y), in: snapshot.nodes)
        guard client.cursor != shape, let text = try? MirrorProtocol.ServerMessage.cursor(shape).jsonString() else { return }
        client.cursor = shape
        client.sendText(text, flush: true)
    }

    static let textRoles: Set<String> = ["AXTextField", "AXSecureTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The cursor the app would show at a window-relative point: the deepest element there decides,
    /// with its ancestors (a label inside a link).
    static func cursorShape(at point: CGPoint, in nodes: [MirrorProtocol.AXNode]) -> MirrorProtocol.CursorShape {
        guard let hit = nodes.last(where: { $0.w > 0 && $0.h > 0 && CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(point) })
        else { return .default }
        if textRoles.contains(hit.role) { return hit.enabled ? .text : .default }
        let ancestors = nodes.filter { hit.key.hasPrefix($0.key + "/") }
        if hit.role == "AXLink" || ancestors.contains(where: { $0.role == "AXLink" }) { return .pointer }
        return .default
    }

    // MARK: Applying viewer input (one at a time, in arrival order)

    private func apply(_ message: MirrorProtocol.ClientMessage, from viewer: Int) async {
        guard let runtime = shared.withLock({ $0.runtime }), !runtime.isStopped else { return }
        let app = runtime.app
        if case .menuAction(let action) = message {
            guard let menus = app.menus else { return }
            do {
                if !action.context {
                    try await menus.perform(path: action.path)
                } else if action.path.isEmpty {
                    try await menus.closeOpen()
                } else {
                    try await menus.performOpen(path: action.path)
                }
            } catch {
                eventSink.yield(.failed("menuAction \(action.path.joined(separator: " > ")) from viewer \(viewer): \(error)"))
            }
            runtime.requestMenuRefresh()
            runtime.requestRefresh()
            // A menu command often changes the app a moment later, and not every change is announced.
            runtime.add(Task { [weak runtime] in
                for delay in Self.menuActionRefreshes {
                    try? await Task.sleep(for: delay)
                    runtime?.requestRefresh()
                }
            })
            return
        }
        guard let window = message.window else { return } // viewport, requestControl: events only (reserved)
        guard let snapshot = try? await loop.submit({ self.snapshots[window] }).get() else { return } // not a mirrored window
        let target = InputSynthesizer.Window(id: window, frame: snapshot.frame)
        do {
            switch message {
            case .act(let act) where act.action == .showMenu && app.menus != nil:
                // AXShowMenu answers only when the menu closes; MenuBridge doesn't wait for that.
                var node = snapshot.node(act.key)
                if node == nil { node = try await app.accessibility.snapshot(window: .number(window)).node(act.key) }
                guard let node, node.w > 0, node.h > 0 else { return }
                let center = CGPoint(x: node.x + node.w / 2, y: node.y + node.h / 2)
                runtime.state.withLock { $0.rightClick = (window, center) }
                try await app.menus?.showMenu(at: CGPoint(x: snapshot.frame.minX + center.x, y: snapshot.frame.minY + center.y))
                runtime.watchMenus()
            case .act(let act):
                try await app.accessibility.perform(key: act.key, action: act.action, window: window)
            case .pointer(let pointer):
                try app.input.send(pointer, in: target)
                if pointer.kind == .move { return }
                if pointer.kind == .rightup, app.menus != nil {
                    // The app may pop up a context menu: read the menus often until it shows.
                    runtime.state.withLock { $0.rightClick = (window, CGPoint(x: pointer.x, y: pointer.y)) }
                    runtime.watchMenus()
                }
            case .text(let text):
                try app.input.type(text: text.text)
            case .key(let key):
                try app.input.send(key)
            case .setText(let setText):
                var node = snapshot.node(setText.key)
                if node == nil { node = try await app.accessibility.snapshot(window: .number(window)).node(setText.key) }
                guard let node else { return }
                try await app.input.replaceText(in: target, field: CGRect(x: node.x, y: node.y, width: node.w, height: node.h),
                                                with: setText.value, timeout: Self.setTextTimeout)
            case .viewport, .menuAction, .requestControl:
                return
            }
        } catch {
            eventSink.yield(.failed("\(message.type) from viewer \(viewer): \(error)"))
        }
        runtime.requestRefresh()
    }

    // MARK: HTTP

    /// A response for a GET (or HEAD) of `path`, or nil when it's not one of the server's files.
    fileprivate func file(_ path: String) -> (type: String, body: Data)? {
        let assets = configuration.assets
        switch path {
        case MirrorProtocol.viewerPagePath: return ("text/html; charset=utf-8", assets.page)
        case MirrorProtocol.viewerScriptPath: return ("text/javascript; charset=utf-8", assets.script)
        case MirrorProtocol.viewerStylePath: return ("text/css; charset=utf-8", assets.style)
        case MirrorProtocol.iconPath: return assets.icon.map { ("image/png", $0) }
        default: return nil
        }
    }

    /// The window's full current frame as PNG (`window` nil: the main window). Nil when there is no
    /// such window or no frame yet.
    public func snapshotPNG(window: MirrorProtocol.WindowID?) async -> Data? {
        guard let capture = try? await loop.submit({ () -> (any MirrorCapture)? in
            guard let id = window ?? self.windows.first?.id else { return nil }
            return self.captures[id]
        }).get(), let frame = await capture.fullFrame() else { return nil }
        return Self.png(frame)
    }

    /// Paints a frame's tiles into one image and encodes it as PNG.
    static func png(_ frame: CapturedFrame) -> Data? {
        let width = Int((Double(frame.width) * frame.scale).rounded()), height = Int((Double(frame.height) * frame.scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for tile in frame.tiles {
            guard let source = CGImageSourceCreateWithData(tile.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let rect = CGRect(x: Double(tile.x) * frame.scale, y: Double(height) - Double(Int(tile.y) + Int(tile.h)) * frame.scale,
                              width: Double(tile.w) * frame.scale, height: Double(tile.h) * frame.scale)
            context.draw(image, in: rect)
        }
        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Whether a page from the request's `Origin` may open the WebSocket. Pages can open WebSockets
    /// to any address, so a page on another site in the host's own browser must not drive the app:
    /// allowed are requests without an Origin (not from a page), loopback pages (the host's own
    /// browser, CollabProxy's local address), the request's own host (a share's public URL, through
    /// CollabProxy) and `allowedOrigins`.
    static func acceptsOrigin(_ head: HTTPRequestHead, allowed: Set<String>) -> Bool {
        guard let origin = head.headers.first(name: "origin") else { return true }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return true }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        if let requestHost = head.headers.first(name: "host")?.lowercased(), requestHost == authority { return true }
        return allowed.contains { $0.lowercased() == origin.lowercased() }
    }

    private func configurePipeline(_ channel: Channel) throws {
        let key = ObjectIdentifier(channel)
        connections[key] = channel
        channel.closeFuture.whenComplete { [weak self] _ in self?.connections[key] = nil }
        let sync = channel.pipeline.syncOperations
        let encoder = HTTPResponseEncoder()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let pipelining = HTTPServerPipelineHandler()
        let errors = HTTPServerProtocolErrorHandler()
        try sync.addHandler(encoder)
        try sync.addHandler(decoder)
        try sync.addHandler(pipelining)
        try sync.addHandler(errors)
        try sync.addHandler(MirrorHTTPHandler(server: self, encoder: encoder, decoder: decoder, downstream: [pipelining, errors]))
    }
}

// MARK: - HTTP handler

/// Serves the viewer files and the snapshot, and switches `/__opentraffic/macapp/ws` to a WebSocket
/// on any request of a connection (not only the first, as NIO's upgrader would).
private final class MirrorHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: MirrorServer
    private let encoder: RemovableChannelHandler
    private let decoder: RemovableChannelHandler
    private let downstream: [RemovableChannelHandler]
    private var request: HTTPRequestHead?
    private var upgraded = false

    init(server: MirrorServer, encoder: RemovableChannelHandler, decoder: RemovableChannelHandler, downstream: [RemovableChannelHandler]) {
        self.server = server
        self.encoder = encoder
        self.decoder = decoder
        self.downstream = downstream
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !upgraded else { return }
        switch unwrapInboundIn(data) {
        case .head(let head): request = head
        case .body: break
        case .end:
            guard let head = request else { return }
            request = nil
            route(head, context: context)
        }
    }

    private func route(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = String(head.uri.prefix { $0 != "?" && $0 != "#" })
        let isUpgrade = head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
        if isUpgrade {
            guard path == MirrorProtocol.webSocketPath, head.method == .GET,
                  head.headers.first(name: "upgrade")?.lowercased() == "websocket",
                  head.headers.first(name: "sec-websocket-version") == "13",
                  let key = head.headers.first(name: "sec-websocket-key"), !key.isEmpty else {
                return respond(head, context: context, status: path == MirrorProtocol.webSocketPath ? .badRequest : .notFound, close: true)
            }
            guard MirrorServer.acceptsOrigin(head, allowed: server.allowedOrigins) else {
                return respond(head, context: context, status: .forbidden, close: true)
            }
            return upgrade(head, key: key, context: context)
        }
        guard head.method == .GET || head.method == .HEAD else {
            return respond(head, context: context, status: .methodNotAllowed)
        }
        if path == MirrorProtocol.snapshotPath {
            let window = URLComponents(string: head.uri)?.queryItems?.first { $0.name == "window" }?.value.flatMap { MirrorProtocol.WindowID($0) }
            let promise = context.eventLoop.makePromise(of: Data?.self)
            promise.completeWithTask { [server] in await server.snapshotPNG(window: window) }
            promise.futureResult.assumeIsolated().whenSuccess { [self] png in
                if let png {
                    respond(head, context: context, status: .ok, type: "image/png", body: png)
                } else {
                    respond(head, context: context, status: .notFound)
                }
            }
            return
        }
        if let file = server.file(path) {
            return respond(head, context: context, status: .ok, type: file.type, body: file.body)
        }
        respond(head, context: context, status: .notFound)
    }

    private func respond(_ head: HTTPRequestHead, context: ChannelHandlerContext, status: HTTPResponseStatus,
                         type: String = "text/plain; charset=utf-8", body: Data? = nil, close: Bool = false) {
        let body = body ?? Data((status == .ok ? "" : "\(status.code) \(status.reasonPhrase)\n").utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: type)
        headers.add(name: "content-length", value: String(body.count))
        headers.add(name: "cache-control", value: "no-store")
        headers.add(name: "x-content-type-options", value: "nosniff")
        let keepAlive = head.isKeepAlive && !close
        if !keepAlive { headers.add(name: "connection", value: "close") }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
        if head.method != .HEAD, !body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))), promise: nil)
        }
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive { done.assumeIsolated().whenComplete { _ in context.close(promise: nil) } }
    }

    private func upgrade(_ head: HTTPRequestHead, key: String, context: ChannelHandlerContext) {
        upgraded = true
        var headers = HTTPHeaders()
        headers.add(name: "upgrade", value: "websocket")
        headers.add(name: "connection", value: "Upgrade")
        headers.add(name: "sec-websocket-accept", value: CollabProxy.webSocketAccept(for: key))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .switchingProtocols, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { [self] result in
            guard case .success = result else { return context.close(promise: nil) }
            let socket = MirrorSocketHandler(server: server)
            do {
                let sync = context.pipeline.syncOperations
                for handler in downstream { _ = sync.removeHandler(handler) }
                try sync.addHandler(WebSocketFrameEncoder(), position: .first)
                try sync.addHandlers([
                    ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: MirrorServer.maximumClientMessageBytes)),
                    WebSocketProtocolErrorHandler(),
                    NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: 64,
                                                maxAccumulatedFrameSize: MirrorServer.maximumClientMessageBytes),
                    socket,
                ])
                _ = sync.removeHandler(context: context)
                _ = sync.removeHandler(decoder)
                _ = sync.removeHandler(encoder)
            } catch {
                return context.close(promise: nil)
            }
            // The HTTP encoder is gone only once the removals above have run: greet after that.
            context.eventLoop.assumeIsolated().execute { socket.begin() }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - WebSocket handler

/// One viewer's WebSocket: text messages in, everything else from the server.
private final class MirrorSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: MirrorServer
    private var context: ChannelHandlerContext?
    private var id: Int?
    private var keepAlive: RepeatedTask?
    private var closing = false

    init(server: MirrorServer) { self.server = server }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    /// Registers the viewer (which greets it) and keeps the connection alive through proxies
    /// (Cloudflare drops WebSockets idle for 100 seconds).
    func begin() {
        guard let context, context.channel.isActive, id == nil else { return }
        id = server.clientConnected(context.channel)
        let channel = context.channel
        keepAlive = context.eventLoop.scheduleRepeatedTask(initialDelay: MirrorServer.pingInterval, delay: MirrorServer.pingInterval) { _ in
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            guard let id else { return }
            server.clientSent(id, Data(frame.unmaskedData.readableBytesView))
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            guard !closing else { return context.close(promise: nil) }
            closing = true
            var data = context.channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: .normalClosure)
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)))
                .assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let id { server.clientWritable(id) }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        keepAlive?.cancel()
        keepAlive = nil
        if let id {
            self.id = nil
            server.clientDisconnected(id)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

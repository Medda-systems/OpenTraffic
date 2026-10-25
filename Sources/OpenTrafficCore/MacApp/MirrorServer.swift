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
    /// Brings a window to the front as the app's key window (`windowAction` `focus`).
    func raise(window: UInt32) async throws
    /// Closes a window like its close button, or cancels a popover (`windowAction` `close`).
    func close(window: UInt32) async throws
    /// Sets a window's size (AXSize) and returns the size it took (the app may keep a minimum or a
    /// maximum), or nil when the bridge can't resize windows.
    func resize(window: UInt32, to size: CGSize) async throws -> CGSize?
}

extension MirrorAccessibility {
    public func raise(window: UInt32) async throws {}
    public func close(window: UInt32) async throws {}
    public func resize(window: UInt32, to size: CGSize) async throws -> CGSize? { nil }
}

// MARK: - The host's viewer options

/// What the host decided about the viewers of a shared Mac app (the live card's options, saved with
/// the share): who may control it, its appearance and its window size.
public struct MacAppViewerOptions: Codable, Hashable, Sendable {
    /// The app's light or dark appearance.
    public enum Appearance: String, Codable, Sendable, CaseIterable {
        /// The first viewer's `prefers-color-scheme` (the app restarts once if it differs from this Mac's).
        case viewer
        /// This Mac's appearance.
        case mac
        case light
        case dark
    }

    /// The main window's size.
    public enum WindowSize: String, Codable, Sendable, CaseIterable {
        /// Resized to fill the leading viewer's browser (within the app's minimum and the off-screen display).
        case fitViewer
        /// The size the app gives it; viewers scale it down to fit.
        case app
    }

    public var control: MirrorProtocol.ControlMode
    public var appearance: Appearance
    public var windowSize: WindowSize

    public init(control: MirrorProtocol.ControlMode = .everyone, appearance: Appearance = .viewer, windowSize: WindowSize = .fitViewer) {
        self.control = control; self.appearance = appearance; self.windowSize = windowSize
    }

    private enum CodingKeys: String, CodingKey { case control, appearance, windowSize }
    /// Unknown or missing values fall back to the defaults, so a newer file still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        control = (try? c.decodeIfPresent(MirrorProtocol.ControlMode.self, forKey: .control)) ?? .everyone
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? .viewer
        windowSize = (try? c.decodeIfPresent(WindowSize.self, forKey: .windowSize)) ?? .fitViewer
    }
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
/// Every window the app shows is mirrored as its own surface with its own capture, tree and input:
/// the main window, second windows and panels (`window`), app-modal alerts (`alert`), and the sheets,
/// sheet alerts and popovers inside a window's tree that are windows of their own (`sheet`, `alert`,
/// `popover`, with that window as `parent`), and a popped-up menu (`menu`). Positions are relative to
/// the main window; node keys are unique across windows (`MirrorProtocol.NodeKey`).
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
        /// The simulated device an iPhone app runs on (sent in `hello`); nil for a Mac app.
        public var device: MirrorProtocol.Device?

        public init(name: String, boot: String = UUID().uuidString, accessibility: any MirrorAccessibility, input: any MirrorInput,
                    menus: (any MirrorMenus)? = nil, device: MirrorProtocol.Device? = nil,
                    makeCapture: @escaping @Sendable (CGWindowID) -> any MirrorCapture) {
            self.name = name; self.boot = boot; self.accessibility = accessibility; self.input = input; self.menus = menus
            self.device = device
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
        /// Who may control the app and how its window is sized (`setViewerOptions` changes them later).
        public var options: MacAppViewerOptions
        /// The largest size a viewer's viewport may give the main window: what fits on the off-screen
        /// display where the hider puts it.
        public var maximumWindowSize: CGSize
        /// Whether a global frame would show on a screen people look at: a resize that would put the
        /// main window there isn't made (the session passes `OffscreenDisplay.isVisible`).
        public var isOnScreen: @Sendable (CGRect) -> Bool

        public init(app: App, assets: Assets, appearance: MirrorProtocol.Appearance = MirrorServer.hostAppearance(),
                    scale: Double? = nil, allowedOrigins: Set<String> = [], options: MacAppViewerOptions = .init(),
                    maximumWindowSize: CGSize = MirrorServer.defaultMaximumWindowSize,
                    isOnScreen: @escaping @Sendable (CGRect) -> Bool = { _ in false }) {
            self.app = app; self.assets = assets; self.appearance = appearance; self.scale = scale; self.allowedOrigins = allowedOrigins
            self.options = options; self.maximumWindowSize = maximumWindowSize; self.isOnScreen = isOnScreen
        }
    }

    /// The off-screen display less the hider's margin (windows sit 40 pt in and 60 pt down, cascading).
    public static let defaultMaximumWindowSize = CGSize(width: OffscreenDisplay.pointSize.width - 80,
                                                         height: OffscreenDisplay.pointSize.height - 100)
    /// The smallest main window a viewport asks for (an app's own minimum may be larger).
    public static let minimumViewportSize = CGSize(width: 200, height: 150)

    /// Who may control the app now, for the host's card.
    public struct ControlState: Equatable, Sendable {
        /// A viewer asking for control (`askToControl`), with the name its page gave.
        public struct Request: Equatable, Sendable, Identifiable {
            public var viewer: Int
            public var name: String?
            public var id: Int { viewer }
        }
        /// The viewer the host gave control; `connected` is false while its page is away (it gets
        /// control back when it reconnects, until the host takes it back).
        public struct Holder: Equatable, Sendable {
            public var viewer: Int?
            public var name: String?
            public var connected: Bool
        }
        public var mode: MirrorProtocol.ControlMode
        public var holder: Holder?
        /// Oldest first.
        public var requests: [Request]

        public init(mode: MirrorProtocol.ControlMode, holder: Holder? = nil, requests: [Request] = []) {
            self.mode = mode; self.holder = holder; self.requests = requests
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
        /// Who may control the app changed: the mode, a viewer asked, the host allowed or took back.
        case control(ControlState)
        /// The leading viewer's color scheme, when it becomes known or changes (the session decides
        /// whether the app's appearance follows).
        case viewerAppearance(MirrorProtocol.Appearance)
    }

    /// Menu reads start at most this often (the bar is read whole, so less often than trees)...
    public static let menuInterval: Duration = .milliseconds(100)
    /// ...and after a right click, this often for `menuWatch`, until the app's context menu shows.
    static let menuWatchStep: Duration = .milliseconds(100)
    static let menuWatch: Duration = .milliseconds(1500)
    /// Extra tree reads after a menu action (each delay counted from the one before).
    static let menuActionRefreshes: [Duration] = [.milliseconds(150), .milliseconds(350)]
    /// Extra reads after a press or a click: sheets, popovers and windows open with an animation,
    /// and not every app announces them.
    static let pressRefreshes: [Duration] = [.milliseconds(200), .milliseconds(400)]
    /// Windows smaller than this (points, either side) aren't mirrored: what is left of a closing
    /// popover, invisible helper windows.
    static let minimumWindowSide: Double = 8
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
    /// A resize waits this long for more viewport changes (a browser window being dragged larger).
    static let resizeSettle: Duration = .milliseconds(150)

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
    /// Every mirrored window's key root and global frame, for input and key translation.
    private var mirrored: [MirrorProtocol.WindowID: MirroredWindow] = [:]
    /// The latest snapshot per window, its keys as the viewers see them (under the window's root).
    private var snapshots: [MirrorProtocol.WindowID: AXSnapshot] = [:]
    /// The latest `tree` message per window, encoded once.
    private var treeTexts: [MirrorProtocol.WindowID: String] = [:]
    private var captures: [MirrorProtocol.WindowID: any MirrorCapture] = [:]
    private var scale: Double?
    private var status = MirrorProtocol.Status(state: .running)
    /// The latest `menu` message, encoded once (nil until the menus were read, or without menus).
    private var menuText: String?
    /// The host's options (control mode, window size).
    private var options: MacAppViewerOptions
    /// The app's appearance, for `hello`.
    private var appearance: MirrorProtocol.Appearance
    /// `askToControl`: who the host gave control.
    private var grant: Grant?
    private var requestCount = 0
    /// The leading viewer's color scheme last reported.
    private var reportedAppearance: MirrorProtocol.Appearance?

    /// Control given to a viewer: its connection, and the id its page keeps across reconnects.
    private struct Grant {
        var viewer: Int?
        var client: String?
        var name: String?
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        app = configuration.app
        options = configuration.options
        appearance = configuration.appearance
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

    // MARK: Viewer options and control

    /// Applies the host's options: a new control mode takes control from whoever had it and drops
    /// waiting requests (every viewer is told); a new window size resizes the main window (`app`
    /// gives it back the size it had). The appearance is the session's (it needs a relaunch).
    public func setViewerOptions(_ options: MacAppViewerOptions) {
        loop.execute {
            let old = self.options
            self.options = options
            if old.control != options.control {
                self.grant = nil
                for client in self.clients.values { client.requested = nil }
                self.controlChanged()
            }
            if old.windowSize != options.windowSize { self.requestResize() }
        }
    }

    /// The options in force.
    public func viewerOptions() async -> MacAppViewerOptions {
        (try? await loop.submit { self.options }.get()) ?? configuration.options
    }

    /// `askToControl`: gives control to a viewer that asked (or any connected viewer); whoever had it
    /// loses it. Its window size then leads.
    public func allowControl(viewer: Int) {
        loop.execute {
            guard self.options.control == .askToControl, let client = self.clients[viewer] else { return }
            self.grant = Grant(viewer: viewer, client: client.token, name: client.name)
            client.requested = nil
            self.controlChanged()
            self.requestResize()
        }
    }

    /// `askToControl`: turns down a viewer's request (it may ask again).
    public func denyControl(viewer: Int) {
        loop.execute {
            guard let client = self.clients[viewer], client.requested != nil else { return }
            client.requested = nil
            self.controlChanged()
        }
    }

    /// `askToControl`: takes control back from the viewer who has it; only the host controls the app.
    public func revokeControl() {
        loop.execute {
            guard self.grant != nil else { return }
            self.grant = nil
            self.controlChanged()
            self.requestResize()
        }
    }

    /// Who may control the app now.
    public func controlState() async -> ControlState {
        (try? await loop.submit { self.currentControlState() }.get()) ?? ControlState(mode: configuration.options.control)
    }

    /// The app's appearance for `hello` (set by the session before it launches the app with it).
    public func setAppearance(_ appearance: MirrorProtocol.Appearance) {
        loop.execute { self.appearance = appearance }
    }

    /// Reads the windows and trees again soon (coalesced like change notifications).
    public func refreshSoon() {
        shared.withLock { $0.runtime }?.requestRefresh()
    }

    /// The windows viewers see now (the latest `windows` list), main first.
    public func currentWindows() async -> [MirrorProtocol.WindowInfo] {
        (try? await loop.submit { self.windows }.get()) ?? []
    }

    // MARK: Replaying after a relaunch

    /// Where a viewer's action is aimed in the app as viewers see it now: its window's key root and
    /// the element (the action's key, or the deepest element under a pointer event) with its frame.
    /// Nil when it names no mirrored window. The session records this with the action, for a replay.
    public func replayTarget(for message: MirrorProtocol.ClientMessage) async -> MacAppReplay.Target? {
        guard let window = message.window else { return nil }
        return try? await loop.submit { () -> MacAppReplay.Target? in
            guard let mirrored = self.mirrored[window] else { return nil }
            let nodes = self.snapshots[window]?.nodes ?? []
            func frame(_ node: MirrorProtocol.AXNode) -> CGRect { CGRect(x: node.x, y: node.y, width: node.w, height: node.h) }
            switch message {
            case .act(let act):
                return MacAppReplay.Target(windowRoot: mirrored.root, key: act.key, frame: nodes.first { $0.key == act.key }.map(frame))
            case .setText(let setText):
                return MacAppReplay.Target(windowRoot: mirrored.root, key: setText.key, frame: nodes.first { $0.key == setText.key }.map(frame))
            case .pointer(let pointer):
                let node = MacAppReplay.element(at: CGPoint(x: pointer.x, y: pointer.y), in: nodes)
                return MacAppReplay.Target(windowRoot: mirrored.root, key: node?.key, frame: node.map(frame))
            default:
                return MacAppReplay.Target(windowRoot: mirrored.root)
            }
        }.get() ?? nil
    }

    /// The windows viewers see now with every element's key and frame (empty until a launch is live).
    public func replayWindows() async -> [MacAppReplay.Window] {
        (try? await loop.submit { () -> [MacAppReplay.Window] in
            guard self.live else { return [] }
            return self.windows.compactMap { info in
                guard let mirrored = self.mirrored[info.id], let snapshot = self.snapshots[info.id] else { return nil }
                var nodes: [String: CGRect] = [:]
                for node in snapshot.nodes { nodes[node.key] = CGRect(x: node.x, y: node.y, width: node.w, height: node.h) }
                return MacAppReplay.Window(id: info.id, root: mirrored.root, nodes: nodes)
            }
        }.get()) ?? []
    }

    /// Applies an action as the host's own (whatever the control mode), in order with viewers'
    /// input. It isn't reported as a viewer message, so the session doesn't record it again.
    public func replay(_ message: MirrorProtocol.ClientMessage) {
        guard MacAppSession.isRecorded(message) else { return }
        inboxSink.yield((0, message))
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
        /// Requests to size the main window for the leading viewer (coalesced).
        let sizeSignals: AsyncStream<Void>
        private let sizeSignal: AsyncStream<Void>.Continuation

        struct State {
            var tasks: [Task<Void, Never>] = []
            var captures: [MirrorProtocol.WindowID: any MirrorCapture] = [:]
            var failedAt: [MirrorProtocol.WindowID: ContinuousClock.Instant] = [:]
            var mainID: MirrorProtocol.WindowID?
            var sentV: [MirrorProtocol.WindowID: String] = [:]
            /// The main window's global frame, for placing a popped-up menu relative to it.
            var mainFrame: CGRect?
            /// Every mirrored window's global frame, for placing a popped-up menu.
            var frames: [MirrorProtocol.WindowID: CGRect] = [:]
            /// The sheets and popovers each window had at the last good read, kept while a read fails.
            var surfaces: [MirrorProtocol.WindowID: [MirroredWindow]] = [:]
            /// The popped-up menu's window (number and global frame), from the menu reads.
            var menuWindow: (id: MirrorProtocol.WindowID, frame: CGRect)?
            /// Where the last right click was (window, window-relative point), for a menu without a frame.
            var rightClick: (window: MirrorProtocol.WindowID, point: CGPoint)?
            /// Until when menu reads are requested often (after a right click or showMenu).
            var menuWatchUntil: ContinuousClock.Instant?
            /// The main window's size before a viewport changed it (given back for `WindowSize.app`).
            var appSize: CGSize?
            /// The smallest size the app let its main window take, learned from resizes it refused.
            var minimumSize: CGSize = .zero
            /// The last resize: the size asked for and the size the window took.
            var lastResize: (asked: CGSize, got: CGSize)?
            var stopped = false
        }
        let state = OSAllocatedUnfairLock(initialState: State())

        init(app: App, generation: Int) {
            self.app = app
            self.generation = generation
            (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            (menuSignals, menuSignal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            (sizeSignals, sizeSignal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        }

        func requestRefresh() { signal.yield() }
        func requestMenuRefresh() { menuSignal.yield() }
        func requestResize() { sizeSignal.yield() }

        /// Reads again after each delay (counted from the one before), for changes that come late.
        func refresh(after delays: [Duration]) {
            add(Task { [weak self] in
                for delay in delays {
                    try? await Task.sleep(for: delay)
                    self?.requestRefresh()
                }
            })
        }

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
            sizeSignal.finish()
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
            self.mirrored = [:]
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
            guard let runtime else { return }
            await self?.sizeLoop(runtime)
        })
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
        // A new launch opens its window at the app's own size: size it for the leading viewer again.
        runtime.requestResize()
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
        /// The key of the window's root node (`MirrorProtocol.NodeKey`): its nodes' keys start with it.
        var root: String
    }

    /// The app's top-level windows the viewers see, the main one first: the main window (kept while
    /// it exists, even when another window becomes main) as `main`, app-modal dialogs as `alert`
    /// (belonging to the main window), every other window (second windows, panels) as `window`.
    /// Positions are relative to the main window; minimized, untitled-number and tiny windows are left out.
    static func mirroredWindows(_ windows: [AccessibilityTree.Window], current: MirrorProtocol.WindowID?) -> [MirroredWindow] {
        let candidates = windows.filter { window in
            window.number != nil && !window.isMinimized && window.frame.width >= minimumWindowSide && window.frame.height >= minimumWindowSide
                && (window.role.isEmpty || window.role == "AXWindow") && !isTitleBarHelper(window, among: windows)
        }
        let isDialog = { (window: AccessibilityTree.Window) in window.subrole == "AXDialog" || window.subrole == "AXSystemDialog" }
        guard let main = candidates.first(where: { current != nil && $0.number == current })
            ?? candidates.first(where: { $0.isMain && !isDialog($0) }) ?? candidates.first(where: { $0.isFocused && !isDialog($0) })
            ?? candidates.first(where: { !isDialog($0) }) ?? candidates.first,
            let mainID = main.number else { return [] }
        let others = candidates.filter { $0.number != mainID }
        let roots = MirrorProtocol.NodeKey.windowRoots(titles: [main.title] + others.map(\.title))
        let origin = main.frame.origin
        return zip([main] + others, roots).map { window, root in
            let id = window.number!
            let kind: MirrorProtocol.WindowKind = id == mainID ? .main : isDialog(window) ? .alert : .window
            let info = MirrorProtocol.WindowInfo(id: id, title: window.title, w: window.frame.width, h: window.frame.height,
                                                 x: window.frame.minX - origin.x, y: window.frame.minY - origin.y, kind: kind,
                                                 parent: kind == .alert ? mainID : nil)
            return MirroredWindow(info: info, frame: window.frame, root: root)
        }
    }

    /// macOS (15 and later) keeps an invisible helper window over every titled window's title bar
    /// buttons, for the tiling menu that shows when the pointer rests there: 66 by 20 points at the
    /// window's top-left, one button, no close button, subrole AXDialog, titled "Window". It is in
    /// AXWindows like a window; listed as one it would be an alert on the main window that never
    /// closes and takes the focus. A short window without a close button over another window's
    /// title bar is such a helper.
    static func isTitleBarHelper(_ window: AccessibilityTree.Window, among windows: [AccessibilityTree.Window]) -> Bool {
        guard !window.hasCloseButton, window.frame.height <= 32 else { return false }
        return windows.contains { other in
            other.number != window.number && other.frame.height > 32 && other.frame.contains(window.frame)
                && window.frame.minY - other.frame.minY <= 16
        }
    }

    /// The kind of a sheet or popover found in a window's tree: a sheet that is an alert (AppKit and
    /// SwiftUI alerts are sheets described as `alert`) is an `alert`.
    static func kind(of surface: AXSnapshot.Surface) -> MirrorProtocol.WindowKind {
        if surface.role == "AXPopover" { return .popover }
        let alert = surface.description.lowercased() == "alert" || surface.subrole == "AXDialog" || surface.subrole == "AXSystemDialog"
        return alert ? .alert : .sheet
    }

    /// A sheet or popover of `parent` as a mirrored window, nil when it is too small to see.
    static func surfaceWindow(_ surface: AXSnapshot.Surface, of parent: MirroredWindow, origin: CGPoint) -> MirroredWindow? {
        let frame = surface.frame
        guard frame.width >= minimumWindowSide, frame.height >= minimumWindowSide else { return nil }
        let info = MirrorProtocol.WindowInfo(id: surface.number, title: "", w: frame.width, h: frame.height,
                                             x: frame.minX - origin.x, y: frame.minY - origin.y, kind: kind(of: surface), parent: parent.info.id)
        return MirroredWindow(info: info, frame: frame, root: MirrorProtocol.NodeKey.rebase(surface.key, onto: parent.root))
    }

    /// A popped-up menu as a mirrored window, belonging to the window it was opened in.
    static func menuWindow(id: MirrorProtocol.WindowID, frame: CGRect, parent: MirrorProtocol.WindowID, origin: CGPoint) -> MirroredWindow? {
        guard frame.width >= minimumWindowSide, frame.height >= minimumWindowSide else { return nil }
        let info = MirrorProtocol.WindowInfo(id: id, title: "", w: frame.width, h: frame.height, x: frame.minX - origin.x,
                                             y: frame.minY - origin.y, kind: .menu, parent: parent)
        return MirroredWindow(info: info, frame: frame, root: "/Menu:")
    }

    /// Which window has the app's focus: the focused window (else the main one) of the app, or the
    /// sheet or alert on it, which takes the focus while it is up.
    static func focusedWindow(_ windows: [AccessibilityTree.Window], mirrored: [MirroredWindow]) -> MirrorProtocol.WindowID? {
        guard let key = windows.first(where: \.isFocused)?.number ?? windows.first(where: \.isMain)?.number,
              mirrored.contains(where: { $0.info.id == key }) else { return nil }
        var focused = key
        // A sheet on a sheet: follow them down.
        while let sheet = mirrored.last(where: { $0.info.parent == focused && ($0.info.kind == .sheet || $0.info.kind == .alert) }) {
            focused = sheet.info.id
        }
        return focused
    }

    /// The snapshot with its keys moved under the window's root (the bridge reads every window as `/Window:`).
    static func rebased(_ snapshot: AXSnapshot, root: String) -> AXSnapshot {
        guard root != MirrorProtocol.NodeKey.root else { return snapshot }
        var nodes = snapshot.nodes
        for index in nodes.indices { nodes[index].key = MirrorProtocol.NodeKey.rebase(nodes[index].key, onto: root) }
        let surfaces = snapshot.surfaces.map { surface in
            var surface = surface
            surface.key = MirrorProtocol.NodeKey.rebase(surface.key, onto: root)
            return surface
        }
        return AXSnapshot(windowNumber: snapshot.windowNumber, title: snapshot.title, frame: snapshot.frame, nodes: nodes, surfaces: surfaces)
    }

    /// One window as the viewers see it: its `windows` entry, its key root, and its snapshot with the
    /// keys viewers (and comments pinned by them) use.
    public struct ViewerWindow: Sendable {
        public var info: MirrorProtocol.WindowInfo
        public var root: String
        public var snapshot: AXSnapshot
    }

    /// Reads every window of an app as a mirror shows it, without a server: the top-level windows
    /// (`current` is the mirror's main window, so the key roots match what viewers got; nil picks the
    /// app's main window) and the sheets, alerts and popovers in them, in the `windows` list's order,
    /// each snapshot's keys under its root. Popped-up menus aren't included (they have no tree).
    /// `MirrorProtocol.NodeKey.unrebase(key, from: root)` gives a node's key as `accessibility` knows it.
    public static func readWindows(_ accessibility: any MirrorAccessibility, current: MirrorProtocol.WindowID? = nil) async throws -> [ViewerWindow] {
        let axWindows = try await accessibility.windows()
        let tops = mirroredWindows(axWindows, current: current)
        let origin = tops.first?.frame.origin ?? .zero
        var mirrored: [MirroredWindow] = []
        var snapshots: [MirrorProtocol.WindowID: AXSnapshot] = [:]
        func read(_ window: MirroredWindow, depth: Int) async {
            guard snapshots[window.info.id] == nil, !mirrored.contains(where: { $0.info.id == window.info.id }) else { return }
            mirrored.append(window)
            guard let raw = try? await accessibility.snapshot(window: .number(window.info.id)) else { return }
            let snapshot = rebased(raw, root: window.root)
            snapshots[window.info.id] = snapshot
            guard depth < 4 else { return }
            for child in snapshot.surfaces.compactMap({ surfaceWindow($0, of: window, origin: origin) }) { await read(child, depth: depth + 1) }
        }
        for window in tops { await read(window, depth: 0) }
        let focused = focusedWindow(axWindows, mirrored: mirrored)
        return mirrored.compactMap { window in
            guard let snapshot = snapshots[window.info.id] else { return nil }
            var info = window.info
            info.focused = info.id == focused
            return ViewerWindow(info: info, root: window.root, snapshot: snapshot)
        }
    }

    /// Reads the window list and every mirrored window's tree, and hands what changed to the viewers.
    /// Sheets and popovers come out of their window's tree and are read in turn, right after it.
    @discardableResult
    private func refresh(_ runtime: Runtime) async throws -> [MirroredWindow] {
        let accessibility = runtime.app.accessibility
        let (current, menuWindow, rightClick) = runtime.state.withLock { ($0.mainID, $0.menuWindow, $0.rightClick) }
        let axWindows = try await accessibility.windows()
        let tops = Self.mirroredWindows(axWindows, current: current)
        let origin = tops.first?.frame.origin ?? .zero
        var mirrored: [MirroredWindow] = []
        var trees: [(MirrorProtocol.WindowID, AXSnapshot, String?)] = []
        var surfacesByParent: [MirrorProtocol.WindowID: [MirroredWindow]] = [:]
        var seen: Set<MirrorProtocol.WindowID> = []

        func read(_ window: MirroredWindow, depth: Int) async {
            guard seen.insert(window.info.id).inserted else { return }
            mirrored.append(window)
            let id = window.info.id
            var children: [MirroredWindow]
            if let read = try? await accessibility.snapshot(window: .number(id)) {
                let snapshot = Self.rebased(read, root: window.root)
                let changed = runtime.state.withLock { state -> Bool in
                    defer { state.sentV[id] = snapshot.v }
                    return state.sentV[id] != snapshot.v
                }
                let text = changed ? try? MirrorProtocol.ServerMessage.tree(snapshot.tree(window: id)).jsonString() : nil
                trees.append((id, snapshot, text))
                children = snapshot.surfaces.compactMap { Self.surfaceWindow($0, of: window, origin: origin) }
            } else {
                // A read that failed (the app busy) keeps the sheets and popovers it had.
                children = runtime.state.withLock { $0.surfaces[id] } ?? []
            }
            surfacesByParent[id] = children
            guard depth < 4 else { return }
            for child in children { await read(child, depth: depth + 1) }
        }
        for window in tops { await read(window, depth: 0) }
        if let menu = menuWindow, !seen.contains(menu.id) {
            let parent = rightClick.flatMap { click in seen.contains(click.window) ? click.window : nil } ?? tops.first?.info.id
            if let parent, let window = Self.menuWindow(id: menu.id, frame: menu.frame, parent: parent, origin: origin) { mirrored.append(window) }
        }
        let focused = Self.focusedWindow(axWindows, mirrored: mirrored)
        for index in mirrored.indices { mirrored[index].info.focused = mirrored[index].info.id == focused }

        let frames = Dictionary(mirrored.map { ($0.info.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let surfaces = surfacesByParent
        runtime.state.withLock { state in
            state.mainID = tops.first?.info.id
            state.mainFrame = tops.first?.frame
            state.frames = frames
            state.surfaces = surfaces
            state.sentV = state.sentV.filter { frames[$0.key] != nil }
        }
        let generation = runtime.generation
        let all = mirrored
        let read = trees
        try await loop.submit { self.update(generation: generation, windows: all, trees: read) }.get()
        return mirrored
    }

    /// On the loop: takes a refresh's results and sends viewers the window list and trees that changed.
    private func update(generation: Int, windows mirrored: [MirroredWindow], trees: [(MirrorProtocol.WindowID, AXSnapshot, String?)]) {
        guard generation == self.generation else { return }
        var texts: [String] = []
        self.mirrored = Dictionary(mirrored.map { ($0.info.id, $0) }, uniquingKeysWith: { a, _ in a })
        let windows = mirrored.map(\.info)
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
            let (mainID, frames, click, menuChanged) = runtime.state.withLock { state in
                // The menu's own window is mirrored too (kind `menu`): a new or closed one reads the windows again.
                let window = open.flatMap { open in open.window.flatMap { id in open.windowFrame.map { (id: id, frame: $0) } } }
                let changed = window?.id != state.menuWindow?.id || window?.frame != state.menuWindow?.frame
                state.menuWindow = window
                return (state.mainID, state.frames, state.rightClick, changed)
            }
            if menuChanged { runtime.requestRefresh() }
            let context = Self.contextMenu(open, mainID: mainID, frames: frames, rightClick: click)
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

    /// The protocol's context menu for a popped-up menu: placed relative to the window it was opened
    /// in (the right-clicked one while it is mirrored, else the main window), at the menu's own
    /// top-left (or the right click when the menu has no frame).
    static func contextMenu(_ open: MenuBridge.OpenMenu?, mainID: MirrorProtocol.WindowID?, frames: [MirrorProtocol.WindowID: CGRect],
                            rightClick: (window: MirrorProtocol.WindowID, point: CGPoint)?) -> MirrorProtocol.ContextMenu? {
        let clicked = rightClick.flatMap { frames[$0.window] != nil ? $0.window : nil }
        guard let open, !open.items.isEmpty, let window = clicked ?? mainID ?? rightClick?.window else { return nil }
        if let frame = frames[window], open.frame.width > 0, open.frame.height > 0 {
            return .init(window: window, x: (open.frame.minX - frame.minX).rounded(), y: (open.frame.minY - frame.minY).rounded(),
                         items: open.items)
        }
        let point = rightClick?.point ?? .zero
        return .init(window: rightClick?.window ?? window, x: point.x, y: point.y, items: open.items)
    }

    // MARK: The main window's size

    /// Sizes the main window for the leading viewer on request (coalesced, after `resizeSettle`),
    /// or gives it back its own size when the host chose `WindowSize.app`.
    private func sizeLoop(_ runtime: Runtime) async {
        for await _ in runtime.sizeSignals {
            try? await Task.sleep(for: Self.resizeSettle)
            if Task.isCancelled || runtime.isStopped { return }
            let generation = runtime.generation
            let wanted = try? await loop.submit { () -> (current: Bool, size: CGSize?) in
                (self.generation == generation, self.wantedMainSize())
            }.get()
            guard let wanted, wanted.current else { continue }
            await resizeMain(to: wanted.size, in: runtime)
        }
    }

    /// The size the leading viewer's viewport asks for, nil when the window keeps the app's size.
    private func wantedMainSize() -> CGSize? {
        guard options.windowSize == .fitViewer, let viewport = leadingViewport() else { return nil }
        return Self.windowSize(for: viewport, maximum: configuration.maximumWindowSize)
    }

    /// The viewer whose size the main window follows: the one the host gave control (`askToControl`),
    /// else the first viewer still connected, of those with a size wish.
    private func leadingViewport() -> MirrorProtocol.Viewport? {
        let sized = clients.values.filter { ($0.viewport?.w ?? 0) > 0 && ($0.viewport?.h ?? 0) > 0 }
        if options.control == .askToControl, let holder = grant?.viewer, let client = sized.first(where: { $0.id == holder }) {
            return client.viewport
        }
        return sized.min { $0.id < $1.id }?.viewport
    }

    /// The main window's size for a viewport: whole points, at least `minimumViewportSize`, at most
    /// `maximum`. Nil for a viewport without a size wish (`0` by `0`).
    static func windowSize(for viewport: MirrorProtocol.Viewport, maximum: CGSize) -> CGSize? {
        guard viewport.w.isFinite, viewport.h.isFinite, viewport.w > 0, viewport.h > 0 else { return nil }
        let w = min(max(viewport.w.rounded(.down), minimumViewportSize.width), maximum.width)
        let h = min(max(viewport.h.rounded(.down), minimumViewportSize.height), maximum.height)
        return CGSize(width: w, height: h)
    }

    /// The size to ask the app for: the wish, but never below the minimum the app showed it keeps.
    static func target(_ want: CGSize, minimum: CGSize) -> CGSize {
        CGSize(width: max(want.width, minimum.width), height: max(want.height, minimum.height))
    }

    /// What a refused resize says about the app's minimum: a side the window kept larger than asked.
    static func learnedMinimum(asked: CGSize, got: CGSize, before: CGSize) -> CGSize {
        CGSize(width: got.width > asked.width + 0.5 ? max(before.width, got.width) : before.width,
               height: got.height > asked.height + 0.5 ? max(before.height, got.height) : before.height)
    }

    /// Resizes the main window through AXSize (second windows, sheets and popovers keep their size),
    /// remembering its own size the first time; `size` nil gives that size back.
    private func resizeMain(to size: CGSize?, in runtime: Runtime) async {
        let (mainID, frame, appSize, minimum, last) = runtime.state.withLock { state in
            (state.mainID, state.mainID.flatMap { state.frames[$0] }, state.appSize, state.minimumSize, state.lastResize)
        }
        guard let mainID, let frame else { return }
        let target: CGSize
        if let size {
            target = Self.target(size, minimum: minimum)
        } else if let appSize {
            target = appSize
        } else {
            return
        }
        let current = frame.size
        if abs(current.width - target.width) < 1, abs(current.height - target.height) < 1 {
            if size == nil { runtime.state.withLock { $0.appSize = nil } }
            return
        }
        // The app already turned this exact size down (a maximum, or a fixed size): don't ask again.
        if let last, last.asked == target, abs(last.got.width - current.width) < 1, abs(last.got.height - current.height) < 1 { return }
        // Never onto the host's screens: a window the app placed elsewhere on the display stays as it is.
        if configuration.isOnScreen(CGRect(origin: frame.origin, size: target)) {
            eventSink.yield(.failed("Didn't resize the window to \(Int(target.width))×\(Int(target.height)): it would reach a screen of this Mac."))
            return
        }
        do {
            guard let got = try await runtime.app.accessibility.resize(window: mainID, to: target) else { return }
            runtime.state.withLock { state in
                if size != nil, state.appSize == nil { state.appSize = current }
                if size == nil { state.appSize = nil }
                state.lastResize = (target, got)
                state.minimumSize = Self.learnedMinimum(asked: target, got: got, before: state.minimumSize)
            }
        } catch {
            eventSink.yield(.failed("Couldn't resize the window to \(Int(target.width))×\(Int(target.height)): \(error)"))
        }
        // The window list carries the new size; the capture sends a full frame of it by itself.
        runtime.requestRefresh()
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
        /// The viewer's latest `viewport`.
        var viewport: MirrorProtocol.Viewport?
        /// From `requestControl`: the name the host sees, and the id the page keeps across reconnects.
        var name: String?
        var token: String?
        /// `askToControl`: when (in request order) it asked for control and the host hasn't answered.
        var requested: Int?
        /// The `control` message it got last.
        var control: MirrorProtocol.Control?
        /// The host's own page (the share's proxy said so): it controls the app in every mode.
        let isHost: Bool

        init(id: Int, channel: Channel, isHost: Bool = false) { self.id = id; self.channel = channel; self.isHost = isHost }

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
        let hello = MirrorProtocol.Hello(boot: app.boot, scale: scale ?? configuration.scale ?? 2, appearance: appearance,
                                         app: .init(name: app.name, device: app.device), windows: windows)
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
        // Without a `control` message everyone controls, so it is only sent when that isn't so.
        if options.control != .everyone || client.control != nil { sendControl(client, flush: false) }
        for window in windows {
            if let text = treeTexts[window.id] { client.sendText(text, flush: false) }
        }
        if let menuText { client.sendText(menuText, flush: false) }
        client.flush()
        for window in windows { syncFrames(client, window: window.id) }
    }

    fileprivate func clientConnected(_ channel: Channel, isHost: Bool) -> Int {
        loop.preconditionInEventLoop()
        let id = nextClientID
        nextClientID += 1
        let client = Client(id: id, channel: channel, isHost: isHost)
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
        guard let client = clients.removeValue(forKey: id) else { return }
        let count = clients.count
        shared.withLock { $0.viewers = count }
        eventSink.yield(.viewerDisconnected(id: id, viewers: count))
        // A viewer with control keeps it while away if its page can say who it is when it comes back.
        var changed = client.requested != nil
        if let grant, grant.viewer == id {
            self.grant = grant.client == nil ? nil : Grant(viewer: nil, client: grant.client, name: grant.name)
            changed = true
        }
        if changed { controlChanged() }
        viewportsChanged()
    }

    /// The viewer's connection drained: windows it fell behind on restart from a full frame.
    fileprivate func clientWritable(_ id: Int) {
        loop.preconditionInEventLoop()
        guard let client = clients[id], !client.stale.isEmpty else { return }
        let windows = client.stale
        client.stale = []
        for window in windows { syncFrames(client, window: window) }
    }

    /// A text message from a viewer: decoded here, applied in order by the applier. Input from a
    /// viewer who may not control the app (`watchOnly`, or `askToControl` without control) is dropped
    /// here, as it arrives: it never reaches the app or the session's record.
    fileprivate func clientSent(_ id: Int, _ data: Data) {
        guard let message = try? MirrorProtocol.ClientMessage.decode(data) else { return } // unknown `t` or not JSON: ignored
        guard let client = clients[id] else { return }
        switch message {
        case .viewport(let viewport):
            eventSink.yield(.message(viewer: id, message, at: Date()))
            client.viewport = viewport
            viewportsChanged()
            return
        case .requestControl(let request):
            eventSink.yield(.message(viewer: id, message, at: Date()))
            requestControl(client, request)
            return
        case .releaseControl:
            eventSink.yield(.message(viewer: id, message, at: Date()))
            releaseControl(client)
            return
        case .act, .pointer, .text, .key, .setText, .menuAction, .windowAction:
            guard mayControl(client) else { return }
        }
        eventSink.yield(.message(viewer: id, message, at: Date()))
        if case .pointer(let pointer) = message, pointer.kind == .move { updateCursor(id, pointer) }
        inboxSink.yield((id, message))
    }

    // MARK: Control (on the loop)

    /// Whether the viewer's input reaches the app now.
    private func mayControl(_ client: Client) -> Bool {
        if client.isHost { return true }
        switch options.control {
        case .everyone: return true
        case .watchOnly: return false
        case .askToControl:
            guard let grant else { return false }
            return grant.viewer == client.id || (grant.client != nil && grant.client == client.token)
        }
    }

    /// The `control` message for a viewer.
    private func control(for client: Client) -> MirrorProtocol.Control {
        let holder = options.control == .askToControl ? grant.map { $0.name ?? "A viewer" } : nil
        return MirrorProtocol.Control(mode: options.control, you: mayControl(client), requested: client.requested != nil, holder: holder)
    }

    private func sendControl(_ client: Client, flush: Bool = true) {
        let control = self.control(for: client)
        guard let text = try? MirrorProtocol.ServerMessage.control(control).jsonString() else { return }
        client.control = control
        client.sendText(text, flush: flush)
    }

    /// Tells every viewer whose `control` changed, and the session who may control the app now.
    private func controlChanged() {
        if live {
            for client in clients.values where client.control != control(for: client) { sendControl(client) }
        }
        eventSink.yield(.control(currentControlState()))
    }

    private func currentControlState() -> ControlState {
        let holder = options.control == .askToControl ? grant.map { grant in
            let connected = clients.values.contains { $0.id == grant.viewer || (grant.client != nil && $0.token == grant.client) }
            return ControlState.Holder(viewer: grant.viewer, name: grant.name, connected: connected)
        } : nil
        let requests = clients.values.compactMap { client in client.requested.map { (order: $0, client: client) } }
            .sorted { $0.order < $1.order }
            .map { ControlState.Request(viewer: $0.client.id, name: $0.client.name) }
        return ControlState(mode: options.control, holder: holder, requests: options.control == .askToControl ? requests : [])
    }

    /// A viewer asks for control. A page that had it (same `client` id) gets it back at once;
    /// otherwise the host is asked (`control` event) and the viewer is told it waits.
    private func requestControl(_ client: Client, _ request: MirrorProtocol.RequestControl) {
        client.name = Self.cleanName(request.name) ?? client.name
        client.token = Self.cleanToken(request.client) ?? client.token
        guard options.control == .askToControl else { return sendControl(client) }
        if let grant, grant.viewer != client.id, grant.client != nil, grant.client == client.token {
            self.grant = Grant(viewer: client.id, client: grant.client, name: client.name ?? grant.name)
            controlChanged()
            requestResize()
            return
        }
        if mayControl(client) { return sendControl(client) }
        if client.requested == nil {
            requestCount += 1
            client.requested = requestCount
        }
        controlChanged()
    }

    /// A viewer gives control back, or takes back its request.
    private func releaseControl(_ client: Client) {
        var changed = false
        if client.requested != nil { client.requested = nil; changed = true }
        if let grant, grant.viewer == client.id || (grant.client != nil && grant.client == client.token) {
            self.grant = nil
            changed = true
            requestResize()
        }
        if changed { controlChanged() } else { sendControl(client) }
    }

    /// A viewer's name as the host sees it: trimmed, without control characters, at most 32 characters.
    static func cleanName(_ name: String?) -> String? {
        guard let name else { return nil }
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(32))
    }

    /// A page's id: 8 to 128 characters of letters, digits, `-` and `_`, else ignored.
    static func cleanToken(_ token: String?) -> String? {
        guard let token, (8...128).contains(token.count),
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }) else { return nil }
        return token
    }

    /// The viewers' sizes or color schemes changed (one connected, left or sent `viewport`).
    private func viewportsChanged() {
        requestResize()
        let first = clients.values.filter { $0.viewport?.appearance != nil }.min { $0.id < $1.id }
        if let appearance = first?.viewport?.appearance, appearance != reportedAppearance {
            reportedAppearance = appearance
            eventSink.yield(.viewerAppearance(appearance))
        }
    }

    private func requestResize() {
        shared.withLock { $0.runtime }?.requestResize()
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
            runtime.refresh(after: Self.menuActionRefreshes)
            return
        }
        guard let window = message.window else { return } // viewport and control requests are handled as they arrive
        // Not a mirrored window: ignored.
        guard let (mirroredWindow, latest) = try? await loop.submit({ () -> (MirroredWindow, AXSnapshot?)? in
            guard let mirrored = self.mirrored[window] else { return nil }
            return (mirrored, self.snapshots[window])
        }).get() else { return }
        let root = mirroredWindow.root
        let target = InputSynthesizer.Window(id: window, frame: latest?.frame ?? mirroredWindow.frame)
        /// The node with this (viewer) key in the latest snapshot, else in a fresh read of the window.
        func node(_ key: String) async throws -> MirrorProtocol.AXNode? {
            if let node = latest?.node(key) { return node }
            return Self.rebased(try await app.accessibility.snapshot(window: .number(window)), root: root).node(key)
        }
        do {
            switch message {
            case .windowAction(let action):
                switch (action.action, mirroredWindow.info.kind) {
                case (.focus, .menu): return
                case (.focus, _): try await app.accessibility.raise(window: window)
                case (.close, .main): return // the share's own window stays
                case (.close, .menu): try await app.menus?.closeOpen()
                case (.close, _): try await app.accessibility.close(window: window)
                }
                runtime.refresh(after: Self.pressRefreshes)
            case .act where latest == nil, .setText where latest == nil:
                return // a window without a tree (a menu): no keys to act on
            case .act(let act) where act.action == .showMenu && app.menus != nil:
                // AXShowMenu answers only when the menu closes; MenuBridge doesn't wait for that.
                guard let node = try await node(act.key), node.w > 0, node.h > 0 else { return }
                let center = CGPoint(x: node.x + node.w / 2, y: node.y + node.h / 2)
                runtime.state.withLock { $0.rightClick = (window, center) }
                try await app.menus?.showMenu(at: target.global(center))
                runtime.watchMenus()
            case .act(let act):
                guard let key = MirrorProtocol.NodeKey.unrebase(act.key, from: root) else { return }
                try await app.accessibility.perform(key: key, action: act.action, window: window)
                runtime.refresh(after: Self.pressRefreshes)
            case .pointer(let pointer):
                try app.input.send(pointer, in: target)
                if pointer.kind == .move { return }
                if pointer.kind == .up { runtime.refresh(after: Self.pressRefreshes) }
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
                guard let node = try await node(setText.key) else { return }
                try await app.input.replaceText(in: target, field: CGRect(x: node.x, y: node.y, width: node.w, height: node.h),
                                                with: setText.value, timeout: Self.setTextTimeout)
            case .viewport, .menuAction, .requestControl, .releaseControl:
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
            let socket = MirrorSocketHandler(server: server, isHost: head.headers.first(name: MirrorProtocol.hostHeader) == "1")
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
    private let isHost: Bool
    private var context: ChannelHandlerContext?
    private var id: Int?
    private var keepAlive: RepeatedTask?
    private var closing = false

    init(server: MirrorServer, isHost: Bool) { self.server = server; self.isHost = isHost }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    /// Registers the viewer (which greets it) and keeps the connection alive through proxies
    /// (Cloudflare drops WebSockets idle for 100 seconds).
    func begin() {
        guard let context, context.channel.isActive, id == nil else { return }
        id = server.clientConnected(context.channel, isHost: isHost)
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

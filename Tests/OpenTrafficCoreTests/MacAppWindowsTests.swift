import AppKit
import ApplicationServices
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import OpenTrafficCore

// Every window a shared Mac app opens, as a surface of its own: sheets, alerts, popovers, a popped-up
// menu and second windows. The rules (kinds, key roots, positions, focus) run without permissions; the
// mirror server over stub bridges checks what viewers get and what reaches the app; the Orbit fixture
// suite opens Orbit's real sheet, alert, popover, Statistics window and context menu (Accessibility and
// Screen Recording permission; skips without them and takes MacAppFixtureTurn through withOrbitFixture).

private typealias Proto = MirrorProtocol

// MARK: - Rules

@Suite struct MacAppWindowRuleTests {
    private func window(_ number: UInt32, title: String = "", subrole: String? = "AXStandardWindow", main: Bool = false, focused: Bool = false,
                        frame: CGRect) -> AccessibilityTree.Window {
        .init(number: number, title: title, role: "AXWindow", subrole: subrole, frame: frame, isMain: main, isFocused: focused, isMinimized: false)
    }

    @Test func everyWindowHasItsOwnKeyRoot() {
        #expect(Proto.NodeKey.windowRoots(titles: ["Orbit Orders", "Statistics", "Statistics", "", "A/B"])
            == ["/Window:", "/Window:Statistics", "/Window:Statistics#2", "/Window:#2", "/Window:A\u{2215}B"])
        // Keys read as `/Window:` move under a root and back; keys of another window don't come back.
        #expect(Proto.NodeKey.rebase("/Window:/Group:/Button:Save", onto: "/Window:/Sheet:") == "/Window:/Sheet:/Group:/Button:Save")
        #expect(Proto.NodeKey.rebase("/Window:", onto: "/Window:Statistics") == "/Window:Statistics")
        #expect(Proto.NodeKey.rebase("/Window:/Button:OK", onto: Proto.NodeKey.root) == "/Window:/Button:OK")
        #expect(Proto.NodeKey.unrebase("/Window:/Sheet:/Group:/Button:Save", from: "/Window:/Sheet:") == "/Window:/Group:/Button:Save")
        #expect(Proto.NodeKey.unrebase("/Window:Statistics", from: "/Window:Statistics") == "/Window:")
        #expect(Proto.NodeKey.unrebase("/Window:Statistics#2/Group:", from: "/Window:Statistics") == nil)
        #expect(Proto.NodeKey.unrebase("/Window:/Group:", from: "/Window:/Sheet:") == nil)
        #expect(Proto.NodeKey.unrebase("/Window:/Group:", from: Proto.NodeKey.root) == "/Window:/Group:")
        #expect(Proto.NodeKey.unrebase("/Menu:", from: Proto.NodeKey.root) == nil)
    }

    @Test func topLevelWindowsAreTheMainOneSecondWindowsAndAppModalAlerts() {
        let main = window(1, title: "Orbit Orders", main: true, frame: CGRect(x: 1750, y: 1172, width: 860, height: 540))
        let stats = window(2, title: "Statistics", focused: true, frame: CGRect(x: 1790, y: 1212, width: 360, height: 260))
        let alert = window(3, subrole: "AXDialog", frame: CGRect(x: 2000, y: 1300, width: 260, height: 140))
        let tiny = window(4, frame: CGRect(x: 0, y: 0, width: 2, height: 1))
        let mirrored = MirrorServer.mirroredWindows([stats, main, alert, tiny], current: nil)
        #expect(mirrored.map(\.info.id) == [1, 2, 3])
        #expect(mirrored.map(\.info.kind) == [.main, .window, .alert])
        #expect(mirrored.map(\.root) == ["/Window:", "/Window:Statistics", "/Window:#2"])
        #expect(mirrored[1].info == Proto.WindowInfo(id: 2, title: "Statistics", w: 360, h: 260, x: 40, y: 40, kind: .window, parent: nil))
        #expect(mirrored[2].info.parent == 1 && mirrored[2].info.x == 250 && mirrored[2].info.y == 128)
        // An app-modal alert alone is never taken for the main window while there is another.
        #expect(MirrorServer.mirroredWindows([alert, main], current: nil).first?.info.id == 1)
    }

    @Test func sheetsAndPopoversBecomeSurfacesOfTheirWindow() {
        let parent = MirrorServer.MirroredWindow(info: .init(id: 2, title: "Statistics", w: 360, h: 260, x: 40, y: 40, kind: .window),
                                                 frame: CGRect(x: 1790, y: 1212, width: 360, height: 260), root: "/Window:Statistics")
        let origin = CGPoint(x: 1750, y: 1172)
        let sheet = AXSnapshot.Surface(number: 7, key: "/Window:/Sheet:", role: "AXSheet", frame: CGRect(x: 1800, y: 1240, width: 300, height: 120))
        let alert = AXSnapshot.Surface(number: 8, key: "/Window:/Sheet:alert", role: "AXSheet", description: "alert", frame: sheet.frame)
        let popover = AXSnapshot.Surface(number: 9, key: "/Window:/Group:/Button:Tracking/Popover:", role: "AXPopover",
                                         frame: CGRect(x: 1900, y: 1400, width: 246, height: 115))
        #expect(MirrorServer.kind(of: sheet) == .sheet && MirrorServer.kind(of: alert) == .alert && MirrorServer.kind(of: popover) == .popover)
        let mirrored = try! #require(MirrorServer.surfaceWindow(popover, of: parent, origin: origin))
        #expect(mirrored.info == Proto.WindowInfo(id: 9, title: "", w: 246, h: 115, x: 150, y: 228, kind: .popover, parent: 2))
        #expect(mirrored.root == "/Window:Statistics/Group:/Button:Tracking/Popover:")
        #expect(MirrorServer.surfaceWindow(sheet, of: parent, origin: origin)?.root == "/Window:Statistics/Sheet:")
        // What is left of a closing popover isn't a surface.
        var closing = popover
        closing.frame.size = CGSize(width: 2, height: 1)
        #expect(MirrorServer.surfaceWindow(closing, of: parent, origin: origin) == nil)
        #expect(MirrorServer.menuWindow(id: 12, frame: CGRect(x: 1800, y: 1300, width: 180, height: 96), parent: 1, origin: origin)?.info
            == Proto.WindowInfo(id: 12, title: "", w: 180, h: 96, x: 50, y: 128, kind: .menu, parent: 1))
    }

    @Test func theFocusIsOnTheKeyWindowOrTheSheetOnIt() {
        let main = window(1, main: true, frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        func mirrored(_ id: UInt32, _ kind: Proto.WindowKind, parent: UInt32? = nil) -> MirrorServer.MirroredWindow {
            .init(info: .init(id: id, w: 100, h: 100, kind: kind, parent: parent), frame: .zero, root: "/Window:")
        }
        let windows = [mirrored(1, .main), mirrored(5, .popover, parent: 1), mirrored(6, .sheet, parent: 1)]
        #expect(MirrorServer.focusedWindow([main], mirrored: windows) == 6)
        #expect(MirrorServer.focusedWindow([main], mirrored: [mirrored(1, .main), mirrored(5, .popover, parent: 1)]) == 1)
        var focusedStats = window(2, focused: true, frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(MirrorServer.focusedWindow([main, focusedStats], mirrored: windows + [mirrored(2, .window)]) == 2)
        focusedStats.number = 99
        #expect(MirrorServer.focusedWindow([focusedStats], mirrored: windows) == nil)
    }

    @Test func snapshotsMoveUnderTheirRootAndKeepTheirOwnHash() {
        let snapshot = AXSnapshot(windowNumber: 7, title: "", frame: .zero, nodes: [
            .init(key: "/Window:", role: "AXSheet", x: 0, y: 0, w: 300, h: 120, depth: 0),
            .init(key: "/Window:/Button:Cancel", role: "AXButton", label: "Cancel", x: 10, y: 80, w: 70, h: 24, depth: 1, actions: [.press]),
        ], surfaces: [.init(number: 9, key: "/Window:/Button:Cancel/Popover:", role: "AXPopover", frame: .zero)])
        let rebased = MirrorServer.rebased(snapshot, root: "/Window:/Sheet:")
        #expect(rebased.nodes.map(\.key) == ["/Window:/Sheet:", "/Window:/Sheet:/Button:Cancel"])
        #expect(rebased.surfaces.map(\.key) == ["/Window:/Sheet:/Button:Cancel/Popover:"])
        #expect(rebased.v != snapshot.v && rebased.v == AXSnapshot.hash(rebased.nodes))
        #expect(MirrorServer.rebased(snapshot, root: Proto.NodeKey.root) == snapshot)
        // The main window's Cancel and the sheet's never share a DOM id.
        #expect(Proto.NodeKey.domID(for: "/Window:/Button:Cancel") != Proto.NodeKey.domID(for: rebased.nodes[1].key))
    }
}

// MARK: - The server over stub bridges

private let mainID: Proto.WindowID = 42
private let mainFrame = CGRect(x: -1500, y: 300, width: 400, height: 300)

private final class WindowsAccessibility: MirrorAccessibility, @unchecked Sendable {
    struct State {
        var windows: [AccessibilityTree.Window]
        /// Nodes per window number (keys as the bridge reads them: `/Window:`...).
        var nodes: [UInt32: [Proto.AXNode]] = [:]
        /// Sheets and popovers per window number.
        var surfaces: [UInt32: [AXSnapshot.Surface]] = [:]
        var performed: [(key: String, window: UInt32?)] = []
        var raised: [UInt32] = []
        var closed: [UInt32] = []
        var streams: [AsyncStream<AXChange>.Continuation] = []
    }
    let state: OSAllocatedUnfairLock<State>

    init(windows: [AccessibilityTree.Window]) {
        var initial = State(windows: windows)
        for window in windows {
            initial.nodes[window.number!] = [
                .init(key: "/Window:", role: "AXWindow", x: 0, y: 0, w: window.frame.width, h: window.frame.height, depth: 0),
                .init(key: "/Window:/Button:Cancel", role: "AXButton", label: "Cancel", x: 20, y: 250, w: 70, h: 24, depth: 1, actions: [.press]),
            ]
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func windows() async throws -> [AccessibilityTree.Window] { state.withLock { $0.windows } }

    func snapshot(window: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        try state.withLock { state in
            guard case .number(let id) = window, let nodes = state.nodes[id] else { throw AccessibilityTreeError.noWindow }
            let frame = state.windows.first { $0.number == id }?.frame
                ?? state.surfaces.values.joined().first { $0.number == id }?.frame ?? .zero
            return AXSnapshot(windowNumber: id, title: "", frame: frame, nodes: nodes, surfaces: state.surfaces[id] ?? [])
        }
    }

    func perform(key: String, action: Proto.Action, window: UInt32?) async throws {
        let known = state.withLock { state -> Bool in
            state.performed.append((key, window))
            return window.flatMap { state.nodes[$0] }?.contains { $0.key == key } ?? false
        }
        guard known else { throw AccessibilityTreeError.unknownKey(key) }
    }

    func raise(window: UInt32) async throws { state.withLock { $0.raised.append(window) } }
    func close(window: UInt32) async throws { state.withLock { $0.closed.append(window) } }

    func changes() -> AsyncStream<AXChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AXChange.self)
        state.withLock { $0.streams.append(continuation) }
        return stream
    }

    func emit(_ kind: AXChange.Kind) {
        for stream in state.withLock({ $0.streams }) { stream.yield(AXChange(kind: kind, notification: "AXCreated", role: nil)) }
    }
}

private final class WindowsCapture: MirrorCapture, @unchecked Sendable {
    let id: CGWindowID
    let size: CGSize
    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(id: CGWindowID, size: CGSize) {
        self.id = id
        self.size = size
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
    }

    func start() async throws { continuation.yield(full()) }
    func stop() async {
        stopped.withLock { $0 = true }
        continuation.finish()
    }
    var isStopped: Bool { stopped.withLock { $0 } }
    func fullFrame() async -> CapturedFrame? { full() }

    private func full() -> CapturedFrame {
        let tile = Proto.Tile(window: id, seq: 0, x: 0, y: 0, w: UInt16(size.width), h: UInt16(size.height), format: .jpeg,
                              data: grayJPEG(width: Int(size.width), height: Int(size.height)))
        return CapturedFrame(window: id, seq: 0, full: true, width: Int(size.width), height: Int(size.height), scale: 1, tiles: [tile], encodeTime: .zero)
    }
}

private func grayJPEG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private final class NoInput: MirrorInput, @unchecked Sendable {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    func send(_ pointer: Proto.Pointer, in window: InputSynthesizer.Window) throws {
        log.withLock { $0.append("pointer \(pointer.kind.rawValue) window \(window.id) frame \(Int(window.frame.minX)),\(Int(window.frame.minY))") }
    }
    func type(text: String) throws {}
    func send(_ key: Proto.Key) throws {}
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {
        log.withLock { $0.append("setText \(text) window \(window.id) field \(Int(field.minX)),\(Int(field.minY))") }
    }
}

/// A WebSocket viewer that keeps every message it gets.
private final class WindowsViewer: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let received = OSAllocatedUnfairLock(initialState: [Proto.ServerMessage]())

    init(port: Int) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)\(Proto.webSocketPath)")!)
        task.maximumMessageSize = 64 << 20
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let message = try? Proto.ServerMessage.decode(text) { received.withLock { $0.append(message) } }
                receive()
            case .success: receive()
            case .failure: break
            }
        }
    }

    var messages: [Proto.ServerMessage] { received.withLock { $0 } }
    var count: Int { received.withLock { $0.count } }

    /// The first message from `index` on that `match` turns into a value, waiting up to `timeout`.
    func first<T: Sendable>(after index: Int = 0, within timeout: Duration = .seconds(5), _ match: @Sendable (Proto.ServerMessage) -> T?) async -> T? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let all = messages
            if index < all.count, let hit = all[index...].lazy.compactMap(match).first { return hit }
            try? await Task.sleep(for: .milliseconds(5))
        } while clock.now < deadline
        return nil
    }

    /// The latest window list (hello's or a `windows` message) that `match` accepts.
    func windows(after index: Int = 0, within timeout: Duration = .seconds(5), where match: @escaping @Sendable ([Proto.WindowInfo]) -> Bool) async -> [Proto.WindowInfo]? {
        await first(after: index, within: timeout) { message in
            switch message {
            case .windows(let list) where match(list): list
            case .hello(let hello) where match(hello.windows): hello.windows
            default: nil
            }
        }
    }

    func tree(after index: Int = 0, within timeout: Duration = .seconds(5), window: Proto.WindowID,
              where match: @escaping @Sendable (Proto.Tree) -> Bool = { _ in true }) async -> Proto.Tree? {
        await first(after: index, within: timeout) { message in
            if case .tree(let tree) = message, tree.window == window, match(tree) { tree } else { nil }
        }
    }

    func frame(after index: Int = 0, within timeout: Duration = .seconds(5), window: Proto.WindowID) async -> Proto.FrameHeader? {
        await first(after: index, within: timeout) { message in
            if case .frame(let frame) = message, frame.window == window { frame } else { nil }
        }
    }

    func send(_ message: Proto.ClientMessage) async throws { try await task.send(.string(message.jsonString())) }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

private let stubAssets = MirrorServer.Assets(page: Data("<!doctype html><title>Viewer</title>".utf8), script: Data(), style: Data())

@Suite("Extra windows over stub bridges", .serialized, .timeLimit(.minutes(2)))
struct MacAppWindowsStubTests {
    private struct Mirror {
        let accessibility: WindowsAccessibility
        let input: NoInput
        let captures: OSAllocatedUnfairLock<[WindowsCapture]>
        let server: MirrorServer
        let viewer: WindowsViewer

        func capture(_ id: CGWindowID) -> WindowsCapture? { captures.withLock { $0.last { $0.id == id } } }
        func stop() async {
            viewer.close()
            await server.stop()
        }
    }

    private func start(_ windows: [AccessibilityTree.Window]) async throws -> Mirror {
        let accessibility = WindowsAccessibility(windows: windows)
        let input = NoInput()
        let captures = OSAllocatedUnfairLock(initialState: [WindowsCapture]())
        let sizes = Dictionary(uniqueKeysWithValues: windows.map { ($0.number!, $0.frame.size) })
        let app = MirrorServer.App(name: "Orbit", boot: "boot-1", accessibility: accessibility, input: input) { id in
            let capture = WindowsCapture(id: id, size: sizes[id] ?? CGSize(width: 300, height: 120))
            captures.withLock { $0.append(capture) }
            return capture
        }
        let server = MirrorServer(configuration: .init(app: app, assets: stubAssets, appearance: .light))
        let port = try await server.start()
        return Mirror(accessibility: accessibility, input: input, captures: captures, server: server, viewer: WindowsViewer(port: port))
    }

    private static let main = AccessibilityTree.Window(number: mainID, title: "Orders", role: "AXWindow", subrole: "AXStandardWindow",
                                                       frame: mainFrame, isMain: true, isFocused: false, isMinimized: false)

    @Test func aSheetInAWindowsTreeIsASurfaceOfItsOwnWithItsOwnTreeFramesAndInput() async throws {
        let mirror = try await start([Self.main])
        defer { Task { await mirror.stop() } }
        let viewer = mirror.viewer
        _ = try #require(await viewer.frame(window: mainID))
        let mark = viewer.count

        // The app opens a sheet: it shows up in the main window's tree as a window of its own.
        let sheetFrame = CGRect(x: mainFrame.minX + 50, y: mainFrame.minY + 28, width: 300, height: 120)
        mirror.accessibility.state.withLock { state in
            state.surfaces[mainID] = [.init(number: 50, key: "/Window:/Sheet:", role: "AXSheet", frame: sheetFrame)]
            state.nodes[50] = [
                .init(key: "/Window:", role: "AXSheet", x: 0, y: 0, w: 300, h: 120, depth: 0),
                .init(key: "/Window:/TextField:Street", role: "AXTextField", label: "Street", value: "", x: 20, y: 20, w: 200, h: 22, depth: 1),
                .init(key: "/Window:/Button:Cancel", role: "AXButton", label: "Cancel", x: 20, y: 80, w: 70, h: 24, depth: 1, actions: [.press]),
            ]
        }
        mirror.accessibility.emit(.sheetCreated)
        let windows = try #require(await viewer.windows(after: mark) { $0.count == 2 })
        #expect(windows[0].id == mainID && windows[0].kind == .main && !windows[0].focused)
        #expect(windows[1] == Proto.WindowInfo(id: 50, title: "", w: 300, h: 120, x: 50, y: 28, kind: .sheet, parent: mainID, focused: true))
        let tree = try #require(await viewer.tree(after: mark, window: 50))
        #expect(tree.nodes.map(\.key) == ["/Window:/Sheet:", "/Window:/Sheet:/TextField:Street", "/Window:/Sheet:/Button:Cancel"])
        #expect(await viewer.frame(after: mark, window: 50)?.full == true)

        // Input for the sheet reaches its own window, with the keys the bridge knows.
        try await viewer.send(.act(.init(window: 50, key: "/Window:/Sheet:/Button:Cancel", action: .press)))
        try await viewer.send(.setText(.init(window: 50, key: "/Window:/Sheet:/TextField:Street", value: "1 Infinite Loop")))
        try await viewer.send(.pointer(.init(window: 50, kind: .down, x: 5, y: 5)))
        // A key of the main window sent for the sheet is ignored.
        try await viewer.send(.act(.init(window: 50, key: "/Window:/Button:Cancel", action: .press)))
        try await Task.sleep(for: .milliseconds(300))
        let performed = mirror.accessibility.state.withLock { $0.performed }
        #expect(performed.map(\.key) == ["/Window:/Button:Cancel"] && performed.map(\.window) == [50])
        #expect(mirror.input.log.withLock { $0 } == ["setText 1 Infinite Loop window 50 field 20,20",
                                                    "pointer down window 50 frame \(Int(sheetFrame.minX)),\(Int(sheetFrame.minY))"])

        // The sheet closes: its surface goes, its capture stops.
        let closedMark = viewer.count
        mirror.accessibility.state.withLock { $0.surfaces[mainID] = []; $0.nodes[50] = nil }
        mirror.accessibility.emit(.destroyed)
        let after = try #require(await viewer.windows(after: closedMark) { $0.count == 1 })
        #expect(after.map(\.id) == [mainID] && after[0].focused)
        let capture = try #require(mirror.capture(50))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !capture.isStopped, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(capture.isStopped)
    }

    @Test func secondWindowsAndAppModalAlertsAreListedCapturedAndFocusedOrClosedFromTheViewer() async throws {
        let stats = AccessibilityTree.Window(number: 43, title: "Statistics", role: "AXWindow", subrole: "AXStandardWindow",
                                             frame: CGRect(x: mainFrame.minX + 24, y: mainFrame.minY + 24, width: 360, height: 260),
                                             isMain: false, isFocused: true, isMinimized: false)
        let alert = AccessibilityTree.Window(number: 44, title: "", role: "AXWindow", subrole: "AXDialog",
                                             frame: CGRect(x: mainFrame.minX + 70, y: mainFrame.minY + 80, width: 260, height: 140),
                                             isMain: false, isFocused: false, isMinimized: false)
        let mirror = try await start([Self.main, stats, alert])
        defer { Task { await mirror.stop() } }
        let viewer = mirror.viewer
        let windows = try #require(await viewer.windows { $0.count == 3 })
        #expect(windows.map(\.kind) == [.main, .window, .alert])
        #expect(windows.map(\.parent) == [nil, nil, mainID])
        #expect(windows.map(\.focused) == [false, true, false])
        #expect(windows[1].x == 24 && windows[1].y == 24 && windows[1].title == "Statistics")
        // Each has its own tree under its own root, and its own frames.
        #expect(await viewer.tree(window: 43)?.nodes.first?.key == "/Window:Statistics")
        #expect(await viewer.tree(window: 44)?.nodes.first?.key == "/Window:#2")
        #expect(await viewer.frame(window: 43) != nil)
        #expect(await viewer.frame(window: 44) != nil)
        try await viewer.send(.act(.init(window: 43, key: "/Window:Statistics/Button:Cancel", action: .press)))

        try await viewer.send(.windowAction(.init(window: mainID, action: .focus)))
        try await viewer.send(.windowAction(.init(window: 43, action: .close)))
        try await viewer.send(.windowAction(.init(window: mainID, action: .close))) // never: the share's own window
        try await viewer.send(.windowAction(.init(window: 777, action: .close))) // not a mirrored window
        try await Task.sleep(for: .milliseconds(300))
        let state = mirror.accessibility.state.withLock { ($0.raised, $0.closed, $0.performed.map(\.key)) }
        #expect(state.0 == [mainID] && state.1 == [43] && state.2 == ["/Window:/Button:Cancel"])
    }
}

@Suite("Reading windows as viewers see them, for agents", .serialized)
struct MacAppViewerWindowsTests {
    @Test func everyWindowIsReadWithTheKeysViewersPinnedCommentsWith() async throws {
        // Statistics has become the app's main window, but the mirror kept Orders as its main one.
        let main = AccessibilityTree.Window(number: mainID, title: "Orders", role: "AXWindow", subrole: "AXStandardWindow",
                                            frame: mainFrame, isMain: false, isFocused: false, isMinimized: false)
        let stats = AccessibilityTree.Window(number: 43, title: "Statistics", role: "AXWindow", subrole: "AXStandardWindow",
                                             frame: mainFrame.offsetBy(dx: 30, dy: 30), isMain: true, isFocused: true, isMinimized: false)
        let accessibility = WindowsAccessibility(windows: [main, stats])
        accessibility.state.withLock { state in
            state.surfaces[mainID] = [.init(number: 50, key: "/Window:/Sheet:", role: "AXSheet", frame: mainFrame.insetBy(dx: 50, dy: 50))]
            state.nodes[50] = [.init(key: "/Window:", role: "AXSheet", x: 0, y: 0, w: 300, h: 200, depth: 0),
                               .init(key: "/Window:/Button:Save", role: "AXButton", label: "Save", x: 10, y: 10, w: 60, h: 24, depth: 1)]
        }
        let read = try await MirrorServer.readWindows(accessibility, current: mainID)
        #expect(read.map(\.info.id) == [mainID, 50, 43])
        #expect(read.map(\.info.kind) == [.main, .sheet, .window])
        #expect(read.map(\.root) == ["/Window:", "/Window:/Sheet:", "/Window:Statistics"])
        #expect(read[1].snapshot.nodes.map(\.key) == ["/Window:/Sheet:", "/Window:/Sheet:/Button:Save"])
        #expect(read.map(\.info.focused) == [false, false, true])
        #expect(Proto.NodeKey.unrebase(read[1].snapshot.nodes[1].key, from: read[1].root) == "/Window:/Button:Save")
        // A comment pinned to the sheet's Save button finds it.
        let trees = read.map { MacAppAgentContext.WindowTree(number: $0.info.id, title: $0.info.title, isMain: $0.info.kind == .main, nodes: $0.snapshot.nodes) }
        let found = try #require(MacAppAgentContext.find(.domID(Proto.NodeKey.domID(for: "/Window:/Sheet:/Button:Save")), in: trees))
        #expect(found.window == 50 && found.element.label == "Save")
        // Without the mirror's main window, the app's main one is the main window.
        #expect(try await MirrorServer.readWindows(accessibility).first?.info.id == 43)
    }

    @Test func agentsReadWindowActionsAsSteps() {
        #expect(MacAppAgentContext.describe(.windowAction(.init(window: 43, action: .close))) == "closed window 43")
        #expect(MacAppAgentContext.describe(.windowAction(.init(window: 43, action: .focus))) == "brought window 43 to the front")
    }
}

// MARK: - The Orbit fixture

private let fixtureAssets = MirrorServer.Assets(page: Data("<!doctype html><title>Orbit</title>".utf8), script: Data(), style: Data())

/// Every on-screen window of one process, every few milliseconds, that is on a screen people look at.
private final class ScreenWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(id: CGWindowID, bounds: CGRect)] = []
    private var sampled = 0
    private var running = true

    init(pid: pid_t) {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                let visible = list.compactMap { entry -> (CGWindowID, CGRect)? in
                    guard entry[kCGWindowOwnerPID as String] as? pid_t == pid, let id = entry[kCGWindowNumber as String] as? CGWindowID,
                          let bounds = entry[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
                          bounds.width > 1, bounds.height > 1, OffscreenDisplay.isVisible(bounds) else { return nil }
                    return (id, bounds)
                }
                lock.withLock { seen += visible; sampled += 1 }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    func stop() -> (visible: [(id: CGWindowID, bounds: CGRect)], samples: Int) {
        lock.withLock {
            running = false
            return (seen, sampled)
        }
    }
}

@MainActor
@Suite("Extra windows on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .timeLimit(.minutes(10)))
struct MacAppWindowsFixtureTests {
    /// Serves Orbit, connects a viewer, and checks that none of Orbit's windows ever showed on a
    /// physical screen while the body ran.
    private func withServedOrbit(_ body: (MirrorServer, WindowsViewer, OrbitFixture) async throws -> Void) async throws {
        try await withOrbitFixture { orbit in
            let watch = ScreenWatch(pid: orbit.pid)
            let server = MirrorServer(configuration: .init(app: try .live(pid: orbit.pid, name: "Orbit"), assets: fixtureAssets))
            let viewer: WindowsViewer
            do {
                viewer = WindowsViewer(port: try await server.start())
            } catch {
                _ = watch.stop()
                throw error
            }
            do {
                try await body(server, viewer, orbit)
            } catch {
                viewer.close()
                await server.stop()
                _ = watch.stop()
                throw error
            }
            viewer.close()
            await server.stop()
            let watched = watch.stop()
            #expect(watched.samples > 10)
            #expect(watched.visible.isEmpty, "Orbit windows on a physical screen: \(watched.visible.prefix(5))")
        }
    }

    /// The main window's latest tree, once it lists the orders.
    private func mainTree(_ viewer: WindowsViewer) async throws -> Proto.Tree {
        let hello = try #require(await viewer.first(within: .seconds(15)) { if case .hello(let h) = $0 { h } else { nil } })
        let main = try #require(hello.windows.first { $0.kind == .main })
        return try #require(await viewer.tree(within: .seconds(15), window: main.id) { $0.nodes.contains { $0.role == "AXRow" } })
    }

    private func press(_ label: String, in tree: Proto.Tree, _ viewer: WindowsViewer) async throws {
        let node = try #require(tree.nodes.first { $0.label == label && $0.actions.contains(.press) }, "no \(label) in window \(tree.window)")
        try await viewer.send(.act(.init(window: tree.window, key: node.key, action: .press)))
    }

    /// The latest tree of each window at the moment.
    private func latestTrees(_ viewer: WindowsViewer) -> [Proto.WindowID: Proto.Tree] {
        var trees: [Proto.WindowID: Proto.Tree] = [:]
        for case .tree(let tree) in viewer.messages { trees[tree.window] = tree }
        return trees
    }

    @Test func theAddressSheetAndTheDeleteAlertAreSurfacesThatTakeInput() async throws {
        try await withServedOrbit { _, viewer, _ in
            let main = try await mainTree(viewer)
            let rows = main.nodes.filter { $0.role == "AXRow" }.count

            // The sheet: its own window over the main one, its own tree under /Window:/Sheet:, its own frames.
            var mark = viewer.count
            try await press("Edit Address…", in: main, viewer)
            let withSheet = try #require(await viewer.windows(after: mark, within: .seconds(10)) { $0.contains { $0.kind == .sheet } },
                                         "no sheet in \(viewer.messages.compactMap { if case .windows(let w) = $0 { w } else { nil } })")
            let sheet = try #require(withSheet.first { $0.kind == .sheet })
            #expect(sheet.parent == main.window && sheet.focused && sheet.x > 0 && sheet.y >= 0 && sheet.w < 600)
            let sheetTree = try #require(await viewer.tree(after: mark, window: sheet.id))
            #expect(sheetTree.nodes.first?.key == "/Window:/Sheet:" && sheetTree.nodes.allSatisfy { $0.key.hasPrefix("/Window:/Sheet:") })
            #expect(await viewer.frame(after: mark, within: .seconds(10), window: sheet.id)?.full == true)
            // The main window's tree no longer carries the sheet, so no key (or DOM id) is in both.
            let mainNow = try #require(latestTrees(viewer)[main.window])
            #expect(!mainNow.nodes.contains { $0.key.hasPrefix("/Window:/Sheet:") })
            #expect(Set(mainNow.nodes.map(\.key)).isDisjoint(with: sheetTree.nodes.map(\.key)))

            // Typing into the sheet's Street field, then Cancel closes it.
            let street = try #require(sheetTree.nodes.first { $0.role == "AXTextField" })
            try await viewer.send(.setText(.init(window: sheet.id, key: street.key, value: "1 Analytical Way")))
            #expect(await viewer.tree(after: mark, window: sheet.id) { $0.nodes.contains { $0.key == street.key && $0.value == "1 Analytical Way" } } != nil)
            mark = viewer.count
            try await press("Cancel", in: sheetTree, viewer)
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { !$0.contains { $0.id == sheet.id } } != nil, "the sheet stayed")

            // The alert: Cancel keeps the order, Delete removes it.
            mark = viewer.count
            try await press("Delete Order", in: main, viewer)
            let withAlert = try #require(await viewer.windows(after: mark, within: .seconds(10)) { $0.contains { $0.kind == .alert } })
            let alert = try #require(withAlert.first { $0.kind == .alert })
            #expect(alert.parent == main.window && alert.focused)
            let alertTree = try #require(await viewer.tree(after: mark, window: alert.id) { $0.nodes.contains { $0.label == "Delete" } })
            #expect(alertTree.nodes.contains { $0.role == "AXButton" && $0.label == "Cancel" })
            mark = viewer.count
            try await press("Cancel", in: alertTree, viewer)
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { !$0.contains { $0.id == alert.id } } != nil, "Cancel left the alert up")
            mark = viewer.count
            try await press("Delete Order", in: main, viewer)
            let again = try #require(await viewer.windows(after: mark, within: .seconds(10)) { $0.contains { $0.kind == .alert } }?.first { $0.kind == .alert })
            let againTree = try #require(await viewer.tree(after: mark, window: again.id) { $0.nodes.contains { $0.label == "Delete" } })
            mark = viewer.count
            try await press("Delete", in: againTree, viewer)
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { !$0.contains { $0.kind == .alert } } != nil, "Delete left the alert up")
            #expect(await viewer.tree(after: mark, within: .seconds(5), window: main.window) { $0.nodes.filter { $0.role == "AXRow" }.count == rows - 1 } != nil,
                    "the order wasn't deleted")
        }
    }

    @Test func theTrackingPopoverAndARowsContextMenuAreSurfacesOverTheMainWindow() async throws {
        try await withServedOrbit { _, viewer, _ in
            let main = try await mainTree(viewer)

            var mark = viewer.count
            try await press("Tracking", in: main, viewer)
            let popover = try #require(await viewer.windows(after: mark, within: .seconds(10)) { $0.contains { $0.kind == .popover } }?.first { $0.kind == .popover })
            #expect(popover.parent == main.window && popover.w > 100 && popover.h > 50)
            let tree = try #require(await viewer.tree(after: mark, window: popover.id))
            #expect(tree.nodes.first?.key.hasSuffix("/Button:Tracking/Popover:") == true)
            #expect(tree.nodes.contains { $0.role == "AXStaticText" && $0.label == "Tracking" })
            #expect(await viewer.frame(after: mark, within: .seconds(10), window: popover.id) != nil)
            mark = viewer.count
            try await viewer.send(.windowAction(.init(window: popover.id, action: .close)))
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { !$0.contains { $0.kind == .popover } } != nil, "the popover stayed")

            // A right click on a row: the menu's own window is listed (kind menu) next to the menu message.
            let text = try #require(latestTrees(viewer)[main.window]?.nodes.first { $0.role == "AXStaticText" && $0.actions.contains(.showMenu) && $0.w > 0 })
            mark = viewer.count
            try await viewer.send(.pointer(.init(window: main.window, kind: .rightdown, x: text.x + 4, y: text.y + 4)))
            try await viewer.send(.pointer(.init(window: main.window, kind: .rightup, x: text.x + 4, y: text.y + 4)))
            let menu = try #require(await viewer.windows(after: mark, within: .seconds(10)) { $0.contains { $0.kind == .menu } }?.first { $0.kind == .menu },
                                    "no menu window")
            #expect(menu.parent == main.window && menu.w > 50 && menu.h > 30)
            let context = try #require(await viewer.first(after: mark, within: .seconds(5)) { message -> Proto.ContextMenu? in
                if case .menu(let m) = message { m.context } else { nil }
            })
            #expect(context.window == main.window && abs(context.x - menu.x) <= 8 && abs(context.y - menu.y) <= 8, "menu \(menu) context \(context)")
            mark = viewer.count
            try await viewer.send(.menuAction(.init(path: [], context: true)))
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { !$0.contains { $0.kind == .menu } } != nil, "the menu window stayed")
        }
    }

    @Test func theStatisticsWindowIsListedCapturedFocusedAndClosedFromTheViewer() async throws {
        try await withServedOrbit { server, viewer, orbit in
            let main = try await mainTree(viewer)
            var mark = viewer.count
            try await viewer.send(.menuAction(.init(path: ["Orders", "Show Statistics"])))
            let windows = try #require(await viewer.windows(after: mark, within: .seconds(10)) { $0.contains { $0.kind == .window } })
            let stats = try #require(windows.first { $0.kind == .window })
            #expect(stats.title == "Statistics" && stats.parent == nil && stats.focused)
            #expect(windows.first?.id == main.window && windows.first?.kind == .main, "the main window changed: \(windows)")
            let tree = try #require(await viewer.tree(after: mark, window: stats.id))
            #expect(tree.nodes.first?.key == "/Window:Statistics" && tree.nodes.allSatisfy { $0.key.hasPrefix("/Window:Statistics") })
            let frame = try #require(await viewer.frame(after: mark, within: .seconds(10), window: stats.id))
            #expect(frame.full && frame.tiles > 0)
            #expect(await server.currentWindows().contains { $0.id == stats.id })
            // Its window really is on the off-screen display.
            #expect(orbit.hider.windows(pid: orbit.pid).contains { $0.id == stats.id && !OffscreenDisplay.isVisible($0.frame) })

            mark = viewer.count
            try await viewer.send(.windowAction(.init(window: main.window, action: .focus)))
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { list in
                list.first { $0.id == main.window }?.focused == true && list.first { $0.id == stats.id }?.focused == false
            } != nil, "focus didn't move to the main window")

            mark = viewer.count
            try await viewer.send(.windowAction(.init(window: stats.id, action: .close)))
            #expect(await viewer.windows(after: mark, within: .seconds(10)) { list in !list.contains { $0.id == stats.id } && list.count == 1 } != nil,
                    "the Statistics window stayed")
        }
    }
}

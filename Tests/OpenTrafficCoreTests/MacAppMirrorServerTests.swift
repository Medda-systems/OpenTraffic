import AppKit
import ApplicationServices
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import OpenTrafficCore

// The mirror server: the stub suite runs the server over stand-in bridges (no permissions needed,
// as on GitHub Actions) and talks to it like the viewer does, over HTTP and a WebSocket. The
// fixture suite serves the real Orbit app (launched hidden through MacAppWindowHider) and needs
// Accessibility and Screen Recording permission; it skips without them and takes MacAppFixtureTurn.

private typealias Proto = MirrorProtocol

// MARK: - Stub bridges

private let stubWindowID: Proto.WindowID = 42
private let stubFrame = CGRect(x: -1500, y: 300, width: 400, height: 300)

private func stubNodes(checked: Bool = false, title: String = "Add Order") -> [Proto.AXNode] {
    [
        .init(key: "/Window:", role: "AXWindow", x: 0, y: 0, w: 400, h: 300, depth: 0),
        .init(key: "/Window:/Button:\(title)", role: "AXButton", label: title, x: 20, y: 250, w: 90, h: 24, depth: 1, actions: [.press]),
        .init(key: "/Window:/CheckBox:Gift", role: "AXCheckBox", label: "Gift", value: checked ? "1" : "0", x: 20, y: 200, w: 60, h: 20, depth: 1, actions: [.press]),
        .init(key: "/Window:/TextField:Customer", role: "AXTextField", label: "Customer", value: "", x: 20, y: 20, w: 200, h: 22, depth: 1),
        .init(key: "/Window:/Link:Help", role: "AXLink", label: "Help", x: 300, y: 20, w: 60, h: 20, depth: 1, actions: [.press]),
        .init(key: "/Window:/Link:Help/StaticText:Help", role: "AXStaticText", label: "Help", x: 300, y: 20, w: 60, h: 20, depth: 2),
    ]
}

private final class StubAccessibility: MirrorAccessibility, @unchecked Sendable {
    struct State {
        var windows: [AccessibilityTree.Window]
        var nodes: [Proto.AXNode] = stubNodes()
        var performed: [(key: String, action: Proto.Action, window: UInt32?)] = []
        var selected: [String] = []
        var snapshots = 0
        var streams: [AsyncStream<AXChange>.Continuation] = []
    }
    let state: OSAllocatedUnfairLock<State>
    /// What a press does to the tree (like an app would).
    var onPerform: (@Sendable (String, inout [Proto.AXNode]) -> Void)?

    init(windows: [AccessibilityTree.Window] = [.init(number: stubWindowID, title: "Orders", role: "AXWindow", subrole: "AXStandardWindow",
                                                         frame: stubFrame, isMain: true, isFocused: true, isMinimized: false)]) {
        state = OSAllocatedUnfairLock(initialState: State(windows: windows))
    }

    func windows() async throws -> [AccessibilityTree.Window] { state.withLock { $0.windows } }

    func snapshot(window: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        try state.withLock { state in
            state.snapshots += 1
            guard case .number(let id) = window, let match = state.windows.first(where: { $0.number == id }) else { throw AccessibilityTreeError.noWindow }
            return AXSnapshot(windowNumber: id, title: match.title, frame: match.frame, nodes: state.nodes)
        }
    }

    func perform(key: String, action: Proto.Action, window: UInt32?) async throws {
        let onPerform = onPerform
        let known = state.withLock { state -> Bool in
            state.performed.append((key, action, window))
            guard state.nodes.contains(where: { $0.key == key }) else { return false }
            onPerform?(key, &state.nodes)
            return true
        }
        guard known else { throw AccessibilityTreeError.unknownKey(key) }
        emit()
    }

    func select(key: String, window: UInt32?) async throws {
        state.withLock { $0.selected.append(key) }
    }

    func changes() -> AsyncStream<AXChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AXChange.self)
        state.withLock { $0.streams.append(continuation) }
        return stream
    }

    func emit(_ kind: AXChange.Kind = .value) {
        for stream in state.withLock({ $0.streams }) { stream.yield(AXChange(kind: kind, notification: "AXValueChanged", role: nil)) }
    }

    func setNodes(_ nodes: [Proto.AXNode]) { state.withLock { $0.nodes = nodes } }
    var snapshotCount: Int { state.withLock { $0.snapshots } }
    var performed: [(key: String, action: Proto.Action, window: UInt32?)] { state.withLock { $0.performed } }
    var selected: [String] { state.withLock { $0.selected } }
}

private final class StubCapture: MirrorCapture, @unchecked Sendable {
    let windowID: CGWindowID
    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: (seq: UInt32(0), started: false, stopped: false, size: CGSize(width: 400, height: 300)))
    let scale = 2.0
    let failure: Error?

    init(windowID: CGWindowID, failure: Error? = nil) {
        self.windowID = windowID
        self.failure = failure
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
    }

    func start() async throws {
        if let failure { throw failure }
        state.withLock { $0.started = true }
        continuation.yield(makeFull(seq: 0))
    }

    func stop() async {
        state.withLock { $0.stopped = true }
        continuation.finish()
    }

    var isStopped: Bool { state.withLock { $0.stopped } }

    func fullFrame() async -> CapturedFrame? {
        let (seq, started) = state.withLock { ($0.seq, $0.started) }
        return started ? makeFull(seq: seq) : nil
    }

    func makeFull(seq: UInt32) -> CapturedFrame {
        let size = state.withLock { $0.size }
        let tile = Proto.Tile(window: windowID, seq: seq, x: 0, y: 0, w: UInt16(size.width), h: UInt16(size.height), format: .jpeg,
                              data: jpeg(width: Int(size.width * scale), height: Int(size.height * scale), gray: 0.9))
        return CapturedFrame(window: windowID, seq: seq, full: true, width: Int(size.width), height: Int(size.height), scale: scale,
                             tiles: [tile], encodeTime: .zero)
    }

    /// Sends a change: `count` small tiles.
    @discardableResult
    func emitChange(tiles count: Int = 2) -> UInt32 {
        let seq = state.withLock { state -> UInt32 in state.seq += 1; return state.seq }
        let tiles = (0..<count).map { index in
            Proto.Tile(window: windowID, seq: seq, x: UInt16(16 * index), y: 16, w: 16, h: 16, format: .jpeg, data: jpeg(width: 32, height: 32, gray: 0.2))
        }
        continuation.yield(CapturedFrame(window: windowID, seq: seq, full: false, width: 400, height: 300, scale: scale, tiles: tiles, encodeTime: .zero))
        return seq
    }
}

private final class StubInput: MirrorInput, @unchecked Sendable {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    var events: [String] { log.withLock { $0 } }

    func send(_ pointer: Proto.Pointer, in window: InputSynthesizer.Window) throws {
        let global = window.global(CGPoint(x: pointer.x, y: pointer.y))
        log.withLock { $0.append("pointer \(pointer.kind.rawValue) \(Int(pointer.x)),\(Int(pointer.y)) window \(window.id) at \(Int(global.x)),\(Int(global.y))") }
    }

    func type(text: String) throws { log.withLock { $0.append("text \(text)") } }
    func send(_ key: Proto.Key) throws { log.withLock { $0.append("key \(key.code.rawValue)") } }

    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {
        log.withLock { $0.append("setText \(text) field \(Int(field.minX)),\(Int(field.minY)),\(Int(field.width)),\(Int(field.height)) window \(window.id)") }
    }
}

/// A gray JPEG of the given pixel size.
private func jpeg(width: Int, height: Int, gray: CGFloat) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private func imageSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return CGSize(width: image.width, height: image.height)
}

private let stubAssets = MirrorServer.Assets(
    page: Data("<!doctype html><html><head><title>Viewer</title></head><body><main id=stage></main></body></html>".utf8),
    script: Data("console.log('viewer')".utf8),
    style: Data("body{margin:0}".utf8),
    icon: Data([0x89, 0x50, 0x4E, 0x47])
)

/// A server over stub bridges, started.
private struct StubMirror {
    let accessibility: StubAccessibility
    let input: StubInput
    let captures: OSAllocatedUnfairLock<[StubCapture]>
    let server: MirrorServer
    let port: Int

    var capture: StubCapture { captures.withLock { $0.last! } }

    static func start(accessibility: StubAccessibility = StubAccessibility(), allowedOrigins: Set<String> = [],
                      captureFailure: Error? = nil) async throws -> StubMirror {
        let input = StubInput()
        let captures = OSAllocatedUnfairLock(initialState: [StubCapture]())
        let app = MirrorServer.App(name: "Orbit", boot: "boot-1", accessibility: accessibility, input: input) { id in
            let capture = StubCapture(windowID: id, failure: captureFailure)
            captures.withLock { $0.append(capture) }
            return capture
        }
        let server = MirrorServer(configuration: .init(app: app, assets: stubAssets, appearance: .dark, allowedOrigins: allowedOrigins))
        let port = try await server.start()
        return StubMirror(accessibility: accessibility, input: input, captures: captures, server: server, port: port)
    }

    func viewer(origin: String? = nil) -> Viewer { Viewer(port: port, origin: origin) }

    func get(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, response as! HTTPURLResponse)
    }
}

// MARK: - A viewer, as the browser page connects

private final class Viewer: @unchecked Sendable {
    enum Item: Sendable {
        case message(Proto.ServerMessage)
        case tile(Proto.Tile)
    }
    struct Received: Sendable {
        var item: Item
        var time: ContinuousClock.Instant
    }

    let task: URLSessionWebSocketTask
    private let received = OSAllocatedUnfairLock(initialState: (items: [Received](), closed: false))

    init(port: Int, origin: String? = nil) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)\(Proto.webSocketPath)")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            let now = ContinuousClock.now
            switch result {
            case .success(.string(let text)):
                if let message = try? Proto.ServerMessage.decode(text) { received.withLock { $0.items.append(.init(item: .message(message), time: now)) } }
                receive()
            case .success(.data(let data)):
                if let tile = try? Proto.Tile(decoding: data) { received.withLock { $0.items.append(.init(item: .tile(tile), time: now)) } }
                receive()
            case .success:
                receive()
            case .failure:
                received.withLock { $0.closed = true }
            }
        }
    }

    var items: [Received] { received.withLock { $0.items } }
    var isClosed: Bool { received.withLock { $0.closed } }
    var messages: [Proto.ServerMessage] { items.compactMap { if case .message(let m) = $0.item { m } else { nil } } }

    /// The first item at or after `index` that matches, waiting up to `timeout`.
    func first(after index: Int = 0, within timeout: Duration = .seconds(5), _ match: @Sendable (Item) -> Bool) async -> (index: Int, received: Received)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let items = self.items
            if index < items.count, let found = items[index...].firstIndex(where: { match($0.item) }) { return (found, items[found]) }
            try? await Task.sleep(for: .milliseconds(2))
        } while clock.now < deadline
        return nil
    }

    func send(_ message: Proto.ClientMessage) async throws { try await task.send(.string(message.jsonString())) }
    func sendRaw(_ text: String) async throws { try await task.send(.string(text)) }
    func close() { task.cancel(with: .normalClosure, reason: nil) }

    /// The tiles that follow the `frame` message at `index`.
    func tiles(after index: Int, count: Int) async -> [Proto.Tile] {
        var tiles: [Proto.Tile] = []
        var cursor = index + 1
        while tiles.count < count, let found = await first(after: cursor, { if case .tile = $0 { true } else { false } }) {
            if case .tile(let tile) = found.received.item { tiles.append(tile) }
            cursor = found.index + 1
        }
        return tiles
    }
}

private extension Viewer.Item {
    var hello: Proto.Hello? { if case .message(.hello(let h)) = self { h } else { nil } }
    var tree: Proto.Tree? { if case .message(.tree(let t)) = self { t } else { nil } }
    var frame: Proto.FrameHeader? { if case .message(.frame(let f)) = self { f } else { nil } }
    var windows: [Proto.WindowInfo]? { if case .message(.windows(let w)) = self { w } else { nil } }
    var status: Proto.Status? { if case .message(.status(let s)) = self { s } else { nil } }
    var cursor: Proto.CursorShape? { if case .message(.cursor(let c)) = self { c } else { nil } }
    var build: Proto.Build? { if case .message(.build(let b)) = self { b } else { nil } }
}

/// A raw HTTP exchange over a socket (URLSession won't send arbitrary Upgrade requests): the status line.
private func rawStatusLine(port: Int, request: String) async -> String {
    await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return "" }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return "" }
        return String(decoding: buffer[0..<count], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    }.value
}

private func upgradeRequest(port: Int, path: String = Proto.webSocketPath, host: String? = nil, origin: String?) -> String {
    var lines = ["GET \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")", "Upgrade: websocket", "Connection: Upgrade",
                 "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="]
    if let origin { lines.append("Origin: \(origin)") }
    return lines.joined(separator: "\r\n") + "\r\n\r\n"
}

// MARK: - Stub suite

@Suite("Mirror server over stub bridges", .serialized, .timeLimit(.minutes(2)))
struct MacAppMirrorServerStubTests {
    @Test func servesTheViewerFilesFromInjectedData() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }

        let (page, pageResponse) = try await mirror.get("/")
        #expect(pageResponse.statusCode == 200)
        #expect(pageResponse.value(forHTTPHeaderField: "content-type") == "text/html; charset=utf-8")
        #expect(page == stubAssets.page)
        let (script, scriptResponse) = try await mirror.get(Proto.viewerScriptPath)
        #expect(script == stubAssets.script)
        #expect(scriptResponse.value(forHTTPHeaderField: "content-type")?.hasPrefix("text/javascript") == true)
        let (style, styleResponse) = try await mirror.get(Proto.viewerStylePath)
        #expect(style == stubAssets.style)
        #expect(styleResponse.value(forHTTPHeaderField: "content-type")?.hasPrefix("text/css") == true)
        let (icon, iconResponse) = try await mirror.get(Proto.iconPath)
        #expect(icon == stubAssets.icon)
        #expect(iconResponse.value(forHTTPHeaderField: "content-type") == "image/png")

        let (_, missing) = try await mirror.get("/__opentraffic/macapp/nothing")
        #expect(missing.statusCode == 404)
        let (_, post) = try await mirror.get("/", method: "POST")
        #expect(post.statusCode == 405)
        let (headBody, head) = try await mirror.get("/", method: "HEAD")
        #expect(head.statusCode == 200 && headBody.isEmpty)
        #expect(head.value(forHTTPHeaderField: "content-length") == String(stubAssets.page.count))

        // The window's current frame as PNG, at the frames' scale.
        let (png, pngResponse) = try await mirror.get(Proto.snapshotPath(window: stubWindowID))
        #expect(pngResponse.statusCode == 200)
        #expect(pngResponse.value(forHTTPHeaderField: "content-type") == "image/png")
        #expect(imageSize(png) == CGSize(width: 800, height: 600))
        let (mainPNG, _) = try await mirror.get(Proto.snapshotPath)
        #expect(imageSize(mainPNG) == CGSize(width: 800, height: 600))
        let (_, unknownWindow) = try await mirror.get(Proto.snapshotPath(window: 7))
        #expect(unknownWindow.statusCode == 404)
    }

    @Test func aViewerGetsHelloThenTreesThenFullFrames() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }

        let hello = try #require(await viewer.first { $0.hello != nil })
        #expect(hello.index == 0)
        let h = try #require(hello.received.item.hello)
        #expect(h.boot == "boot-1")
        #expect(h.scale == 2)
        #expect(h.appearance == .dark)
        #expect(h.app.name == "Orbit")
        #expect(h.windows == [Proto.WindowInfo(id: stubWindowID, title: "Orders", w: 400, h: 300, x: 0, y: 0, kind: .main, parent: nil, focused: true)])

        let tree = try #require(await viewer.first { $0.tree != nil })
        #expect(tree.index == 1)
        #expect(tree.received.item.tree?.window == stubWindowID)
        #expect(tree.received.item.tree?.nodes == stubNodes())
        #expect(tree.received.item.tree?.v == AXSnapshot.hash(stubNodes()))

        let frame = try #require(await viewer.first { $0.frame != nil })
        #expect(frame.index == 2)
        let header = try #require(frame.received.item.frame)
        #expect(header.window == stubWindowID && header.full && header.tiles == 1)
        let tiles = await viewer.tiles(after: frame.index, count: header.tiles)
        #expect(tiles.count == 1)
        let tile = try #require(tiles.first)
        #expect(tile.window == stubWindowID && tile.seq == header.seq)
        #expect(tile.x == 0 && tile.y == 0 && tile.w == 400 && tile.h == 300 && tile.format == .jpeg)
        #expect(imageSize(tile.data) == CGSize(width: 800, height: 600))
        #expect(mirror.server.viewerCount == 1)
    }

    @Test func actionsAndInputReachTheBridgesInOrder() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        _ = try #require(await viewer.first { $0.frame != nil })

        try await viewer.send(.act(.init(window: stubWindowID, key: "/Window:/Button:Add Order", action: .press)))
        try await viewer.send(.pointer(.init(window: stubWindowID, kind: .down, x: 30, y: 40)))
        try await viewer.send(.pointer(.init(window: stubWindowID, kind: .up, x: 30, y: 40)))
        try await viewer.send(.text(.init(window: stubWindowID, text: "Ada")))
        try await viewer.send(.key(.init(window: stubWindowID, code: .enter)))
        try await viewer.send(.setText(.init(window: stubWindowID, key: "/Window:/TextField:Customer", value: "Grace")))
        try await viewer.send(.act(.init(window: stubWindowID, key: "/Window:/CheckBox:Gift", action: .press)))
        // For a window that isn't mirrored: ignored.
        try await viewer.send(.text(.init(window: 9, text: "lost")))
        try await viewer.send(.text(.init(window: stubWindowID, text: "last")))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while mirror.input.events.last != "text last", clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mirror.input.events == [
            "pointer down 30,40 window 42 at -1470,340",
            "pointer up 30,40 window 42 at -1470,340",
            "text Ada",
            "key Enter",
            "setText Grace field 20,20,200,22 window 42",
            "text last",
        ])
        let performed = mirror.accessibility.performed
        #expect(performed.map(\.key) == ["/Window:/Button:Add Order", "/Window:/CheckBox:Gift"])
        #expect(performed.allSatisfy { $0.action == .press && $0.window == stubWindowID })
    }

    @Test func aClickOnARowsTextSelectsTheRow() async throws {
        // The app is never active: AppKit drops a click on a SwiftUI text in a List row (it doesn't accept
        // the first mouse), so the server selects the row through Accessibility after the click.
        let accessibility = StubAccessibility()
        accessibility.setNodes(stubNodes() + [
            .init(key: "/Window:/Outline:", role: "AXOutline", x: 200, y: 60, w: 180, h: 120, depth: 1),
            .init(key: "/Window:/Outline:/Row:", role: "AXRow", x: 200, y: 60, w: 180, h: 40, depth: 2, selected: true),
            .init(key: "/Window:/Outline:/Row:/Cell:", role: "AXCell", x: 200, y: 60, w: 180, h: 40, depth: 3, selected: true),
            .init(key: "/Window:/Outline:/Row:/Cell:/StaticText:Ada", role: "AXStaticText", label: "Ada", x: 210, y: 70, w: 50, h: 16, depth: 4),
            .init(key: "/Window:/Outline:/Row:#2", role: "AXRow", x: 200, y: 100, w: 180, h: 40, depth: 2),
            .init(key: "/Window:/Outline:/Row:#2/Cell:", role: "AXCell", x: 200, y: 100, w: 180, h: 40, depth: 3),
            .init(key: "/Window:/Outline:/Row:#2/Cell:/StaticText:Grace", role: "AXStaticText", label: "Grace", x: 210, y: 110, w: 50, h: 16, depth: 4),
            .init(key: "/Window:/Outline:/Row:#2/Cell:/TextField:Note", role: "AXTextField", label: "Note", value: "", x: 280, y: 110, w: 90, h: 20, depth: 4),
            // A table's column comes after its rows and covers them.
            .init(key: "/Window:/Outline:/Column:", role: "AXColumn", x: 200, y: 60, w: 180, h: 120, depth: 2),
        ])
        let mirror = try await StubMirror.start(accessibility: accessibility)
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        _ = try #require(await viewer.first { $0.frame != nil })

        func click(_ x: Double, _ y: Double, _ modifiers: [Proto.Modifier] = []) async throws {
            try await viewer.send(.pointer(.init(window: stubWindowID, kind: .down, x: x, y: y, modifiers: modifiers)))
            try await viewer.send(.pointer(.init(window: stubWindowID, kind: .up, x: x, y: y, modifiers: modifiers)))
        }
        try await click(220, 115)                     // Grace's name: her row
        try await click(220, 75)                      // Ada's name: her row is selected already
        try await click(300, 115)                     // the field in Grace's row: the field's own click
        try await click(220, 115, [.cmd])         // a Cmd-click is the app's to read
        try await click(350, 130)                     // the empty part of Grace's row: the row too
        try await click(50, 150)                      // outside any row
        try await viewer.send(.text(.init(window: stubWindowID, text: "done")))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while mirror.input.events.last != "text done", clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mirror.input.events.filter { $0.hasPrefix("pointer up") }.count == 6)
        #expect(accessibility.selected == ["/Window:/Outline:/Row:#2", "/Window:/Outline:/Row:#2"])
    }

    @Test func aChangedTreeIsPushedWithin100Milliseconds() async throws {
        let accessibility = StubAccessibility()
        let mirror = try await StubMirror.start(accessibility: accessibility)
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        let first = try #require(await viewer.first { $0.frame != nil })
        try await Task.sleep(for: .milliseconds(100))

        var slowest: Duration = .zero
        for round in 1...5 {
            let nodes = stubNodes(title: "Add Order \(round)")
            accessibility.setNodes(nodes)
            let changed = ContinuousClock.now
            accessibility.emit()
            let tree = try #require(await viewer.first(after: first.index) { $0.tree?.nodes == nodes })
            slowest = max(slowest, tree.received.time - changed)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(slowest < .milliseconds(100), "a tree arrived \(slowest) after the change")

        // A burst of changes is coalesced: snapshots start at most every 50 ms, and the last state arrives.
        try await Task.sleep(for: .milliseconds(100))
        let before = accessibility.snapshotCount
        let started = ContinuousClock.now
        var lastChange = started
        for index in 0..<20 {
            try await Task.sleep(for: .milliseconds(5))
            accessibility.setNodes(stubNodes(title: "Burst \(index)"))
            lastChange = ContinuousClock.now
            accessibility.emit()
        }
        let last = try #require(await viewer.first(after: first.index) { $0.tree?.nodes == stubNodes(title: "Burst 19") })
        let elapsed = ContinuousClock.now - started
        let snapshots = accessibility.snapshotCount - before
        #expect(snapshots <= Int(elapsed / .milliseconds(50)) + 2, "\(snapshots) snapshots in \(elapsed)")
        #expect(last.received.time - lastChange < .milliseconds(100), "the last change's tree arrived after \(last.received.time - lastChange)")
        // An unchanged tree is not sent again.
        let trees = viewer.items.filter { $0.item.tree?.nodes == stubNodes(title: "Burst 19") }
        #expect(trees.count == 1)
    }

    @Test func framesReachEveryViewerWithin150Milliseconds() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let one = mirror.viewer(), two = mirror.viewer()
        defer { one.close(); two.close() }
        let oneStart = try #require(await one.first { $0.frame != nil })
        let twoStart = try #require(await two.first { $0.frame != nil })

        for _ in 0..<5 {
            let sent = ContinuousClock.now
            let seq = mirror.capture.emitChange(tiles: 3)
            for (viewer, start) in [(one, oneStart.index), (two, twoStart.index)] {
                let header = try #require(await viewer.first(after: start) { $0.frame?.seq == seq })
                #expect(header.received.item.frame?.full == false && header.received.item.frame?.tiles == 3)
                let tiles = await viewer.tiles(after: header.index, count: 3)
                #expect(tiles.count == 3 && tiles.allSatisfy { $0.seq == seq && $0.window == stubWindowID })
                #expect(tiles.map(\.x) == [0, 16, 32])
                let arrived = try #require(viewer.items.last { if case .tile(let t) = $0.item { t.seq == seq } else { false } }).time
                #expect(arrived - sent < .milliseconds(150), "tiles arrived \(arrived - sent) after the frame")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aLateViewerStartsFromAFullFrameOfTheCurrentPixels() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let early = mirror.viewer()
        defer { early.close() }
        _ = try #require(await early.first { $0.frame != nil })
        var latest: UInt32 = 0
        for _ in 0..<3 { latest = mirror.capture.emitChange() }
        let seq = latest
        _ = try #require(await early.first { $0.frame?.seq == seq })

        let late = mirror.viewer()
        defer { late.close() }
        let frame = try #require(await late.first { $0.frame != nil })
        #expect(frame.received.item.frame?.full == true)
        #expect(frame.received.item.frame?.seq == seq)
        // Later changes follow as usual.
        let next = mirror.capture.emitChange()
        #expect(await late.first { $0.frame?.seq == next && $0.frame?.full == false } != nil)
        #expect(late.items.compactMap(\.item.frame).filter(\.full).count == 1)
    }

    @Test func statusWindowsAndCursorAreSentToViewers() async throws {
        let accessibility = StubAccessibility()
        let mirror = try await StubMirror.start(accessibility: accessibility)
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        _ = try #require(await viewer.first { $0.frame != nil })

        mirror.server.setStatus(.init(state: .restarting, message: "Rebuilt; restarting Orbit"))
        #expect(await viewer.first { $0.status?.state == .restarting }?.received.item.status?.message == "Rebuilt; restarting Orbit")
        // A viewer that joins now hears it right after hello.
        let late = mirror.viewer()
        defer { late.close() }
        let lateStatus = try #require(await late.first { $0.status != nil })
        #expect(lateStatus.index == 1)
        mirror.server.setStatus(.init(state: .running))
        #expect(await late.first { $0.status?.state == .running } != nil)

        // The window resizes (the viewer-options work will do this through AXSize): a new window list.
        accessibility.state.withLock { $0.windows[0].frame.size = CGSize(width: 500, height: 320) }
        accessibility.emit(.windowResized)
        let windows = try #require(await viewer.first { $0.windows != nil }?.received.item.windows)
        #expect(windows.map(\.w) == [500] && windows.map(\.h) == [320] && windows.first?.kind == .main)

        // The cursor follows what's under the pointer: a text field, a link (also over its label), else the arrow.
        try await viewer.send(.pointer(.init(window: stubWindowID, kind: .move, x: 50, y: 30)))
        #expect(await viewer.first { $0.cursor == .text } != nil)
        try await viewer.send(.pointer(.init(window: stubWindowID, kind: .move, x: 310, y: 25)))
        #expect(await viewer.first { $0.cursor == .pointer } != nil)
        try await viewer.send(.pointer(.init(window: stubWindowID, kind: .move, x: 150, y: 150)))
        #expect(await viewer.first { $0.cursor == .default } != nil)
        let cursors = viewer.items.compactMap(\.item.cursor)
        #expect(cursors == [.text, .pointer, .default])
    }

    @Test func aFailedBuildIsToldToViewersAndToViewersWhoComeLater() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        let first = try #require(await viewer.first { $0.frame != nil })
        // Nothing about builds before one runs.
        #expect(!viewer.items.contains { $0.item.build != nil })

        mirror.server.setBuild(.init(building: true))
        #expect(await viewer.first { $0.build == .init(building: true) } != nil)
        mirror.server.setBuild(.init(failed: true))
        #expect(await viewer.first { $0.build == .init(failed: true) } != nil)
        // The same state again isn't sent again.
        mirror.server.setBuild(.init(failed: true))
        // A viewer that joins now hears it right after hello (it sees the previous version).
        let late = mirror.viewer()
        defer { late.close() }
        let lateBuild = try #require(await late.first { $0.build != nil })
        #expect(lateBuild.index == 1 && lateBuild.received.item.build == .init(failed: true))
        // A good build: the banner goes for everyone, and later viewers are told so too.
        mirror.server.setBuild(.init())
        #expect(await viewer.first { $0.build == .init() } != nil)
        #expect(await late.first { $0.build == .init() } != nil)
        #expect(viewer.items.dropFirst(first.index).compactMap(\.item.build) == [.init(building: true), .init(failed: true), .init()])
        let later = mirror.viewer()
        defer { later.close() }
        #expect(await later.first { $0.build != nil }?.received.item.build == .init())
    }

    @Test func reservedAndUnknownMessagesBecomeEventsAndNothingBreaks() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let collected = OSAllocatedUnfairLock(initialState: [MirrorServer.Event]())
        let watcher = Task { for await event in mirror.server.events { collected.withLock { $0.append(event) } } }
        defer { watcher.cancel() }
        let viewer = mirror.viewer()
        _ = try #require(await viewer.first { $0.frame != nil })

        try await viewer.send(.viewport(.init(w: 1200, h: 700, appearance: .light)))
        try await viewer.sendRaw(#"{"t":"somethingNew","x":1}"#)
        try await viewer.sendRaw("not json")
        try await viewer.send(.act(.init(window: stubWindowID, key: "/Window:/Gone", action: .press)))
        try await viewer.send(.text(.init(window: stubWindowID, text: "still here")))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while mirror.input.events != ["text still here"], clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mirror.input.events == ["text still here"])
        #expect(!viewer.isClosed)
        viewer.close()
        while mirror.server.viewerCount > 0, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        let events = collected.withLock { $0 }
        #expect(events.contains { if case .viewerConnected(_, 1) = $0 { true } else { false } })
        #expect(events.contains { if case .message(_, .viewport(let v), _) = $0 { v.w == 1200 && v.h == 700 && v.appearance == .light } else { false } })
        #expect(events.contains { if case .failed(let reason) = $0 { reason.contains("act") } else { false } })
        #expect(events.contains { if case .viewerDisconnected(_, 0) = $0 { true } else { false } })
        #expect(mirror.server.viewerCount == 0)
    }

    @Test func pagesFromOtherSitesCannotOpenTheSocket() async throws {
        let mirror = try await StubMirror.start(allowedOrigins: ["https://orbit.example.dev"])
        defer { Task { await mirror.server.stop() } }
        let port = mirror.port
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "https://evil.example")) == "HTTP/1.1 403 Forbidden")
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "null")) == "HTTP/1.1 403 Forbidden")
        // Not a page (tools), the host's own browser, the share's public host through the proxy, a configured origin.
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: nil)) == "HTTP/1.1 101 Switching Protocols")
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "http://127.0.0.1:61234")) == "HTTP/1.1 101 Switching Protocols")
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "http://localhost:9")) == "HTTP/1.1 101 Switching Protocols")
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, host: "share.example.dev", origin: "https://share.example.dev"))
            == "HTTP/1.1 101 Switching Protocols")
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "https://orbit.example.dev")) == "HTTP/1.1 101 Switching Protocols")
        // Origins can be changed while running (the public URL is known once the tunnel is up).
        mirror.server.setAllowedOrigins(["https://later.example.dev"])
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "https://later.example.dev")) == "HTTP/1.1 101 Switching Protocols")
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, origin: "https://orbit.example.dev")) == "HTTP/1.1 403 Forbidden")
        // Upgrades elsewhere are refused.
        #expect(await rawStatusLine(port: port, request: upgradeRequest(port: port, path: "/other", origin: nil)) == "HTTP/1.1 404 Not Found")
    }

    @Test func aSocketOnAConnectionThatAlreadyServedAPageWorks() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let get = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(mirror.port)\r\n\r\n"
        // Two requests on one connection: the page, then the upgrade. Only the first status line is read,
        // so check the page's and then that the 101 follows in the same stream.
        let both = await Task.detached { [port = mirror.port] in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let request = get + upgradeRequest(port: port, origin: nil)
            _ = request.withCString { write(fd, $0, strlen($0)) }
            var text = ""
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !text.contains("101 Switching Protocols") {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                text += String(decoding: buffer[0..<count], as: UTF8.self)
            }
            return text
        }.value
        #expect(both.hasPrefix("HTTP/1.1 200 OK"))
        #expect(both.contains("HTTP/1.1 101 Switching Protocols"))
    }

    @Test func worksAsACollabProxyUpstream() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let proxy = CollabProxy(configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: mirror.port, overlayScript: Data("console.log('overlay')".utf8)))
        let proxyPort = try await proxy.start()
        defer { Task { await proxy.stop() } }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(proxyPort)/")!)
        let page = String(decoding: data, as: UTF8.self)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(page.contains(CollabProxy.scriptTag))
        #expect(page.contains(CollabProxy.bridgeTag(nonce: nil)))
        #expect(page.contains("<main id=stage></main>"))
    }

    @Test func aNewLaunchGreetsConnectedViewersAgain() async throws {
        let mirror = try await StubMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        let first = try #require(await viewer.first { $0.frame != nil })
        let oldCapture = mirror.capture

        let accessibility = StubAccessibility(windows: [.init(number: 77, title: "Orders", role: "AXWindow", subrole: nil,
                                                              frame: CGRect(x: 0, y: 0, width: 300, height: 200), isMain: true, isFocused: true, isMinimized: false)])
        let input = StubInput()
        let app = MirrorServer.App(name: "Orbit", boot: "boot-2", accessibility: accessibility, input: input) { id in
            let capture = StubCapture(windowID: id)
            mirror.captures.withLock { $0.append(capture) }
            return capture
        }
        try await mirror.server.replace(app: app)
        #expect(oldCapture.isStopped)
        let hello = try #require(await viewer.first(after: first.index + 1) { $0.hello != nil })
        #expect(hello.received.item.hello?.boot == "boot-2")
        #expect(hello.received.item.hello?.windows.map(\.id) == [77])
        #expect(await viewer.first(after: hello.index) { $0.tree?.window == 77 } != nil)
        #expect(await viewer.first(after: hello.index) { $0.frame?.window == 77 && $0.frame?.full == true } != nil)
        // Input now goes to the new launch.
        try await viewer.send(.text(.init(window: 77, text: "new")))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while input.events.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(input.events == ["text new"])
        #expect(mirror.input.events.isEmpty)
    }

    @Test func startFailsWithoutAWindowOrWhenCaptureFails() async throws {
        await #expect(throws: MirrorServerError.noWindow) {
            _ = try await StubMirror.start(accessibility: StubAccessibility(windows: []))
        }
        await #expect(throws: MirrorServerError.self) {
            _ = try await StubMirror.start(captureFailure: WindowCaptureError.notPermitted)
        }
    }

    @Test func stopClosesViewersAndStopsCapturing() async throws {
        let mirror = try await StubMirror.start()
        let viewer = mirror.viewer()
        _ = try #require(await viewer.first { $0.frame != nil })
        await mirror.server.stop()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !viewer.isClosed, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.isClosed)
        #expect(mirror.capture.isStopped)
        await #expect(throws: (any Error).self) {
            _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(mirror.port)/")!)
        }
    }
}

@Suite struct MacAppMirrorServerRuleTests {
    private func window(_ number: UInt32?, main: Bool = false, focused: Bool = false, minimized: Bool = false,
                        role: String = "AXWindow", frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)) -> AccessibilityTree.Window {
        .init(number: number, title: "W\(number ?? 0)", role: role, subrole: nil, frame: frame, isMain: main, isFocused: focused, isMinimized: minimized)
    }

    @Test func theMainWindowComesFirstAndIsKeptWhileItExists() {
        let windows = [window(1), window(2, main: true), window(3, focused: true)]
        let first = MirrorServer.mirroredWindows(windows, current: nil)
        // The main one first; the others are second windows (side by side in the viewer), not left out.
        #expect(first.map(\.info.id) == [2, 1, 3])
        #expect(first.first?.info == Proto.WindowInfo(id: 2, title: "W2", w: 300, h: 200, x: 0, y: 0, kind: .main, parent: nil))
        #expect(first.first?.frame == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(first.dropFirst().allSatisfy { $0.info.kind == .window && $0.info.parent == nil })
        // Another window becoming main doesn't move the mirror; the first one closing does.
        #expect(MirrorServer.mirroredWindows([window(1, main: true), window(2)], current: 2).map(\.info.id) == [2, 1])
        #expect(MirrorServer.mirroredWindows([window(1, main: true)], current: 2).map(\.info.id) == [1])
        // No number, minimized, zero-sized or not a window: not mirrored.
        #expect(MirrorServer.mirroredWindows([window(nil, main: true), window(4, minimized: true),
                                              window(5, frame: .zero), window(6, role: "AXSheet")], current: nil).isEmpty)
        #expect(MirrorServer.mirroredWindows([window(nil, main: true), window(7)], current: nil).map(\.info.id) == [7])
    }

    @Test func cursorShapeFollowsTheElementUnderThePointer() {
        let nodes = stubNodes()
        #expect(MirrorServer.cursorShape(at: CGPoint(x: 50, y: 30), in: nodes) == .text)
        #expect(MirrorServer.cursorShape(at: CGPoint(x: 310, y: 25), in: nodes) == .pointer)
        #expect(MirrorServer.cursorShape(at: CGPoint(x: 30, y: 260), in: nodes) == .default)
        #expect(MirrorServer.cursorShape(at: CGPoint(x: 900, y: 900), in: nodes) == .default)
        var disabled = nodes
        disabled[3].enabled = false
        #expect(MirrorServer.cursorShape(at: CGPoint(x: 50, y: 30), in: disabled) == .default)
    }

    @Test func snapshotsPaintEveryTileAtTheFramesScale() throws {
        let tiles = [
            Proto.Tile(window: 1, seq: 3, x: 0, y: 0, w: 20, h: 10, format: .jpeg, data: jpeg(width: 40, height: 20, gray: 1)),
            Proto.Tile(window: 1, seq: 3, x: 0, y: 10, w: 20, h: 10, format: .jpeg, data: jpeg(width: 40, height: 20, gray: 0)),
        ]
        let frame = CapturedFrame(window: 1, seq: 3, full: true, width: 20, height: 20, scale: 2, tiles: tiles, encodeTime: .zero)
        let png = try #require(MirrorServer.png(frame))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 40 && image.height == 40)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // The top tile is white, the bottom one black (y grows downwards in tiles).
        #expect((bitmap.colorAt(x: 20, y: 5)?.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.9)
        #expect((bitmap.colorAt(x: 20, y: 35)?.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.1)
    }

    @Test func onlyStartupHiccupsAreRetried() {
        #expect(MirrorServer.isTransient(WindowCaptureError.timedOut))
        #expect(MirrorServer.isTransient(WindowCaptureError.windowNotFound(3)))
        #expect(MirrorServer.isTransient(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)))
        #expect(!MirrorServer.isTransient(WindowCaptureError.notPermitted))
        #expect(!MirrorServer.isTransient(NSError(domain: "x", code: 1)))
    }
}

// MARK: - The Orbit fixture, served for real

private let fixtureAssets = MirrorServer.Assets(page: Data("<!doctype html><title>Orbit</title>".utf8), script: Data(), style: Data())

@MainActor
@Suite("Mirror server on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .timeLimit(.minutes(10)))
struct MacAppMirrorServerFixtureTests {
    @Test func aViewerGetsHelloTreeAndTilesOfTheRealWindow() async throws {
        try await withMirroredOrbit { server, viewer, orbit in
            let hello = try #require(await viewer.first(within: .seconds(10)) { $0.hello != nil }?.received.item.hello)
            #expect(hello.app.name == "Orbit")
            #expect(hello.scale >= 1)
            let window = try #require(hello.windows.first)
            #expect(hello.windows.count == 1 && window.kind == .main && window.w > 300 && window.h > 200)

            let tree = try #require(await viewer.first { $0.tree?.window == window.id }?.received.item.tree)
            #expect(tree.nodes.first?.key == Proto.NodeKey.root)
            #expect(tree.nodes.contains { $0.role == "AXButton" && $0.label == "Add Order" && $0.actions.contains(.press) })

            let frame = try #require(await viewer.first(within: .seconds(10)) { $0.frame?.window == window.id })
            let header = try #require(frame.received.item.frame)
            #expect(header.full)
            let tiles = await viewer.tiles(after: frame.index, count: header.tiles)
            #expect(tiles.count == header.tiles)
            let tile = try #require(tiles.first)
            #expect(tile.window == window.id && tile.seq == header.seq && tile.format == .jpeg)
            #expect(Double(tile.w) == window.w.rounded() && Double(tile.h) == window.h.rounded())
            let size = try #require(imageSize(tile.data))
            #expect(abs(size.width - Double(tile.w) * hello.scale) <= 1 && abs(size.height - Double(tile.h) * hello.scale) <= 1)

            let png = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(server.port!)\(Proto.snapshotPath(window: window.id))")!).0
            #expect(imageSize(png).map { abs($0.width - window.w * hello.scale) <= 2 } == true)
        }
    }

    @Test func anActChangesTheTreeAndThePixels() async throws {
        try await withMirroredOrbit { _, viewer, _ in
            let start = try #require(await viewer.first(within: .seconds(10)) { $0.frame?.full == true })
            let tree = try #require(viewer.items.compactMap(\.item.tree).last)
            let checkbox = try #require(tree.nodes.first { $0.role == "AXCheckBox" && $0.actions.contains(.press) && $0.w > 0 })
            let pressed = ContinuousClock.now
            try await viewer.send(.act(.init(window: tree.window, key: checkbox.key, action: .press)))
            let changed = try #require(await viewer.first(after: start.index) { item in
                item.tree?.nodes.first { $0.key == checkbox.key }.map { $0.value != checkbox.value } ?? false
            })
            print("MirrorServer fixture: tree after act press in \(changed.received.time - pressed)")
            // The checkbox redraws: a frame with tiles follows.
            let frame = try #require(await viewer.first(after: start.index + 1) { $0.frame != nil && $0.frame?.full == false })
            #expect((frame.received.item.frame?.tiles ?? 0) > 0)
        }
    }

    @Test func textEntryReachesTheFocusedField() async throws {
        try await withMirroredOrbit { _, viewer, _ in
            _ = try #require(await viewer.first(within: .seconds(10)) { $0.frame?.full == true })
            let tree = try #require(viewer.items.compactMap(\.item.tree).last)
            let field = try #require(newCustomerField(in: tree.nodes))
            let rows = tree.nodes.filter { $0.role == "AXRow" }.count

            try await viewer.send(.setText(.init(window: tree.window, key: field.key, value: "Ada Lovelace")))
            #expect(await viewer.first(within: .seconds(5)) { $0.tree?.nodes.first { $0.key == field.key }?.value == "Ada Lovelace" } != nil)
            // Typing goes to the focused field (setText left the caret at the end), Enter adds the order.
            try await viewer.send(.text(.init(window: tree.window, text: ", Countess")))
            #expect(await viewer.first(within: .seconds(5)) { $0.tree?.nodes.first { $0.key == field.key }?.value == "Ada Lovelace, Countess" } != nil)
            try await viewer.send(.key(.init(window: tree.window, code: .enter)))
            #expect(await viewer.first(within: .seconds(5)) { ($0.tree?.nodes.filter { $0.role == "AXRow" }.count ?? 0) == rows + 1 } != nil)
        }
    }

    @Test func aViewportResizesTheWindowWhichSendsANewWindowListAndAFullFrame() async throws {
        try await withMirroredOrbit { server, viewer, orbit in
            let hello = try #require(await viewer.first(within: .seconds(10)) { $0.hello != nil }?.received.item.hello)
            let start = try #require(await viewer.first(within: .seconds(10)) { $0.frame?.full == true })
            let window = try #require(hello.windows.first)
            // Larger: Orbit has a minimum size. The server resizes the main window through AXSize to the
            // viewer's room (viewer options, fit to the viewer); the app may round, so compare with what it took.
            try await viewer.send(.viewport(.init(w: window.w + 80, h: window.h + 60, appearance: nil)))
            let resized = try #require(await viewer.first(after: start.index, within: .seconds(10)) { item in
                item.windows?.first.map { $0.w > window.w && $0.h > window.h } ?? false
            }, "no window list with a larger size: \(viewer.items.compactMap(\.item.windows))")
            let info = try #require(resized.received.item.windows?.first)
            #expect(info.id == window.id)
            let size = try mainWindowSize(of: orbit.pid)
            #expect(abs(size.width - (window.w + 80)) <= 1 && abs(size.height - (window.h + 60)) <= 1, "AXSize is \(size)")
            #expect(abs(info.w - size.width) <= 1 && abs(info.h - size.height) <= 1)
            // The capture follows the resize with a full frame of the new size (it may come before the window list).
            let resizedTile = await viewer.first(after: start.index + 1, within: .seconds(5), isTile(of: size))
            #expect(resizedTile != nil, "no full frame of \(size); frames: \(viewer.items.compactMap(\.item.frame))")
        }
    }
}

/// Launches Orbit hidden, serves it with a MirrorServer over the real bridges, connects a viewer,
/// runs the body, then stops the server and quits Orbit.
@MainActor
private func withMirroredOrbit(_ body: (MirrorServer, Viewer, OrbitFixture) async throws -> Void) async throws {
    try await withOrbitFixture { orbit in
        try await waitForRows(orbit.pid)
        let server = MirrorServer(configuration: .init(app: try .live(pid: orbit.pid, name: "Orbit"), assets: fixtureAssets))
        let port = try await server.start()
        let viewer = Viewer(port: port)
        do {
            try await body(server, viewer, orbit)
        } catch {
            viewer.close()
            await server.stop()
            throw error
        }
        viewer.close()
        await server.stop()
    }
}

/// Waits until Orbit's main window lists its orders (it fills the list a moment after launch).
private func waitForRows(_ pid: pid_t) async throws {
    let tree = try AccessibilityTree(pid: pid)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while clock.now < deadline {
        if let snapshot = try? await tree.snapshot(window: .main), snapshot.title == "Orbit Orders", snapshot.nodes.contains(where: { $0.role == "AXRow" }) { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw FixtureError("Orbit's orders didn't appear")
}

/// The New customer field: the text field in the sidebar, below the list.
private func newCustomerField(in nodes: [Proto.AXNode]) -> Proto.AXNode? {
    guard let list = nodes.first(where: { $0.role == "AXOutline" || $0.role == "AXTable" }) else { return nil }
    return nodes.first { $0.role == "AXTextField" && $0.x < list.x + list.w && $0.y >= list.y + list.h - 1 }
}

/// Matches a tile of this size in points.
private func isTile(of size: CGSize) -> @Sendable (Viewer.Item) -> Bool {
    { item in
        guard case .tile(let tile) = item else { return false }
        return abs(Double(tile.w) - size.width) <= 1 && abs(Double(tile.h) - size.height) <= 1
    }
}

private func mainWindowSize(of pid: pid_t) throws -> CGSize {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success, let value else {
        throw FixtureError("Orbit has no main window")
    }
    var current: CFTypeRef?
    var taken = CGSize.zero
    guard AXUIElementCopyAttributeValue(value as! AXUIElement, kAXSizeAttribute as CFString, &current) == .success, let current,
          AXValueGetValue(current as! AXValue, .cgSize, &taken) else { throw FixtureError("can't read AXSize") }
    return taken
}

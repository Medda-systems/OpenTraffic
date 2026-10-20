import AppKit
import Foundation
import ImageIO
import os
import Testing
@testable import OpenTrafficCore

// Viewer options for a shared Mac app (docs/macapp-mirror-protocol.md, Viewer options): who may
// control it (everyone, watch only, ask to control), its window size (fit the leading viewer) and its
// appearance. The stub suite runs a MirrorServer over stand-in bridges and talks to it like the
// viewer page does (no permissions needed); the fixture suite starts real sessions of Orbit and needs
// Accessibility and Screen Recording (it skips without them and takes MacAppFixtureTurn).

private typealias Proto = MirrorProtocol

// MARK: - Stub bridges

private let mainID: Proto.WindowID = 42
private let secondID: Proto.WindowID = 43
private let mainFrame = CGRect(x: -1500, y: 300, width: 400, height: 300)
private let secondFrame = CGRect(x: -1000, y: 300, width: 300, height: 200)

private final class OptionsAccessibility: MirrorAccessibility, @unchecked Sendable {
    struct State {
        var windows: [AccessibilityTree.Window]
        var performed: [String] = []
        var resizes: [(window: UInt32, size: CGSize)] = []
        var raised: [UInt32] = []
        var closed: [UInt32] = []
        /// The app's minimum window size: a smaller AXSize gives this.
        var minimum = CGSize(width: 300, height: 250)
        var streams: [AsyncStream<AXChange>.Continuation] = []
    }
    let state: OSAllocatedUnfairLock<State>

    init(secondWindow: Bool = false) {
        var windows = [AccessibilityTree.Window(number: mainID, title: "Orders", role: "AXWindow", subrole: "AXStandardWindow",
                                                frame: mainFrame, isMain: true, isFocused: true, isMinimized: false)]
        if secondWindow {
            windows.append(.init(number: secondID, title: "Statistics", role: "AXWindow", subrole: "AXStandardWindow",
                                 frame: secondFrame, isMain: false, isFocused: false, isMinimized: false))
        }
        state = OSAllocatedUnfairLock(initialState: State(windows: windows))
    }

    func windows() async throws -> [AccessibilityTree.Window] { state.withLock { $0.windows } }

    func snapshot(window: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        try state.withLock { state in
            guard case .number(let id) = window, let match = state.windows.first(where: { $0.number == id }) else { throw AccessibilityTreeError.noWindow }
            let nodes: [Proto.AXNode] = [
                .init(key: "/Window:", role: "AXWindow", x: 0, y: 0, w: match.frame.width, h: match.frame.height, depth: 0),
                .init(key: "/Window:/Button:Add Order", role: "AXButton", label: "Add Order", x: 20, y: 20, w: 90, h: 24, depth: 1, actions: [.press]),
                .init(key: "/Window:/TextField:Customer", role: "AXTextField", label: "Customer", value: "", x: 20, y: 60, w: 200, h: 22, depth: 1),
            ]
            return AXSnapshot(windowNumber: id, title: match.title, frame: match.frame, nodes: nodes)
        }
    }

    func perform(key: String, action: Proto.Action, window: UInt32?) async throws {
        state.withLock { $0.performed.append("\(action.rawValue) \(key)") }
    }

    func changes() -> AsyncStream<AXChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AXChange.self)
        state.withLock { $0.streams.append(continuation) }
        return stream
    }

    func raise(window: UInt32) async throws { state.withLock { $0.raised.append(window) } }
    func close(window: UInt32) async throws { state.withLock { $0.closed.append(window) } }

    /// Like AppKit: the size never goes below the app's minimum; the window's top-left stays.
    func resize(window: UInt32, to size: CGSize) async throws -> CGSize? {
        let (got, streams) = state.withLock { state -> (CGSize, [AsyncStream<AXChange>.Continuation]) in
            let got = CGSize(width: max(size.width, state.minimum.width), height: max(size.height, state.minimum.height))
            state.resizes.append((window, size))
            if let index = state.windows.firstIndex(where: { $0.number == window }) { state.windows[index].frame.size = got }
            return (got, state.streams)
        }
        for stream in streams { stream.yield(AXChange(kind: .layout, notification: "AXResized", role: nil)) }
        return got
    }

    var performed: [String] { state.withLock { $0.performed } }
    var resizes: [(window: UInt32, size: CGSize)] { state.withLock { $0.resizes } }
    var raised: [UInt32] { state.withLock { $0.raised } }
    var closed: [UInt32] { state.withLock { $0.closed } }
}

private final class OptionsCapture: MirrorCapture, @unchecked Sendable {
    let windowID: CGWindowID
    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let started = OSAllocatedUnfairLock(initialState: false)

    init(windowID: CGWindowID) {
        self.windowID = windowID
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
    }

    func start() async throws {
        started.withLock { $0 = true }
        continuation.yield(full())
    }

    func stop() async { continuation.finish() }
    func fullFrame() async -> CapturedFrame? { started.withLock { $0 } ? full() : nil }

    private func full() -> CapturedFrame {
        let tile = Proto.Tile(window: windowID, seq: 0, x: 0, y: 0, w: 16, h: 16, format: .jpeg, data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        return CapturedFrame(window: windowID, seq: 0, full: true, width: 16, height: 16, scale: 2, tiles: [tile], encodeTime: .zero)
    }
}

private final class OptionsInput: MirrorInput, @unchecked Sendable {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    var events: [String] { log.withLock { $0 } }
    func send(_ pointer: Proto.Pointer, in window: InputSynthesizer.Window) throws { log.withLock { $0.append("pointer \(pointer.kind.rawValue)") } }
    func type(text: String) throws { log.withLock { $0.append("text \(text)") } }
    func send(_ key: Proto.Key) throws { log.withLock { $0.append("key \(key.code.rawValue)") } }
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {
        log.withLock { $0.append("setText \(text)") }
    }
}

private final class OptionsMenus: MirrorMenus, @unchecked Sendable {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    var events: [String] { log.withLock { $0 } }
    func bar() async throws -> [Proto.MenuItem] { [Proto.MenuItem(title: "Orders", items: [Proto.MenuItem(title: "Ship")])] }
    func perform(path: [String]) async throws { log.withLock { $0.append("menu \(path.joined(separator: ">"))") } }
    func openMenu() async throws -> MenuBridge.OpenMenu? { nil }
    func performOpen(path: [String]) async throws { log.withLock { $0.append("context \(path.joined(separator: ">"))") } }
    func closeOpen() async throws { log.withLock { $0.append("close menu") } }
    func showMenu(at point: CGPoint) async throws -> Bool { false }
}

private let assets = MirrorServer.Assets(page: Data("<!doctype html><title>Orbit</title>".utf8), script: Data(), style: Data())

/// A server over the stub bridges, started, with every event it emits collected.
private struct OptionsMirror {
    let accessibility: OptionsAccessibility
    let input: OptionsInput
    let menus: OptionsMenus
    let server: MirrorServer
    let port: Int
    let events: OSAllocatedUnfairLock<[MirrorServer.Event]>
    let watcher: Task<Void, Never>

    static func start(_ options: MacAppViewerOptions = .init(), secondWindow: Bool = false,
                      maximum: CGSize = CGSize(width: 1600, height: 1000),
                      isOnScreen: @escaping @Sendable (CGRect) -> Bool = { _ in false }) async throws -> OptionsMirror {
        let accessibility = OptionsAccessibility(secondWindow: secondWindow)
        let input = OptionsInput()
        let menus = OptionsMenus()
        let app = MirrorServer.App(name: "Orbit", boot: "boot-1", accessibility: accessibility, input: input, menus: menus) { OptionsCapture(windowID: $0) }
        let server = MirrorServer(configuration: .init(app: app, assets: assets, appearance: .light, options: options, maximumWindowSize: maximum,
                                                       isOnScreen: isOnScreen))
        let port = try await server.start()
        let events = OSAllocatedUnfairLock(initialState: [MirrorServer.Event]())
        let watcher = Task { for await event in server.events { events.withLock { $0.append(event) } } }
        return OptionsMirror(accessibility: accessibility, input: input, menus: menus, server: server, port: port, events: events, watcher: watcher)
    }

    func viewer(host: Bool = false) -> OptionsViewer { OptionsViewer(port: port, host: host) }

    func stop() async {
        await server.stop()
        watcher.cancel()
    }

    /// Input messages that reached the session's record (`.message` events), by type.
    var recordedInput: [String] {
        events.withLock { $0 }.compactMap { event -> String? in
            guard case .message(_, let message, _) = event else { return nil }
            switch message {
            case .viewport, .requestControl, .releaseControl: return nil
            default: return message.type
            }
        }
    }

    var appearanceEvents: [Proto.Appearance] {
        events.withLock { $0 }.compactMap { if case .viewerAppearance(let a) = $0 { a } else { nil } }
    }
}

/// A viewer as the page connects; `host` sends the header the share's proxy adds for the host's page.
private final class OptionsViewer: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let received = OSAllocatedUnfairLock(initialState: [Proto.ServerMessage]())

    convenience init(port: Int, host: Bool) {
        self.init(port: port, headers: host ? [Proto.hostHeader: "1"] : [:])
    }

    init(port: Int, headers: [String: String]) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)\(Proto.webSocketPath)")!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
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
            case .success:
                receive()
            case .failure:
                break
            }
        }
    }

    var messages: [Proto.ServerMessage] { received.withLock { $0 } }
    var controls: [Proto.Control] { messages.compactMap { if case .control(let c) = $0 { c } else { nil } } }
    var lastControl: Proto.Control? { controls.last }

    func send(_ message: Proto.ClientMessage) async throws { try await task.send(.string(message.jsonString())) }
    func close() { task.cancel(with: .normalClosure, reason: nil) }

    /// Waits until a message matches.
    @discardableResult
    func wait(within timeout: Duration = .seconds(5), _ what: String, _ match: @Sendable (Proto.ServerMessage) -> Bool) async throws -> Proto.ServerMessage {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let found = messages.first(where: match) { return found }
            try await Task.sleep(for: .milliseconds(5))
        } while clock.now < deadline
        throw FixtureError("viewer never got \(what); got \(messages.map(\.type))")
    }

    /// Waits until its latest `control` is this one.
    func waitForControl(_ expected: Proto.Control, within timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if lastControl == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError("viewer's control is \(String(describing: lastControl)), not \(expected)")
    }

    func waitForHello() async throws { try await wait("hello") { if case .hello = $0 { true } else { false } } }
}

private func eventually(_ what: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw FixtureError("timed out waiting for \(what)")
}

/// Every kind of input a viewer can send, aimed at the main window.
private let everyInput: [Proto.ClientMessage] = [
    .act(.init(window: mainID, key: "/Window:/Button:Add Order", action: .press)),
    .pointer(.init(window: mainID, kind: .move, x: 30, y: 30)),
    .pointer(.init(window: mainID, kind: .down, x: 30, y: 30)),
    .pointer(.init(window: mainID, kind: .up, x: 30, y: 30)),
    .pointer(.init(window: mainID, kind: .wheel, x: 30, y: 30, dy: 40)),
    .text(.init(window: mainID, text: "Ada")),
    .key(.init(window: mainID, code: .enter)),
    .setText(.init(window: mainID, key: "/Window:/TextField:Customer", value: "Ada")),
    .menuAction(.init(path: ["Orders", "Ship"])),
    .menuAction(.init(path: [], context: true)),
    .windowAction(.init(window: mainID, action: .focus)),
]

/// Sends a viewport without a size wish and waits until the server reported it: everything sent before
/// it has arrived. (It replaces the viewer's own viewport.)
private func sync(_ viewer: OptionsViewer, _ mirror: OptionsMirror, marker: Double) async throws {
    try await viewer.send(.viewport(.init(w: 0, h: marker)))
    try await eventually("the marker viewport") {
        mirror.events.withLock { $0 }.contains { if case .message(_, .viewport(let v), _) = $0 { v.h == marker } else { false } }
    }
}

// MARK: - Control, over stub bridges

@Suite("Viewer options over stub bridges", .serialized, .timeLimit(.minutes(2)))
struct MacAppViewerOptionsStubTests {
    @Test func everyoneControlsWithoutAControlMessage() async throws {
        let mirror = try await OptionsMirror.start()
        defer { Task { await mirror.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        try await viewer.waitForHello()
        try await viewer.send(.text(.init(window: mainID, text: "hi")))
        try await eventually("the text") { mirror.input.events == ["text hi"] }
        // The default needs no message: a viewer without one controls the app.
        #expect(viewer.controls.isEmpty)
    }

    @Test func watchOnlyDropsEveryKindOfInputServerSide() async throws {
        let mirror = try await OptionsMirror.start(.init(control: .watchOnly))
        defer { Task { await mirror.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        try await viewer.waitForControl(.init(mode: .watchOnly, you: false))
        // It comes right after hello, before the trees.
        let types = viewer.messages.map(\.type)
        #expect(Array(types.prefix(2)) == ["hello", "control"])

        for message in everyInput { try await viewer.send(message) }
        try await sync(viewer, mirror, marker: 1)
        // Give the applier a moment: nothing may reach the bridges or the session's record.
        try await Task.sleep(for: .milliseconds(300))
        #expect(mirror.input.events.isEmpty)
        #expect(mirror.accessibility.performed.isEmpty)
        #expect(mirror.menus.events.isEmpty)
        #expect(mirror.accessibility.raised.isEmpty && mirror.accessibility.closed.isEmpty)
        #expect(mirror.recordedInput.isEmpty)

        // The host switches to everyone: the viewer is told, and its input applies again.
        mirror.server.setViewerOptions(.init(control: .everyone))
        try await viewer.waitForControl(.init(mode: .everyone, you: true))
        for message in everyInput { try await viewer.send(message) }
        try await eventually("every input applied") {
            mirror.input.events.count == 7 && mirror.menus.events.count == 2 && mirror.accessibility.raised == [mainID]
        }
        #expect(mirror.input.events == ["pointer move", "pointer down", "pointer up", "pointer wheel", "text Ada", "key Enter", "setText Ada"])
        #expect(mirror.accessibility.performed == ["press /Window:/Button:Add Order"])
        #expect(mirror.menus.events == ["menu Orders>Ship", "close menu"])
        #expect(mirror.recordedInput.count == everyInput.count)
    }

    @Test func askToControlGivesOneViewerControlUntilTheHostTakesItBack() async throws {
        let mirror = try await OptionsMirror.start(.init(control: .askToControl))
        defer { Task { await mirror.stop() } }
        let ada = mirror.viewer()
        let bob = mirror.viewer()
        defer { ada.close(); bob.close() }
        try await ada.waitForControl(.init(mode: .askToControl, you: false))
        try await bob.waitForControl(.init(mode: .askToControl, you: false))

        // Ada asks: she is told she waits, and the host sees her request.
        try await ada.send(.requestControl(.init(name: "Ada\u{0007} Lovelace", client: "ada-browser-0001")))
        try await ada.waitForControl(.init(mode: .askToControl, you: false, requested: true))
        try await eventually("Ada's request") { await mirror.server.controlState().requests.count == 1 }
        let request = try #require(await mirror.server.controlState().requests.first)
        #expect(request.name == "Ada Lovelace")
        #expect(mirror.events.withLock { $0 }.contains { if case .control(let s) = $0 { s.requests.map(\.viewer) == [request.viewer] } else { false } })

        // Bob asks too and is turned down: he may ask again.
        try await bob.send(.requestControl(.init(name: "Bob", client: nil)))
        try await bob.waitForControl(.init(mode: .askToControl, you: false, requested: true))
        let bobID = try #require(await mirror.server.controlState().requests.last?.viewer)
        mirror.server.denyControl(viewer: bobID)
        try await bob.waitForControl(.init(mode: .askToControl, you: false, requested: false))

        // The host allows Ada: her input applies, Bob's doesn't, and Bob sees who has control.
        mirror.server.allowControl(viewer: request.viewer)
        try await ada.waitForControl(.init(mode: .askToControl, you: true, holder: "Ada Lovelace"))
        try await bob.waitForControl(.init(mode: .askToControl, you: false, holder: "Ada Lovelace"))
        try await bob.send(.text(.init(window: mainID, text: "bob")))
        try await ada.send(.text(.init(window: mainID, text: "ada")))
        try await eventually("Ada's text") { mirror.input.events == ["text ada"] }
        try await sync(bob, mirror, marker: 2)
        #expect(mirror.input.events == ["text ada"])
        #expect(await mirror.server.controlState().holder == .init(viewer: request.viewer, name: "Ada Lovelace", connected: true))

        // Ada's page drops and comes back with the same browser id: control is hers again at once.
        ada.close()
        try await eventually("Ada away") { await mirror.server.controlState().holder?.connected == false }
        try await bob.waitForControl(.init(mode: .askToControl, you: false, holder: "Ada Lovelace"))
        let back = mirror.viewer()
        defer { back.close() }
        try await back.waitForControl(.init(mode: .askToControl, you: false, holder: "Ada Lovelace"))
        try await back.send(.requestControl(.init(name: "Ada Lovelace", client: "ada-browser-0001")))
        try await back.waitForControl(.init(mode: .askToControl, you: true, holder: "Ada Lovelace"))
        #expect(await mirror.server.controlState().requests.isEmpty)
        try await back.send(.text(.init(window: mainID, text: "again")))
        try await eventually("Ada's text after reconnecting") { mirror.input.events == ["text ada", "text again"] }

        // The host takes control back: nobody but the host controls the app.
        mirror.server.revokeControl()
        try await back.waitForControl(.init(mode: .askToControl, you: false))
        try await bob.waitForControl(.init(mode: .askToControl, you: false))
        try await back.send(.text(.init(window: mainID, text: "late")))
        try await sync(back, mirror, marker: 3)
        try await Task.sleep(for: .milliseconds(200))
        #expect(mirror.input.events == ["text ada", "text again"])
        #expect(await mirror.server.controlState().holder == nil)
    }

    @Test func aViewerGivesControlBackAndAModeChangeDropsGrantsAndRequests() async throws {
        let mirror = try await OptionsMirror.start(.init(control: .askToControl))
        defer { Task { await mirror.stop() } }
        let ada = mirror.viewer()
        let bob = mirror.viewer()
        defer { ada.close(); bob.close() }
        try await ada.waitForControl(.init(mode: .askToControl, you: false))
        try await ada.send(.requestControl(.init(name: "Ada", client: "ada-browser-0002")))
        try await eventually("Ada's request") { await mirror.server.controlState().requests.count == 1 }
        let adaID = try #require(await mirror.server.controlState().requests.first?.viewer)
        mirror.server.allowControl(viewer: adaID)
        try await ada.waitForControl(.init(mode: .askToControl, you: true, holder: "Ada"))
        try await ada.send(.releaseControl)
        try await ada.waitForControl(.init(mode: .askToControl, you: false))
        #expect(await mirror.server.controlState().holder == nil)

        // A waiting request, then a new mode: it is dropped and everyone is told.
        try await bob.send(.requestControl(.init(name: "Bob")))
        try await bob.waitForControl(.init(mode: .askToControl, you: false, requested: true))
        mirror.server.setViewerOptions(.init(control: .watchOnly))
        try await bob.waitForControl(.init(mode: .watchOnly, you: false))
        try await ada.waitForControl(.init(mode: .watchOnly, you: false))
        #expect(await mirror.server.controlState() == .init(mode: .watchOnly))
        // Asking in another mode changes nothing.
        try await bob.send(.requestControl(.init(name: "Bob")))
        try await sync(bob, mirror, marker: 4)
        #expect(await mirror.server.controlState().requests.isEmpty)
    }

    @Test func theHostsOwnPageControlsTheAppInEveryMode() async throws {
        let mirror = try await OptionsMirror.start(.init(control: .watchOnly))
        defer { Task { await mirror.stop() } }
        let host = mirror.viewer(host: true)
        let visitor = mirror.viewer()
        defer { host.close(); visitor.close() }
        try await host.waitForControl(.init(mode: .watchOnly, you: true))
        try await visitor.waitForControl(.init(mode: .watchOnly, you: false))
        try await visitor.send(.text(.init(window: mainID, text: "visitor")))
        try await host.send(.text(.init(window: mainID, text: "host")))
        try await eventually("the host's text") { mirror.input.events == ["text host"] }
        try await sync(visitor, mirror, marker: 5)
        #expect(mirror.input.events == ["text host"])

        mirror.server.setViewerOptions(.init(control: .askToControl))
        try await host.waitForControl(.init(mode: .askToControl, you: true))
        try await host.send(.text(.init(window: mainID, text: "still host")))
        try await eventually("the host's text in ask to control") { mirror.input.events == ["text host", "text still host"] }
    }

    @Test func onlyTheSharesProxySaysWhichPageIsTheHosts() async throws {
        let mirror = try await OptionsMirror.start(.init(control: .watchOnly))
        defer { Task { await mirror.stop() } }
        // As a Mac app share sets it up (AppStore.startShareProxy): the mirror server behind CollabProxy.
        let proxy = CollabProxy(configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: mirror.port, overlayScript: Data(),
                                                     rewritesHostHeader: true, mirrorsMacApp: true))
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }
        let origin = "http://127.0.0.1:\(port)"

        // A visitor can't say it is the host: the proxy drops the header.
        let visitor = OptionsViewer(port: port, headers: ["Origin": origin, Proto.hostHeader: "1"])
        defer { visitor.close() }
        try await visitor.waitForControl(.init(mode: .watchOnly, you: false))

        // The host's own page (signed in with the host cookie, on this Mac) controls the app.
        let host = OptionsViewer(port: port, headers: ["Origin": origin, "Cookie": "\(CollabProxy.hostCookiePrefix)_\(port)=\(proxy.hostToken)"])
        defer { host.close() }
        try await host.waitForControl(.init(mode: .watchOnly, you: true))
        try await visitor.send(.text(.init(window: mainID, text: "visitor")))
        try await host.send(.text(.init(window: mainID, text: "host")))
        try await eventually("the host's text") { mirror.input.events == ["text host"] }
        try await sync(visitor, mirror, marker: 7)
        #expect(mirror.input.events == ["text host"])
    }

    // MARK: Window size

    @Test func aViewportResizesOnlyTheMainWindowWithinTheAppsMinimumAndTheDisplay() async throws {
        let mirror = try await OptionsMirror.start(secondWindow: true, maximum: CGSize(width: 1600, height: 1000))
        defer { Task { await mirror.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        try await viewer.waitForHello()

        try await viewer.send(.viewport(.init(w: 1200.7, h: 700.2, appearance: .dark)))
        try await eventually("a resize to 1200x700") { mirror.accessibility.resizes.count == 1 }
        #expect(mirror.accessibility.resizes.first?.window == mainID)
        #expect(mirror.accessibility.resizes.first?.size == CGSize(width: 1200, height: 700))
        // Viewers get the new size in a window list; the second window keeps its own.
        let windows = try await viewer.wait("the resized window list") { message in
            if case .windows(let list) = message { list.first { $0.id == mainID }?.w == 1200 } else { false }
        }
        if case .windows(let list) = windows {
            #expect(list.first { $0.id == mainID }?.h == 700)
            #expect(list.first { $0.id == secondID }?.w == 300 && list.first { $0.id == secondID }?.h == 200)
        }

        // Smaller than the app allows: asked once, and the app's minimum is learned.
        try await viewer.send(.viewport(.init(w: 120, h: 90)))
        try await eventually("a resize to the smallest viewport size") { mirror.accessibility.resizes.count == 2 }
        #expect(mirror.accessibility.resizes.last?.size == MirrorServer.minimumViewportSize)
        try await viewer.send(.viewport(.init(w: 260, h: 200)))
        try await Task.sleep(for: .milliseconds(600))
        #expect(mirror.accessibility.resizes.count == 2, "asked below the app's minimum again: \(mirror.accessibility.resizes)")

        // Larger than the off-screen display: the most that fits.
        try await viewer.send(.viewport(.init(w: 5000, h: 3000)))
        try await eventually("a resize to the maximum") { mirror.accessibility.resizes.count == 3 }
        #expect(mirror.accessibility.resizes.last?.size == CGSize(width: 1600, height: 1000))

        // The Simple view has no size wish: with no viewer wishing one, the window gets its own size back.
        try await viewer.send(.viewport(.init(w: 0, h: 0, appearance: .dark)))
        try await eventually("the app's own size after the Simple view") { mirror.accessibility.resizes.count == 4 }
        #expect(mirror.accessibility.resizes.last?.size == mainFrame.size)
        try await viewer.send(.viewport(.init(w: 900, h: 600)))
        try await eventually("a resize to 900x600") { mirror.accessibility.resizes.count == 5 }
        #expect(mirror.accessibility.resizes.last?.size == CGSize(width: 900, height: 600))

        // The host keeps the app's own size: the window gets back the size it had, and stays.
        mirror.server.setViewerOptions(.init(windowSize: .app))
        try await eventually("the app's own size back") { mirror.accessibility.resizes.count == 6 }
        #expect(mirror.accessibility.resizes.last?.size == mainFrame.size)
        #expect(mirror.accessibility.resizes.allSatisfy { $0.window == mainID })
        try await viewer.send(.viewport(.init(w: 700, h: 500)))
        try await Task.sleep(for: .milliseconds(600))
        #expect(mirror.accessibility.resizes.count == 6, "resized while keeping the app's size")
    }

    @Test func aResizeThatWouldReachAScreenOfThisMacIsNotMade() async throws {
        // A pretend screen starts 500 points right of the main window's left edge.
        let screen = CGRect(x: mainFrame.minX + 500, y: 0, width: 2000, height: 2000)
        let mirror = try await OptionsMirror.start(isOnScreen: { $0.intersects(screen) })
        defer { Task { await mirror.stop() } }
        let viewer = mirror.viewer()
        defer { viewer.close() }
        try await viewer.waitForHello()
        try await viewer.send(.viewport(.init(w: 900, h: 600)))
        try await eventually("the refusal") {
            mirror.events.withLock { $0 }.contains { if case .failed(let reason) = $0 { reason.contains("screen of this Mac") } else { false } }
        }
        #expect(mirror.accessibility.resizes.isEmpty)
        try await viewer.send(.viewport(.init(w: 450, h: 400)))
        try await eventually("a resize that stays off the screen") { mirror.accessibility.resizes.count == 1 }
        #expect(mirror.accessibility.resizes.first?.size == CGSize(width: 450, height: 400))
    }

    @Test func theFirstViewerLeadsTheSizeAndTheHolderLeadsInAskToControl() async throws {
        let mirror = try await OptionsMirror.start()
        defer { Task { await mirror.stop() } }
        let simple = mirror.viewer()
        defer { simple.close() }
        try await simple.waitForHello()
        // The first viewer is on the Simple view: its scheme counts, not its (missing) size.
        try await simple.send(.viewport(.init(w: 0, h: 0, appearance: .dark)))
        let first = mirror.viewer()
        defer { first.close() }
        try await first.waitForHello()
        try await first.send(.viewport(.init(w: 1000, h: 600, appearance: .light)))
        try await eventually("the first sized viewer's size") { mirror.accessibility.resizes.last?.size == CGSize(width: 1000, height: 600) }
        let second = mirror.viewer()
        try await second.waitForHello()
        try await second.send(.viewport(.init(w: 800, h: 500, appearance: .light)))
        try await eventually("the second viewer's viewport") {
            mirror.events.withLock { $0 }.contains { if case .message(_, .viewport(let v), _) = $0 { v.w == 800 } else { false } }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(mirror.accessibility.resizes.last?.size == CGSize(width: 1000, height: 600))
        #expect(mirror.appearanceEvents == [.dark])

        // The first one leaves: the next one leads.
        first.close()
        try await eventually("the second viewer's size") { mirror.accessibility.resizes.last?.size == CGSize(width: 800, height: 500) }

        // Ask to control: the viewer with control leads.
        let third = mirror.viewer()
        defer { third.close(); second.close() }
        try await third.waitForHello()
        try await third.send(.viewport(.init(w: 1300, h: 800)))
        mirror.server.setViewerOptions(.init(control: .askToControl))
        try await third.waitForControl(.init(mode: .askToControl, you: false))
        try await third.send(.requestControl(.init(name: "Cy")))
        try await eventually("Cy's request") { await mirror.server.controlState().requests.count == 1 }
        let cy = try #require(await mirror.server.controlState().requests.first?.viewer)
        #expect(mirror.accessibility.resizes.last?.size == CGSize(width: 800, height: 500))
        mirror.server.allowControl(viewer: cy)
        try await eventually("the holder's size") { mirror.accessibility.resizes.last?.size == CGSize(width: 1300, height: 800) }
        mirror.server.revokeControl()
        try await eventually("the first viewer's size again") { mirror.accessibility.resizes.last?.size == CGSize(width: 800, height: 500) }
    }
}

// MARK: - Rules

@Suite struct MacAppViewerOptionsRuleTests {
    @Test func aViewportBecomesAWindowSizeInWholePointsWithinLimits() {
        let maximum = CGSize(width: 1840, height: 1100)
        #expect(MirrorServer.windowSize(for: .init(w: 1200.9, h: 700.4), maximum: maximum) == CGSize(width: 1200, height: 700))
        #expect(MirrorServer.windowSize(for: .init(w: 50, h: 20), maximum: maximum) == MirrorServer.minimumViewportSize)
        #expect(MirrorServer.windowSize(for: .init(w: 4000, h: 3000), maximum: maximum) == maximum)
        #expect(MirrorServer.windowSize(for: .init(w: 0, h: 0), maximum: maximum) == nil)
        #expect(MirrorServer.windowSize(for: .init(w: .nan, h: 500), maximum: maximum) == nil)
        // The display's own limit: the hider's window origin is 40 by 60 points in.
        #expect(MirrorServer.defaultMaximumWindowSize == CGSize(width: OffscreenDisplay.pointSize.width - 80, height: OffscreenDisplay.pointSize.height - 100))
    }

    @Test func aRefusedResizeTeachesTheAppsMinimum() {
        let asked = CGSize(width: 200, height: 150)
        let learned = MirrorServer.learnedMinimum(asked: asked, got: CGSize(width: 480, height: 150), before: .zero)
        #expect(learned == CGSize(width: 480, height: 0))
        #expect(MirrorServer.learnedMinimum(asked: asked, got: CGSize(width: 300, height: 320), before: learned) == CGSize(width: 480, height: 320))
        #expect(MirrorServer.target(CGSize(width: 300, height: 900), minimum: CGSize(width: 480, height: 320)) == CGSize(width: 480, height: 900))
    }

    @Test func namesAndBrowserIDsFromViewersAreCleaned() {
        #expect(MirrorServer.cleanName("  Ada\u{0}\u{7} Lovelace \n") == "Ada Lovelace")
        #expect(MirrorServer.cleanName("   ") == nil)
        #expect(MirrorServer.cleanName(String(repeating: "x", count: 50))?.count == 32)
        #expect(MirrorServer.cleanToken("q9XAbc-_0123456789abcd") == "q9XAbc-_0123456789abcd")
        #expect(MirrorServer.cleanToken("short") == nil)
        #expect(MirrorServer.cleanToken("has space in it") == nil)
        #expect(MirrorServer.cleanToken("ümlaut-ümlaut") == nil)
        #expect(MirrorServer.cleanToken(String(repeating: "a", count: 129)) == nil)
    }

    @Test func theAppearanceGoesToTheAppAsLaunchArgumentsAndDarkNeedsADarkMac() {
        #expect(MacAppSession.appearanceArguments(.light) == ["-NSRequiresAquaSystemAppearance", "YES"])
        #expect(MacAppSession.appearanceArguments(.dark) == ["-NSRequiresAquaSystemAppearance", "NO"])
        #expect(MacAppSession.achievableAppearance(.light, host: .dark) == .light)
        #expect(MacAppSession.achievableAppearance(.light, host: .light) == .light)
        #expect(MacAppSession.achievableAppearance(.dark, host: .dark) == .dark)
        #expect(MacAppSession.achievableAppearance(.dark, host: .light) == .light)
    }

    @Test func theOptionsDefaultToEveryoneTheFirstViewersAppearanceAndFittingTheViewer() throws {
        let options = MacAppViewerOptions()
        #expect(options.control == .everyone && options.appearance == .viewer && options.windowSize == .fitViewer)
        let decoded = try JSONDecoder().decode(MacAppViewerOptions.self, from: Data("{}".utf8))
        #expect(decoded == options)
        let encoded = try JSONEncoder().encode(MacAppViewerOptions(control: .askToControl, appearance: .dark, windowSize: .app))
        #expect(try JSONDecoder().decode(MacAppViewerOptions.self, from: encoded) == MacAppViewerOptions(control: .askToControl, appearance: .dark, windowSize: .app))
    }
}

// MARK: - Appearance and size on the Orbit fixture

@MainActor
@Suite("Viewer options on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .macAppFixtureTurn, .timeLimit(.minutes(10)))
struct MacAppViewerOptionsFixtureTests {
    /// The first viewer's color scheme relaunches the copy in it, and the host's choice relaunches it
    /// again: each launch's first frame is light or dark, and `hello` says which.
    @Test func lightAndDarkLaunchesGiveALightAndADarkFirstFrame() async throws {
        // Dark can only be shown on a Mac in Dark; on a light Mac the dark half can't be checked.
        let host = MirrorServer.hostAppearance()
        let session = try await startOrbitSession(.init(appearance: .viewer, windowSize: .app))
        do {
            #expect(session.appearance == host)
            let port = try #require(session.port)
            let viewer = PixelViewer(port: port)
            defer { viewer.close() }
            let firstBoot = try await viewer.hello().boot
            let hostLuma = try await viewer.firstFrameLuma(boot: firstBoot)
            guard host == .dark else {
                // A dark wish on a light Mac changes nothing (and doesn't restart the app).
                try await viewer.send(.viewport(.init(w: 0, h: 0, appearance: .dark)))
                try await Task.sleep(for: .seconds(2))
                #expect(session.appearance == .light && session.pid != nil)
                #expect((try? await viewer.hello(after: firstBoot, within: .seconds(1))) == nil)
                #expect(hostLuma > 0.6, "a light launch's first frame isn't light: \(hostLuma)")
                await session.stop()
                return
            }

            // The first viewer prefers light: the app restarts in it.
            try await viewer.send(.viewport(.init(w: 0, h: 0, appearance: .light)))
            let switched = try await viewer.hello(after: firstBoot)
            #expect(switched.appearance == .light)
            #expect(session.appearance == .light && session.viewerAppearance == .light)
            let pid = try #require(session.pid)
            #expect(OrbitFixture.run("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"]).contains("-NSRequiresAquaSystemAppearance YES"))
            let lightLuma = try await viewer.firstFrameLuma(boot: switched.boot)

            // The host picks dark: it restarts dark again.
            session.setViewerOptions(.init(appearance: .dark, windowSize: .app))
            let back = try await viewer.hello(after: switched.boot)
            #expect(back.appearance == .dark)
            let backLuma = try await viewer.firstFrameLuma(boot: back.boot)

            print("Viewer options fixture: luma dark \(hostLuma), light \(lightLuma), dark again \(backLuma)")
            #expect(hostLuma < 0.4, "a dark launch's first frame isn't dark: \(hostLuma)")
            #expect(lightLuma > 0.6, "a light launch's first frame isn't light: \(lightLuma)")
            #expect(backLuma < 0.4, "the dark relaunch's first frame isn't dark: \(backLuma)")
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    /// A viewport sizes Orbit's real window through AXSize; the app's minimum holds.
    @Test func aViewportResizesTheRealWindow() async throws {
        let session = try await startOrbitSession(.init(appearance: .mac, windowSize: .fitViewer))
        do {
            let port = try #require(session.port)
            let viewer = PixelViewer(port: port)
            defer { viewer.close() }
            let hello = try await viewer.hello()
            let start = try #require(hello.windows.first)
            let wanted = CGSize(width: start.w + 120, height: start.h + 80)
            try await viewer.send(.viewport(.init(w: wanted.width, h: wanted.height)))
            try await viewer.waitForMainWindow(within: .seconds(10)) { abs($0.w - wanted.width) <= 1 && abs($0.h - wanted.height) <= 1 }
            let pid = try #require(session.pid)
            let real = try #require(mainWindowSize(of: pid))
            #expect(abs(real.width - wanted.width) <= 1 && abs(real.height - wanted.height) <= 1, "AXSize is \(real)")

            // Far below Orbit's minimum: it keeps its minimum, which viewers see.
            try await viewer.send(.viewport(.init(w: 200, h: 150)))
            try await viewer.waitForMainWindow(within: .seconds(10)) { $0.w < wanted.width - 1 }
            let small = try #require(mainWindowSize(of: pid))
            #expect(small.width >= 200 && small.height >= 150)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }
}

private let fixtureAssets = MirrorServer.Assets(page: Data("<!doctype html><title>Orbit</title>".utf8), script: Data(), style: Data())
/// In this checkout's .build, like the session fixture tests' folders.
private let fixtureSessions = OrbitFixture.repository.appendingPathComponent(".build/macapp-session-tests", isDirectory: true)

@MainActor
private func startOrbitSession(_ options: MacAppViewerOptions) async throws -> MacAppSession {
    try OrbitFixture.buildIfNeeded()
    await MacAppSession.removeLeftovers(in: fixtureSessions)
    let app = MacApp(name: "Orbit", bundle: OrbitFixture.app, bundleIdentifier: OrbitFixture.bundleIdentifier, projectDirectory: OrbitFixture.folder, isRunning: false)
    let session = MacAppSession(options: .init(app: app, data: .empty, assets: fixtureAssets, viewerOptions: options,
                                               sessionDirectory: fixtureSessions.appendingPathComponent(UUID().uuidString, isDirectory: true),
                                               restartsAutomatically: false))
    try await session.start()
    return session
}

/// The real main window's AXSize.
private func mainWindowSize(of pid: pid_t) -> CGSize? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success, let value else { return nil }
    var size: CFTypeRef?
    var taken = CGSize.zero
    guard AXUIElementCopyAttributeValue(value as! AXUIElement, kAXSizeAttribute as CFString, &size) == .success, let size,
          AXValueGetValue(size as! AXValue, .cgSize, &taken) else { return nil }
    return taken
}

/// A viewer that keeps hellos, window lists and the tiles of full frames, by boot.
private final class PixelViewer: @unchecked Sendable {
    struct Seen { var hellos: [Proto.Hello] = []; var windows: [[Proto.WindowInfo]] = []; var tiles: [(boot: String?, tile: Proto.Tile)] = []; var fullSeqs: Set<String> = [] }
    let task: URLSessionWebSocketTask
    private let seen = OSAllocatedUnfairLock(initialState: Seen())

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
                let message = try? Proto.ServerMessage.decode(text)
                seen.withLock { seen in
                    switch message {
                    case .hello(let hello): seen.hellos.append(hello); seen.windows.append(hello.windows)
                    case .windows(let list): seen.windows.append(list)
                    case .frame(let frame) where frame.full: seen.fullSeqs.insert("\(frame.window):\(frame.seq)")
                    default: break
                    }
                }
                receive()
            case .success(.data(let data)):
                if let tile = try? Proto.Tile(decoding: data) {
                    seen.withLock { seen in
                        if seen.fullSeqs.contains("\(tile.window):\(tile.seq)") { seen.tiles.append((seen.hellos.last?.boot, tile)) }
                    }
                }
                receive()
            case .success:
                receive()
            case .failure:
                break
            }
        }
    }

    func send(_ message: Proto.ClientMessage) async throws { try await task.send(.string(message.jsonString())) }
    func close() { task.cancel(with: .normalClosure, reason: nil) }

    /// The first hello, or the first with another boot than `boot`.
    func hello(after boot: String? = nil, within timeout: Duration = .seconds(40)) async throws -> Proto.Hello {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let hello = seen.withLock({ $0.hellos.first { boot == nil || $0.boot != boot } }) { return hello }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError("no hello\(boot.map { " after boot \($0)" } ?? "")")
    }

    func waitForMainWindow(within timeout: Duration, _ match: @Sendable (Proto.WindowInfo) -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let main = seen.withLock({ $0.windows.last?.first }), match(main) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError("the main window never matched; last \(String(describing: seen.withLock { $0.windows.last?.first }))")
    }

    /// The mean luma (0 dark to 1 light) of the first full frame of the launch with this boot.
    func firstFrameLuma(boot: String, within timeout: Duration = .seconds(20)) async throws -> Double {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let tiles = seen.withLock { $0.tiles.filter { $0.boot == boot }.map(\.tile) }
            if let first = tiles.first {
                let frame = tiles.filter { $0.window == first.window && $0.seq == first.seq }
                if let luma = meanLuma(frame) { return luma }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError("no full frame for boot \(boot)")
    }
}

/// The tiles drawn into a small gray image, averaged.
private func meanLuma(_ tiles: [Proto.Tile]) -> Double? {
    let side = 64
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    let width = tiles.map { Double($0.x) + Double($0.w) }.max() ?? 1, height = tiles.map { Double($0.y) + Double($0.h) }.max() ?? 1
    for tile in tiles {
        guard let source = CGImageSourceCreateWithData(tile.data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
        let rect = CGRect(x: Double(tile.x) / width * Double(side), y: Double(side) - (Double(tile.y) + Double(tile.h)) / height * Double(side),
                          width: Double(tile.w) / width * Double(side), height: Double(tile.h) / height * Double(side))
        context.draw(image, in: rect)
    }
    guard let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
    var total = 0
    for index in 0..<(side * side) { total += Int(pixels[index]) }
    return Double(total) / Double(side * side) / 255
}

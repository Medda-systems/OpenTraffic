import AppKit
import ApplicationServices
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import OpenTrafficCore

// App menus and context menus: the rules (shortcuts as shown, what is never offered, the protocol's
// shapes), the mirror server's menu messages over stub bridges (no permissions needed, as on GitHub
// Actions), and MenuBridge plus the server on the real Orbit fixture (Accessibility and Screen
// Recording permission; skips without them and takes MacAppFixtureTurn through withOrbitFixture).

private typealias Proto = MirrorProtocol
private typealias Item = MirrorProtocol.MenuItem

// MARK: - Rules

@Suite struct MacAppMenuRuleTests {
    @Test func shortcutsReadAsMacMenusShowThem() {
        func s(_ char: String?, _ modifiers: Int?, _ glyph: Int? = nil) -> String? { MenuBridge.shortcut(char: char, modifiers: modifiers, glyph: glyph) }
        #expect(s("S", 1) == "⇧⌘S")
        #expect(s("s", 0) == "⌘S")
        #expect(s("I", 2) == "⌥⌘I")
        #expect(s("Q", 4) == "⌃⌘Q")
        #expect(s("Q", 7) == "⌃⌥⇧⌘Q")
        #expect(s(",", 0) == "⌘,")
        #expect(s("?", 0) == "⌘?")
        #expect(s("⎋", 2, 27) == "⌥⌘⎋")
        #expect(s("\t", 12, 2) == "⌃⇥")
        #expect(s("\t", 13, 2) == "⌃⇧⇥")
        #expect(s("\r", 0) == "⌘↩")
        #expect(s("\u{8}", 0) == "⌘⌫")
        #expect(s("\u{F700}", 2) == "⌥⌘↑")
        #expect(s("\u{F708}", 0) == "⌘F5")
        #expect(s(" ", 4) == "⌃⌘Space")
        #expect(s("F", 24) == "fnF")
        #expect(s(nil, 8, 150) == "🎤")
        #expect(s(nil, 8) == nil)
        #expect(s("", 0) == nil)
        #expect(s(nil, nil) == nil)
    }

    private func item(_ title: String, id: String? = nil, shortcut: String? = nil) -> MenuBridge.ItemAttributes {
        .init(role: "AXMenuItem", title: title, enabled: true, shortcut: shortcut, checked: false, identifier: id, hasCommandKey: shortcut != nil)
    }

    @Test func itemsThatReachBeyondTheAppAreNeverOffered() {
        // By the selector AppKit puts in the identifier, whatever the language.
        for id in ["terminate:", "hide:", "hideOtherApplications:", "unhideAllApplications:", "NSAlternateQuitMenuItem", "_NSMenuItemAutoFillIdentifier",
                   "startDictation:", "orderFrontCharacterPalette:", "toggleFullScreen:", "performMiniaturize:", "miniaturizeAll:",
                   "_zoomLeft:", "_zoomFill:", "_handleInsertFromPasswordsCommand:"] {
            #expect(MenuBridge.isBlocked(item("Anything", id: id), inAppMenu: false), "\(id)")
        }
        // Services and AutoFill by what their submenus hold.
        #expect(MenuBridge.isBlocked(item("Dienste"), inAppMenu: true, submenuIdentifiers: ["_processRequest:"]))
        #expect(MenuBridge.isBlocked(item("Remplissage"), inAppMenu: false, submenuIdentifiers: ["_handleInsertFromContactsCommand:"]))
        // The app menu's system items, for apps without identifiers.
        #expect(MenuBridge.isBlocked(item("Quit Orbit"), inAppMenu: true))
        #expect(MenuBridge.isBlocked(item("Hide Orbit"), inAppMenu: true))
        #expect(MenuBridge.isBlocked(item("Services"), inAppMenu: true))
        #expect(MenuBridge.isBlocked(item("Beenden", shortcut: "⌘Q"), inAppMenu: true))
        #expect(MenuBridge.isBlocked(item("Diktat", shortcut: "🎤"), inAppMenu: false))
        // The app's own items stay, including ones that only look like system items elsewhere.
        #expect(!MenuBridge.isBlocked(item("About Orbit", id: "orderFrontStandardAboutPanel:"), inAppMenu: true))
        #expect(!MenuBridge.isBlocked(item("Settings…", shortcut: "⌘,"), inAppMenu: true))
        #expect(!MenuBridge.isBlocked(item("Mark All Shipped", id: "menuAction:", shortcut: "⇧⌘S"), inAppMenu: false))
        #expect(!MenuBridge.isBlocked(item("Hide Sidebar", shortcut: "⌃⌘S"), inAppMenu: false))
        #expect(!MenuBridge.isBlocked(item("Quit Game", shortcut: "⌘Q"), inAppMenu: false))
        #expect(!MenuBridge.isBlocked(item("Copy", id: "copy:", shortcut: "⌘C"), inAppMenu: false))
    }

    @Test func separatorsAreTidied() {
        let line = Item.separatorItem
        let a = Item(title: "A"), b = Item(title: "B")
        #expect(MenuBridge.tidySeparators([line, a, line, line, b, line]) == [a, line, b])
        #expect(MenuBridge.tidySeparators([line, line]) == [])
        #expect(MenuBridge.tidySeparators([a, b]) == [a, b])
        // A submenu with nothing left to choose (section headings only) is dropped.
        #expect(!MenuBridge.hasEnabledItem([Item(title: "Halves", enabled: false), line, Item(title: "Quarters", enabled: false)]))
        #expect(MenuBridge.hasEnabledItem([Item(title: "Halves", enabled: false), Item(title: "Sub", items: [Item(title: "Left")])]))
        #expect(!MenuBridge.hasEnabledItem([Item(title: "Sub", items: [Item(title: "Left", enabled: false)])]))
    }

    @Test func menuMessagesWriteEveryFieldAndReadMissingOnes() throws {
        let bar = [Item(title: "Orders", items: [Item(title: "Mark All Shipped", shortcut: "⇧⌘S"), .separatorItem,
                                                 Item(title: "Filter", items: [Item(title: "All", checked: true)])])]
        let plain = try Proto.ServerMessage.menu(.init(bar: bar)).jsonString()
        #expect(plain.contains(#""context":null"#))
        #expect(plain.contains(#""separator":false"#) && plain.contains(#""separator":true"#))
        #expect(plain.contains(#""shortcut":"⇧⌘S""#))
        #expect(try Proto.ServerMessage.decode(plain) == .menu(.init(bar: bar)))

        let context = Proto.ContextMenu(window: 7, x: 52, y: 131, items: [Item(title: "Duplicate"), .separatorItem, Item(title: "Delete")])
        let open = try Proto.ServerMessage.menu(.init(bar: bar, context: context)).jsonString()
        #expect(open.contains(#""context":{"#) && open.contains(#""window":7"#))
        #expect(try Proto.ServerMessage.decode(open) == .menu(.init(bar: bar, context: context)))

        // Readers take missing fields as their defaults.
        #expect(try Proto.ServerMessage.decode(#"{"t":"menu","bar":[{"title":"File"}]}"#) == .menu(.init(bar: [Item(title: "File")])))
        #expect(try Proto.ClientMessage.decode(#"{"t":"menuAction","path":["Orders","Mark All Shipped"]}"#)
            == .menuAction(.init(path: ["Orders", "Mark All Shipped"], context: false)))
        #expect(try Proto.ClientMessage.decode(#"{"t":"menuAction","path":[],"context":true}"#) == .menuAction(.init(path: [], context: true)))
        let action = try Proto.ClientMessage.menuAction(.init(path: ["Duplicate"], context: true)).jsonString()
        #expect(action.contains(#""context":true"#) && action.contains(#""t":"menuAction""#))
    }

    @Test func aPoppedUpMenuIsPlacedRelativeToTheWindowItWasOpenedIn() {
        let open = MenuBridge.OpenMenu(items: [Item(title: "Duplicate")], frame: CGRect(x: 1802, y: 1303, width: 134, height: 93))
        let main = CGRect(x: 1750, y: 1172, width: 1440, height: 988)
        let second = CGRect(x: 1790, y: 1212, width: 360, height: 260)
        let frames: [Proto.WindowID: CGRect] = [9: main, 11: second]
        #expect(MirrorServer.contextMenu(open, mainID: 9, frames: frames, rightClick: nil) == .init(window: 9, x: 52, y: 131, items: open.items))
        // Right-clicked in the second window: relative to that one.
        #expect(MirrorServer.contextMenu(open, mainID: 9, frames: frames, rightClick: (11, CGPoint(x: 10, y: 90)))
            == .init(window: 11, x: 12, y: 91, items: open.items))
        // Without a frame: at the right click.
        let frameless = MenuBridge.OpenMenu(items: open.items, frame: .zero)
        #expect(MirrorServer.contextMenu(frameless, mainID: 9, frames: frames, rightClick: (9, CGPoint(x: 40, y: 50)))
            == .init(window: 9, x: 40, y: 50, items: open.items))
        #expect(MirrorServer.contextMenu(nil, mainID: 9, frames: frames, rightClick: nil) == nil)
        #expect(MirrorServer.contextMenu(.init(items: [], frame: open.frame), mainID: 9, frames: frames, rightClick: nil) == nil)
    }
}

// MARK: - Stub bridges

private let windowID: Proto.WindowID = 42
private let windowFrame = CGRect(x: -1500, y: 300, width: 400, height: 300)

private let rowNodes: [Proto.AXNode] = [
    .init(key: "/Window:", role: "AXWindow", x: 0, y: 0, w: 400, h: 300, depth: 0),
    .init(key: "/Window:/Row:Ada", role: "AXRow", label: "Ada", x: 10, y: 40, w: 300, h: 24, depth: 1),
    .init(key: "/Window:/Row:Ada/StaticText:Ada", role: "AXStaticText", label: "Ada", x: 20, y: 44, w: 80, h: 16, depth: 2, actions: [.showMenu]),
]

private final class MenuStubAccessibility: MirrorAccessibility, @unchecked Sendable {
    let state = OSAllocatedUnfairLock(initialState: (performed: [String](), streams: [AsyncStream<AXChange>.Continuation]()))

    func windows() async throws -> [AccessibilityTree.Window] {
        [.init(number: windowID, title: "Orders", role: "AXWindow", subrole: "AXStandardWindow", frame: windowFrame, isMain: true, isFocused: true, isMinimized: false)]
    }

    func snapshot(window: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        AXSnapshot(windowNumber: windowID, title: "Orders", frame: windowFrame, nodes: rowNodes)
    }

    func perform(key: String, action: Proto.Action, window: UInt32?) async throws {
        state.withLock { $0.performed.append("\(action.rawValue) \(key)") }
    }

    func changes() -> AsyncStream<AXChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AXChange.self)
        state.withLock { $0.streams.append(continuation) }
        return stream
    }

    func emit(_ kind: AXChange.Kind) {
        for stream in state.withLock({ $0.streams }) { stream.yield(AXChange(kind: kind, notification: "AXMenuOpened", role: "AXMenu")) }
    }

    var performed: [String] { state.withLock { $0.performed } }
}

/// A menu bar and, when "popped up", a context menu, like MenuBridge on a real app.
private final class StubMenus: MirrorMenus, @unchecked Sendable {
    struct State {
        var bar: [Item]
        var open: MenuBridge.OpenMenu?
        var log: [String] = []
        var reads = 0
    }
    let state: OSAllocatedUnfairLock<State>
    /// What a right click (seen as a pointer rightup in the input stub) pops up.
    let contextItems = [Item(title: "Mark as Shipped"), Item(title: "Duplicate"), .separatorItem, Item(title: "Delete")]

    init(bar: [Item]) { state = OSAllocatedUnfairLock(initialState: State(bar: bar)) }

    func bar() async throws -> [Item] { state.withLock { $0.reads += 1; return $0.bar } }
    func perform(path: [String]) async throws { state.withLock { $0.log.append("perform \(path.joined(separator: " > "))") } }
    func openMenu() async throws -> MenuBridge.OpenMenu? { state.withLock { $0.open } }
    func performOpen(path: [String]) async throws {
        state.withLock { $0.log.append("performOpen \(path.joined(separator: " > "))"); $0.open = nil }
    }
    func closeOpen() async throws { state.withLock { $0.log.append("closeOpen"); $0.open = nil } }
    func showMenu(at point: CGPoint) async throws -> Bool {
        state.withLock { $0.log.append("showMenu \(Int(point.x)),\(Int(point.y))") }
        popUp(at: point)
        return true
    }

    /// The app pops up its context menu with its top-left at this global point.
    func popUp(at point: CGPoint) {
        state.withLock { $0.open = .init(items: contextItems, frame: CGRect(x: point.x, y: point.y, width: 134, height: 93)) }
    }

    func setBar(_ bar: [Item]) { state.withLock { $0.bar = bar } }
    var log: [String] { state.withLock { $0.log } }
}

/// Pops the stub's context menu up a little after a right click, as an app does.
private final class MenuStubInput: MirrorInput, @unchecked Sendable {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    weak var menus: StubMenus?

    func send(_ pointer: Proto.Pointer, in window: InputSynthesizer.Window) throws {
        log.withLock { $0.append("pointer \(pointer.kind.rawValue) \(Int(pointer.x)),\(Int(pointer.y))") }
        if pointer.kind == .rightdown, let menus {
            let global = window.global(CGPoint(x: pointer.x, y: pointer.y))
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                menus.popUp(at: global)
            }
        }
    }
    func type(text: String) throws { log.withLock { $0.append("text \(text)") } }
    func send(_ key: Proto.Key) throws { log.withLock { $0.append("key \(key.code.rawValue)") } }
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {}
}

private final class MenuStubCapture: MirrorCapture, @unchecked Sendable {
    let windowID: CGWindowID
    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    init(windowID: CGWindowID) {
        self.windowID = windowID
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
    }

    func start() async throws { continuation.yield(full()) }
    func stop() async { continuation.finish() }
    func fullFrame() async -> CapturedFrame? { full() }

    private func full() -> CapturedFrame {
        let tile = Proto.Tile(window: windowID, seq: 0, x: 0, y: 0, w: 400, h: 300, format: .jpeg, data: grayJPEG())
        return CapturedFrame(window: windowID, seq: 0, full: true, width: 400, height: 300, scale: 2, tiles: [tile], encodeTime: .zero)
    }
}

private func grayJPEG() -> Data {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private let assets = MirrorServer.Assets(page: Data("<!doctype html><title>Viewer</title>".utf8), script: Data(), style: Data())

private let orbitBar = [
    Item(title: "Orbit", items: [Item(title: "About Orbit")]),
    Item(title: "Orders", items: [Item(title: "Mark All Shipped", shortcut: "⇧⌘S"), Item(title: "Show Statistics", shortcut: "⌥⌘I"), .separatorItem,
                                  Item(title: "Filter", items: [Item(title: "All", checked: true), Item(title: "Open"), Item(title: "Shipped")])]),
]

private struct MenuMirror {
    let accessibility: MenuStubAccessibility
    let input: MenuStubInput
    let menus: StubMenus?
    let server: MirrorServer
    let port: Int

    static func start(menus: StubMenus? = StubMenus(bar: orbitBar)) async throws -> MenuMirror {
        let accessibility = MenuStubAccessibility()
        let input = MenuStubInput()
        input.menus = menus
        let app = MirrorServer.App(name: "Orbit", boot: "boot-1", accessibility: accessibility, input: input, menus: menus) { MenuStubCapture(windowID: $0) }
        let server = MirrorServer(configuration: .init(app: app, assets: assets, appearance: .light))
        let port = try await server.start()
        return MenuMirror(accessibility: accessibility, input: input, menus: menus, server: server, port: port)
    }
}

// MARK: - A viewer, as the browser page connects (JSON messages only)

private final class MenuViewer: @unchecked Sendable {
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
            case .success:
                receive()
            case .failure:
                break
            }
        }
    }

    var messages: [Proto.ServerMessage] { received.withLock { $0 } }
    var menus: [Proto.Menu] { messages.compactMap { if case .menu(let m) = $0 { m } else { nil } } }
    var trees: [Proto.Tree] { messages.compactMap { if case .tree(let t) = $0 { t } else { nil } } }

    /// The first message at or after `index` that matches, waiting up to `timeout`.
    func first(after index: Int = 0, within timeout: Duration = .seconds(5), _ match: @Sendable (Proto.ServerMessage) -> Bool) async -> (index: Int, message: Proto.ServerMessage)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let all = messages
            if index < all.count, let found = all[index...].firstIndex(where: match) { return (found, all[found]) }
            try? await Task.sleep(for: .milliseconds(5))
        } while clock.now < deadline
        return nil
    }

    func menu(after index: Int = 0, within timeout: Duration = .seconds(5), _ match: @escaping @Sendable (Proto.Menu) -> Bool) async -> (index: Int, menu: Proto.Menu)? {
        guard let found = await first(after: index, within: timeout, { if case .menu(let m) = $0 { match(m) } else { false } }),
              case .menu(let menu) = found.message else { return nil }
        return (found.index, menu)
    }

    func send(_ message: Proto.ClientMessage) async throws { try await task.send(.string(message.jsonString())) }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

private func waitUntil(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - Stub suite

@Suite("Menus in the mirror server over stub bridges", .serialized, .timeLimit(.minutes(2)))
struct MacAppMenuServerStubTests {
    @Test func aViewerGetsTheMenuBarAfterHelloAndChangesArePushed() async throws {
        let mirror = try await MenuMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = MenuViewer(port: mirror.port)
        defer { viewer.close() }
        let first = try #require(await viewer.menu { $0.bar == orbitBar })
        #expect(first.menu.context == nil)
        let hello = try #require(viewer.messages.firstIndex { if case .hello = $0 { true } else { false } })
        #expect(hello < first.index)

        // A later viewer gets the menu as part of its greeting (after hello and the trees, before frames).
        let late = MenuViewer(port: mirror.port)
        defer { late.close() }
        let greeted = try #require(await late.menu { $0.bar == orbitBar })
        let tree = try #require(late.messages.firstIndex { if case .tree = $0 { true } else { false } })
        #expect(tree < greeted.index)

        // The bar changes (an item is switched off): a menu-opened notification brings it at once.
        var edited = orbitBar
        edited[1].items[0].enabled = false
        let changed = edited
        mirror.menus?.setBar(changed)
        mirror.accessibility.emit(.menuOpened)
        let pushed = await viewer.menu(after: first.index + 1, within: .seconds(1)) { $0.bar == changed }
        #expect(pushed != nil, "no menu with the change within 1 s")
        // An unchanged bar isn't sent again.
        let count = viewer.menus.count
        mirror.accessibility.emit(.menuClosed)
        try await Task.sleep(for: .milliseconds(400))
        #expect(viewer.menus.count == count)
    }

    @Test func menuActionsReachTheMenusInOrder() async throws {
        let mirror = try await MenuMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = MenuViewer(port: mirror.port)
        defer { viewer.close() }
        _ = try #require(await viewer.menu { _ in true })
        try await viewer.send(.menuAction(.init(path: ["Orders", "Mark All Shipped"])))
        try await viewer.send(.menuAction(.init(path: ["Orders", "Filter", "Shipped"])))
        try await viewer.send(.menuAction(.init(path: ["Duplicate"], context: true)))
        try await viewer.send(.menuAction(.init(path: [], context: true)))
        let menus = try #require(mirror.menus)
        #expect(await waitUntil { menus.log.count == 4 })
        #expect(menus.log == ["perform Orders > Mark All Shipped", "perform Orders > Filter > Shipped", "performOpen Duplicate", "closeOpen"])
    }

    @Test func aRightClickBringsTheContextMenuAndChoosingClosesIt() async throws {
        let mirror = try await MenuMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = MenuViewer(port: mirror.port)
        defer { viewer.close() }
        let start = try #require(await viewer.menu { _ in true })
        try await viewer.send(.pointer(.init(window: windowID, kind: .rightdown, x: 52, y: 131)))
        try await viewer.send(.pointer(.init(window: windowID, kind: .rightup, x: 52, y: 131)))
        // The stub app pops its menu up 150 ms after the press; the server is watching by then.
        let opened = try #require(await viewer.menu(after: start.index + 1, within: .seconds(2)) { $0.context != nil })
        let context = try #require(opened.menu.context)
        #expect(context.window == windowID && context.x == 52 && context.y == 131)
        #expect(context.items.map(\.title) == ["Mark as Shipped", "Duplicate", "", "Delete"])
        #expect(opened.menu.bar == orbitBar)

        try await viewer.send(.menuAction(.init(path: ["Duplicate"], context: true)))
        let closed = await viewer.menu(after: opened.index + 1, within: .seconds(2)) { $0.context == nil }
        #expect(closed != nil, "the context menu didn't go away after choosing")
        #expect(mirror.menus?.log == ["performOpen Duplicate"])
    }

    @Test func showMenuOpensTheMenuThroughTheMenusAtTheNodesCenter() async throws {
        let mirror = try await MenuMirror.start()
        defer { Task { await mirror.server.stop() } }
        let viewer = MenuViewer(port: mirror.port)
        defer { viewer.close() }
        let start = try #require(await viewer.menu { _ in true })
        try await viewer.send(.act(.init(window: windowID, key: "/Window:/Row:Ada/StaticText:Ada", action: .showMenu)))
        let opened = try #require(await viewer.menu(after: start.index + 1, within: .seconds(2)) { $0.context != nil })
        // The text is at 20,44 (80×16): its center, in global points.
        #expect(mirror.menus?.log == ["showMenu \(Int(windowFrame.minX) + 60),\(Int(windowFrame.minY) + 52)"])
        #expect(opened.menu.context?.x == 60 && opened.menu.context?.y == 52)
        #expect(mirror.accessibility.performed.isEmpty, "AXShowMenu went through the tree bridge, which waits until the menu closes")
        // Escape in the viewer: an empty context path closes it.
        try await viewer.send(.menuAction(.init(path: [], context: true)))
        #expect(await viewer.menu(after: opened.index + 1, within: .seconds(2)) { $0.context == nil } != nil)
    }

    @Test func anAppWithoutMenusSendsNoMenuAndIgnoresMenuActions() async throws {
        let mirror = try await MenuMirror.start(menus: nil)
        defer { Task { await mirror.server.stop() } }
        let collected = OSAllocatedUnfairLock(initialState: [Proto.ClientMessage]())
        let watcher = Task { for await event in mirror.server.events { if case .message(_, let m, _) = event { collected.withLock { $0.append(m) } } } }
        defer { watcher.cancel() }
        let viewer = MenuViewer(port: mirror.port)
        defer { viewer.close() }
        _ = try #require(await viewer.first { if case .tree = $0 { true } else { false } })
        try await viewer.send(.menuAction(.init(path: ["Orders", "Mark All Shipped"])))
        #expect(await waitUntil { collected.withLock { $0 }.contains(.menuAction(.init(path: ["Orders", "Mark All Shipped"]))) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewer.menus.isEmpty)
    }
}

// MARK: - Orbit fixture

@MainActor
@Suite("Menus on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .timeLimit(.minutes(10)))
struct MacAppMenuFixtureTests {
    @Test func theMenuBarListsTheAppsMenusWithShortcutsAndNothingOfTheHosts() async throws {
        try await withOrbitFixture { orbit in
            let menus = try MenuBridge(pid: orbit.pid)
            let clock = ContinuousClock()
            let started = clock.now
            let bar = try await menus.bar()
            print("MenuBridge fixture: menu bar read in \(clock.now - started)")
            #expect(bar.map(\.title) == ["Orbit", "File", "Edit", "View", "Orders", "Window", "Help"])
            let orders = try #require(bar.first { $0.title == "Orders" })
            #expect(orders.items.first == Item(title: "Mark All Shipped", shortcut: "⇧⌘S"))
            #expect(orders.items.contains(Item(title: "Show Statistics", shortcut: "⌥⌘I")))
            let filter = try #require(orders.items.first { $0.title == "Filter" })
            #expect(filter.items.map(\.title) == ["All", "Open", "Shipped"])
            #expect(filter.items.first?.checked == true && filter.shortcut == nil)
            #expect(orders.items.contains { $0.separator })

            // Nothing of the host's Mac or that would take the window away.
            func titles(_ items: [Item]) -> [String] { items.flatMap { [$0.title] + titles($0.items) } }
            let all = titles(bar)
            for title in ["Apple", "About This Mac", "Shut Down…", "Recent Items", "Services", "Hide Orbit", "Hide Others", "Show All", "Quit Orbit",
                          "AutoFill", "Passwords…", "Start Dictation", "Emoji & Symbols", "Enter Full Screen", "Minimize", "Fill", "Move & Resize"] {
                #expect(!all.contains(title), "\(title) is offered")
            }
            #expect(titles(bar[0].items).contains("About Orbit"))
            let edit = try #require(bar.first { $0.title == "Edit" })
            #expect(edit.items.contains(Item(title: "Undo", enabled: false, shortcut: "⌘Z")))
            #expect(edit.items.last?.separator == false && edit.items.first?.separator == false)

            // Blocked and unknown paths are refused; a disabled item isn't pressed.
            await #expect(throws: MenuBridgeError.noSuchItem(["Orbit", "Quit Orbit"])) { try await menus.perform(path: ["Orbit", "Quit Orbit"]) }
            await #expect(throws: MenuBridgeError.noSuchItem(["Apple", "Shut Down…"])) { try await menus.perform(path: ["Apple", "Shut Down…"]) }
            await #expect(throws: MenuBridgeError.noSuchItem(["Orders", "Filter"])) { try await menus.perform(path: ["Orders", "Filter"]) }
            await #expect(throws: MenuBridgeError.disabled(["Edit", "Undo"])) { try await menus.perform(path: ["Edit", "Undo"]) }
            #expect(orbit.isRunning)
            #expect(try await menus.openMenu() == nil)
        }
    }

    @Test func aMenuActionFromTheViewerMarksAllOrdersShipped() async throws {
        try await withMirroredOrbit { server, viewer, _ in
            let menu = try #require(await viewer.menu(within: .seconds(10)) { !$0.bar.isEmpty })
            // What the viewer maps ⇧⌘S to: the item with that shortcut.
            let item = try #require(menu.menu.bar.first { $0.title == "Orders" }?.items.first { $0.shortcut == "⇧⌘S" })
            #expect(item.title == "Mark All Shipped")
            let tree = try #require(await viewer.first(within: .seconds(10)) { m in
                if case .tree(let t) = m { t.nodes.contains { $0.label.hasSuffix(" open") && $0.label != "0 open" } } else { false }
            })
            let start = tree.index
            let pressed = ContinuousClock.now
            try await viewer.send(.menuAction(.init(path: ["Orders", item.title])))
            let shipped = await viewer.first(after: start + 1, within: .seconds(5)) { m in
                if case .tree(let t) = m { t.nodes.contains { $0.label == "0 open" } } else { false }
            }
            #expect(shipped != nil, "the tree never said 0 open")
            print("Menus fixture: tree after Mark All Shipped in \(ContinuousClock.now - pressed)")
            _ = server
        }
    }

    @Test func aRightClickOnARowShowsItsContextMenuAndAnItemCanBeChosen() async throws {
        try await withMirroredOrbit { _, viewer, _ in
            _ = try #require(await viewer.menu(within: .seconds(10)) { !$0.bar.isEmpty })
            let found = try #require(await viewer.first(within: .seconds(10)) { m in
                if case .tree(let t) = m { t.nodes.contains { $0.key.contains("/Row:") && $0.role == "AXStaticText" && $0.w > 0 } } else { false }
            })
            guard case .tree(let tree) = found.message else { return }
            let rows = tree.nodes.filter { $0.role == "AXRow" }.count
            let text = try #require(tree.nodes.first { $0.key.contains("/Row:") && $0.role == "AXStaticText" && $0.w > 0 })
            let point = (x: text.x + 4, y: text.y + text.h / 2)
            let before = viewer.messages.count
            let clicked = ContinuousClock.now
            try await viewer.send(.pointer(.init(window: tree.window, kind: .rightdown, x: point.x, y: point.y)))
            try await viewer.send(.pointer(.init(window: tree.window, kind: .rightup, x: point.x, y: point.y)))
            let opened = try #require(await viewer.menu(after: before, within: .seconds(5)) { $0.context != nil }, "no context menu")
            print("Menus fixture: context menu in \(ContinuousClock.now - clicked)")
            let context = try #require(opened.menu.context)
            #expect(context.items.map(\.title) == ["Mark as Shipped", "Duplicate", "", "Delete"])
            #expect(context.items[2].separator)
            #expect(context.window == tree.window)
            #expect(abs(context.x - point.x) <= 8 && abs(context.y - point.y) <= 8, "menu at \(context.x),\(context.y), click at \(point)")

            try await viewer.send(.menuAction(.init(path: ["Duplicate"], context: true)))
            let duplicated = await viewer.first(after: opened.index + 1, within: .seconds(5)) { m in
                if case .tree(let t) = m { t.nodes.filter { $0.role == "AXRow" }.count == rows + 1 } else { false }
            }
            #expect(duplicated != nil, "no row was added")
            #expect(await viewer.menu(after: opened.index + 1, within: .seconds(5)) { $0.context == nil } != nil, "the context menu stayed")

            // Open it again and close it without choosing (Escape or a click elsewhere in the viewer).
            let again = viewer.messages.count
            try await viewer.send(.pointer(.init(window: tree.window, kind: .rightdown, x: point.x, y: point.y)))
            try await viewer.send(.pointer(.init(window: tree.window, kind: .rightup, x: point.x, y: point.y)))
            let reopened = try #require(await viewer.menu(after: again, within: .seconds(5)) { $0.context != nil })
            try await viewer.send(.menuAction(.init(path: [], context: true)))
            #expect(await viewer.menu(after: reopened.index + 1, within: .seconds(5)) { $0.context == nil } != nil, "the context menu didn't close")
        }
    }
}

/// Launches Orbit hidden, serves it with a MirrorServer over the real bridges, connects a viewer,
/// runs the body, then stops the server and quits Orbit.
@MainActor
private func withMirroredOrbit(_ body: (MirrorServer, MenuViewer, OrbitFixture) async throws -> Void) async throws {
    try await withOrbitFixture { orbit in
        try await waitForOrders(orbit.pid)
        let server = MirrorServer(configuration: .init(app: try .live(pid: orbit.pid, name: "Orbit"), assets: assets))
        let port = try await server.start()
        let viewer = MenuViewer(port: port)
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
private func waitForOrders(_ pid: pid_t) async throws {
    let tree = try AccessibilityTree(pid: pid)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while clock.now < deadline {
        if let snapshot = try? await tree.snapshot(window: .main), snapshot.title == "Orbit Orders", snapshot.nodes.contains(where: { $0.role == "AXRow" }) { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw FixtureError("Orbit's orders didn't appear")
}

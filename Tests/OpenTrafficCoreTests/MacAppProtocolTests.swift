import Foundation
import Testing
@testable import OpenTrafficCore

// The Mac app mirror protocol (docs/macapp-mirror-protocol.md): every message round-trips, the
// contract's own examples decode and re-encode to the same JSON, and the tile layout and node keys
// match what the viewer computes in JavaScript.

private typealias MP = MirrorProtocol

/// The JSON as a Foundation object, so two encodings compare regardless of key order and 2 vs 2.0.
private func object(_ json: String) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
}

private func sameJSON(_ a: String, _ b: String) throws -> Bool {
    try object(a).isEqual(try object(b))
}

private let mainWindow = MP.WindowInfo(id: 1, title: "", w: 860, h: 572, x: 0, y: 0, kind: .main, parent: nil)
private let addOrder = MP.AXNode(key: "/Window:/Group:/Button:Add Order", role: "AXButton", label: "Add Order", value: nil, x: 226, y: 530, w: 86, h: 24, depth: 2, enabled: true, focused: false, selected: false, actions: [.press])

private let everyServerMessage: [MP.ServerMessage] = [
    .hello(MP.Hello(boot: UUID().uuidString, scale: 2, appearance: .dark, app: MP.AppInfo(name: "Orbit"), windows: [mainWindow])),
    .windows([mainWindow, MP.WindowInfo(id: 2, title: "New Order", w: 400, h: 220, x: 230, y: 28, kind: .sheet, parent: 1, focused: true),
              MP.WindowInfo(id: 3, title: "Statistics", w: 360, h: 260, x: 0, y: 0, kind: .window)]),
    .tree(MP.Tree(window: 1, v: "a1b2", nodes: [
        MP.AXNode(key: "/Window:", role: "AXWindow", x: 0, y: 0, w: 860, h: 572, depth: 0),
        addOrder,
        MP.AXNode(key: "/Window:/Group:/CheckBox:Gift wrap", role: "AXCheckBox", label: "Gift wrap", value: "1", x: 20, y: 40, w: 90, h: 18, depth: 2, focused: true, selected: true, actions: [.press]),
        MP.AXNode(key: "/Window:/Group:/Incrementor:Quantity", role: "AXIncrementor", label: "Quantity", value: "3", x: 120, y: 40, w: 19, h: 22, depth: 2, enabled: false, actions: [.increment, .decrement]),
    ])),
    .frame(MP.FrameHeader(window: 1, seq: 12, full: false, tiles: 3)),
    .cursor(.pointer),
    .status(MP.Status(state: .restarting, message: "Rebuilt; restarting Orbit")),
    .status(MP.Status(state: .running)),
    .menu(MP.Menu(bar: [MP.MenuItem(title: "Orders", items: [MP.MenuItem(title: "Mark All Shipped", shortcut: "⇧⌘S"), MP.MenuItem(title: "Show Archived", enabled: false, checked: true)])])),
    .control(MP.Control(mode: .askToControl, you: false)),
    .control(MP.Control(mode: .askToControl, you: false, requested: true, holder: "Ada")),
    .control(MP.Control(mode: .watchOnly, you: true)),
    .build(MP.Build(building: true, failed: false)),
    .build(MP.Build(building: false, failed: true)),
]

private let everyClientMessage: [MP.ClientMessage] = [
    .act(MP.Act(window: 1, key: "/Window:/Group:/Button:Add Order", action: .press)),
    .pointer(MP.Pointer(window: 1, kind: .wheel, x: 10, y: 20, dx: 0, dy: -30, modifiers: [.shift])),
    .pointer(MP.Pointer(window: 2, kind: .down, x: 10.5, y: 20.25)),
    .text(MP.Text(window: 1, text: "Ada \"Countess\" Lovelace 🚀")),
    .key(MP.Key(window: 1, code: .enter, modifiers: [.cmd, .shift, .alt, .ctrl])),
    .setText(MP.SetText(window: 1, key: "/Window:/Group:/TextField:New customer", value: "Ada Lovelace")),
    .viewport(MP.Viewport(w: 1200, h: 700, appearance: .dark)),
    .viewport(MP.Viewport(w: 390, h: 700)),
    .menuAction(MP.MenuAction(path: ["Orders", "Mark All Shipped"])),
    .windowAction(MP.WindowAction(window: 3, action: .focus)),
    .windowAction(MP.WindowAction(window: 3, action: .close)),
    .requestControl(MP.RequestControl(name: "Ada", client: "q9XAbc-_0123456789abcd")),
    .requestControl(MP.RequestControl()),
    .releaseControl,
]

@Test func everyServerMessageRoundTrips() throws {
    for message in everyServerMessage {
        let text = try message.jsonString()
        #expect(try MP.ServerMessage.decode(text) == message, "\(text)")
        #expect(try object(text)["t"] as? String == message.type)
    }
    // Every message type the contract names is covered above.
    #expect(Set(everyServerMessage.map(\.type)) == ["hello", "windows", "tree", "frame", "cursor", "status", "menu", "control", "build"])
}

@Test func everyClientMessageRoundTrips() throws {
    for message in everyClientMessage {
        let text = try message.jsonString()
        #expect(try MP.ClientMessage.decode(text) == message, "\(text)")
        #expect(try object(text)["t"] as? String == message.type)
    }
    #expect(Set(everyClientMessage.map(\.type)) == ["act", "pointer", "text", "key", "setText", "viewport", "menuAction", "windowAction", "requestControl", "releaseControl"])
}

@Test func theContractsServerExamplesDecodeAndReencodeExactly() throws {
    let examples: [(String, MP.ServerMessage)] = [
        (#"{"t":"hello","boot":"6F1C7D0E-2D7B-4E55-9C59-0B5A3C1D2E3F","scale":2,"appearance":"dark","app":{"name":"Orbit"},"windows":[{"id":1,"title":"","w":860,"h":572,"x":0,"y":0,"kind":"main","parent":null,"focused":false}]}"#,
         .hello(MP.Hello(boot: "6F1C7D0E-2D7B-4E55-9C59-0B5A3C1D2E3F", scale: 2, appearance: .dark, app: MP.AppInfo(name: "Orbit"), windows: [mainWindow]))),
        (#"{"t":"windows","windows":[{"id":1,"title":"","w":860,"h":572,"x":0,"y":0,"kind":"main","parent":null,"focused":false},{"id":2,"title":"","w":380,"h":154,"x":240,"y":28,"kind":"sheet","parent":1,"focused":true}]}"#,
         .windows([mainWindow, MP.WindowInfo(id: 2, title: "", w: 380, h: 154, x: 240, y: 28, kind: .sheet, parent: 1, focused: true)])),
        (#"{"t":"tree","window":1,"v":"<hash>","nodes":[{"key":"/Window:/Group:/Button:Add Order","role":"AXButton","label":"Add Order","value":null,"x":226,"y":530,"w":86,"h":24,"depth":2,"enabled":true,"focused":false,"selected":false,"actions":["press"]}]}"#,
         .tree(MP.Tree(window: 1, v: "<hash>", nodes: [addOrder]))),
        (#"{"t":"frame","window":1,"seq":12,"full":false,"tiles":3}"#,
         .frame(MP.FrameHeader(window: 1, seq: 12, full: false, tiles: 3))),
        (#"{"t":"cursor","shape":"default"}"#, .cursor(.default)),
        (#"{"t":"status","state":"crashed","message":"Orbit quit unexpectedly"}"#,
         .status(MP.Status(state: .crashed, message: "Orbit quit unexpectedly"))),
        (#"{"t":"menu","bar":[{"title":"Orders","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[{"title":"Mark All Shipped","enabled":true,"checked":false,"shortcut":"⇧⌘S","separator":false,"items":[]},{"title":"","enabled":false,"checked":false,"shortcut":null,"separator":true,"items":[]}]}],"context":null}"#,
         .menu(MP.Menu(bar: [MP.MenuItem(title: "Orders", items: [MP.MenuItem(title: "Mark All Shipped", shortcut: "⇧⌘S"), .separatorItem])]))),
        (#"{"t":"menu","bar":[],"context":{"window":1,"x":52,"y":131,"items":[{"title":"Duplicate","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[]}]}}"#,
         .menu(MP.Menu(bar: [], context: MP.ContextMenu(window: 1, x: 52, y: 131, items: [MP.MenuItem(title: "Duplicate")])))),
        (#"{"t":"control","mode":"askToControl","you":false,"requested":true,"holder":"Ada"}"#,
         .control(MP.Control(mode: .askToControl, you: false, requested: true, holder: "Ada"))),
        (#"{"t":"control","mode":"everyone","you":true,"requested":false,"holder":null}"#, .control(MP.Control(mode: .everyone, you: true))),
        (#"{"t":"control","mode":"askToControl","you":false,"requested":false,"holder":null,"refused":true}"#,
         .control(MP.Control(mode: .askToControl, you: false, refused: true))),
        (#"{"t":"build","building":false,"failed":true}"#, .build(MP.Build(failed: true))),
        (#"{"t":"build","building":true,"failed":true}"#, .build(MP.Build(building: true, failed: true))),
    ]
    for (json, expected) in examples {
        let decoded = try MP.ServerMessage.decode(json)
        #expect(decoded == expected, "\(json)")
        #expect(try sameJSON(decoded.jsonString(), json), "\(json)")
    }
}

@Test func theContractsClientExamplesDecodeAndReencodeExactly() throws {
    let examples: [(String, MP.ClientMessage)] = [
        (#"{"t":"act","window":1,"key":"/Window:/Group:/Button:Add Order","action":"press"}"#,
         .act(MP.Act(window: 1, key: "/Window:/Group:/Button:Add Order", action: .press))),
        (#"{"t":"pointer","window":1,"kind":"move","x":10,"y":20,"dx":0,"dy":-30,"modifiers":["shift"]}"#,
         .pointer(MP.Pointer(window: 1, kind: .move, x: 10, y: 20, dx: 0, dy: -30, modifiers: [.shift]))),
        (#"{"t":"text","window":1,"text":"Ada"}"#, .text(MP.Text(window: 1, text: "Ada"))),
        (#"{"t":"key","window":1,"code":"Enter","modifiers":["cmd","shift","alt","ctrl"]}"#,
         .key(MP.Key(window: 1, code: .enter, modifiers: [.cmd, .shift, .alt, .ctrl]))),
        (#"{"t":"setText","window":1,"key":"/Window:/Group:/TextField:Customer","value":"Ada Lovelace"}"#,
         .setText(MP.SetText(window: 1, key: "/Window:/Group:/TextField:Customer", value: "Ada Lovelace"))),
        (#"{"t":"viewport","w":1200,"h":700,"appearance":"dark"}"#, .viewport(MP.Viewport(w: 1200, h: 700, appearance: .dark))),
        (#"{"t":"menuAction","path":["Orders","Mark All Shipped"],"context":false}"#, .menuAction(MP.MenuAction(path: ["Orders", "Mark All Shipped"]))),
        (#"{"t":"menuAction","path":[],"context":true}"#, .menuAction(MP.MenuAction(path: [], context: true))),
        (#"{"t":"windowAction","window":2,"action":"close"}"#, .windowAction(MP.WindowAction(window: 2, action: .close))),
        (#"{"t":"requestControl","name":"Ada","client":"q9X…"}"#, .requestControl(MP.RequestControl(name: "Ada", client: "q9X…"))),
        (#"{"t":"releaseControl"}"#, .releaseControl),
        (#"{"t":"viewport","w":0,"h":0,"appearance":null}"#, .viewport(MP.Viewport(w: 0, h: 0))),
    ]
    for (json, expected) in examples {
        let decoded = try MP.ClientMessage.decode(json)
        #expect(decoded == expected, "\(json)")
        #expect(try sameJSON(decoded.jsonString(), json), "\(json)")
    }
}

@Test func optionalFieldsAreWrittenAsNullAndMayBeOmitted() throws {
    // Written: null, never missing, so the viewer reads null rather than undefined.
    let window = try object(try MP.ServerMessage.windows([mainWindow]).jsonString())
    let parent = try #require((window["windows"] as? [NSDictionary])?.first?["parent"])
    #expect(parent is NSNull)
    let node = try #require((try object(try MP.ServerMessage.tree(MP.Tree(window: 1, v: "x", nodes: [addOrder])).jsonString())["nodes"] as? [NSDictionary])?.first)
    #expect(node["value"] is NSNull)
    #expect(try object(try MP.ServerMessage.status(MP.Status(state: .stopped)).jsonString())["message"] is NSNull)
    #expect(try object(try MP.ClientMessage.viewport(MP.Viewport(w: 1, h: 2)).jsonString())["appearance"] is NSNull)
    #expect(try object(try MP.ServerMessage.control(MP.Control(mode: .everyone, you: true)).jsonString())["holder"] is NSNull)
    #expect(try object(try MP.ClientMessage.requestControl(MP.RequestControl()).jsonString())["client"] is NSNull)
    // The shapes reserved before the viewer options still read: a bare control and a bare requestControl.
    #expect(try MP.ServerMessage.decode(#"{"t":"control","mode":"watchOnly","you":false}"#) == .control(MP.Control(mode: .watchOnly, you: false)))
    #expect(try MP.ClientMessage.decode(#"{"t":"requestControl"}"#) == .requestControl(MP.RequestControl()))
    #expect(try MP.ClientMessage.decode(#"{"t":"requestControl","name":7}"#) == .requestControl(MP.RequestControl()))

    // Read: the viewer may leave out wheel deltas and modifiers.
    #expect(try MP.ClientMessage.decode(#"{"t":"pointer","window":1,"kind":"down","x":3,"y":4}"#) == .pointer(MP.Pointer(window: 1, kind: .down, x: 3, y: 4)))
    #expect(try MP.ClientMessage.decode(#"{"t":"key","window":1,"code":"Escape"}"#) == .key(MP.Key(window: 1, code: .escape)))
    // Unknown fields are ignored, so later Tasks can add fields without breaking older readers.
    #expect(try MP.ClientMessage.decode(#"{"t":"text","window":1,"text":"x","composing":true}"#) == .text(MP.Text(window: 1, text: "x")))
    #expect(try MP.ServerMessage.decode(#"{"t":"frame","window":1,"seq":1,"full":true,"tiles":1,"encodeMs":4}"#) == .frame(MP.FrameHeader(window: 1, seq: 1, full: true, tiles: 1)))
}

@Test func unknownMessageTypesAreReportedSoTheyCanBeIgnored() {
    #expect(throws: MirrorProtocolError.unknownMessage("drawOnScreen")) { try MP.ClientMessage.decode(#"{"t":"drawOnScreen","window":1}"#) }
    #expect(throws: MirrorProtocolError.unknownMessage("future")) { try MP.ServerMessage.decode(#"{"t":"future"}"#) }
    #expect(throws: (any Error).self) { try MP.ClientMessage.decode(#"{"t":"act","window":1,"key":"k","action":"explode"}"#) }
    #expect(throws: (any Error).self) { try MP.ClientMessage.decode(#"{"window":1}"#) }
}

@Test func nodeKeysContainUnescapedSlashes() throws {
    let text = try MP.ClientMessage.act(MP.Act(window: 1, key: "/Window:/Button:OK", action: .press)).jsonString()
    #expect(text.contains(#""key":"/Window:/Button:OK""#))
}

@Test func tilesUseTheSeventeenByteBigEndianHeader() throws {
    let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    let tile = MP.Tile(window: 1, seq: 12, x: 10, y: 20, w: 30, h: 40, format: .webp, data: image)
    let bytes = tile.encoded()
    #expect(MP.Tile.headerSize == 17)
    #expect(Array(bytes.prefix(17)) == [0, 0, 0, 1, 0, 0, 0, 12, 0, 10, 0, 20, 0, 30, 0, 40, 1])
    #expect(bytes.dropFirst(17) == image)
    #expect(try MP.Tile(decoding: bytes) == tile)

    let large = MP.Tile(window: 0xDEAD_BEEF, seq: UInt32.max, x: 0x1234, y: 65535, w: 1, h: 0x0102, format: .jpeg, data: Data())
    #expect(Array(large.encoded()) == [0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0xFF, 0xFF, 0xFF, 0x12, 0x34, 0xFF, 0xFF, 0x00, 0x01, 0x01, 0x02, 0x00])
    #expect(try MP.Tile(decoding: large.encoded()) == large)
    // A Data slice with a non-zero start index decodes too (as when cut out of a larger buffer).
    let sliced = (Data([9, 9]) + bytes).dropFirst(2)
    #expect(try MP.Tile(decoding: sliced) == tile)

    #expect(throws: MirrorProtocolError.tileTooShort(16)) { try MP.Tile(decoding: Data(bytes.prefix(16))) }
    var badFormat = bytes
    badFormat[16] = 7
    #expect(throws: MirrorProtocolError.unknownTileFormat(7)) { try MP.Tile(decoding: badFormat) }
    #expect(MP.TileFormat.jpeg.mimeType == "image/jpeg" && MP.TileFormat.webp.mimeType == "image/webp")
}

@Test func nodeKeysFollowTheRoleLabelPathRule() {
    #expect(MP.NodeKey.segment(role: "AXButton", label: "Add Order") == "/Button:Add Order")
    #expect(MP.NodeKey.segment(role: "AXGroup", label: "") == "/Group:")
    #expect(MP.NodeKey.segment(role: "SomeCustomRole", label: "x") == "/SomeCustomRole:x")
    // Labels: 40 characters, whitespace collapsed, slashes can't split the path.
    let long = String(repeating: "abcdefghij", count: 6)
    #expect(MP.NodeKey.segment(role: "AXStaticText", label: long) == "/StaticText:" + String(long.prefix(40)))
    #expect(MP.NodeKey.segment(role: "AXStaticText", label: "  Ship\nto:\tA/B ") == "/StaticText:Ship to: A\u{2215}B")

    var children = MP.NodeKey.Siblings(parent: MP.NodeKey.root + "/Group:")
    #expect(children.key(role: "AXButton", label: "Add Order") == "/Window:/Group:/Button:Add Order")
    #expect(children.key(role: "AXRow", label: "Grace Hopper") == "/Window:/Group:/Row:Grace Hopper")
    #expect(children.key(role: "AXRow", label: "Grace Hopper") == "/Window:/Group:/Row:Grace Hopper#2")
    #expect(children.key(role: "AXRow", label: "Alan Turing") == "/Window:/Group:/Row:Alan Turing")
    #expect(children.key(role: "AXRow", label: "Grace Hopper") == "/Window:/Group:/Row:Grace Hopper#3")
}

@Test func domIDsMatchTheViewersJavaScriptHash() {
    // Expected values computed in JavaScript with the doc's snippet:
    // let h = 5381; for (i...) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0; "ax-" + h.toString(36)
    #expect(MP.NodeKey.domID(for: "/Window:/Group:/Button:Add Order") == "ax-3tt01y")
    #expect(MP.NodeKey.domID(for: "/Window:") == "ax-himme")
    #expect(MP.NodeKey.domID(for: "") == "ax-45h")
    #expect(MP.NodeKey.domID(for: "/Window:/Group:/Row:Grace Hopper 🚀#2") == "ax-1nv41hb")
    #expect(MP.NodeKey.domID(for: "/Window:/Group:/StaticText:Ünïcödé ∕ path") == "ax-t0f4cz")
    #expect(addOrder.domID == "ax-3tt01y")
}

@Test func actionsMapToAccessibilityActionNames() {
    #expect(MP.Action.allCases.map(\.rawValue) == ["press", "increment", "decrement", "confirm", "cancel", "showMenu", "scrollToVisible"])
    #expect(MP.Action.allCases.map(\.axName) == ["AXPress", "AXIncrement", "AXDecrement", "AXConfirm", "AXCancel", "AXShowMenu", "AXScrollToVisible"])
    for action in MP.Action.allCases { #expect(MP.Action(axName: action.axName) == action) }
    #expect(MP.Action(axName: "AXRaise") == nil)
    #expect(MP.WindowKind.allCases.map(\.rawValue) == ["main", "sheet", "alert", "popover", "menu", "window"])
    #expect(MP.KeyCode.allCases.map(\.rawValue) == ["Enter", "Escape", "Tab", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space"])
    #expect(MP.snapshotPath(window: 3) == "/__opentraffic/macapp/snapshot.png?window=3")
    #expect(MP.webSocketPath.hasPrefix(MP.pathPrefix) && MP.viewerScriptPath.hasPrefix(MP.pathPrefix))
}

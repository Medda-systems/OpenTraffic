import Foundation

/// The wire contract between a shared Mac app's mirror server (MirrorServer, in the session) and the
/// viewer page in the browser (macapp-viewer.js). docs/macapp-mirror-protocol.md is the same contract
/// in prose; keep the two in step.
///
/// JSON text messages carry their type in `t`. Every optional field is always written, as `null`
/// when absent, so the viewer reads `null` and never `undefined`; decoders accept a missing field as
/// `null` and ignore fields they don't know, so later versions only add fields. Frame tiles travel as
/// binary WebSocket messages with a fixed 17-byte big-endian header (`Tile`).
public enum MirrorProtocol {
    // MARK: HTTP and WebSocket paths on the mirror server's origin

    /// Everything the mirror serves besides the viewer page lives under this prefix.
    public static let pathPrefix = "/__opentraffic/macapp/"
    /// `GET /`: the viewer page (HTML, so CollabProxy injects bridge.js and collab.js into it).
    public static let viewerPagePath = "/"
    public static let viewerScriptPath = "/__opentraffic/macapp/viewer.js"
    public static let viewerStylePath = "/__opentraffic/macapp/viewer.css"
    public static let iconPath = "/__opentraffic/macapp/icon.png"
    /// `GET /__opentraffic/macapp/snapshot.png?window=<id>`: the window's full current frame.
    public static let snapshotPath = "/__opentraffic/macapp/snapshot.png"
    /// The WebSocket: server messages (JSON text + binary tiles) out, client messages (JSON text) in.
    public static let webSocketPath = "/__opentraffic/macapp/ws"

    public static func snapshotPath(window: WindowID) -> String { "\(snapshotPath)?window=\(window)" }

    public typealias WindowID = UInt32

    // MARK: Shared vocabulary

    public enum Appearance: String, Codable, Sendable, CaseIterable { case dark, light }

    /// What a window is, so the viewer knows where to draw it: the `main` window, a `sheet` or an
    /// `alert` attached to a window (or an app-modal alert), a `popover`, a popped-up `menu`, or a
    /// second ordinary `window` (a panel too). Servers before the extra-windows work sent only `main`.
    public enum WindowKind: String, Codable, Sendable, CaseIterable {
        case main, sheet, alert, popover, menu, window

        /// Kinds that belong to another window (`parent`) and are drawn over it.
        public var isAttached: Bool { self == .sheet || self == .alert || self == .popover || self == .menu }
    }

    /// What `windowAction` does to a window: bring it to the front and make it the app's key window
    /// (`focus`, where typing goes), or close it like its close button (`close`).
    public enum WindowActionKind: String, Codable, Sendable, CaseIterable { case focus, close }

    /// Accessibility actions by their protocol names. A node lists the ones it supports; `act` asks
    /// for one. Other AX actions (AXRaise, AXPick, ...) are not part of the protocol.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case press, increment, decrement, confirm, cancel, showMenu, scrollToVisible

        /// The AXUIElement action name (kAXPressAction etc.).
        public var axName: String {
            switch self {
            case .press: "AXPress"
            case .increment: "AXIncrement"
            case .decrement: "AXDecrement"
            case .confirm: "AXConfirm"
            case .cancel: "AXCancel"
            case .showMenu: "AXShowMenu"
            case .scrollToVisible: "AXScrollToVisible"
            }
        }

        public init?(axName: String) {
            guard let action = Self.allCases.first(where: { $0.axName == axName }) else { return nil }
            self = action
        }
    }

    public enum CursorShape: String, Codable, Sendable, CaseIterable { case `default`, pointer, text, grab }

    public enum RunState: String, Codable, Sendable, CaseIterable { case running, restarting, crashed, stopped }

    public enum PointerKind: String, Codable, Sendable, CaseIterable { case move, down, up, rightdown, rightup, wheel }

    public enum KeyCode: String, Codable, Sendable, CaseIterable {
        case enter = "Enter", escape = "Escape", tab = "Tab", backspace = "Backspace", delete = "Delete"
        case arrowUp = "ArrowUp", arrowDown = "ArrowDown", arrowLeft = "ArrowLeft", arrowRight = "ArrowRight"
        case space = "Space"
    }

    public enum Modifier: String, Codable, Sendable, CaseIterable { case cmd, shift, alt, ctrl }

    /// Reserved for the viewer-options Task: who may control the app.
    public enum ControlMode: String, Codable, Sendable, CaseIterable { case everyone, watchOnly, askToControl }

    // MARK: Server to client payloads

    public struct AppInfo: Codable, Equatable, Sendable {
        public var name: String
        public init(name: String) { self.name = name }
    }

    /// One window of the app. Geometry in points; `x`/`y` place it relative to the main window's
    /// top-left (the main window itself is at 0,0). `parent` is the window a sheet/alert/popover/menu
    /// belongs to. `focused` marks the app's key window (where typing goes; a sheet while it is up).
    public struct WindowInfo: Codable, Equatable, Sendable {
        public var id: WindowID
        public var title: String
        public var w: Double
        public var h: Double
        public var x: Double
        public var y: Double
        public var kind: WindowKind
        public var parent: WindowID?
        public var focused: Bool

        public init(id: WindowID, title: String = "", w: Double, h: Double, x: Double = 0, y: Double = 0, kind: WindowKind = .main, parent: WindowID? = nil,
                    focused: Bool = false) {
            self.id = id; self.title = title; self.w = w; self.h = h; self.x = x; self.y = y; self.kind = kind; self.parent = parent
            self.focused = focused
        }

        private enum CodingKeys: String, CodingKey { case id, title, w, h, x, y, kind, parent, focused }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(WindowID.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            w = try c.decode(Double.self, forKey: .w)
            h = try c.decode(Double.self, forKey: .h)
            x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
            y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
            kind = try c.decodeIfPresent(WindowKind.self, forKey: .kind) ?? .main
            parent = try c.decodeIfPresent(WindowID.self, forKey: .parent)
            focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(kind, forKey: .kind)
            try c.encode(parent, forKey: .parent)
            try c.encode(focused, forKey: .focused)
        }
    }

    /// `{"t":"hello"}`: the first message on every connection. A `boot` different from the last one
    /// the viewer saw means the app restarted: drop the layer and every window.
    public struct Hello: Codable, Equatable, Sendable {
        public var boot: String
        /// Backing scale of the frames: a tile `w`×`h` points is `w*scale`×`h*scale` pixels.
        public var scale: Double
        public var appearance: Appearance
        public var app: AppInfo
        public var windows: [WindowInfo]

        public init(boot: String, scale: Double, appearance: Appearance, app: AppInfo, windows: [WindowInfo]) {
            self.boot = boot; self.scale = scale; self.appearance = appearance; self.app = app; self.windows = windows
        }
    }

    /// `{"t":"windows"}`: the full current window list whenever one appears, moves, resizes or closes.
    public struct Windows: Codable, Equatable, Sendable {
        public var windows: [WindowInfo]
        public init(windows: [WindowInfo]) { self.windows = windows }
    }

    /// One accessibility element. `key` is stable across snapshots (see `NodeKey`); `role` is the raw
    /// AX role string passed through (`AXButton`, `AXCheckBox`, ...); `label` is the element's name
    /// (`""` when it has none); `value` its value as a string (checkboxes `"0"`/`"1"`) or null.
    /// Geometry in points relative to the node's window's top-left; `depth` is 0 for the window.
    public struct AXNode: Codable, Equatable, Sendable {
        public var key: String
        public var role: String
        public var label: String
        public var value: String?
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public var depth: Int
        public var enabled: Bool
        public var focused: Bool
        public var selected: Bool
        public var actions: [Action]

        public init(key: String, role: String, label: String = "", value: String? = nil, x: Double, y: Double, w: Double, h: Double, depth: Int, enabled: Bool = true, focused: Bool = false, selected: Bool = false, actions: [Action] = []) {
            self.key = key; self.role = role; self.label = label; self.value = value
            self.x = x; self.y = y; self.w = w; self.h = h; self.depth = depth
            self.enabled = enabled; self.focused = focused; self.selected = selected; self.actions = actions
        }

        private enum CodingKeys: String, CodingKey { case key, role, label, value, x, y, w, h, depth, enabled, focused, selected, actions }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            role = try c.decode(String.self, forKey: .role)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            value = try c.decodeIfPresent(String.self, forKey: .value)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
            w = try c.decode(Double.self, forKey: .w)
            h = try c.decode(Double.self, forKey: .h)
            depth = try c.decode(Int.self, forKey: .depth)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
            selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
            actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(role, forKey: .role)
            try c.encode(label, forKey: .label)
            try c.encode(value, forKey: .value)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            try c.encode(depth, forKey: .depth)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(focused, forKey: .focused)
            try c.encode(selected, forKey: .selected)
            try c.encode(actions, forKey: .actions)
        }

        /// The DOM id the viewer gives this node's element.
        public var domID: String { NodeKey.domID(for: key) }
    }

    /// `{"t":"tree"}`: a full snapshot of one window's accessibility tree, in document order (a parent
    /// before its children). There are no deltas in v1. `v` identifies the snapshot's content: equal
    /// trees have equal `v`.
    public struct Tree: Codable, Equatable, Sendable {
        public var window: WindowID
        public var v: String
        public var nodes: [AXNode]
        public init(window: WindowID, v: String, nodes: [AXNode]) { self.window = window; self.v = v; self.nodes = nodes }
    }

    /// `{"t":"frame"}`: announces that exactly `tiles` binary tile messages follow for this window.
    /// `full` means the tiles cover the whole window (first frame, after a resize).
    public struct FrameHeader: Codable, Equatable, Sendable {
        public var window: WindowID
        public var seq: UInt32
        public var full: Bool
        public var tiles: Int
        public init(window: WindowID, seq: UInt32, full: Bool, tiles: Int) { self.window = window; self.seq = seq; self.full = full; self.tiles = tiles }
    }

    public struct Cursor: Codable, Equatable, Sendable {
        public var shape: CursorShape
        public init(shape: CursorShape) { self.shape = shape }
    }

    public struct Status: Codable, Equatable, Sendable {
        public var state: RunState
        public var message: String?
        public init(state: RunState, message: String? = nil) { self.state = state; self.message = message }

        private enum CodingKeys: String, CodingKey { case state, message }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(RunState.self, forKey: .state)
            message = try c.decodeIfPresent(String.self, forKey: .message)
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(state, forKey: .state)
            try c.encode(message, forKey: .message)
        }
    }

    /// One menu or menu item: a top-level menu of the bar (its `items` are the menu), an item, a
    /// submenu (an item with `items`) or a separator line (`separator`, with an empty title).
    public struct MenuItem: Codable, Equatable, Sendable {
        public var title: String
        public var enabled: Bool
        public var checked: Bool
        /// The key equivalent as the viewer shows it, e.g. `⇧⌘S`, or null.
        public var shortcut: String?
        /// The submenu's items; empty for a plain item.
        public var items: [MenuItem]
        /// A separator line between groups of items (title `""`, never enabled).
        public var separator: Bool

        public init(title: String, enabled: Bool = true, checked: Bool = false, shortcut: String? = nil, items: [MenuItem] = [],
                    separator: Bool = false) {
            self.title = title; self.enabled = enabled; self.checked = checked; self.shortcut = shortcut; self.items = items
            self.separator = separator
        }

        /// A separator line.
        public static let separatorItem = MenuItem(title: "", enabled: false, separator: true)

        private enum CodingKeys: String, CodingKey { case title, enabled, checked, shortcut, items, separator }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
            shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
            items = try c.decodeIfPresent([MenuItem].self, forKey: .items) ?? []
            separator = try c.decodeIfPresent(Bool.self, forKey: .separator) ?? false
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(checked, forKey: .checked)
            try c.encode(shortcut, forKey: .shortcut)
            try c.encode(items, forKey: .items)
            try c.encode(separator, forKey: .separator)
        }
    }

    /// A menu the app has popped up (a context menu after a right click, or a pop-up button's
    /// menu): its items, and where it is, as the top-left corner in points relative to window
    /// `window`'s top-left.
    public struct ContextMenu: Codable, Equatable, Sendable {
        public var window: WindowID
        public var x: Double
        public var y: Double
        public var items: [MenuItem]
        public init(window: WindowID, x: Double, y: Double, items: [MenuItem]) {
            self.window = window; self.x = x; self.y = y; self.items = items
        }
    }

    /// `{"t":"menu","bar":[...],"context":null}`: the app's menu bar (top-level menus, each with its
    /// items) and the menu it has popped up, if any. Sent on connect (once read) and whenever either
    /// changes.
    public struct Menu: Codable, Equatable, Sendable {
        public var bar: [MenuItem]
        /// The open context (pop-up) menu, or null when none is open.
        public var context: ContextMenu?
        public init(bar: [MenuItem], context: ContextMenu? = nil) { self.bar = bar; self.context = context }
        private enum CodingKeys: String, CodingKey { case bar, context }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bar = try c.decodeIfPresent([MenuItem].self, forKey: .bar) ?? []
            context = try c.decodeIfPresent(ContextMenu.self, forKey: .context)
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bar, forKey: .bar)
            try c.encode(context, forKey: .context)
        }
    }

    /// Reserved for the viewer-options Task: `{"t":"control","mode":"everyone","you":true}`, the control
    /// mode and whether this viewer may control the app right now.
    public struct Control: Codable, Equatable, Sendable {
        public var mode: ControlMode
        public var you: Bool
        public init(mode: ControlMode, you: Bool) { self.mode = mode; self.you = you }
    }

    // MARK: Client to server payloads

    /// `{"t":"act"}`: perform an accessibility action on the node with this key in the window's latest
    /// snapshot. The server never takes raw handles from the client; unknown keys are ignored.
    public struct Act: Codable, Equatable, Sendable {
        public var window: WindowID
        public var key: String
        public var action: Action
        public init(window: WindowID, key: String, action: Action) { self.window = window; self.key = key; self.action = action }
    }

    /// `{"t":"pointer"}`: a pointer event at window-relative points. `dx`/`dy` are wheel deltas in
    /// points (0 for other kinds); both and `modifiers` may be omitted by the client.
    public struct Pointer: Codable, Equatable, Sendable {
        public var window: WindowID
        public var kind: PointerKind
        public var x: Double
        public var y: Double
        public var dx: Double
        public var dy: Double
        public var modifiers: [Modifier]

        public init(window: WindowID, kind: PointerKind, x: Double, y: Double, dx: Double = 0, dy: Double = 0, modifiers: [Modifier] = []) {
            self.window = window; self.kind = kind; self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.modifiers = modifiers
        }

        private enum CodingKeys: String, CodingKey { case window, kind, x, y, dx, dy, modifiers }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            window = try c.decode(WindowID.self, forKey: .window)
            kind = try c.decode(PointerKind.self, forKey: .kind)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
            dx = try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0
            dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0
            modifiers = try c.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
        }
    }

    /// `{"t":"text"}`: type Unicode text at the app's current focus.
    public struct Text: Codable, Equatable, Sendable {
        public var window: WindowID
        public var text: String
        public init(window: WindowID, text: String) { self.window = window; self.text = text }
    }

    /// `{"t":"key"}`: press one named key, with modifiers (may be omitted).
    public struct Key: Codable, Equatable, Sendable {
        public var window: WindowID
        public var code: KeyCode
        public var modifiers: [Modifier]
        public init(window: WindowID, code: KeyCode, modifiers: [Modifier] = []) { self.window = window; self.code = code; self.modifiers = modifiers }

        private enum CodingKeys: String, CodingKey { case window, code, modifiers }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            window = try c.decode(WindowID.self, forKey: .window)
            code = try c.decode(KeyCode.self, forKey: .code)
            modifiers = try c.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
        }
    }

    /// `{"t":"setText"}`: replace a field's whole value (the server focuses it, selects all, types).
    public struct SetText: Codable, Equatable, Sendable {
        public var window: WindowID
        public var key: String
        public var value: String
        public init(window: WindowID, key: String, value: String) { self.window = window; self.key = key; self.value = value }
    }

    /// Reserved for the viewer-options Task: the viewer's usable size in CSS pixels and its
    /// `prefers-color-scheme` (null when unknown).
    public struct Viewport: Codable, Equatable, Sendable {
        public var w: Double
        public var h: Double
        public var appearance: Appearance?
        public init(w: Double, h: Double, appearance: Appearance? = nil) { self.w = w; self.h = h; self.appearance = appearance }

        private enum CodingKeys: String, CodingKey { case w, h, appearance }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            w = try c.decode(Double.self, forKey: .w)
            h = try c.decode(Double.self, forKey: .h)
            appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance)
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            try c.encode(appearance, forKey: .appearance)
        }
    }

    /// `{"t":"menuAction","path":["Orders","Mark All Shipped"],"context":false}`: choose a menu item by
    /// its titles, from the menu bar down (`context` false) or from the open context menu down
    /// (`context` true). An empty `path` with `context` true closes the context menu without choosing.
    public struct MenuAction: Codable, Equatable, Sendable {
        public var path: [String]
        public var context: Bool
        public init(path: [String], context: Bool = false) { self.path = path; self.context = context }

        private enum CodingKeys: String, CodingKey { case path, context }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decodeIfPresent([String].self, forKey: .path) ?? []
            context = try c.decodeIfPresent(Bool.self, forKey: .context) ?? false
        }
    }

    /// `{"t":"windowAction","window":2,"action":"close"}`: focus or close a window from the viewer
    /// (a second window's tab, its close button in a tab strip). The main window is never closed.
    public struct WindowAction: Codable, Equatable, Sendable {
        public var window: WindowID
        public var action: WindowActionKind
        public init(window: WindowID, action: WindowActionKind) { self.window = window; self.action = action }
    }

    // MARK: Messages

    public enum ServerMessage: Codable, Equatable, Sendable {
        case hello(Hello)
        case windows([WindowInfo])
        case tree(Tree)
        case frame(FrameHeader)
        case cursor(CursorShape)
        case status(Status)
        /// The menu bar and the open context menu.
        case menu(Menu)
        /// Reserved: the viewer-options Task.
        case control(Control)

        public var type: String {
            switch self {
            case .hello: "hello"
            case .windows: "windows"
            case .tree: "tree"
            case .frame: "frame"
            case .cursor: "cursor"
            case .status: "status"
            case .menu: "menu"
            case .control: "control"
            }
        }

        public init(from decoder: any Decoder) throws {
            let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .t)
            switch type {
            case "hello": self = .hello(try Hello(from: decoder))
            case "windows": self = .windows(try Windows(from: decoder).windows)
            case "tree": self = .tree(try Tree(from: decoder))
            case "frame": self = .frame(try FrameHeader(from: decoder))
            case "cursor": self = .cursor(try Cursor(from: decoder).shape)
            case "status": self = .status(try Status(from: decoder))
            case "menu": self = .menu(try Menu(from: decoder))
            case "control": self = .control(try Control(from: decoder))
            default: throw MirrorProtocolError.unknownMessage(type)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: TypeKey.self)
            try c.encode(type, forKey: .t)
            switch self {
            case .hello(let payload): try payload.encode(to: encoder)
            case .windows(let windows): try Windows(windows: windows).encode(to: encoder)
            case .tree(let payload): try payload.encode(to: encoder)
            case .frame(let payload): try payload.encode(to: encoder)
            case .cursor(let shape): try Cursor(shape: shape).encode(to: encoder)
            case .status(let payload): try payload.encode(to: encoder)
            case .menu(let payload): try payload.encode(to: encoder)
            case .control(let payload): try payload.encode(to: encoder)
            }
        }

        /// The JSON text of a WebSocket text message.
        public func jsonData() throws -> Data { try MirrorProtocol.encoder.encode(self) }
        public func jsonString() throws -> String { String(decoding: try jsonData(), as: UTF8.self) }
        public static func decode(_ data: Data) throws -> ServerMessage { try JSONDecoder().decode(ServerMessage.self, from: data) }
        public static func decode(_ text: String) throws -> ServerMessage { try decode(Data(text.utf8)) }
    }

    public enum ClientMessage: Codable, Equatable, Sendable {
        case act(Act)
        case pointer(Pointer)
        case text(Text)
        case key(Key)
        case setText(SetText)
        /// Reserved: the viewer-options Task.
        case viewport(Viewport)
        /// Choose a menu item (menu bar or context menu), or close the context menu.
        case menuAction(MenuAction)
        /// Focus or close a window.
        case windowAction(WindowAction)
        /// Reserved: the viewer-options Task (`Ask to control`): `{"t":"requestControl"}`.
        case requestControl

        public var type: String {
            switch self {
            case .act: "act"
            case .pointer: "pointer"
            case .text: "text"
            case .key: "key"
            case .setText: "setText"
            case .viewport: "viewport"
            case .menuAction: "menuAction"
            case .windowAction: "windowAction"
            case .requestControl: "requestControl"
            }
        }

        /// The window the message is aimed at, when it names one.
        public var window: WindowID? {
            switch self {
            case .act(let m): m.window
            case .pointer(let m): m.window
            case .text(let m): m.window
            case .key(let m): m.window
            case .setText(let m): m.window
            case .windowAction(let m): m.window
            case .viewport, .menuAction, .requestControl: nil
            }
        }

        public init(from decoder: any Decoder) throws {
            let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .t)
            switch type {
            case "act": self = .act(try Act(from: decoder))
            case "pointer": self = .pointer(try Pointer(from: decoder))
            case "text": self = .text(try Text(from: decoder))
            case "key": self = .key(try Key(from: decoder))
            case "setText": self = .setText(try SetText(from: decoder))
            case "viewport": self = .viewport(try Viewport(from: decoder))
            case "menuAction": self = .menuAction(try MenuAction(from: decoder))
            case "windowAction": self = .windowAction(try WindowAction(from: decoder))
            case "requestControl": self = .requestControl
            default: throw MirrorProtocolError.unknownMessage(type)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: TypeKey.self)
            try c.encode(type, forKey: .t)
            switch self {
            case .act(let payload): try payload.encode(to: encoder)
            case .pointer(let payload): try payload.encode(to: encoder)
            case .text(let payload): try payload.encode(to: encoder)
            case .key(let payload): try payload.encode(to: encoder)
            case .setText(let payload): try payload.encode(to: encoder)
            case .viewport(let payload): try payload.encode(to: encoder)
            case .menuAction(let payload): try payload.encode(to: encoder)
            case .windowAction(let payload): try payload.encode(to: encoder)
            case .requestControl: break
            }
        }

        public func jsonData() throws -> Data { try MirrorProtocol.encoder.encode(self) }
        public func jsonString() throws -> String { String(decoding: try jsonData(), as: UTF8.self) }
        /// Servers should ignore (not fail on) `MirrorProtocolError.unknownMessage`.
        public static func decode(_ data: Data) throws -> ClientMessage { try JSONDecoder().decode(ClientMessage.self, from: data) }
        public static func decode(_ text: String) throws -> ClientMessage { try decode(Data(text.utf8)) }
    }

    private enum TypeKey: String, CodingKey { case t }

    /// Slashes unescaped so node keys read as written (`"/Window:/Button:OK"`, not `"\/Window..."`).
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    // MARK: Binary tiles

    public enum TileFormat: UInt8, Codable, Sendable, CaseIterable {
        case jpeg = 0
        case webp = 1

        public var mimeType: String {
            switch self {
            case .jpeg: "image/jpeg"
            case .webp: "image/webp"
            }
        }
    }

    /// One binary WebSocket message after a `frame` header: a 17-byte header, all integers big-endian
    /// (network order, `DataView`'s default), then the encoded image.
    ///
    ///     offset 0  UInt32 window
    ///     offset 4  UInt32 seq
    ///     offset 8  UInt16 x       (points, from the window's top-left)
    ///     offset 10 UInt16 y
    ///     offset 12 UInt16 w       (points; the image is w*scale by h*scale pixels)
    ///     offset 14 UInt16 h
    ///     offset 16 UInt8  format  (0 JPEG, 1 WebP)
    ///     offset 17 image bytes, to the end of the message
    public struct Tile: Equatable, Sendable {
        public static let headerSize = 17

        public var window: WindowID
        public var seq: UInt32
        public var x: UInt16
        public var y: UInt16
        public var w: UInt16
        public var h: UInt16
        public var format: TileFormat
        public var data: Data

        public init(window: WindowID, seq: UInt32, x: UInt16, y: UInt16, w: UInt16, h: UInt16, format: TileFormat, data: Data) {
            self.window = window; self.seq = seq; self.x = x; self.y = y; self.w = w; self.h = h; self.format = format; self.data = data
        }

        public func encoded() -> Data {
            var out = Data(capacity: Self.headerSize + data.count)
            func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) } }
            append(window)
            append(seq)
            append(x)
            append(y)
            append(w)
            append(h)
            append(format.rawValue)
            out.append(data)
            return out
        }

        public init(decoding bytes: Data) throws {
            let bytes = Array(bytes)
            guard bytes.count >= Self.headerSize else { throw MirrorProtocolError.tileTooShort(bytes.count) }
            func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
                var value: T = 0
                for index in 0..<MemoryLayout<T>.size { value = value << 8 | T(bytes[offset + index]) }
                return value
            }
            guard let format = TileFormat(rawValue: bytes[16]) else { throw MirrorProtocolError.unknownTileFormat(bytes[16]) }
            self.init(
                window: read(UInt32.self, at: 0),
                seq: read(UInt32.self, at: 4),
                x: read(UInt16.self, at: 8),
                y: read(UInt16.self, at: 10),
                w: read(UInt16.self, at: 12),
                h: read(UInt16.self, at: 14),
                format: format,
                data: Data(bytes[Self.headerSize...])
            )
        }
    }

    // MARK: Node keys

    /// Node keys name an element by its path from the window, so they survive re-snapshots: one
    /// `/<Role without AX>:<label>` segment per level, the label cut to 40 characters, with `#n`
    /// (n = 2, 3, ...) on the second and later siblings that would otherwise have the same segment.
    /// The main window itself is always `/Window:` (its title is left out, so keys survive a title
    /// change), e.g. `/Window:/Group:/Button:Add Order`. Keys are unique across all of an app's
    /// windows (so are the viewer's DOM ids): a second window's root is `/Window:<title>` (`#n` when
    /// windows share one), and a sheet, alert or popover keeps the key it has in its parent's tree
    /// (`/Window:/Sheet:`), its elements continuing from it.
    public enum NodeKey {
        public static let labelLimit = 40
        public static let root = "/Window:"

        /// The roots of the top-level windows, in order (the main window first): the main window
        /// `/Window:`, every other `/Window:<title>`, with `#n` on the second and later window that
        /// would have the same root (an untitled second window is `/Window:#2`).
        public static func windowRoots(titles: [String]) -> [String] {
            var seen: [String: Int] = [:]
            return titles.enumerated().map { index, title in
                let segment = index == 0 ? root : NodeKey.segment(role: "AXWindow", label: title)
                let count = (seen[segment] ?? 0) + 1
                seen[segment] = count
                return segment + (count > 1 ? "#\(count)" : "")
            }
        }

        /// A key read in a window whose root is `/Window:` (as the accessibility bridge reads every
        /// window), moved under `root`.
        public static func rebase(_ key: String, onto root: String) -> String {
            guard root != NodeKey.root, key.hasPrefix(NodeKey.root) else { return key }
            return root + key.dropFirst(NodeKey.root.count)
        }

        /// The other way: a key under `root` as the accessibility bridge knows it, or nil when it
        /// isn't under `root`.
        public static func unrebase(_ key: String, from root: String) -> String? {
            guard root != NodeKey.root else { return key.hasPrefix(NodeKey.root) ? key : nil }
            guard key == root || key.hasPrefix(root + "/") else { return nil }
            return NodeKey.root + key.dropFirst(root.count)
        }

        /// One path segment, without the sibling suffix. Whitespace runs (newlines, tabs) become one
        /// space and `/` becomes `∕` (U+2215), so a label can never split the path.
        public static func segment(role: String, label: String) -> String {
            let role = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            let collapsed = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let cleaned = collapsed.replacingOccurrences(of: "/", with: "\u{2215}")
            return "/\(role):\(String(cleaned.prefix(labelLimit)))"
        }

        /// Gives each child of one parent its key: call `key(role:label:)` for the children in order.
        public struct Siblings {
            public let parent: String
            private var seen: [String: Int] = [:]

            public init(parent: String) { self.parent = parent }

            public mutating func key(role: String, label: String) -> String {
                let segment = NodeKey.segment(role: role, label: label)
                let count = (seen[segment] ?? 0) + 1
                seen[segment] = count
                return parent + segment + (count > 1 ? "#\(count)" : "")
            }
        }

        /// The viewer's DOM id for a key: `ax-` + djb2 over the key's UTF-16 code units (the units
        /// JavaScript's `charCodeAt` returns), as an unsigned 32-bit number in base 36.
        public static func domID(for key: String) -> String {
            var hash: UInt32 = 5381
            for unit in key.utf16 { hash = hash &* 33 &+ UInt32(unit) }
            return "ax-" + String(hash, radix: 36)
        }
    }
}

public enum MirrorProtocolError: Error, Equatable, Sendable {
    /// A JSON message whose `t` this side doesn't know: ignore it (the other side may be newer).
    case unknownMessage(String)
    case tileTooShort(Int)
    case unknownTileFormat(UInt8)
}

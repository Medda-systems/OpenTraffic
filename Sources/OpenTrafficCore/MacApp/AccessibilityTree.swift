import ApplicationServices
import CoreGraphics
import Foundation

/// Reads, acts on and watches another app's accessibility tree, from outside its process.
///
/// One `AccessibilityTree` serves one process (`pid`). A snapshot lists one window's elements as
/// mirror protocol nodes (`MirrorProtocol.AXNode`) with the protocol's stable keys
/// (`MirrorProtocol.NodeKey`); `perform(key:action:)` and `focus(key:)` find an element by its key
/// in the last snapshot; `changes()` streams the app's accessibility notifications so a server can
/// push updates instead of polling.
///
/// Every AX call, the observer included, runs on one thread of its own (`AXExecutor`): AX calls are
/// synchronous IPC, so they stay off the main thread and never run concurrently. The bridge refuses
/// its own process: in-process AX runs the callee on the caller's thread, and SwiftUI asserts that
/// its accessibility is only touched on the main thread.
public final class AccessibilityTree: @unchecked Sendable {
    public let pid: pid_t

    /// The most elements one snapshot visits, so a runaway tree (a huge table) cannot stall the bridge.
    public static let nodeLimit = 4000
    /// The deepest level one snapshot visits.
    public static let depthLimit = 64
    /// How long one AX call may wait for an unresponsive app.
    public static let messagingTimeout: Float = 2

    private let executor: AXExecutor
    private let hub = AXChangeHub()
    // Touched on the executor only.
    private let app: AXUIElement
    private var observer: AXObserver?
    private var elementsByWindow: [UInt32: [String: AXUIElement]] = [:]
    private var lastWindow: UInt32?
    /// Sheets and popovers found by the latest snapshots, by their window number: they aren't among
    /// the app's AXWindows, so `.number` finds them here.
    private var surfaceElements: [UInt32: AXUIElement] = [:]

    /// Is this process allowed to use Accessibility (System Settings > Privacy & Security)?
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt when this process is not trusted yet. Returns
    /// whether it is trusted now (the user's answer arrives later; check `isTrusted` again).
    @discardableResult
    public static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// A bridge to the process `pid`. Throws `.ownProcess` for this process's own pid.
    public init(pid: pid_t) throws {
        guard pid != getpid() else { throw AccessibilityTreeError.ownProcess }
        guard pid > 0 else { throw AccessibilityTreeError.noProcess }
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        executor = AXExecutor(name: "OpenTraffic.AccessibilityTree.\(pid)")
        executor.start()
        executor.waitUntilReady()
        let app = AXHandle(app)
        executor.perform { _ = AXUIElementSetMessagingTimeout(app.value, AccessibilityTree.messagingTimeout) }
    }

    deinit {
        let observer = observer.map(AXHandle.init), hub = hub, app = AXHandle(app), executor = executor
        executor.perform {
            if let observer = observer?.value {
                for notification in AXChange.notifications { AXObserverRemoveNotification(observer, app.value, notification as CFString) }
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
                Unmanaged.passUnretained(hub).release()
            }
            hub.finishAll()
            executor.stop()
        }
    }

    // MARK: Windows

    /// Which window a snapshot reads.
    public enum WindowSelector: Sendable, Hashable {
        /// The app's main window, else its focused window, else its first window.
        case main
        /// The app's focused window, else its main window.
        case focused
        /// The window with this window server number (`CGWindowID`, as ScreenCaptureKit uses).
        case number(UInt32)
        /// The first window with exactly this title.
        case title(String)
        /// The n-th entry of the app's window list (front to back).
        case index(Int)
    }

    /// One of the app's windows. `frame` is in global points with the origin at the top-left of the
    /// primary display (Accessibility's coordinates).
    public struct Window: Sendable, Equatable {
        public var number: UInt32?
        public var title: String
        public var role: String
        public var subrole: String?
        public var frame: CGRect
        public var isMain: Bool
        public var isFocused: Bool
        public var isMinimized: Bool
    }

    /// The app's windows, front to back (AXWindows).
    public func windows() async throws -> [Window] {
        try await run { [self] in
            try checkTrust()
            let main = copy(app, kAXMainWindowAttribute).map { $0 as! AXUIElement }
            let focused = copy(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            return windowElements().map { element in
                Window(number: windowNumber(element), title: copy(element, kAXTitleAttribute) as? String ?? "",
                       role: copy(element, kAXRoleAttribute) as? String ?? "", subrole: copy(element, kAXSubroleAttribute) as? String,
                       frame: frame(element) ?? .zero,
                       isMain: main.map { CFEqual($0, element) } ?? false, isFocused: focused.map { CFEqual($0, element) } ?? false,
                       isMinimized: copy(element, kAXMinimizedAttribute) as? Bool ?? false)
            }
        }
    }

    // MARK: Snapshot

    /// A full snapshot of one window's elements, in document order (a parent before its children),
    /// with the mirror protocol's fields and keys. Also remembers the elements, so `perform` and
    /// `focus` can find them by key until the next snapshot of the same window.
    public func snapshot(window: WindowSelector = .main) async throws -> AXSnapshot {
        try await run { [self] in
            try checkTrust()
            guard let element = resolve(window) else { throw AccessibilityTreeError.noWindow }
            return try read(window: element)
        }
    }

    // MARK: Acting

    /// Performs a protocol action on the element with this key in the last snapshot of `window`
    /// (by default the window snapshotted last). When the element is gone since, takes a new
    /// snapshot of that window and tries once more.
    public func perform(key: String, action: MirrorProtocol.Action, window: UInt32? = nil) async throws {
        try await act(key: key, window: window, operation: "perform \(action.axName)") { element in
            AXUIElementPerformAction(element, action.axName as CFString)
        }
    }

    /// Moves the keyboard focus to the element with this key (sets AXFocused).
    public func focus(key: String, window: UInt32? = nil) async throws {
        try await act(key: key, window: window, operation: "focus") { element in
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// The AXIdentifier of the element with this key in the last snapshot of `window` (by default the
    /// window snapshotted last): SwiftUI's `accessibilityIdentifier`, AppKit's `identifier`. Nil when it has
    /// none or isn't in that snapshot. For the agent's context (`MacAppAgentContext`), not the mirror.
    public func identifier(key: String, window: UInt32? = nil) async throws -> String? {
        try await run { [self] in
            try checkTrust()
            guard let windowID = window ?? lastWindow, let element = elementsByWindow[windowID]?[key] else { return nil }
            return copy(element, "AXIdentifier") as? String
        }
    }

    // MARK: Windows from the viewer

    /// Brings a window (or a sheet's window) to the front and makes it the app's main and key
    /// window, so typing goes there. The app isn't activated.
    public func raise(window number: UInt32) async throws {
        try await run { [self] in
            try checkTrust()
            guard let element = windowElement(number: number) else { throw AccessibilityTreeError.noWindow }
            let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard raised == .success || raised == .actionUnsupported else {
                throw AccessibilityTreeError.axFailure(operation: "raise", code: raised.rawValue)
            }
        }
    }

    /// Closes a window like its close button; a popover is cancelled (it has no close button).
    public func close(window number: UInt32) async throws {
        try await run { [self] in
            try checkTrust()
            guard let element = windowElement(number: number) else { throw AccessibilityTreeError.noWindow }
            if (copy(element, kAXRoleAttribute) as? String) == "AXPopover" {
                let result = AXUIElementPerformAction(element, kAXCancelAction as CFString)
                guard result == .success else { throw AccessibilityTreeError.axFailure(operation: "cancel popover", code: result.rawValue) }
                return
            }
            guard let button = copy(element, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }) else {
                throw AccessibilityTreeError.axFailure(operation: "close (no close button)", code: AXError.attributeUnsupported.rawValue)
            }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard result == .success else { throw AccessibilityTreeError.axFailure(operation: "close", code: result.rawValue) }
        }
    }

    // MARK: Changes

    /// The app's accessibility notifications as a stream: values, focus, destroyed elements,
    /// layout, windows, sheets and menus. Several streams may be open at once; each gets every
    /// change. The stream ends when the bridge goes away.
    public func changes() -> AsyncStream<AXChange> {
        let (stream, continuation) = AsyncStream<AXChange>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let id = hub.add(continuation)
        let hub = hub
        continuation.onTermination = { _ in hub.remove(id) }
        executor.perform { [self] in startObserving() }
        return stream
    }

    /// Waits until every AX call queued before it has run (and with it, the observer is set up).
    public func settle() async {
        _ = try? await run { () }
    }

    // MARK: - Executor-confined internals

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            executor.perform { continuation.resume(with: Result { try work() }) }
        }
    }

    private func checkTrust() throws {
        guard AXIsProcessTrusted() else { throw AccessibilityTreeError.notTrusted }
    }

    private func act(key: String, window: UInt32?, operation: String,
                     _ body: @escaping @Sendable (AXUIElement) -> AXError) async throws {
        try await run { [self] in
            try checkTrust()
            guard let windowID = window ?? lastWindow, elementsByWindow[windowID] != nil else { throw AccessibilityTreeError.unknownKey(key) }
            var result = elementsByWindow[windowID]?[key].map(body)
            if result == nil || result == .invalidUIElement {
                // The element went away (or the key is new): read that window again and retry once.
                if let element = windowElement(number: windowID) ?? (windowID == lastWindow ? resolve(.main) : nil) {
                    _ = try read(window: element)
                }
                result = elementsByWindow[windowID]?[key].map(body)
            }
            guard let result else { throw AccessibilityTreeError.unknownKey(key) }
            guard result == .success else { throw AccessibilityTreeError.axFailure(operation: operation, code: result.rawValue) }
        }
    }

    private func startObserving() {
        guard observer == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passRetained(hub).toOpaque()
        for notification in AXChange.notifications {
            _ = AXObserverAddNotification(created, app, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func windowElements() -> [AXUIElement] {
        (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private func windowElement(number: UInt32) -> AXUIElement? {
        if let window = windowElements().first(where: { windowNumber($0) == number }) { return window }
        // A sheet or popover seen by a snapshot, while it is still there.
        guard let surface = surfaceElements[number] else { return nil }
        guard copy(surface, kAXRoleAttribute) != nil, windowNumber(surface) == number else {
            surfaceElements[number] = nil
            return nil
        }
        return surface
    }

    private func resolve(_ selector: WindowSelector) -> AXUIElement? {
        let main = copy(app, kAXMainWindowAttribute).map { $0 as! AXUIElement }
        let focused = copy(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        switch selector {
        case .main: return main ?? focused ?? windowElements().first
        case .focused: return focused ?? main
        case .number(let number): return windowElement(number: number)
        case .title(let title): return windowElements().first { copy($0, kAXTitleAttribute) as? String == title }
        case .index(let index):
            let all = windowElements()
            return all.indices.contains(index) ? all[index] : nil
        }
    }

    /// The window server number of a window element: the private `_AXUIElementGetWindow` when it
    /// exists, else the on-screen window of this pid with the same frame.
    private func windowNumber(_ window: AXUIElement) -> UInt32? {
        if let getWindow = axGetWindow {
            var number: CGWindowID = 0
            if getWindow(window, &number) == .success, number != 0 { return number }
        }
        guard let frame = frame(window),
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect == frame else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }

    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute, kAXSubroleAttribute,
    ]

    private func read(window: AXUIElement) throws -> AXSnapshot {
        let windowFrame = frame(window) ?? .zero
        let number = windowNumber(window)
        var nodes: [MirrorProtocol.AXNode] = []
        var elements: [String: AXUIElement] = [:]
        var surfaces: [AXSnapshot.Surface] = []

        /// The batched attributes of one element (`attributes` order), nil for the missing ones.
        func fetch(_ element: AXUIElement) -> [AnyObject?]? {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Self.attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let values = values as? [AnyObject], values.count == Self.attributeNames.count else { return nil }
            return values.map { Self.isPresent($0) ? $0 : nil }
        }
        func label(_ present: [AnyObject?]) -> (role: String, label: String) {
            let role = Self.role(present[0] as? String ?? "AXUnknown", subrole: present[10] as? String)
            return (role, Self.label(role: role, description: present[1] as? String, title: present[2] as? String, value: present[3]))
        }
        func visit(_ element: AXUIElement, _ present: [AnyObject?], key: String, depth: Int, clip: CGRect) {
            guard nodes.count < Self.nodeLimit else { return }
            let (role, name) = label(present)
            let position = present[4].flatMap { Self.point($0) } ?? .zero
            let size = present[5].flatMap { Self.size($0) } ?? .zero
            let raw = CGRect(origin: CGPoint(x: position.x - windowFrame.minX, y: position.y - windowFrame.minY), size: size)
            let frame = Self.visibleFrame(raw, clip: clip)
            nodes.append(MirrorProtocol.AXNode(
                key: key, role: role, label: name, value: Self.valueString(role: role, value: present[3]),
                x: Double(frame.minX), y: Double(frame.minY), w: Double(frame.width), h: Double(frame.height), depth: depth,
                enabled: (present[6] as? Bool) ?? true, focused: (present[7] as? Bool) ?? false, selected: (present[8] as? Bool) ?? false,
                actions: Self.actions(actionNames(element))))
            elements[key] = element
            // Never read inside an element scrolled out of view: asking AppKit about a lazily made row's
            // contents makes it lay the row out, which changes the list's size, so a polled tree would
            // never settle. Its own node (and key) is there; its contents come when it scrolls in.
            guard depth < Self.depthLimit, !Self.isScrolledAway(raw, clip: clip),
                  let children = present[9] as? [AXUIElement], !children.isEmpty else { return }
            // A child's key needs its label, so read every child before visiting the first one.
            var siblings = MirrorProtocol.NodeKey.Siblings(parent: key)
            let read = children.compactMap { child in fetch(child).map { (child, $0) } }
            let keyed = read.map { child, present in
                let (role, name) = label(present)
                return (child, present, siblings.key(role: role, label: name))
            }
            let childClip = role == kAXScrollAreaRole ? clip.intersection(frame) : clip
            for (child, present, childKey) in keyed {
                if let surface = surface(child, present, key: childKey) {
                    // A sheet or popover is a window of its own: mirrored as its own surface, not here.
                    surfaces.append(surface)
                    surfaceElements[surface.number] = child
                    continue
                }
                visit(child, present, key: childKey, depth: depth + 1, clip: childClip)
            }
        }
        /// A child that is a sheet or popover with a window of its own (a window number other than
        /// this window's), else nil.
        func surface(_ child: AXUIElement, _ present: [AnyObject?], key: String) -> AXSnapshot.Surface? {
            let role = present[0] as? String ?? ""
            guard Self.surfaceRoles.contains(role), let own = windowNumber(child), own != number else { return nil }
            let position = present[4].flatMap { Self.point($0) } ?? .zero
            let size = present[5].flatMap { Self.size($0) } ?? .zero
            return AXSnapshot.Surface(number: own, key: key, role: role, subrole: present[10] as? String,
                                      description: present[1] as? String ?? "", frame: CGRect(origin: position, size: size))
        }
        guard let root = fetch(window) else { throw AccessibilityTreeError.noWindow }
        visit(window, root, key: MirrorProtocol.NodeKey.root, depth: 0, clip: CGRect(origin: .zero, size: windowFrame.size))

        let windowID = number ?? 0
        elementsByWindow[windowID] = elements
        lastWindow = windowID
        return AXSnapshot(windowNumber: number, title: copy(window, kAXTitleAttribute) as? String ?? "", frame: windowFrame,
                          nodes: nodes, surfaces: surfaces)
    }

    /// Roles of elements that live in windows of their own inside another window's tree.
    static let surfaceRoles: Set<String> = ["AXSheet", "AXPopover"]

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute).flatMap(Self.point),
              let size = copy(element, kAXSizeAttribute).flatMap(Self.size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    // MARK: - Pure rules (tested without Accessibility)

    /// The role the protocol shows. AppKit reports a secure field as an AXTextField with the subrole
    /// AXSecureTextField; it is shown as AXSecureTextField, so its value is never mirrored and the
    /// viewer can draw a password field.
    static func role(_ role: String, subrole: String?) -> String {
        subrole == "AXSecureTextField" ? "AXSecureTextField" : role
    }

    /// A node's frame as the protocol sends it: as is while any of it can be seen, else zero. An element
    /// is out of sight when it has no size or lies wholly outside the window or a scroll area around
    /// it. AppKit lays rows scrolled out of view out lazily and reports jittery frames for them; zeroing
    /// them keeps equal trees equal (`v`) while their keys stay put.
    static func visibleFrame(_ frame: CGRect, clip: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0, !clip.isNull, frame.intersects(clip) else { return .zero }
        return frame
    }

    /// Has the element a real frame that lies wholly outside what can be seen? (A zero-size element
    /// is not scrolled away: some SwiftUI containers report no size while their children show.)
    static func isScrolledAway(_ frame: CGRect, clip: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && (clip.isNull || !frame.intersects(clip))
    }

    /// The protocol's label: AXDescription, else AXTitle, else the value of static text; `""` when none.
    static func label(role: String, description: String?, title: String?, value: Any?) -> String {
        if let description, !description.isEmpty { return description }
        if let title, !title.isEmpty { return title }
        if role == kAXStaticTextRole, let text = value as? String { return text }
        return ""
    }

    /// The protocol's value: text as is, checkboxes and radio buttons `"0"`/`"1"`, whole numbers
    /// without a fraction; nothing for secure text fields (never mirror a secret, not even its
    /// length) and for values that aren't text or numbers.
    static func valueString(role: String, value: Any?) -> String? {
        guard role != "AXSecureTextField", let value else { return nil }
        if let text = value as? String { return text }
        guard let number = value as? NSNumber else { return nil }
        if role == kAXCheckBoxRole || role == kAXRadioButtonRole || CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.doubleValue != 0 ? "1" : "0"
        }
        let double = number.doubleValue
        if double.isFinite, double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
        return "\(double)"
    }

    /// The protocol actions among an element's AX action names, in protocol order.
    static func actions(_ axNames: [String]) -> [MirrorProtocol.Action] {
        let names = Set(axNames)
        return MirrorProtocol.Action.allCases.filter { names.contains($0.axName) }
    }

    private static func isPresent(_ value: AnyObject) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return true }
        return AXValueGetType(value as! AXValue) != .axError
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// One window's accessibility tree at one moment, as mirror protocol nodes.
public struct AXSnapshot: Sendable, Equatable {
    /// A sheet or popover inside the window that is a window of its own (its own window number):
    /// left out of `nodes`, it is read with `snapshot(window: .number(number))`. `key` is the key it
    /// would have had among `nodes`; `frame` is global, like the window's.
    public struct Surface: Sendable, Equatable {
        public var number: UInt32
        public var key: String
        public var role: String
        public var subrole: String?
        public var description: String
        public var frame: CGRect

        public init(number: UInt32, key: String, role: String, subrole: String? = nil, description: String = "", frame: CGRect) {
            self.number = number; self.key = key; self.role = role; self.subrole = subrole; self.description = description; self.frame = frame
        }
    }

    /// The window server number of the window (`CGWindowID`), when known.
    public var windowNumber: UInt32?
    public var title: String
    /// The window's frame in global points, origin at the top-left of the primary display.
    public var frame: CGRect
    public var nodes: [MirrorProtocol.AXNode]
    /// Sheets and popovers in the window that are windows of their own, in document order.
    public var surfaces: [Surface]
    /// The content hash the viewer sees as the tree's `v`: equal nodes give an equal `v`.
    public let v: String

    public init(windowNumber: UInt32?, title: String, frame: CGRect, nodes: [MirrorProtocol.AXNode], surfaces: [Surface] = []) {
        self.windowNumber = windowNumber; self.title = title; self.frame = frame; self.nodes = nodes; self.surfaces = surfaces
        v = AXSnapshot.hash(nodes)
    }

    /// The node with this key.
    public func node(_ key: String) -> MirrorProtocol.AXNode? { nodes.first { $0.key == key } }

    /// The `tree` message for this snapshot as window `id`.
    public func tree(window id: MirrorProtocol.WindowID) -> MirrorProtocol.Tree {
        MirrorProtocol.Tree(window: id, v: v, nodes: nodes)
    }

    /// A cheap content hash: 64-bit FNV-1a over every field of every node, as 16 hex digits.
    public static func hash(_ nodes: [MirrorProtocol.AXNode]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            hash = (hash ^ 0x1f) &* 0x0000_0100_0000_01b3 // field separator
        }
        for node in nodes {
            mix(node.key); mix(node.role); mix(node.label); mix(node.value ?? "\u{0}")
            mix("\(node.x),\(node.y),\(node.w),\(node.h),\(node.depth)")
            mix("\(node.enabled)\(node.focused)\(node.selected)")
            mix(node.actions.map(\.rawValue).joined(separator: ","))
        }
        return String(format: "%016llx", hash)
    }
}

/// One accessibility notification from the watched app.
public struct AXChange: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case value, focus, destroyed, created, layout, title, selection
        case windowCreated, windowMoved, windowResized, windowMinimized, windowRestored, mainWindow, focusedWindow
        case sheetCreated, menuOpened, menuClosed
    }

    public var kind: Kind
    /// The AX notification name, e.g. `AXValueChanged`.
    public var notification: String
    /// The role of the element it is about, when it can still be read (not for destroyed ones).
    public var role: String?
    public var date: Date

    public init(kind: Kind, notification: String, role: String?, date: Date = Date()) {
        self.kind = kind; self.notification = notification; self.role = role; self.date = date
    }

    /// The AX notifications the bridge listens to, and the kind each one becomes.
    static let kinds: [String: Kind] = [
        kAXValueChangedNotification: .value,
        kAXFocusedUIElementChangedNotification: .focus,
        kAXUIElementDestroyedNotification: .destroyed,
        kAXCreatedNotification: .created,
        kAXLayoutChangedNotification: .layout,
        kAXTitleChangedNotification: .title,
        kAXSelectedChildrenChangedNotification: .selection,
        kAXSelectedRowsChangedNotification: .selection,
        kAXWindowCreatedNotification: .windowCreated,
        kAXWindowMovedNotification: .windowMoved,
        kAXWindowResizedNotification: .windowResized,
        kAXWindowMiniaturizedNotification: .windowMinimized,
        kAXWindowDeminiaturizedNotification: .windowRestored,
        kAXMainWindowChangedNotification: .mainWindow,
        kAXFocusedWindowChangedNotification: .focusedWindow,
        kAXSheetCreatedNotification: .sheetCreated,
        kAXMenuOpenedNotification: .menuOpened,
        kAXMenuClosedNotification: .menuClosed,
    ]
    static let notifications = kinds.keys.sorted()
}

public enum AccessibilityTreeError: Error, Equatable, Sendable {
    /// This process may not use Accessibility; see `AccessibilityTree.requestTrust()`.
    case notTrusted
    /// The bridge was asked to read its own process, which it never does.
    case ownProcess
    case noProcess
    /// The app has no window that matches.
    case noWindow
    /// No element with this key in the last snapshot of that window, not even after a new snapshot.
    case unknownKey(String)
    /// The app refused or failed the call (`code` is the AXError).
    case axFailure(operation: String, code: Int32)
}

// MARK: - The AX thread and the observer callback

/// Carries an AX handle into a block for the AX thread, the only place it is used.
struct AXHandle<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A thread with its own run loop that runs blocks one after another, in the order given; the AX
/// observer's source sits on the same run loop, so notifications arrive on this thread too.
final class AXExecutor: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInitiated
    }

    override func main() {
        let runLoop = CFRunLoopGetCurrent()!
        // A timer far in the future keeps the run loop alive while there is nothing else on it.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
        lock.withLock { self.runLoop = runLoop }
        ready.signal()
        CFRunLoopRun()
    }

    func waitUntilReady() { ready.wait() }

    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop = lock.withLock({ self.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Stops the run loop; call from a block on this thread.
    func stop() {
        guard let runLoop = lock.withLock({ self.runLoop }) else { return }
        CFRunLoopStop(runLoop)
    }
}

/// Fans the observer's notifications out to every open `changes()` stream.
final class AXChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AXChange>.Continuation] = [:]

    func add(_ continuation: AsyncStream<AXChange>.Continuation) -> UUID {
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        return id
    }

    func remove(_ id: UUID) { _ = lock.withLock { continuations.removeValue(forKey: id) } }

    func yield(_ change: AXChange) {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield(change) }
    }

    func finishAll() {
        let all = lock.withLock { () -> [AsyncStream<AXChange>.Continuation] in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in all { continuation.finish() }
    }
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let hub = Unmanaged<AXChangeHub>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    guard let kind = AXChange.kinds[name] else { return }
    var role: AnyObject?
    let readRole = kind != .destroyed && AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
    hub.yield(AXChange(kind: kind, notification: name, role: readRole ? role as? String : nil))
}

private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// `_AXUIElementGetWindow`, the window server number of a window element; private, so looked up at
/// run time and optional.
private let axGetWindow: AXGetWindow? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: AXGetWindow.self)
}()

import ApplicationServices
import CoreGraphics
import Foundation

/// Reads and uses another app's menus from outside its process: its menu bar (the mirror protocol's
/// `menu` message) and a menu it has popped up (a context menu after a right click, or a pop-up
/// button's menu), so viewers in a browser can use them.
///
/// Menu items are chosen with AXPress on the item itself, without opening the menu on screen. That is
/// also how keyboard shortcuts typed in the viewer reach the app: Cmd key equivalents posted as events
/// don't reach an app that isn't active, so the viewer maps them to their menu item (`menuAction`).
///
/// A popped-up menu isn't among the app's accessibility children: it is found as the app's on-screen
/// window at the pop-up menu level, hit-tested through Accessibility down to its AXMenu.
///
/// Items that reach beyond the app are never listed and can't be chosen: the Apple menu (the host's
/// Mac: Shut Down, Log Out, recent files), Services, AutoFill (the host's passwords and contacts),
/// Dictation and the character palette, and items that hide, quit, minimize, full-screen or tile the
/// app (`isBlocked`).
///
/// Every AX call runs on one thread of its own, like `AccessibilityTree`'s, so reading a large menu bar
/// never holds up tree snapshots.
public final class MenuBridge: @unchecked Sendable {
    public let pid: pid_t

    /// The deepest submenu level read (the bar's menus are level 1).
    public static let depthLimit = 4
    /// The most items one read visits.
    public static let itemLimit = 3000
    /// How long one AX call may wait for the app.
    public static let messagingTimeout: Float = 2
    /// How long pressing an item may take. An item whose action runs a modal loop (an alert, a menu)
    /// answers only when that ends; by then the press has been delivered, so a timeout counts as done.
    public static let pressTimeout: Float = 0.5
    /// The window level of popped-up menus (`kCGPopUpMenuWindowLevel`).
    static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    private let executor: AXExecutor
    // Touched on the executor only.
    private let app: AXUIElement

    /// A menu the app has popped up: its items (filtered like the bar's) and its frame in global
    /// points (origin at the top-left of the primary display).
    public struct OpenMenu: Sendable, Equatable {
        public var items: [MirrorProtocol.MenuItem]
        public var frame: CGRect
        public init(items: [MirrorProtocol.MenuItem], frame: CGRect) { self.items = items; self.frame = frame }
    }

    public init(pid: pid_t) throws {
        guard pid != getpid() else { throw AccessibilityTreeError.ownProcess }
        guard pid > 0 else { throw AccessibilityTreeError.noProcess }
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        executor = AXExecutor(name: "OpenTraffic.MenuBridge.\(pid)")
        executor.start()
        executor.waitUntilReady()
        let app = AXHandle(app)
        executor.perform { _ = AXUIElementSetMessagingTimeout(app.value, MenuBridge.messagingTimeout) }
    }

    deinit {
        let executor = executor
        executor.perform { executor.stop() }
    }

    // MARK: The menu bar

    /// The app's menu bar: its menus (the Apple menu left out), their items and submenus, with
    /// blocked items left out and separators tidied.
    public func bar() async throws -> [MirrorProtocol.MenuItem] {
        try await run { [self] in
            try checkTrust()
            var budget = Self.itemLimit
            return barItems().compactMap { top in
                let title = top.attributes.title
                guard !title.isEmpty else { return nil }
                let items = top.menu.map { readMenu($0, depth: 2, inAppMenu: top.isAppMenu, budget: &budget) } ?? []
                return MirrorProtocol.MenuItem(title: title, enabled: top.attributes.enabled, items: items)
            }
        }
    }

    /// Chooses a menu bar item by its titles, from the bar down (`["Orders", "Mark All Shipped"]`).
    /// Throws `noSuchItem` for a path that doesn't lead to an item (or leads to a blocked one) and
    /// `disabled` for an item that is off.
    public func perform(path: [String]) async throws {
        try await run { [self] in
            try checkTrust()
            guard let first = path.first, let top = barItems().first(where: { $0.attributes.title == first }) else {
                throw MenuBridgeError.noSuchItem(path)
            }
            guard path.count > 1, let menu = top.menu else { throw MenuBridgeError.noSuchItem(path) }
            try press(path: Array(path.dropFirst()), in: menu, inAppMenu: top.isAppMenu, fullPath: path)
        }
    }

    // MARK: Popped-up menus

    /// The menu the app has popped up (a context menu, a pop-up button's menu), or nil when none is
    /// open. With submenus open too, the outermost menu.
    public func openMenu() async throws -> OpenMenu? {
        try await run { [self] in
            try checkTrust()
            guard let menu = findOpenMenu() else { return nil }
            var budget = Self.itemLimit
            let items = readMenu(menu, depth: 1, inAppMenu: false, budget: &budget)
            let frame = Self.frame(of: menu) ?? .zero
            return OpenMenu(items: items, frame: frame)
        }
    }

    /// Chooses an item of the open menu by its titles (`["Duplicate"]`, or `["Share", "Mail"]` in a
    /// submenu). Throws `noOpenMenu` when no menu is open.
    public func performOpen(path: [String]) async throws {
        try await run { [self] in
            try checkTrust()
            guard let menu = findOpenMenu() else { throw MenuBridgeError.noOpenMenu }
            try press(path: path, in: menu, inAppMenu: false, fullPath: path)
        }
    }

    /// Closes the open menu without choosing anything (nothing happens when none is open).
    public func closeOpen() async throws {
        try await run { [self] in
            try checkTrust()
            guard let menu = findOpenMenu() else { return }
            AXUIElementSetMessagingTimeout(menu, Self.pressTimeout)
            let result = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            guard result == .success || result == .cannotComplete else {
                throw MenuBridgeError.axFailure(operation: "close the menu", code: result.rawValue)
            }
        }
    }

    /// Asks the element at a global point (or the nearest of its ancestors that can) to show its
    /// context menu (AXShowMenu). Returns false when nothing there has one. The menu opens a moment
    /// later; read it with `openMenu()`.
    @discardableResult
    public func showMenu(at point: CGPoint) async throws -> Bool {
        try await run { [self] in
            try checkTrust()
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return false }
            var element = hit
            for _ in 0..<12 {
                guard let current = element else { break }
                if actionNames(current).contains(kAXShowMenuAction) {
                    // Showing a menu runs the app's menu loop, which answers only when the menu closes.
                    AXUIElementSetMessagingTimeout(current, Self.pressTimeout)
                    let result = AXUIElementPerformAction(current, kAXShowMenuAction as CFString)
                    guard result == .success || result == .cannotComplete else {
                        throw MenuBridgeError.axFailure(operation: "show the menu", code: result.rawValue)
                    }
                    return true
                }
                element = copy(current, kAXParentAttribute).map { $0 as! AXUIElement }
            }
            return false
        }
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

    /// The attributes read per menu item, in one call.
    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
        kAXMenuItemCmdGlyphAttribute, kAXMenuItemMarkCharAttribute, kAXIdentifierAttribute, kAXChildrenAttribute,
    ]

    /// What one menu item says about itself.
    struct ItemAttributes: Sendable, Equatable {
        var role: String
        var title: String
        var enabled: Bool
        var shortcut: String?
        var checked: Bool
        var identifier: String?
        var hasCommandKey: Bool

        /// A separator line: no title, never enabled, no key equivalent.
        var isSeparator: Bool { title.isEmpty && !enabled && !hasCommandKey }
    }

    private func attributes(_ element: AXUIElement) -> (ItemAttributes, [AXUIElement])? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let raw = values as? [AnyObject], raw.count == Self.attributeNames.count else { return nil }
        let present = raw.map { Self.isPresent($0) ? $0 : nil }
        let char = present[3] as? String
        let modifiers = (present[4] as? NSNumber)?.intValue
        let glyph = (present[5] as? NSNumber)?.intValue
        let mark = present[6] as? String
        let attributes = ItemAttributes(
            role: present[0] as? String ?? "", title: present[1] as? String ?? "", enabled: (present[2] as? Bool) ?? true,
            shortcut: Self.shortcut(char: char, modifiers: modifiers, glyph: glyph), checked: !(mark ?? "").isEmpty,
            identifier: present[7] as? String, hasCommandKey: !(char ?? "").isEmpty || (glyph ?? 0) != 0)
        return (attributes, present[8] as? [AXUIElement] ?? [])
    }

    private struct TopMenu {
        var attributes: ItemAttributes
        var menu: AXUIElement?
        var isAppMenu: Bool
    }

    /// The bar's menus without the Apple menu (always the first); the app's own menu comes next.
    private func barItems() -> [TopMenu] {
        guard let bar = copy(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
              let tops = copy(bar, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return tops.enumerated().dropFirst().compactMap { index, element in
            guard let (attributes, children) = self.attributes(element) else { return nil }
            let menu = children.first { (copy($0, kAXRoleAttribute) as? String) == kAXMenuRole }
            return TopMenu(attributes: attributes, menu: menu, isAppMenu: index == 1)
        }
    }

    /// The items of a menu element as protocol items: blocked ones left out, separators tidied.
    private func readMenu(_ menu: AXUIElement, depth: Int, inAppMenu: Bool, budget: inout Int) -> [MirrorProtocol.MenuItem] {
        guard let children = copy(menu, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var items: [MirrorProtocol.MenuItem] = []
        for child in children {
            guard budget > 0 else { break }
            budget -= 1
            guard let (attributes, grandchildren) = self.attributes(child), attributes.role == kAXMenuItemRole else { continue }
            if attributes.isSeparator { items.append(.separatorItem); continue }
            guard !attributes.title.isEmpty else { continue } // a custom view (a search field), not something to choose
            let submenu = grandchildren.first { (copy($0, kAXRoleAttribute) as? String) == kAXMenuRole }
            let submenuIdentifiers = submenu.map(identifiers(in:)) ?? []
            if Self.isBlocked(attributes, inAppMenu: inAppMenu, submenuIdentifiers: submenuIdentifiers) { continue }
            var subitems: [MirrorProtocol.MenuItem] = []
            if let submenu {
                guard depth < Self.depthLimit else { continue }
                subitems = readMenu(submenu, depth: depth + 1, inAppMenu: inAppMenu, budget: &budget)
                if !Self.hasEnabledItem(subitems) { continue } // empty, or only blocked items and section headings were in it
            }
            items.append(MirrorProtocol.MenuItem(title: attributes.title, enabled: attributes.enabled, checked: attributes.checked,
                                                 shortcut: submenu == nil ? attributes.shortcut : nil, items: subitems))
        }
        return Self.tidySeparators(items)
    }

    private func identifiers(in menu: AXUIElement) -> [String] {
        ((copy(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(40).compactMap { copy($0, kAXIdentifierAttribute) as? String }
    }

    /// Walks `path` from `menu` down (each step an allowed item with that title) and presses the item.
    private func press(path: [String], in menu: AXUIElement, inAppMenu: Bool, fullPath: [String]) throws {
        guard !path.isEmpty else { throw MenuBridgeError.noSuchItem(fullPath) }
        var current = menu
        for (index, title) in path.enumerated() {
            let children = (copy(current, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            var found: (AXUIElement, ItemAttributes, AXUIElement?)?
            for child in children {
                guard let (attributes, grandchildren) = self.attributes(child), attributes.role == kAXMenuItemRole,
                      !attributes.isSeparator, attributes.title == title else { continue }
                let submenu = grandchildren.first { (copy($0, kAXRoleAttribute) as? String) == kAXMenuRole }
                guard !Self.isBlocked(attributes, inAppMenu: inAppMenu, submenuIdentifiers: submenu.map(identifiers(in:)) ?? []) else { continue }
                found = (child, attributes, submenu)
                break
            }
            guard let (item, attributes, submenu) = found else { throw MenuBridgeError.noSuchItem(fullPath) }
            if index < path.count - 1 {
                guard let submenu else { throw MenuBridgeError.noSuchItem(fullPath) }
                current = submenu
                continue
            }
            guard submenu == nil else { throw MenuBridgeError.noSuchItem(fullPath) } // a submenu isn't something to choose
            guard attributes.enabled else { throw MenuBridgeError.disabled(fullPath) }
            AXUIElementSetMessagingTimeout(item, Self.pressTimeout)
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            guard result == .success || result == .cannotComplete else {
                throw MenuBridgeError.axFailure(operation: "choose \(fullPath.joined(separator: " > "))", code: result.rawValue)
            }
            return
        }
    }

    /// The app's popped-up menu: its on-screen window at the pop-up menu level, hit-tested down to the
    /// AXMenu (a popped-up menu isn't among the app's accessibility children).
    private func findOpenMenu() -> AXUIElement? {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let frames = windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == Self.popUpMenuLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        var menus: [AXUIElement] = []
        for frame in frames {
            // A point on the first item, the middle and the last item: one of them is on an item, not a separator.
            for point in [CGPoint(x: frame.midX, y: frame.minY + 12), CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: frame.midX, y: frame.maxY - 12)] {
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { continue }
                var element = hit
                var found: AXUIElement?
                for _ in 0..<6 {
                    guard let current = element else { break }
                    if (copy(current, kAXRoleAttribute) as? String) == kAXMenuRole { found = current; break }
                    element = copy(current, kAXParentAttribute).map { $0 as! AXUIElement }
                }
                if let found {
                    menus.append(found)
                    break
                }
            }
        }
        // With a submenu open, the outermost menu: the one that isn't inside a menu item.
        return menus.first { menu in
            let parent = copy(menu, kAXParentAttribute).map { $0 as! AXUIElement }
            return parent.flatMap { copy($0, kAXRoleAttribute) as? String } != kAXMenuItemRole
        } ?? menus.first
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func isPresent(_ value: AnyObject) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return true }
        return AXValueGetType(value as! AXValue) != .axError
    }

    // MARK: - Pure rules (tested without Accessibility)

    /// Item identifiers (AppKit puts the action's selector there) of items that reach beyond the app or
    /// take its window away from the viewers.
    static let blockedIdentifiers: Set<String> = [
        "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:", "NSAlternateQuitMenuItem",
        "_NSMenuItemAutoFillIdentifier", "startDictation:", "orderFrontCharacterPalette:",
        "toggleFullScreen:", "performMiniaturize:", "miniaturizeAll:", "_removeWindowFromStageManagerSet:",
    ]
    /// Prefixes of blocked identifiers: AutoFill's items, window tiling.
    static let blockedIdentifierPrefixes = ["_handleInsertFrom", "_zoom"]
    /// Identifiers inside the Services submenu.
    static let servicesIdentifiers: Set<String> = ["_processRequest:", "_configureServicesMenu:"]
    /// Titles of the app menu's system items, for apps whose items carry no identifier.
    static let blockedAppMenuTitles: Set<String> = ["Services", "Show All", "Hide Others"]
    static let blockedAppMenuTitlePrefixes = ["Quit", "Hide "]
    static let blockedAppMenuShortcuts: Set<String> = ["⌘Q", "⌥⌘Q", "⌘H", "⌥⌘H"]
    /// The microphone and globe glyphs: Dictation and the character palette.
    static let blockedGlyphShortcuts: Set<String> = ["🎤", "🌐"]

    /// Whether an item is left out of what viewers see and can choose: items that act on the host's
    /// Mac or its other apps (Services, AutoFill, Dictation, the character palette) and items that
    /// would hide, quit, minimize, full-screen or tile the shared app.
    static func isBlocked(_ item: ItemAttributes, inAppMenu: Bool, submenuIdentifiers: [String] = []) -> Bool {
        if let id = item.identifier {
            if blockedIdentifiers.contains(id) || blockedIdentifierPrefixes.contains(where: id.hasPrefix) { return true }
        }
        if submenuIdentifiers.contains(where: servicesIdentifiers.contains) { return true }
        if submenuIdentifiers.contains(where: { $0.hasPrefix("_handleInsertFrom") }) { return true }
        if let shortcut = item.shortcut, blockedGlyphShortcuts.contains(shortcut) { return true }
        if inAppMenu {
            if blockedAppMenuTitles.contains(item.title) || blockedAppMenuTitlePrefixes.contains(where: item.title.hasPrefix) { return true }
            if let shortcut = item.shortcut, blockedAppMenuShortcuts.contains(shortcut) { return true }
        }
        return false
    }

    /// Whether anything in these items (or their submenus) can be chosen.
    static func hasEnabledItem(_ items: [MirrorProtocol.MenuItem]) -> Bool {
        items.contains { !$0.separator && ($0.items.isEmpty ? $0.enabled : hasEnabledItem($0.items)) }
    }

    /// Drops separators at the start and end and runs of them (left by blocked items).
    static func tidySeparators(_ items: [MirrorProtocol.MenuItem]) -> [MirrorProtocol.MenuItem] {
        var out: [MirrorProtocol.MenuItem] = []
        for item in items {
            if item.separator, out.last?.separator ?? true { continue }
            out.append(item)
        }
        while out.last?.separator == true { out.removeLast() }
        return out
    }

    /// AXMenuItemCmdModifiers bits. 0 alone means Command.
    static let shiftBit = 1, optionBit = 2, controlBit = 4, noCommandBit = 8, functionBit = 16

    /// A key equivalent as macOS shows it in menus: modifiers in the order fn ⌃ ⌥ ⇧ ⌘, then the key
    /// (letters in capitals, named keys as their symbols, `Space`, `F5`). Nil when the item has none.
    static func shortcut(char: String?, modifiers: Int?, glyph: Int?) -> String? {
        guard let key = keyName(char: char, glyph: glyph) else { return nil }
        let bits = modifiers ?? 0
        var text = ""
        if bits & functionBit != 0 { text += "fn" }
        if bits & controlBit != 0 { text += "⌃" }
        if bits & optionBit != 0 { text += "⌥" }
        if bits & shiftBit != 0 { text += "⇧" }
        if bits & noCommandBit == 0 { text += "⌘" }
        return text + key
    }

    /// Symbols for the menu glyph codes (kMenu…Glyph) that name keys.
    static let glyphNames: [Int: String] = [
        0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x0C: "↩", 0x0D: "↩", 0x17: "⌫", 0x1B: "⎋",
        0x1C: "⌧", 0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→", 0x66: "↖", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6", 0x75: "F7", 0x76: "F8", 0x77: "F9",
        0x78: "F10", 0x79: "F11", 0x7A: "F12", 0x87: "F13", 0x88: "F14", 0x89: "F15", 0x8C: "⏏", 0x95: "🌐", 0x96: "🎤",
    ]

    /// Symbols for characters that aren't printable as themselves.
    static func keyName(char: String?, glyph: Int?) -> String? {
        if let glyph, glyph != 0, let name = glyphNames[glyph] { return name }
        guard let char, let scalar = char.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x09: return "⇥"
        case 0x0D, 0x0A: return "↩"
        case 0x03: return "⌤"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return "Space"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71A: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return char.uppercased()
        }
    }
}

public enum MenuBridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No allowed item at this path (or it leads to a submenu, not an item).
    case noSuchItem([String])
    /// The item is there but switched off.
    case disabled([String])
    /// A context-menu action came while no menu was open.
    case noOpenMenu
    case axFailure(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .noSuchItem(let path): "No menu item \(path.joined(separator: " > "))"
        case .disabled(let path): "The menu item \(path.joined(separator: " > ")) is disabled"
        case .noOpenMenu: "No menu is open"
        case .axFailure(let operation, let code): "Couldn't \(operation) (AXError \(code))"
        }
    }
}

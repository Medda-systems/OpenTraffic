import ApplicationServices
import CoreGraphics
import Foundation

/// Pointer and keyboard input delivered to one process with `CGEvent.postToPid`, so a shared Mac app
/// kept off screen (or on another Space) gets a viewer's clicks, drags, scrolls and typing without
/// the host's cursor moving, the app being activated, or the host's frontmost app changing.
///
/// What it takes for AppKit to accept such events (found against the Orbit fixture, macOS 26/27):
/// - Mouse and wheel events need the target window's number in event field 51 (the window server's
///   own window-id field, which AppKit reads for `NSEvent.window`) and the window-relative location
///   set with `CGEventSetWindowLocation`. The public fields `mouseEventWindowUnderMousePointer…` are
///   ignored, and without both values AppKit gets a window-less event and drops it. The window does
///   not have to be key, on screen or on the active Space, and the app is never activated.
/// - Plain keys and text reach the app's focused element (a click on a field focuses it first).
/// - Key equivalents (⌘A, menu shortcuts) do not: AppKit only routes them through an active app's
///   key window. So `replaceText` selects the field's text through Accessibility
///   (`AXSelectedTextRange`) instead of ⌘A, and menu commands go through the AX menu bar.
/// - SwiftUI text fields ignore AXValue writes, which is why `setText` types instead of writing.
///
/// Posting needs Accessibility permission (`isPermitted`). Coordinates passed in are window-relative
/// points with a top-left origin, like the protocol's and AXSnapshot's nodes; `Window.frame` is the
/// window's current frame in global CG coordinates (top-left origin of the main display, as AX
/// reports AXPosition/AXSize). `Window(snapshot)` takes both from an AccessibilityTree snapshot.
public struct InputSynthesizer: Sendable {
    public let pid: pid_t

    public init(pid: pid_t) { self.pid = pid }

    /// The window an event is aimed at: its window-server id and current global frame in points.
    public struct Window: Equatable, Sendable {
        public var id: CGWindowID
        public var frame: CGRect
        public init(id: CGWindowID, frame: CGRect) { self.id = id; self.frame = frame }

        /// The window an accessibility snapshot was taken of; its nodes' frames are relative to it.
        /// Nil when the snapshot has no window number.
        public init?(_ snapshot: AXSnapshot) {
            guard let number = snapshot.windowNumber else { return nil }
            self.init(id: number, frame: snapshot.frame)
        }

        /// A window-relative point in global CG coordinates.
        public func global(_ point: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
        }
    }

    public enum Button: Sendable, Equatable { case left, right }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case eventUnavailable
        case fieldNotFocused

        public var description: String {
            switch self {
            case .eventUnavailable: "Couldn't create the input event."
            case .fieldNotFocused: "The text field didn't take focus after the click."
            }
        }
    }

    /// Posting events to another process needs Accessibility permission.
    public static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Characters per keyboard event in `type(text:)`; CGEvent carries at most 20 UTF-16 units.
    public static let textChunkLength = 20

    // MARK: Pointer

    public func move(to point: CGPoint, in window: Window, modifiers: [MirrorProtocol.Modifier] = []) throws {
        try postMouse(.mouseMoved, at: point, in: window, button: .left, clickCount: 0, modifiers: modifiers)
    }

    /// A button press. `clickCount` 2 on the second down/up pair makes a double click.
    public func mouseDown(at point: CGPoint, in window: Window, button: Button = .left, clickCount: Int = 1, modifiers: [MirrorProtocol.Modifier] = []) throws {
        try postMouse(button == .left ? .leftMouseDown : .rightMouseDown, at: point, in: window, button: button, clickCount: clickCount, modifiers: modifiers)
    }

    public func mouseUp(at point: CGPoint, in window: Window, button: Button = .left, clickCount: Int = 1, modifiers: [MirrorProtocol.Modifier] = []) throws {
        try postMouse(button == .left ? .leftMouseUp : .rightMouseUp, at: point, in: window, button: button, clickCount: clickCount, modifiers: modifiers)
    }

    /// A move to the point, then down/up; `count` 2 is a double click (two pairs, the second with click count 2).
    public func click(at point: CGPoint, in window: Window, button: Button = .left, count: Int = 1, modifiers: [MirrorProtocol.Modifier] = []) throws {
        try move(to: point, in: window, modifiers: modifiers)
        for clickCount in 1...max(1, count) {
            try mouseDown(at: point, in: window, button: button, clickCount: clickCount, modifiers: modifiers)
            try mouseUp(at: point, in: window, button: button, clickCount: clickCount, modifiers: modifiers)
        }
    }

    /// One dragged-pointer step while the left button is down (between `mouseDown` and `mouseUp`).
    public func dragged(to point: CGPoint, in window: Window, modifiers: [MirrorProtocol.Modifier] = []) throws {
        try postMouse(.leftMouseDragged, at: point, in: window, button: .left, clickCount: 1, modifiers: modifiers)
    }

    /// A whole left-button drag: down at `start`, `steps` dragged events along the line, up at `end`.
    public func drag(from start: CGPoint, to end: CGPoint, in window: Window, steps: Int = 8, modifiers: [MirrorProtocol.Modifier] = []) throws {
        try move(to: start, in: window, modifiers: modifiers)
        try mouseDown(at: start, in: window, modifiers: modifiers)
        let steps = max(1, steps)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            try dragged(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), in: window, modifiers: modifiers)
        }
        try mouseUp(at: end, in: window, modifiers: modifiers)
    }

    /// A wheel event at the point with pixel deltas in the browser's sense: positive `dy` scrolls
    /// down (content moves up), positive `dx` scrolls right. No scroll or momentum phase.
    public func scroll(at point: CGPoint, in window: Window, dx: Double = 0, dy: Double, modifiers: [MirrorProtocol.Modifier] = []) throws {
        let (vertical, horizontal) = Self.wheelDeltas(dx: dx, dy: dy)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            throw Failure.eventUnavailable
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        try post(event, at: point, in: window, modifiers: modifiers)
    }

    /// A protocol `pointer` message (window-relative points), as the mirror server receives it.
    public func send(_ pointer: MirrorProtocol.Pointer, in window: Window) throws {
        let point = CGPoint(x: pointer.x, y: pointer.y)
        switch pointer.kind {
        case .move: try move(to: point, in: window, modifiers: pointer.modifiers)
        case .down: try mouseDown(at: point, in: window, modifiers: pointer.modifiers)
        case .up: try mouseUp(at: point, in: window, modifiers: pointer.modifiers)
        case .rightdown: try mouseDown(at: point, in: window, button: .right, modifiers: pointer.modifiers)
        case .rightup: try mouseUp(at: point, in: window, button: .right, modifiers: pointer.modifiers)
        case .wheel: try scroll(at: point, in: window, dx: pointer.dx, dy: pointer.dy, modifiers: pointer.modifiers)
        }
    }

    // MARK: Keyboard

    /// Types Unicode text at the app's current focus, `textChunkLength` UTF-16 units per event
    /// (never splitting a surrogate pair).
    public func type(text: String) throws {
        for chunk in Self.chunks(of: text) {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { throw Failure.eventUnavailable }
                event.flags = []
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.postToPid(pid)
            }
        }
    }

    /// Presses one named key. Modifier combinations that are key equivalents (⌘…) don't reach an
    /// inactive app; see the type's documentation.
    public func press(key: MirrorProtocol.KeyCode, modifiers: [MirrorProtocol.Modifier] = []) throws {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: Self.virtualKey(for: key), keyDown: keyDown) else {
                throw Failure.eventUnavailable
            }
            event.flags = Self.flags(for: modifiers).union(Self.keyFlags(for: key))
            event.postToPid(pid)
        }
    }

    /// A protocol `key` message.
    public func send(_ key: MirrorProtocol.Key) throws { try press(key: key.code, modifiers: key.modifiers) }

    /// Presses one key by its virtual key code with these flags, leaving the characters to the key
    /// code (the system fills them in from the keyboard layout). The iOS Simulator's hardware keyboard
    /// reads the key code, not the characters, so text for it is typed key by key (`keystroke(for:)`).
    public func press(virtualKey: CGKeyCode, flags: CGEventFlags = []) throws {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown) else { throw Failure.eventUnavailable }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    /// The key (US ANSI layout) and whether Shift is held for a character a keyboard can type, nil for
    /// anything else (accented letters, emoji, other scripts).
    public static func keystroke(for character: Character) -> (key: CGKeyCode, shift: Bool)? {
        if let key = unshifted[character] { return (key, false) }
        if let key = shifted[character] { return (key, true) }
        if character.isLetter, character.isUppercase, let lower = character.lowercased().first, let key = unshifted[lower],
           lower.isASCII { return (key, true) }
        return nil
    }

    /// Carbon `kVK_ANSI_…` codes of the characters typed without Shift on a US keyboard.
    private static let unshifted: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31, "\n": 0x24, "\t": 0x30,
    ]

    /// The characters typed with Shift on a US keyboard, by the key they're on.
    private static let shifted: [Character: CGKeyCode] = [
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "%": 0x17, "^": 0x16, "&": 0x1A, "*": 0x1C, "(": 0x19, ")": 0x1D,
        "_": 0x1B, "+": 0x18, "{": 0x21, "}": 0x1E, "|": 0x2A, ":": 0x29, "\"": 0x27, "<": 0x2B, ">": 0x2F, "?": 0x2C, "~": 0x32,
    ]

    /// Replaces a text field's whole value: clicks the field (window-relative frame), waits until the
    /// app reports a focused element, selects all of its text through Accessibility, then types the
    /// new text. This is how the protocol's `setText` works: SwiftUI bindings ignore AXValue writes,
    /// and ⌘A doesn't reach an inactive app.
    public func replaceText(in window: Window, field: CGRect, with text: String, timeout: Duration = .seconds(1)) async throws {
        try click(at: CGPoint(x: field.midX, y: field.midY), in: window)
        let app = AXUIElementCreateApplication(pid)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let globalField = field.isEmpty ? nil : CGRect(origin: window.global(field.origin), size: field.size)
        var found = Self.focusedTextElement(of: app, within: globalField)
        while found == nil {
            guard clock.now < deadline else { throw Failure.fieldNotFocused }
            try await Task.sleep(for: .milliseconds(25))
            found = Self.focusedTextElement(of: app, within: globalField)
        }
        guard let focused = found else { throw Failure.fieldNotFocused }
        var length = 0
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXNumberOfCharactersAttribute as CFString, &value) == .success, let count = value as? Int {
            length = count
        } else if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value) == .success, let string = value as? String {
            length = string.utf16.count
        }
        var range = CFRange(location: 0, length: length)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }
        if text.isEmpty {
            if length > 0 { try press(key: .backspace) }
        } else {
            try type(text: text)
        }
    }

    // MARK: Pure helpers (tested without permissions)

    /// macOS virtual key codes (Carbon `kVK_…`) for the protocol's named keys.
    public static func virtualKey(for key: MirrorProtocol.KeyCode) -> CGKeyCode {
        switch key {
        case .enter: 0x24       // kVK_Return: the browser's Enter is the main Return key
        case .escape: 0x35
        case .tab: 0x30
        case .backspace: 0x33   // kVK_Delete
        case .delete: 0x75      // kVK_ForwardDelete
        case .arrowUp: 0x7E
        case .arrowDown: 0x7D
        case .arrowLeft: 0x7B
        case .arrowRight: 0x7C
        case .space: 0x31
        }
    }

    public static func flags(for modifiers: [MirrorProtocol.Modifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .cmd: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .alt: flags.insert(.maskAlternate)
            case .ctrl: flags.insert(.maskControl)
            }
        }
    }

    /// The flags a real keyboard adds to a key: arrows and forward delete are function keys, arrows
    /// also numeric-pad keys, as AppKit expects for NSUpArrowFunctionKey and friends.
    static func keyFlags(for key: MirrorProtocol.KeyCode) -> CGEventFlags {
        switch key {
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: [.maskSecondaryFn, .maskNumericPad]
        case .delete: .maskSecondaryFn
        default: []
        }
    }

    /// Browser-style deltas to CG wheel deltas (wheel1 vertical, wheel2 horizontal; positive scrolls
    /// toward the top/left), rounded to whole pixels.
    static func wheelDeltas(dx: Double, dy: Double) -> (vertical: Int32, horizontal: Int32) {
        func clamp(_ value: Double) -> Int32 { Int32(max(Double(Int32.min), min(Double(Int32.max), (-value).rounded()))) }
        return (clamp(dy), clamp(dx))
    }

    /// UTF-16 chunks of at most `textChunkLength` units that never split a surrogate pair.
    static func chunks(of text: String) -> [[UniChar]] {
        var result: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > textChunkLength {
                result.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Posting

    private func postMouse(_ type: CGEventType, at point: CGPoint, in window: Window, button: Button, clickCount: Int, modifiers: [MirrorProtocol.Modifier]) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: window.global(point), mouseButton: button == .left ? .left : .right) else {
            throw Failure.eventUnavailable
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        try post(event, at: point, in: window, modifiers: modifiers)
    }

    private func post(_ event: CGEvent, at point: CGPoint, in window: Window, modifiers: [MirrorProtocol.Modifier]) throws {
        event.location = window.global(point)
        event.flags = Self.flags(for: modifiers)
        event.setIntegerValueField(Self.windowNumberField, value: Int64(window.id))
        Self.setWindowLocation?(event, point)
        event.postToPid(pid)
    }

    /// The event field AppKit reads as the event's window number (`kCGSEventWindowIDField`, private).
    static let windowNumberField = CGEventField(rawValue: 51)!

    /// `CGEventSetWindowLocation` (exported by CoreGraphics, not in the headers): the location within
    /// the window, top-left origin, which the window server normally fills in while routing.
    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
    }()

    /// The app's focused element if it is a text input (inside `frame` when given).
    private static func focusedTextElement(of app: AXUIElement, within frame: CGRect?) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard let role = role as? String, ["AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSearchField"].contains(role) else { return nil }
        guard let frame, let elementFrame = Self.frame(of: element) else { return element }
        return frame.insetBy(dx: -2, dy: -2).intersects(elementFrame) ? element : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}

import AppKit
import CoreGraphics
import Foundation
import os

// An iPhone app in the iOS Simulator, shared like a Mac app. MacAppSession runs it (same server,
// same lifecycle, same viewer); this file is what differs:
//
// - The app is started with simctl (SimulatorLauncher): in your booted device (its real data) or in
//   OpenTraffic's own erased device (empty data).
// - The window viewers see is Simulator.app's window for that device, found by its title (the device's
//   name). Simulator.app is kept off screen with MacAppWindowHider when OpenTraffic opened it for the
//   share; a Simulator you already had open is captured where it is (moving your own Simulator windows
//   away, and getting them back, isn't worth surprising you), and you see what viewers do.
// - Its tree comes from Simulator.app's accessibility, which shows the simulated app's elements inside
//   the device window. Only the elements on the device's screen are sent (not the Simulator's toolbar).
// - Input goes to Simulator.app through InputSynthesizer: clicks become touches, moves with the button
//   down become finger moves, a run of wheel events becomes one finger drag, and text is typed key by
//   key (the Simulator's hardware keyboard reads key codes); what no key types is pasted through the
//   device's pasteboard.
// - The viewer gets `app.device` in `hello`: the device's name and where its screen is in the window,
//   and shows just the screen in a phone frame.

// MARK: - The device's screen

/// A device type's screen, from its `capabilities.plist` (inside the `.simdevicetype` bundle).
public struct SimulatorScreen: Sendable, Equatable {
    /// The screen's size in points (pixels over scale).
    public var points: CGSize
    public var scale: Double
    /// The screen's corner radius in points (0 for square screens).
    public var cornerRadius: Double

    public init(points: CGSize, scale: Double, cornerRadius: Double) {
        self.points = points; self.scale = scale; self.cornerRadius = cornerRadius
    }

    /// Where device types are installed: CoreSimulator's profiles (Xcode 15 and later), then inside Xcode.
    public static var deviceTypeFolders: [URL] {
        var folders = [URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes", isDirectory: true)]
        let xcode = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        folders.append(URL(fileURLWithPath: xcode).appendingPathComponent("Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes"))
        return folders
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [String: SimulatorScreen?]())

    /// The screen of the device type with this identifier (`com.apple.CoreSimulator.SimDeviceType.iPhone-17`),
    /// read from the first `.simdevicetype` in `folders` whose bundle identifier it is.
    public static func load(deviceType: String, folders: [URL] = deviceTypeFolders) -> SimulatorScreen? {
        let key = deviceType + "|" + folders.map(\.path).joined(separator: ":")
        if let cached = cache.withLock({ $0[key] }) { return cached }
        var found: SimulatorScreen?
        search: for folder in folders {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "simdevicetype" {
                let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
                guard info?["CFBundleIdentifier"] as? String == deviceType else { continue }
                if let capabilities = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Resources/capabilities.plist")) as? [String: Any] {
                    found = parse(capabilities: capabilities)
                }
                break search
            }
        }
        let result = found
        cache.withLock { $0[key] = result }
        return result
    }

    /// `capabilities.ScreenDimensionsCapability` (`main-screen-width`/`-height` in pixels, `main-screen-scale`),
    /// else the `primary` entry of `capabilities.displays`; the corner radius from `DeviceCornerRadius`.
    static func parse(capabilities plist: [String: Any]) -> SimulatorScreen? {
        let capabilities = plist["capabilities"] as? [String: Any] ?? plist
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        var width: Double?, height: Double?, scale: Double?, radius = number(capabilities["DeviceCornerRadius"])
        if let dimensions = capabilities["ScreenDimensionsCapability"] as? [String: Any] {
            width = number(dimensions["main-screen-width"])
            height = number(dimensions["main-screen-height"])
            scale = number(dimensions["main-screen-scale"])
        }
        if width == nil || height == nil || scale == nil,
           let displays = capabilities["displays"] as? [[String: Any]],
           let primary = displays.first(where: { $0["deviceName"] as? String == "primary" }) ?? displays.first {
            width = number(primary["width"]); height = number(primary["height"]); scale = number(primary["scale"])
            radius = radius ?? number(primary["cornerRadiusUL"])
        }
        guard let width, let height, let scale, width > 0, height > 0, scale > 0 else { return nil }
        return SimulatorScreen(points: CGSize(width: width / scale, height: height / scale), scale: scale, cornerRadius: radius ?? 0)
    }
}

// MARK: - Finding the device's window

public enum SimulatorWindows {
    /// Whether a Simulator window's title is this device's: the name itself ("iPhone 17"), or the name
    /// followed by the OS ("iPhone 17 – iOS 26.0", older Simulators). "iPhone 17 Pro" isn't "iPhone 17".
    public static func title(_ title: String, isDevice name: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, title.hasPrefix(name) else { return false }
        let rest = title.dropFirst(name.count)
        if rest.isEmpty { return true }
        return [" – ", " - ", " — ", " ("].contains { rest.hasPrefix($0) }
    }

    /// The Simulator's window for the device named `name`: the one titled exactly so, else one titled
    /// with the name and its OS. Minimized windows and ones without a window number don't count.
    public static func deviceWindow(_ windows: [AccessibilityTree.Window], device name: String) -> AccessibilityTree.Window? {
        let candidates = windows.filter { $0.number != nil && !$0.isMinimized && (($0.role.isEmpty) || $0.role == "AXWindow") }
        let trimmed = { (window: AccessibilityTree.Window) in window.title.trimmingCharacters(in: .whitespaces) }
        return candidates.first { trimmed($0) == name } ?? candidates.first { title($0.title, isDevice: name) }
    }
}

// MARK: - Where the screen is in the window

/// Where the device's screen is in the Simulator's device window, and the way between device points
/// and window points (the Simulator may show the device at any size).
public struct SimulatorScreenMapping: Sendable, Equatable {
    /// The screen in the window, in window points (top-left origin).
    public var rect: CGRect
    /// The screen's size in device points.
    public var points: CGSize

    public init(rect: CGRect, points: CGSize) { self.rect = rect; self.points = points }

    /// Window points per device point.
    public var factor: Double { points.width > 0 ? rect.width / points.width : 1 }

    /// A point on the device's screen (device points) in the window.
    public func window(_ device: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + device.x * factor, y: rect.minY + device.y * factor)
    }

    /// A point in the window in device points (outside the screen too).
    public func device(_ window: CGPoint) -> CGPoint {
        let factor = factor > 0 ? factor : 1
        return CGPoint(x: (window.x - rect.minX) / factor, y: (window.y - rect.minY) / factor)
    }

    /// The window point moved onto the screen (1 point in from its edges).
    public func clamp(_ point: CGPoint) -> CGPoint {
        let inner = rect.insetBy(dx: min(1, rect.width / 2), dy: min(1, rect.height / 2))
        return CGPoint(x: min(max(point.x, inner.minX), inner.maxX), y: min(max(point.y, inner.minY), inner.maxY))
    }

    /// Whether a node's centre is on the screen.
    public func shows(_ node: MirrorProtocol.AXNode) -> Bool {
        rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: node.x + node.w / 2, y: node.y + node.h / 2))
    }

    /// The screen in a window `window` big, from its elements (`nodes`, window points):
    /// 1. the largest element with the screen's proportions (the simulated app's own element, or the
    ///    Simulator's screen view), at least 80 points wide, within 3 %;
    /// 2. else, when the window is the screen plus a title bar (the Simulator without device bezels),
    ///    the part under the title bar;
    /// 3. else nothing: the viewer then shows the whole window.
    public static func locate(nodes: [MirrorProtocol.AXNode], window: CGSize, screen: SimulatorScreen?) -> SimulatorScreenMapping? {
        guard let screen, screen.points.width > 0, screen.points.height > 0, window.width > 0, window.height > 0 else { return nil }
        let aspect = screen.points.width / screen.points.height
        let bounds = CGRect(origin: .zero, size: window).insetBy(dx: -1, dy: -1)
        let match = nodes
            .filter { $0.depth > 0 && $0.w >= 80 && $0.h >= 80 && abs($0.w / $0.h - aspect) / aspect <= 0.03 }
            .filter { bounds.contains(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }
            .max { $0.w * $0.h < $1.w * $1.h }
        if let match {
            return SimulatorScreenMapping(rect: CGRect(x: match.x, y: match.y, width: match.w, height: match.h), points: screen.points)
        }
        let height = window.width / aspect
        let titleBar = window.height - height
        if titleBar >= 0, titleBar <= 100 {
            return SimulatorScreenMapping(rect: CGRect(x: 0, y: titleBar, width: window.width, height: height), points: screen.points)
        }
        return nil
    }

    /// What the viewer is told about the device.
    public func device(named name: String, cornerRadius: Double) -> MirrorProtocol.Device {
        MirrorProtocol.Device(name: name, screen: .init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height, radius: cornerRadius * factor))
    }
}

// MARK: - Accessibility: the device's window and its screen

/// Simulator.app's accessibility, narrowed to one device's window: `windows()` lists only it (as the
/// main, focused window), snapshots keep only the elements on the device's screen (the simulated
/// app's), and the window is never resized or closed. A press the bridge refuses becomes a tap at the
/// element's centre.
final class SimulatorAccessibility: MirrorAccessibility, @unchecked Sendable {
    let inner: any MirrorAccessibility
    let deviceName: String
    let screen: SimulatorScreen?
    /// Taps a window point (`tap(window number, window frame, point)`), for presses the bridge refuses.
    let tap: @Sendable (UInt32, CGRect, CGPoint) throws -> Void

    private struct State {
        var mappings: [UInt32: SimulatorScreenMapping] = [:]
        var windowNumber: UInt32?
        var last: [UInt32: AXSnapshot] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(inner: any MirrorAccessibility, deviceName: String, screen: SimulatorScreen?,
         tap: @escaping @Sendable (UInt32, CGRect, CGPoint) throws -> Void) {
        self.inner = inner; self.deviceName = deviceName; self.screen = screen; self.tap = tap
    }

    /// Where the screen is in the device window, once a snapshot of it was read.
    func mapping(window: UInt32) -> SimulatorScreenMapping? { state.withLock { $0.mappings[window] } }

    /// The device's window as the Simulator has it now.
    func deviceWindow() async throws -> AccessibilityTree.Window? {
        let found = SimulatorWindows.deviceWindow(try await inner.windows(), device: deviceName)
        state.withLock { $0.windowNumber = found?.number }
        return found
    }

    func windows() async throws -> [AccessibilityTree.Window] {
        guard var window = try await deviceWindow() else { return [] }
        window.isMain = true
        window.isFocused = true
        return [window]
    }

    func snapshot(window selector: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        let number: UInt32
        switch selector {
        case .number(let id): number = id
        default:
            guard let id = try await deviceWindow()?.number else { throw AccessibilityTreeError.noWindow }
            number = id
        }
        let raw = try await inner.snapshot(window: .number(number))
        let mapping = SimulatorScreenMapping.locate(nodes: raw.nodes, window: raw.frame.size, screen: screen)
            ?? state.withLock { $0.mappings[number] }
        let snapshot = Self.screenOnly(raw, mapping: mapping)
        state.withLock { state in
            if let mapping { state.mappings[number] = mapping }
            state.last[number] = snapshot
        }
        return snapshot
    }

    /// The window and the elements on the screen; the Simulator's own sheets and popovers aren't the app's.
    static func screenOnly(_ snapshot: AXSnapshot, mapping: SimulatorScreenMapping?) -> AXSnapshot {
        let nodes = mapping.map { mapping in snapshot.nodes.filter { $0.depth == 0 || mapping.shows($0) } } ?? snapshot.nodes
        return AXSnapshot(windowNumber: snapshot.windowNumber, title: snapshot.title, frame: snapshot.frame, nodes: nodes)
    }

    func perform(key: String, action: MirrorProtocol.Action, window: UInt32?) async throws {
        do {
            try await inner.perform(key: key, action: action, window: window)
        } catch {
            // The bridge may not press a simulated element; a tap at its centre does what a finger would.
            guard action == .press,
                  let number = window ?? state.withLock({ $0.windowNumber }),
                  let snapshot = state.withLock({ $0.last[number] }),
                  let node = snapshot.node(key), node.depth > 0, node.w > 0, node.h > 0 else { throw error }
            try tap(number, snapshot.frame, CGPoint(x: node.x + node.w / 2, y: node.y + node.h / 2))
        }
    }

    func changes() -> AsyncStream<AXChange> { inner.changes() }

    /// Makes the device's window the Simulator's key window, so typing goes to this device.
    func raise(window: UInt32) async throws { try await inner.raise(window: window) }
    /// The device's window stays open.
    func close(window: UInt32) async throws {}
    /// The Simulator's window keeps its size (resizing it scales the device).
    func resize(window: UInt32, to size: CGSize) async throws -> CGSize? { nil }
}

// MARK: - Input: touches, drags and keys

/// What the simulator's input needs from the synthesizer beyond the mirror's input.
public protocol SimulatorInputDevice: MirrorInput {
    func dragged(to point: CGPoint, in window: InputSynthesizer.Window, modifiers: [MirrorProtocol.Modifier]) throws
    func press(virtualKey: CGKeyCode, flags: CGEventFlags) throws
}

extension InputSynthesizer: SimulatorInputDevice {}

/// A run of wheel events as one finger drag: down where the wheel started, moved by the scrolled
/// distance (scrolling down moves the finger up), up once the wheel has been still a moment. The finger
/// stays on the screen; at its edge it lifts and starts again where the run began.
struct SimulatorScrollGesture: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        case down(CGPoint)
        case drag(CGPoint)
        case up(CGPoint)
    }

    private(set) var window: CGWindowID?
    private(set) var start: CGPoint = .zero
    private(set) var finger: CGPoint = .zero

    var isActive: Bool { window != nil }

    /// The steps for one wheel event at `point` (window points) in `window`; `screen` keeps the finger on the device.
    mutating func wheel(at point: CGPoint, dx: Double, dy: Double, window id: CGWindowID, screen: SimulatorScreenMapping?) -> [Step] {
        var steps: [Step] = []
        if window != id {
            steps += end()
            window = id
            start = screen?.clamp(point) ?? point
            finger = start
            steps.append(.down(start))
        }
        let wanted = CGPoint(x: finger.x - dx, y: finger.y - dy)
        let clamped = screen?.clamp(wanted) ?? wanted
        if clamped == wanted {
            finger = wanted
            steps.append(.drag(finger))
        } else {
            // At the edge: lift there and put the finger down where the run began.
            steps += [.drag(clamped), .up(clamped), .down(start)]
            finger = start
        }
        return steps
    }

    /// Lifts the finger, if it is down.
    mutating func end() -> [Step] {
        guard window != nil else { return [] }
        window = nil
        return [.up(finger)]
    }
}

/// Input for a simulated device through Simulator.app: viewer pointers become touches (a move with the
/// button down is a finger move, right clicks are ignored: iOS has none), wheel runs become drags, text
/// is typed key by key on a US layout, and what no key types is pasted (Cmd-V after putting it on the
/// device's pasteboard).
final class SimulatorInput: MirrorInput, @unchecked Sendable {
    let inner: any SimulatorInputDevice
    /// The screen in a window, from the accessibility snapshots.
    let mapping: @Sendable (CGWindowID) -> SimulatorScreenMapping?
    /// Puts text on the device's pasteboard (`simctl pbcopy`).
    let paste: @Sendable (String) throws -> Void
    /// How long the wheel is still before the finger lifts.
    let scrollEnd: Duration
    /// How long a tapped field gets to take focus before its text is selected (`replaceText`).
    let focusDelay: Duration

    private struct State {
        var gesture = SimulatorScrollGesture()
        var gestureWindow: InputSynthesizer.Window?
        /// Bumped by every wheel event: a pending lift for an older one does nothing.
        var wheelCount = 0
        var buttonDown = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timers = DispatchQueue(label: "se.medda.opentraffic.simulator-scroll")

    /// `kVK_ANSI_A` and `kVK_ANSI_V`, for select all and paste.
    static let keyA: CGKeyCode = 0x00
    static let keyV: CGKeyCode = 0x09

    init(inner: any SimulatorInputDevice, mapping: @escaping @Sendable (CGWindowID) -> SimulatorScreenMapping?,
         paste: @escaping @Sendable (String) throws -> Void, scrollEnd: Duration = .milliseconds(120), focusDelay: Duration = .milliseconds(250)) {
        self.inner = inner; self.mapping = mapping; self.paste = paste; self.scrollEnd = scrollEnd; self.focusDelay = focusDelay
    }

    func send(_ pointer: MirrorProtocol.Pointer, in window: InputSynthesizer.Window) throws {
        if pointer.kind == .wheel { return try wheel(pointer, in: window) }
        try endScroll()
        let point = CGPoint(x: pointer.x, y: pointer.y)
        switch pointer.kind {
        case .rightdown, .rightup, .wheel:
            return
        case .down:
            state.withLock { $0.buttonDown = true }
            try inner.send(pointer, in: window)
        case .up:
            state.withLock { $0.buttonDown = false }
            try inner.send(pointer, in: window)
        case .move:
            if state.withLock({ $0.buttonDown }) {
                try inner.dragged(to: point, in: window, modifiers: pointer.modifiers)
            } else {
                try inner.send(pointer, in: window)
            }
        }
    }

    private func wheel(_ pointer: MirrorProtocol.Pointer, in window: InputSynthesizer.Window) throws {
        let screen = mapping(window.id)
        let (lift, steps, count) = state.withLock { state -> (([SimulatorScrollGesture.Step], InputSynthesizer.Window)?, [SimulatorScrollGesture.Step], Int) in
            // A run in another window: the finger lifts in the first one.
            var lift: ([SimulatorScrollGesture.Step], InputSynthesizer.Window)?
            if let previous = state.gestureWindow, previous != window { lift = (state.gesture.end(), previous) }
            state.gestureWindow = window
            let steps = state.gesture.wheel(at: CGPoint(x: pointer.x, y: pointer.y), dx: pointer.dx, dy: pointer.dy, window: window.id, screen: screen)
            state.wheelCount += 1
            return (lift, steps, state.wheelCount)
        }
        if let lift { try post(lift.0, in: lift.1) }
        try post(steps, in: window)
        let delay = Double(scrollEnd.components.seconds) + Double(scrollEnd.components.attoseconds) / 1e18
        timers.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let ending = self.state.withLock { state -> ([SimulatorScrollGesture.Step], InputSynthesizer.Window?)? in
                guard state.wheelCount == count else { return nil }
                return (state.gesture.end(), state.gestureWindow)
            }
            if let (steps, window) = ending, let window { try? self.post(steps, in: window) }
        }
    }

    /// Lifts a finger left down by a wheel run (before any other input).
    private func endScroll() throws {
        let ending = state.withLock { state -> ([SimulatorScrollGesture.Step], InputSynthesizer.Window?) in
            state.wheelCount += 1
            return (state.gesture.end(), state.gestureWindow)
        }
        if let window = ending.1, !ending.0.isEmpty { try post(ending.0, in: window) }
    }

    private func post(_ steps: [SimulatorScrollGesture.Step], in window: InputSynthesizer.Window) throws {
        for step in steps {
            switch step {
            case .down(let point): try inner.send(.init(window: window.id, kind: .down, x: point.x, y: point.y), in: window)
            case .drag(let point): try inner.dragged(to: point, in: window, modifiers: [])
            case .up(let point): try inner.send(.init(window: window.id, kind: .up, x: point.x, y: point.y), in: window)
            }
        }
    }

    func type(text: String) throws {
        try endScroll()
        var unkeyed = ""
        func flush() throws {
            guard !unkeyed.isEmpty else { return }
            try paste(unkeyed)
            try inner.press(virtualKey: Self.keyV, flags: .maskCommand)
            unkeyed = ""
        }
        for character in text {
            if let stroke = InputSynthesizer.keystroke(for: character) {
                try flush()
                try inner.press(virtualKey: stroke.key, flags: stroke.shift ? .maskShift : [])
            } else {
                unkeyed.append(character)
            }
        }
        try flush()
    }

    func send(_ key: MirrorProtocol.Key) throws {
        try endScroll()
        try inner.send(key)
    }

    /// Taps the field, selects its text (Cmd-A, which iOS takes from a hardware keyboard) and types the
    /// new text over it (Backspace for none).
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {
        try endScroll()
        let center = CGPoint(x: field.midX, y: field.midY)
        try inner.send(.init(window: window.id, kind: .down, x: center.x, y: center.y), in: window)
        try inner.send(.init(window: window.id, kind: .up, x: center.x, y: center.y), in: window)
        try await Task.sleep(for: min(focusDelay, timeout))
        try inner.press(virtualKey: Self.keyA, flags: .maskCommand)
        if text.isEmpty {
            try inner.send(MirrorProtocol.Key(window: window.id, code: .backspace))
        } else {
            try type(text: text)
        }
    }
}

// MARK: - The outside world

/// What a simulator share does outside OpenTraffic: simctl, Simulator.app, the bridges. `live` in the
/// product; tests pass stubs.
public struct SimulatorEnvironment: Sendable {
    /// Starts the app (`SimulatorLauncher.launch`), its output appended to the file.
    public var launch: @Sendable (MacApp, MacAppSession.DataSource, URL?) async throws -> SimulatorLaunch
    /// Starts the app again in the same device (`simctl launch --terminate-running-process`).
    public var relaunch: @Sendable (SimulatorLaunch, URL?) async throws -> SimulatorLaunch
    /// Quits the app (`simctl terminate`).
    public var terminate: @Sendable (SimulatorLaunch) async -> Void
    /// Quits the app and shuts OpenTraffic's own device down (`SimulatorLauncher.stop`).
    public var stop: @Sendable (SimulatorLaunch) async -> Void
    /// Sets a device's appearance (`simctl ui <udid> appearance`).
    public var setAppearance: @Sendable (SimulatorDevice, MirrorProtocol.Appearance) async -> Void
    /// A device's appearance now, nil when simctl doesn't say.
    public var appearance: @Sendable (SimulatorDevice) async -> MirrorProtocol.Appearance?
    /// Simulator.app's process, when it runs.
    public var runningSimulator: @Sendable () -> pid_t?
    /// Opens Simulator.app hidden, kept off screen by the hider, showing this device; its pid.
    public var openSimulator: @Sendable @MainActor (MacAppWindowHider, SimulatorDevice, Duration) async throws -> pid_t
    /// Quits the Simulator.app OpenTraffic opened.
    public var quitSimulator: @Sendable @MainActor (MacAppWindowHider, pid_t) async -> Void
    /// The bridges for Simulator.app's process.
    public var accessibility: @Sendable (pid_t) throws -> any MirrorAccessibility
    public var input: @Sendable (pid_t) -> any SimulatorInputDevice
    public var capture: @Sendable (CGWindowID) -> any MirrorCapture
    /// Puts text on a device's pasteboard (`simctl pbcopy`).
    public var paste: @Sendable (SimulatorDevice, String) throws -> Void
    /// The device type's screen.
    public var screen: @Sendable (SimulatorDevice) -> SimulatorScreen?
    /// Accessibility and Screen Recording (throws `MacAppSessionError.permission`).
    public var checkPermissions: @Sendable () throws -> Void
    /// How long the device's window may take to show after the app started.
    public var windowTimeout: Duration

    public init(launch: @escaping @Sendable (MacApp, MacAppSession.DataSource, URL?) async throws -> SimulatorLaunch,
                relaunch: @escaping @Sendable (SimulatorLaunch, URL?) async throws -> SimulatorLaunch,
                terminate: @escaping @Sendable (SimulatorLaunch) async -> Void,
                stop: @escaping @Sendable (SimulatorLaunch) async -> Void,
                setAppearance: @escaping @Sendable (SimulatorDevice, MirrorProtocol.Appearance) async -> Void,
                appearance: @escaping @Sendable (SimulatorDevice) async -> MirrorProtocol.Appearance?,
                runningSimulator: @escaping @Sendable () -> pid_t?,
                openSimulator: @escaping @Sendable @MainActor (MacAppWindowHider, SimulatorDevice, Duration) async throws -> pid_t,
                quitSimulator: @escaping @Sendable @MainActor (MacAppWindowHider, pid_t) async -> Void,
                accessibility: @escaping @Sendable (pid_t) throws -> any MirrorAccessibility,
                input: @escaping @Sendable (pid_t) -> any SimulatorInputDevice,
                capture: @escaping @Sendable (CGWindowID) -> any MirrorCapture,
                paste: @escaping @Sendable (SimulatorDevice, String) throws -> Void,
                screen: @escaping @Sendable (SimulatorDevice) -> SimulatorScreen?,
                checkPermissions: @escaping @Sendable () throws -> Void,
                windowTimeout: Duration = .seconds(60)) {
        self.launch = launch; self.relaunch = relaunch; self.terminate = terminate; self.stop = stop
        self.setAppearance = setAppearance; self.appearance = appearance; self.runningSimulator = runningSimulator
        self.openSimulator = openSimulator; self.quitSimulator = quitSimulator; self.accessibility = accessibility
        self.input = input; self.capture = capture; self.paste = paste; self.screen = screen
        self.checkPermissions = checkPermissions; self.windowTimeout = windowTimeout
    }

    /// simctl, Simulator.app, AccessibilityTree, InputSynthesizer and WindowCapture.
    public static func live(simctl: Simctl = Simctl()) -> SimulatorEnvironment {
        SimulatorEnvironment(
            launch: { app, data, output in
                try await Task.detached { try SimulatorLauncher.launch(app, data: data, simctl: simctl, output: output) }.value
            },
            relaunch: { launch, output in
                try await Task.detached { try SimulatorLauncher.relaunch(launch, simctl: simctl, output: output) }.value
            },
            terminate: { launch in
                await Task.detached { _ = try? simctl.run(["terminate", launch.device.udid, launch.bundleIdentifier], timeout: 30) }.value
            },
            stop: { launch in await Task.detached { SimulatorLauncher.stop(launch, simctl: simctl) }.value },
            setAppearance: { device, appearance in
                await Task.detached { _ = try? simctl.run(["ui", device.udid, "appearance", appearance.rawValue], timeout: 30) }.value
            },
            appearance: { device in
                await Task.detached { () -> MirrorProtocol.Appearance? in
                    let said = (try? simctl.run(["ui", device.udid, "appearance"], timeout: 30))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return said.flatMap(MirrorProtocol.Appearance.init(rawValue:))
                }.value
            },
            runningSimulator: { SimulatorDiscovery.simulatorAppPID() },
            openSimulator: { hider, device, timeout in
                guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SimulatorDiscovery.simulatorAppIdentifier) else {
                    throw MacAppSessionError.failed("The Simulator app wasn't found. Install Xcode, then try again.")
                }
                let running = try await hider.launch(bundle: bundle, arguments: ["-CurrentDeviceUDID", device.udid], windowTimeout: timeout)
                return running.processIdentifier
            },
            quitSimulator: { hider, pid in await hider.release(pid: pid, terminate: true) },
            accessibility: { pid in try AccessibilityTree(pid: pid) },
            input: { pid in InputSynthesizer(pid: pid) },
            capture: { WindowCapture(windowID: $0) },
            paste: { device, text in try simctl.run(["pbcopy", device.udid], timeout: 10, input: Data(text.utf8)) },
            screen: { device in device.deviceTypeIdentifier.flatMap { SimulatorScreen.load(deviceType: $0) } },
            checkPermissions: { try MacAppSession.checkPermissions() }
        )
    }
}

extension SimulatorLauncher {
    /// Starts the app again in the device it runs in (same data).
    public static func relaunch(_ launch: SimulatorLaunch, simctl: Simctl = Simctl(), output: URL? = nil) throws -> SimulatorLaunch {
        let printed = try simctl.run(["launch", "--terminate-running-process"] + outputArguments(output) + [launch.device.udid, launch.bundleIdentifier], timeout: 60)
        var again = launch
        again.pid = launchedPID(printed)
        return again
    }
}

// MARK: - The session's simulator side

/// The simulator side of a MacAppSession whose app is an iPhone app: starts and stops it with simctl,
/// makes sure Simulator.app shows its device, and makes the mirror's bridges for the device's window.
@MainActor
final class SimulatorSession {
    let app: MacApp
    let data: MacAppSession.DataSource
    let environment: SimulatorEnvironment
    let hider: MacAppWindowHider

    /// The app's launch: its device and process.
    private(set) var launch: SimulatorLaunch?
    /// Simulator.app's process, once the device's window was found.
    private(set) var simulatorPID: pid_t?
    /// Whether OpenTraffic opened Simulator.app for this share (it is then hidden, and quit at the end).
    private(set) var openedSimulator = false

    init(app: MacApp, data: MacAppSession.DataSource, environment: SimulatorEnvironment, hider: MacAppWindowHider) {
        self.app = app; self.data = data; self.environment = environment; self.hider = hider
    }

    /// The app runs on the simulator's real data: nothing can reset it, and its appearance stays the device's.
    var usesRealData: Bool { launch?.usesRealData ?? (data == .copy) }

    struct Launched {
        var pid: pid_t
        var app: MirrorServer.App
        /// The appearance the device shows.
        var appearance: MirrorProtocol.Appearance
        var openedSimulator: Bool
    }

    /// Starts the app (`fresh`: from scratch, erasing OpenTraffic's own device; else again in the device
    /// it runs in), shows its device in Simulator.app and returns the bridges for the device's window.
    func start(fresh: Bool, appearance wanted: MirrorProtocol.Appearance, output: URL?, boot: String) async throws -> Launched {
        try environment.checkPermissions()
        let launch: SimulatorLaunch
        if let previous = self.launch, !fresh {
            launch = try await environment.relaunch(previous, output)
        } else {
            launch = try await environment.launch(app, data, output)
        }
        self.launch = launch
        guard let pid = launch.pid else {
            throw MacAppSessionError.failed("simctl started \(app.name) but didn't say which process it is.")
        }
        var appearance = wanted
        if launch.usesRealData {
            // Your own simulator keeps its own appearance.
            appearance = await environment.appearance(launch.device) ?? wanted
        } else {
            await environment.setAppearance(launch.device, wanted)
        }
        let simulator = try await showDevice(launch.device)
        let accessibility = try environment.accessibility(simulator)
        let input = environment.input(simulator)
        let screen = environment.screen(launch.device)
        let narrowed = SimulatorAccessibility(inner: accessibility, deviceName: launch.device.name, screen: screen) { number, frame, point in
            let target = InputSynthesizer.Window(id: number, frame: frame)
            try input.send(.init(window: number, kind: .down, x: point.x, y: point.y), in: target)
            try input.send(.init(window: number, kind: .up, x: point.x, y: point.y), in: target)
        }
        let window = try await waitForWindow(narrowed, device: launch.device)
        // The first read finds the screen in the window, for the viewer's phone frame.
        _ = try? await narrowed.snapshot(window: .number(window))
        let device = narrowed.mapping(window: window).map { $0.device(named: launch.device.name, cornerRadius: screen?.cornerRadius ?? 0) }
            ?? MirrorProtocol.Device(name: launch.device.name)
        let simulatorInput = SimulatorInput(inner: input, mapping: { narrowed.mapping(window: $0) },
                                            paste: { [environment] text in try environment.paste(launch.device, text) })
        let mirrored = MirrorServer.App(name: app.name, boot: boot, accessibility: narrowed, input: simulatorInput, menus: nil, device: device,
                                        makeCapture: environment.capture)
        return Launched(pid: pid, app: mirrored, appearance: appearance, openedSimulator: openedSimulator)
    }

    /// Simulator.app's process with a window for `device`: the running one (its windows stay where they
    /// are), else one OpenTraffic opens hidden and keeps off screen.
    private func showDevice(_ device: SimulatorDevice) async throws -> pid_t {
        if let pid = simulatorPID, MacAppSession.isAlive(pid) { return pid }
        if let running = environment.runningSimulator() {
            simulatorPID = running
            openedSimulator = false
            return running
        }
        let pid = try await environment.openSimulator(hider, device, environment.windowTimeout)
        simulatorPID = pid
        openedSimulator = true
        return pid
    }

    /// Waits for the Simulator's window of `device` (it shows once the device has booted).
    private func waitForWindow(_ accessibility: SimulatorAccessibility, device: SimulatorDevice) async throws -> UInt32 {
        let deadline = ContinuousClock.now + environment.windowTimeout
        while true {
            if let number = try? await accessibility.deviceWindow()?.number { return number }
            guard ContinuousClock.now < deadline else {
                throw MacAppSessionError.failed("The Simulator didn't show \(device.name) within \(environment.windowTimeout.components.seconds) seconds. Open it in the Simulator (File > Open Simulator > \(device.name)), then try again.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Quits the app (the device keeps running).
    func terminate() async {
        guard let launch else { return }
        await environment.terminate(launch)
    }

    /// Quits the app, shuts OpenTraffic's own device down, and quits Simulator.app if OpenTraffic opened it.
    func stop() async {
        if let launch { await environment.stop(launch) }
        launch = nil
        if openedSimulator, let pid = simulatorPID { await environment.quitSimulator(hider, pid) }
        simulatorPID = nil
        openedSimulator = false
    }
}

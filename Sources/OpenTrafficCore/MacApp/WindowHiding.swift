import AppKit
import ApplicationServices
import CoreGraphics
import os

// Keeping a shared Mac app's windows away from the user while ScreenCaptureKit can still capture
// them. Hidden, minimized and fully off-screen windows are ordered out, and ordered-out windows
// can't be captured; AppKit pulls a window that is fully off every screen back on screen when its
// app unhides. So the windows go to a screen nobody looks at: a virtual display (CoreGraphics'
// CGVirtualDisplay, the same one DeskPad and BetterDisplay use) parked diagonally at a corner of
// the user's displays. See docs/macapp-window-hiding.md for what was tried and the limits.

/// A window of an app kept off screen: its CoreGraphics id (for ScreenCaptureKit), its
/// accessibility element (for reading and driving it) and its frame in global screen coordinates
/// (top-left origin, like CGWindowList and AXPosition).
public struct HiddenWindow: @unchecked Sendable, Equatable {
    public var id: CGWindowID
    public var element: AXUIElement
    public var frame: CGRect
    public var title: String?

    public static func == (a: HiddenWindow, b: HiddenWindow) -> Bool {
        a.id == b.id && a.frame == b.frame && a.title == b.title && CFEqual(a.element, b.element)
    }
}

/// Runs window-server work (display configuration, display lists, window moves) on a serial
/// background queue with a deadline, so a stuck window server fails one call with an error instead
/// of hanging the caller's thread. A call that missed its deadline may still be stuck in the window
/// server; until it returns, every later call fails at once (`windowServerNotResponding`) instead of
/// queueing behind it.
final class WindowServerCalls: Sendable {
    private enum CallState { case pending, finished, timedOut }

    private let queue: DispatchQueue
    /// The calls that missed their deadline and haven't returned yet.
    private let stuck = OSAllocatedUnfairLock(initialState: [UInt64: String]())
    private let nextToken = OSAllocatedUnfairLock(initialState: UInt64(0))

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// What is stuck right now, if anything.
    var stuckCall: String? { stuck.withLock { $0.values.first } }

    func run<T: Sendable>(_ what: String, timeout: Duration, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        if let stuckCall { throw OffscreenDisplay.Failure.windowServerNotResponding(stuckCall) }
        let token = nextToken.withLock { $0 += 1; return $0 }
        let state = OSAllocatedUnfairLock(initialState: CallState.pending)
        let stuck = self.stuck
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                let result = Result { try work() }
                state.withLock { state in
                    switch state {
                    case .pending:
                        state = .finished
                        continuation.resume(with: result)
                    case .timedOut:
                        // It came back after all: the window server answers again.
                        state = .finished
                        stuck.withLock { _ = $0.removeValue(forKey: token) }
                    case .finished:
                        break
                    }
                }
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                state.withLock { state in
                    guard state == .pending else { return }
                    state = .timedOut
                    stuck.withLock { $0[token] = what }
                    continuation.resume(throwing: OffscreenDisplay.Failure.timedOut(what))
                }
            }
        }
    }
}

/// The virtual display windows are kept on: one per process, made on first use and kept until the
/// process exits (macOS removes it then). It is never torn down between sessions: a virtual display
/// made after an earlier one went away in the same process never comes online, and creating and
/// removing displays is the window server's most fragile path. The Dock and the menu bar may show
/// up on it, but no physical screen does.
///
/// Every display-configuration and display-list call runs off the main thread with a deadline
/// (`createTimeout` to make it, `callTimeout` per call) and throws instead of hanging.
@MainActor
public final class OffscreenDisplay {
    public enum Failure: Error, Equatable {
        /// CoreGraphics' CGVirtualDisplay classes are missing or refused the display.
        case unavailable(String)
        /// A window-server call didn't return within its deadline (it may still be stuck).
        case timedOut(String)
        /// An earlier call that timed out is still stuck in the window server.
        case windowServerNotResponding(String)
    }

    /// Size in points; the backing store is twice that, like a Retina screen.
    nonisolated public static let pointSize = CGSize(width: 1920, height: 1200)
    /// The vendor id the display reports ("OT").
    nonisolated public static let vendorID: UInt32 = 0x4F54
    /// How long making the display and waiting for it to come online may take (1.1 to 2.2 s usually).
    nonisolated public static let createTimeout: Duration = .seconds(10)
    /// How long any other single window-server call may take.
    nonisolated public static let callTimeout: Duration = .seconds(2)

    nonisolated static let calls = WindowServerCalls(label: "se.medda.opentraffic.offscreen-display")

    /// What this process knows about the displays, readable from any thread: refreshed whenever the
    /// display is made, checked or moved and after every display change.
    private struct Known {
        var live: Set<CGDirectDisplayID> = []
        var physical: [CGRect] = []
    }
    nonisolated private static let known = OSAllocatedUnfairLock(initialState: Known())

    private static var current: OffscreenDisplay?
    private static var creating: Task<OffscreenDisplay, Error>?
    private static var isShutDown = false

    /// Ids of the virtual displays alive in this process (at most one).
    nonisolated public static var liveDisplayIDs: Set<CGDirectDisplayID> { known.withLock { $0.live } }

    public let displayID: CGDirectDisplayID
    /// Retained: the display lives as long as this reference (released only by `shutdown`).
    private var object: DisplayObject?
    private var reconfigurationBox: Unmanaged<OffscreenDisplay>?
    private var placing = false
    private var replaceScheduled = false

    /// The display's frame in global coordinates (top-left origin), as of the last check.
    public private(set) var bounds: CGRect = .zero

    /// The process's display, made on first use (it may take up to `createTimeout`). Call `ready()`
    /// before putting windows on it.
    public static func shared() async throws -> OffscreenDisplay {
        if let current { return current }
        if isShutDown { throw Failure.unavailable("the virtual display was shut down in this process") }
        if let creating { return try await creating.value }
        let task = Task { @MainActor in try await OffscreenDisplay.make() }
        creating = task
        defer { creating = nil }
        let display = try await task.value
        current = display
        return display
    }

    /// For tests only: lets go of the display (macOS removes it) and refuses to make another one in
    /// this process, since a second display in one process never comes online. Move every window
    /// off it first: when a display goes away, macOS moves its windows to a screen the user sees.
    public static func shutdown() async {
        isShutDown = true
        guard let display = current else { return }
        current = nil
        if let box = display.reconfigurationBox {
            CGDisplayRemoveReconfigurationCallback(displayReconfigured, box.toOpaque())
            box.release()
            display.reconfigurationBox = nil
        }
        known.withLock { _ = $0.live.remove(display.displayID) }
        // The last reference goes on the window-server queue: removing a display is a display
        // configuration like any other.
        let object = display.object
        display.object = nil
        _ = try? await calls.run("removing the virtual display", timeout: callTimeout) { withExtendedLifetime(object) {} }
    }

    private static func make() async throws -> OffscreenDisplay {
        let made = try await calls.run("creating the virtual display", timeout: createTimeout) { try createVirtualDisplay() }
        let display = OffscreenDisplay(made)
        try await display.refresh()
        return display
    }

    private init(_ made: DisplayObject) {
        object = made
        displayID = made.id
        Self.known.withLock { _ = $0.live.insert(made.id) }
        let box = Unmanaged.passRetained(self)
        reconfigurationBox = box
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, box.toOpaque())
    }

    /// The CGVirtualDisplay, made through its private Objective-C interface.
    final class DisplayObject: @unchecked Sendable {
        let object: NSObject
        let id: CGDirectDisplayID
        init(object: NSObject, id: CGDirectDisplayID) {
            self.object = object
            self.id = id
        }
    }

    nonisolated private static func createVirtualDisplay() throws -> DisplayObject {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        else { throw Failure.unavailable("CGVirtualDisplay is not available on this macOS") }

        let size = pointSize
        let descriptor = descriptorClass.init()
        descriptor.setValue("OpenTraffic", forKey: "name")
        descriptor.setValue(UInt32(size.width * 2), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(size.height * 2), forKey: "maxPixelsHigh")
        // About 27 inches, so AppKit picks ordinary text sizes.
        descriptor.setValue(NSValue(size: NSSize(width: 597, height: 373)), forKey: "sizeInMillimeters")
        descriptor.setValue(vendorID, forKey: "vendorID")
        descriptor.setValue(UInt32(0x0001), forKey: "productID")
        descriptor.setValue(UInt32(getpid()), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        typealias InitWithDescriptor = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<NSObject>?
        typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<NSObject>?
        typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let initDescriptor = NSSelectorFromString("initWithDescriptor:")
        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let apply = NSSelectorFromString("applySettings:")
        guard let displayAlloc = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let modeAlloc = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              displayAlloc.responds(to: initDescriptor), modeAlloc.responds(to: initMode)
        else { throw Failure.unavailable("CGVirtualDisplay has an unknown interface") }

        let makeDisplay = unsafeBitCast(displayAlloc.method(for: initDescriptor), to: InitWithDescriptor.self)
        guard let display = makeDisplay(displayAlloc, initDescriptor, descriptor)?.takeRetainedValue()
        else { throw Failure.unavailable("the virtual display was refused") }
        let makeMode = unsafeBitCast(modeAlloc.method(for: initMode), to: InitMode.self)
        guard let mode = makeMode(modeAlloc, initMode, UInt(size.width), UInt(size.height), 60)?.takeRetainedValue()
        else { throw Failure.unavailable("the display mode was refused") }
        let settings = settingsClass.init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(UInt32(1), forKey: "hiDPI")
        guard display.responds(to: apply),
              unsafeBitCast(display.method(for: apply), to: ApplySettings.self)(display, apply, settings),
              let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0
        else { throw Failure.unavailable("the display settings were refused") }
        return DisplayObject(object: display, id: id)
    }

    /// The frames of the screens people look at (every active display but virtual ones), as of the
    /// last time this process checked: when its display was made, checked by `ready()` or moved, and
    /// after every display change. Empty before the display exists.
    nonisolated public static func physicalScreenFrames() -> [CGRect] {
        known.withLock { $0.physical }
    }

    /// Whether any part of `frame` (global, top-left origin) is on a screen people look at.
    nonisolated public static func isVisible(_ frame: CGRect) -> Bool {
        isVisible(frame, on: physicalScreenFrames())
    }

    nonisolated static func isVisible(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        !frame.isEmpty && screens.contains { $0.intersects(frame) }
    }

    nonisolated static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Where the display and the screens around it are. Window-server calls: on `calls` only.
    struct Layout: Sendable {
        var online: Bool
        var bounds: CGRect
        /// Screens people look at.
        var physical: [CGRect]
        /// Other OpenTraffic virtual displays (other processes').
        var others: [CGRect]

        /// Whether the display is clear of every screen and of other processes' displays.
        var isParked: Bool {
            !physical.contains { OffscreenDisplay.sharesEdge($0, bounds) || $0.intersects(bounds) }
                && !others.contains { $0.intersects(bounds) }
        }
    }

    nonisolated private static func layout(of id: CGDirectDisplayID) -> Layout {
        let active = activeDisplays()
        let live = known.withLock { $0.live }
        var physical: [CGRect] = []
        var others: [CGRect] = []
        for display in active where display != id && !live.contains(display) {
            if CGDisplayVendorNumber(display) == vendorID {
                others.append(CGDisplayBounds(display))
            } else {
                physical.append(CGDisplayBounds(display))
            }
        }
        return Layout(online: active.contains(id), bounds: CGDisplayBounds(id), physical: physical, others: others)
    }

    /// Moves the display to the first free corner while it touches a physical screen or overlaps
    /// another OpenTraffic display (macOS first puts a new display to the right of the main one,
    /// and rearranges when screens change). Window-server calls: on `calls` only.
    nonisolated private static func arrange(_ id: CGDirectDisplayID) -> Layout {
        var layout = layout(of: id)
        guard layout.online, !layout.bounds.isEmpty, !layout.isParked else { return layout }
        let origins = cornerOrigins(for: layout.bounds.size, around: layout.physical, avoiding: layout.others)
        for origin in origins where !layout.isParked {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { break }
            CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { break }
            layout = Self.layout(of: id)
        }
        return layout
    }

    /// Whether `a` shares more than a corner point with `b` (the pointer could cross between them).
    nonisolated static func sharesEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        let touch = a.insetBy(dx: -1, dy: -1).intersection(b)
        return !touch.isNull && max(touch.width, touch.height) > 1
    }

    /// Where the display may go: diagonally off a corner of a physical screen, touching nothing
    /// but that corner, so the pointer practically never wanders onto it, and not on top of
    /// another OpenTraffic display.
    nonisolated static func cornerOrigins(for size: CGSize, around screens: [CGRect], avoiding others: [CGRect] = []) -> [CGPoint] {
        screens.flatMap { s in [
            CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX - size.width, y: s.maxY),
            CGPoint(x: s.maxX, y: s.minY - size.height), CGPoint(x: s.minX - size.width, y: s.minY - size.height),
        ] }.filter { origin in
            let frame = CGRect(origin: origin, size: size)
            return !screens.contains { $0.intersects(frame) || sharesEdge($0, frame) } && !others.contains { $0.intersects(frame) }
        }
    }

    private func remember(_ layout: Layout) {
        if layout.online { bounds = layout.bounds }
        Self.known.withLock { $0.physical = layout.physical }
    }

    /// Reads where the display and the screens are now.
    private func refresh() async throws {
        let id = displayID
        remember(try await Self.calls.run("listing the displays", timeout: Self.callTimeout) { Self.layout(of: id) })
    }

    /// Waits until macOS has the display online and parked at a corner (a moment after it's made;
    /// at once later). Throws when that takes longer than `timeout`.
    public func ready(timeout: Duration = OffscreenDisplay.createTimeout) async throws {
        let deadline = ContinuousClock.now + timeout
        let id = displayID
        while true {
            let layout = try await Self.calls.run("waiting for the virtual display", timeout: Self.callTimeout) { Self.layout(of: id) }
            remember(layout)
            if layout.online, !layout.bounds.isEmpty {
                if layout.isParked { return }
                // Moved (or not, when no corner is free); the next look says whether it worked.
                try await place()
            }
            guard ContinuousClock.now < deadline else {
                throw Failure.timedOut(layout.online ? "parking the virtual display at a corner" : "the virtual display coming online")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Moves the display to a free corner if it needs to (off the main thread, with a deadline).
    func place() async throws {
        guard !placing else { return }
        placing = true
        defer { placing = false }
        let id = displayID
        remember(try await Self.calls.run("arranging the displays", timeout: Self.callTimeout) { Self.arrange(id) })
    }

    /// A display was added, removed or moved (by the user, another process, or this one). Nothing
    /// is reconfigured from inside the callback: a moment later the display is checked, and moved
    /// if it needs to be, on the window-server queue. Changes that come in a burst are handled once.
    fileprivate func reconfigured(_ flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag), !replaceScheduled, object != nil else { return }
        replaceScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            replaceScheduled = false
            guard object != nil else { return }
            if placing { try? await refresh() } else { try? await place() }
        }
    }
}

private let displayReconfigured: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    let display = Unmanaged<OffscreenDisplay>.fromOpaque(userInfo).takeUnretainedValue()
    if Thread.isMainThread {
        MainActor.assumeIsolated { display.reconfigured(flags) }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { display.reconfigured(flags) } }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// CGWindowListCreate (ids only, much cheaper than CGWindowListCopyWindowInfo), which Swift hides.
@_silgen_name("CGWindowListCreate")
private func windowListIDs(_ option: CGWindowListOption, _ relativeTo: CGWindowID) -> Unmanaged<CFArray>?

/// The on-screen windows' ids, front to back.
private func onScreenWindowIDs() -> [CGWindowID] {
    guard let list = windowListIDs(.optionOnScreenOnly, kCGNullWindowID)?.takeRetainedValue() else { return [] }
    // The values are the ids themselves, not CFNumbers.
    return (0..<CFArrayGetCount(list)).map { CGWindowID(UInt(bitPattern: CFArrayGetValueAtIndex(list, $0))) }
}

/// Owner and bounds of just these windows.
private func describeWindows(_ ids: [CGWindowID]) -> [(id: CGWindowID, pid: pid_t, bounds: CGRect)] {
    guard !ids.isEmpty else { return [] }
    var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &values, values.count, nil),
          let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [] }
    return info.compactMap { entry in
        guard let id = entry[kCGWindowNumber as String] as? CGWindowID, let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = entry[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
        else { return nil }
        return (id, pid, bounds)
    }
}

/// Launches Mac apps so the user never sees them and they never take focus, and keeps every
/// window they open (including later ones: panels, alerts; sheets follow their parent) on the
/// off-screen display, where ScreenCaptureKit can still capture them. The Dock may show the app's
/// icon; it never becomes the active app, so the menu bar never switches to it.
///
/// Window moves run off the main thread with a deadline (`OffscreenDisplay.callTimeout`), and the
/// watchdog runs on its own queue: a window server that stops answering fails the share that needs
/// it (with `OffscreenDisplay.Failure`) and never blocks the main thread.
@MainActor
public final class MacAppWindowHider {
    public enum Failure: Error, Equatable {
        /// The process isn't trusted for Accessibility (System Settings > Privacy & Security).
        case notTrusted
        case observerFailed(pid_t, Int32)
        /// LaunchServices (through `/usr/bin/open`) didn't start the app; its message.
        case launchFailed(String)
    }

    /// Accessibility is what moves the windows; without it nothing can be hidden.
    public static var isPermitted: Bool { AXIsProcessTrusted() }

    /// How long an accessibility call to the shared app may take before it fails (AX's own default
    /// is 6 s).
    nonisolated static let messagingTimeout: Float = 2

    private final class Watch {
        let pid: pid_t
        let app: AXUIElement
        let observer: AXObserver
        var windows: [AXUIElement] = []
        init(pid: pid_t, app: AXUIElement, observer: AXObserver) {
            self.pid = pid
            self.app = app
            self.observer = observer
        }
    }

    /// Accessibility elements handed to and from the window-move queue.
    private struct Elements: @unchecked Sendable { var elements: [AXUIElement] }

    /// kAXWindowCreated can come a few hundred milliseconds after the window shows; focus and
    /// main-window changes come within a frame for ordinary windows.
    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]

    /// How often the watchdog looks for windows of watched apps on a physical screen (panels and
    /// alerts can show before accessibility reports them). One cheap window-id list per tick.
    public var watchdogInterval: Duration = .milliseconds(16) {
        didSet { if watchdog != nil { startWatchdog() } }
    }

    private var display: OffscreenDisplay?
    private var watchdog: DispatchSourceTimer?
    private var watches: [pid_t: Watch] = [:]
    /// The watched pids, for the watchdog's queue.
    private let watched = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    private var box: Unmanaged<MacAppWindowHider>?
    private let moves = WindowServerCalls(label: "se.medda.opentraffic.window-moves")
    private var sweeps: [pid_t: Task<Void, Error>] = [:]
    private var sweepAgain: Set<pid_t> = []

    public init() {}

    /// The display the windows are kept on (once the first launch or `keepOffScreen` made it ready).
    public var offscreenBounds: CGRect? { display?.bounds }

    /// Launches a fresh instance of the app hidden and without activating it, waits up to
    /// `windowTimeout` for its first window, moves its windows to the off-screen display, then
    /// unhides it so its windows are ordered in (capturable) where nobody sees them. When the
    /// windows can't be moved (the window server doesn't answer), the app is quit while still
    /// hidden and the error is thrown.
    ///
    /// With `output`, the app's standard output and error are appended to that file. NSWorkspace
    /// can't redirect them, so the app is then launched the same way through `/usr/bin/open`
    /// (`-n -j -g --stdout --stderr`) and found among the running apps by its bundle path.
    public func launch(bundle: URL, environment: [String: String] = [:], arguments: [String] = [],
                       windowTimeout: Duration = .seconds(10), output: URL? = nil) async throws -> NSRunningApplication {
        guard Self.isPermitted else { throw Failure.notTrusted }
        try await offscreenDisplay()
        let app: NSRunningApplication
        if let output {
            app = try await Self.openHidden(bundle: bundle, environment: environment, arguments: arguments, output: output)
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.createsNewApplicationInstance = true
            configuration.addsToRecentItems = false
            configuration.environment = environment
            configuration.arguments = arguments
            app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        }
        do {
            // Hidden, its windows are ordered out: moving them now can't flash anything.
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            let deadline = ContinuousClock.now + windowTimeout
            while Self.axWindows(of: element).isEmpty, ContinuousClock.now < deadline, !app.isTerminated {
                try await Task.sleep(for: .milliseconds(25))
            }
            try await keepOffScreen(pid: app.processIdentifier)
            app.unhide()
            // Unhiding takes effect a moment later: wait until the windows are ordered in, so they
            // can be captured as soon as this returns.
            try await waitUntilOrderedIn(app.processIdentifier, timeout: .seconds(2))
            // The windows are on a screen, so AppKit has no reason to move them as it orders them in;
            // one more look in case it did (the moved notification and the watchdog catch later ones).
            try await sweep(app.processIdentifier)
        } catch {
            unwatch(app.processIdentifier)
            app.forceTerminate()
            throw error
        }
        return app
    }

    /// Launches a new instance of the app hidden, in the background, with its standard output and
    /// error going to `output`, and returns it once it is among the running apps.
    private static func openHidden(bundle: URL, environment: [String: String], arguments: [String],
                                   output: URL) async throws -> NSRunningApplication {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        func instances() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path }
        }
        let before = Set(instances().map(\.processIdentifier))
        var openArguments = ["-n", "-j", "-g", "--stdout", output.path, "--stderr", output.path]
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) { openArguments += ["--env", "\(name)=\(value)"] }
        openArguments += ["-a", path]
        if !arguments.isEmpty { openArguments += ["--args"] + arguments }
        let finished = await Task.detached { () -> (status: Int32, message: String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = openArguments
            var own = ProcessInfo.processInfo.environment
            own.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            process.environment = own
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        guard finished.status == 0 else {
            throw Failure.launchFailed(finished.message.isEmpty ? "open exited with status \(finished.status)" : finished.message)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let app = instances().first(where: { !before.contains($0.processIdentifier) }) { return app }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.launchFailed("the app was opened but didn't show up among the running apps")
    }

    /// Waits (up to `timeout`) until every window accessibility reports for the app is in the
    /// window server's on-screen list. A window on another Space never is; then it just returns.
    private func waitUntilOrderedIn(_ pid: pid_t, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let ids = windows(pid: pid).map(\.id)
            if !ids.isEmpty {
                let onScreen = try await moves.run("listing windows", timeout: OffscreenDisplay.callTimeout) { Set(onScreenWindowIDs()) }
                if ids.allSatisfy(onScreen.contains) { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Moves the app's windows to the off-screen display and keeps them there: windows it opens
    /// later and windows it moves back are moved again as soon as accessibility reports them.
    public func keepOffScreen(pid: pid_t) async throws {
        guard Self.isPermitted else { throw Failure.notTrusted }
        try await offscreenDisplay()
        if watches[pid] == nil {
            var observer: AXObserver?
            let made = AXObserverCreate(pid, axNotified, &observer)
            guard made == .success, let observer else { throw Failure.observerFailed(pid, made.rawValue) }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            let watch = Watch(pid: pid, app: app, observer: observer)
            watches[pid] = watch
            watched.withLock { _ = $0.insert(pid) }
            for notification in Self.appNotifications {
                AXObserverAddNotification(observer, app, notification as CFString, refcon())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if watchdog == nil { startWatchdog() }
        }
        try await sweep(pid)
    }

    /// The app's windows as they are now.
    public func windows(pid: pid_t) -> [HiddenWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return Self.axWindows(of: app).compactMap { element in
            var id: CGWindowID = 0
            guard axWindowID(element, &id) == .success, id != 0, let frame = Self.frame(of: element) else { return nil }
            return HiddenWindow(id: id, element: element, frame: frame, title: Self.string(element, kAXTitleAttribute))
        }
    }

    /// Quits the app (with `terminate`, forcibly after 2 s) and stops watching it. The off-screen
    /// display stays for the next share (it lives as long as the process). Quit the app first if
    /// you pass `terminate: false`: if the process exits, macOS moves the display's windows to a
    /// screen the user sees.
    public func release(pid: pid_t, terminate: Bool = true) async {
        if terminate, let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
            if !app.isTerminated { app.forceTerminate() }
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
        }
        unwatch(pid)
    }

    private func unwatch(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        watched.withLock { _ = $0.remove(pid) }
        sweepAgain.remove(pid)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
        for notification in Self.appNotifications {
            AXObserverRemoveNotification(watch.observer, watch.app, notification as CFString)
        }
        for window in watch.windows { AXObserverRemoveNotification(watch.observer, window, kAXMovedNotification as CFString) }
        if watches.isEmpty {
            watchdog?.cancel()
            watchdog = nil
            if let box {
                box.release()
                self.box = nil
            }
        }
    }

    /// Window ids the watchdog has seen; touched only on its queue.
    private final class WatchdogState: @unchecked Sendable {
        var known: Set<CGWindowID> = []
        var suspects: Set<CGWindowID> = []

        /// Looks at windows that appeared since the last tick (and ones still waiting to be moved)
        /// and returns the watched apps with a window on a physical screen.
        func check(watched: Set<pid_t>) -> Set<pid_t> {
            guard !watched.isEmpty else { return [] }
            let current = onScreenWindowIDs()
            let fresh = current.filter { !known.contains($0) }
            known = Set(current)
            let look = fresh + suspects.filter { known.contains($0) && !fresh.contains($0) }
            guard !look.isEmpty else { return [] }
            var stillSuspect: Set<CGWindowID> = []
            var pids: Set<pid_t> = []
            for window in describeWindows(look) where watched.contains(window.pid) {
                if OffscreenDisplay.isVisible(window.bounds) {
                    stillSuspect.insert(window.id)
                    pids.insert(window.pid)
                }
            }
            suspects = stillSuspect
            return pids
        }
    }

    /// A weak reference the watchdog's queue may hold.
    private final class WeakHider: @unchecked Sendable {
        weak var hider: MacAppWindowHider?
        init(_ hider: MacAppWindowHider) { self.hider = hider }
    }

    /// The watchdog runs on its own queue: listing windows is a window-server call, and the main
    /// thread must not wait on it. Only apps it finds on a physical screen come back to the main
    /// thread, to be swept.
    private func startWatchdog() {
        watchdog?.cancel()
        let seconds = Double(watchdogInterval.components.seconds) + Double(watchdogInterval.components.attoseconds) / 1e18
        watchdog = Self.makeWatchdog(every: max(seconds, 0.005), watched: watched, owner: WeakHider(self))
    }

    /// Nonisolated, so the timer's handler isn't taken to be main-actor code (Swift checks that at
    /// run time and traps when it runs on the watchdog's queue).
    nonisolated private static func makeWatchdog(every seconds: Double, watched: OSAllocatedUnfairLock<Set<pid_t>>, owner: WeakHider) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "se.medda.opentraffic.window-watchdog", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: seconds, leeway: .milliseconds(2))
        let state = WatchdogState()
        timer.setEventHandler {
            let pids = state.check(watched: watched.withLock { $0 })
            guard !pids.isEmpty else { return }
            Task { @MainActor in
                for pid in pids { owner.hider?.sweepLater(pid) }
            }
        }
        timer.resume()
        return timer
    }

    @discardableResult
    private func offscreenDisplay() async throws -> OffscreenDisplay {
        let made: OffscreenDisplay
        if let display { made = display } else { made = try await OffscreenDisplay.shared() }
        display = made
        try await made.ready()
        return made
    }

    private func refcon() -> UnsafeMutableRawPointer {
        if let box { return box.toOpaque() }
        // Retained while something is watched, released by the last `unwatch`.
        let made = Unmanaged.passRetained(self)
        box = made
        return made.toOpaque()
    }

    fileprivate func notified(pid: pid_t) {
        sweepLater(pid)
    }

    /// A sweep nobody waits for (an accessibility notification, the watchdog). If it fails, the
    /// watchdog asks again while a window stays on a physical screen.
    private func sweepLater(_ pid: pid_t) {
        guard watches[pid] != nil else { return }
        Task { try? await sweep(pid) }
    }

    /// Puts every window of the app that a person could see onto the off-screen display, and
    /// subscribes to its moves. One sweep per app at a time; asking during one runs another after it.
    private func sweep(_ pid: pid_t) async throws {
        if let running = sweeps[pid] {
            sweepAgain.insert(pid)
            // The running sweep looks again before it finishes, so waiting for it is enough.
            try await running.value
            return
        }
        let task = Task { @MainActor in
            defer { sweeps[pid] = nil }
            repeat {
                sweepAgain.remove(pid)
                try await sweepOnce(pid)
            } while sweepAgain.contains(pid) && watches[pid] != nil
        }
        sweeps[pid] = task
        try await task.value
    }

    private func sweepOnce(_ pid: pid_t) async throws {
        guard let watch = watches[pid], let bounds = display?.bounds, !bounds.isEmpty else { return }
        let app = Elements(elements: [watch.app])
        let current = try await moves.run("moving windows to the off-screen display", timeout: OffscreenDisplay.callTimeout) {
            Elements(elements: Self.moveWindows(of: app.elements[0], onto: bounds))
        }.elements
        guard watches[pid] === watch else { return }
        for window in current where !watch.windows.contains(where: { CFEqual($0, window) }) {
            AXObserverAddNotification(watch.observer, window, kAXMovedNotification as CFString, refcon())
        }
        watch.windows = current
    }

    /// Moves every window of `app` that isn't on the off-screen display (or shows on a physical
    /// screen) onto it, and returns the app's windows. Off the main thread.
    nonisolated private static func moveWindows(of app: AXUIElement, onto bounds: CGRect) -> [AXUIElement] {
        let current = axWindows(of: app)
        for (index, window) in current.enumerated() {
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            guard let frame = frame(of: window), !bounds.contains(frame.origin) || OffscreenDisplay.isVisible(frame) else { continue }
            // Cascade a little so windows don't sit exactly on top of each other; stay clear of
            // the display's menu bar so AppKit has no reason to move them.
            let step = CGFloat(index % 10) * 24
            var origin = CGPoint(x: bounds.minX + 40 + step, y: bounds.minY + 60 + step)
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        return current
    }

    // MARK: Accessibility helpers

    nonisolated static func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}

private let axNotified: AXObserverCallback = { _, element, _, refcon in
    guard let refcon, let pid = MacAppWindowHider.pid(of: element) else { return }
    let hider = Unmanaged<MacAppWindowHider>.fromOpaque(refcon).takeUnretainedValue()
    // The observer's source is on the main run loop.
    MainActor.assumeIsolated { hider.notified(pid: pid) }
}

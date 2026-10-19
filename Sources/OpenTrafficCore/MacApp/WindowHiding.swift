import AppKit
import ApplicationServices
import CoreGraphics

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

/// The virtual display windows are kept on. One per process, shared by every hider that holds it;
/// it disappears when the last one lets go (and with the process). The Dock and the menu bar may
/// show up on it, but no physical screen does.
@MainActor
public final class OffscreenDisplay {
    public enum Failure: Error, Equatable {
        /// CoreGraphics' CGVirtualDisplay classes are missing or refused the display.
        case unavailable(String)
    }

    /// Size in points; the backing store is twice that, like a Retina screen.
    public static let pointSize = CGSize(width: 1920, height: 1200)
    /// The vendor id the display reports ("OT").
    public static let vendorID: UInt32 = 0x4F54

    private static var shared: OffscreenDisplay?
    private static var holders = 0
    /// Ids of the virtual displays alive in this process.
    public private(set) static var liveDisplayIDs: Set<CGDirectDisplayID> = []

    public let displayID: CGDirectDisplayID
    /// Retained: the display lives as long as this object.
    private let display: NSObject
    private var reconfigurationBox: Unmanaged<OffscreenDisplay>?
    private var placing = false

    /// The display's frame in global coordinates (top-left origin).
    public var bounds: CGRect { CGDisplayBounds(displayID) }

    /// The shared display, created on first use. Balance with `release()`.
    public static func acquire() throws -> OffscreenDisplay {
        if let shared {
            holders += 1
            return shared
        }
        let display = try OffscreenDisplay()
        shared = display
        holders = 1
        return display
    }

    public static func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0, let display = shared {
            shared = nil
            display.invalidate()
        }
    }

    private init() throws {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        else { throw Failure.unavailable("CGVirtualDisplay is not available on this macOS") }

        let size = Self.pointSize
        let descriptor = descriptorClass.init()
        descriptor.setValue("OpenTraffic", forKey: "name")
        descriptor.setValue(UInt32(size.width * 2), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(size.height * 2), forKey: "maxPixelsHigh")
        // About 27 inches, so AppKit picks ordinary text sizes.
        descriptor.setValue(NSValue(size: NSSize(width: 597, height: 373)), forKey: "sizeInMillimeters")
        descriptor.setValue(Self.vendorID, forKey: "vendorID")
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

        self.display = display
        self.displayID = id
        Self.liveDisplayIDs.insert(id)
        place()
        let box = Unmanaged.passRetained(self)
        reconfigurationBox = box
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, box.toOpaque())
    }

    private func invalidate() {
        if let box = reconfigurationBox {
            CGDisplayRemoveReconfigurationCallback(displayReconfigured, box.toOpaque())
            box.release()
            reconfigurationBox = nil
        }
        Self.liveDisplayIDs.remove(displayID)
        // The CGVirtualDisplay goes away with this object.
    }

    /// The frames of the screens people look at: every active display but the virtual ones.
    public static func physicalScreenFrames() -> [CGRect] {
        activeDisplays().filter { !liveDisplayIDs.contains($0) && CGDisplayVendorNumber($0) != vendorID }.map(CGDisplayBounds)
    }

    /// Whether any part of `frame` (global, top-left origin) is on a screen people look at.
    public static func isVisible(_ frame: CGRect) -> Bool {
        !frame.isEmpty && physicalScreenFrames().contains { $0.intersects(frame) }
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Whether `a` shares more than a corner point with `b` (the pointer could cross between them).
    nonisolated static func sharesEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        let touch = a.insetBy(dx: -1, dy: -1).intersection(b)
        return !touch.isNull && max(touch.width, touch.height) > 1
    }

    /// Where the display may go: diagonally off a corner of a physical screen, touching nothing
    /// but that corner, so the pointer practically never wanders onto it.
    nonisolated static func cornerOrigins(for size: CGSize, around screens: [CGRect]) -> [CGPoint] {
        screens.flatMap { s in [
            CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX - size.width, y: s.maxY),
            CGPoint(x: s.maxX, y: s.minY - size.height), CGPoint(x: s.minX - size.width, y: s.minY - size.height),
        ] }.filter { origin in
            let frame = CGRect(origin: origin, size: size)
            return !screens.contains { $0.intersects(frame) || sharesEdge($0, frame) }
        }
    }

    /// Waits until macOS has the display online and parked at a corner (a moment after it's made).
    public func ready(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Self.activeDisplays().contains(displayID), !bounds.isEmpty {
                place()
                if !Self.physicalScreenFrames().contains(where: { Self.sharesEdge($0, bounds) || $0.intersects(bounds) }) { return }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Moves the display to a free corner when it shares an edge with a physical screen (macOS
    /// first puts a new display to the right of the main one, and rearranges when screens change).
    func place() {
        guard !placing else { return }
        placing = true
        defer { placing = false }
        guard !bounds.isEmpty else { return }
        for origin in Self.cornerOrigins(for: bounds.size, around: Self.physicalScreenFrames()) {
            if !Self.physicalScreenFrames().contains(where: { Self.sharesEdge($0, bounds) || $0.intersects(bounds) }) { return }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return }
        }
    }

    fileprivate func reconfigured(_ flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag), !placing else { return }
        place()
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
@MainActor
public final class MacAppWindowHider {
    public enum Failure: Error, Equatable {
        /// The process isn't trusted for Accessibility (System Settings > Privacy & Security).
        case notTrusted
        case observerFailed(pid_t, Int32)
    }

    /// Accessibility is what moves the windows; without it nothing can be hidden.
    public static var isPermitted: Bool { AXIsProcessTrusted() }

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

    /// kAXWindowCreated can come a few hundred milliseconds after the window shows; focus and
    /// main-window changes come within a frame for ordinary windows.
    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]

    /// How often the watchdog looks for windows of watched apps on a physical screen (panels and
    /// alerts can show before accessibility reports them). One cheap window-id list per tick.
    public var watchdogInterval: Duration = .milliseconds(16) {
        didSet { if watchdog != nil { startWatchdog() } }
    }

    private var display: OffscreenDisplay?
    private var watchdog: Timer?
    private var knownWindowIDs: Set<CGWindowID> = []
    private var suspectWindowIDs: Set<CGWindowID> = []
    private var watches: [pid_t: Watch] = [:]
    private var box: Unmanaged<MacAppWindowHider>?

    public init() {}

    /// The display the windows are kept on (created by the first launch or `keepOffScreen`).
    public var offscreenBounds: CGRect? { display?.bounds }

    /// Launches a fresh instance of the app hidden and without activating it, waits up to
    /// `windowTimeout` for its first window, moves its windows to the off-screen display, then
    /// unhides it so its windows are ordered in (capturable) where nobody sees them.
    public func launch(bundle: URL, environment: [String: String] = [:], arguments: [String] = [],
                       windowTimeout: Duration = .seconds(10)) async throws -> NSRunningApplication {
        guard Self.isPermitted else { throw Failure.notTrusted }
        try await offscreenDisplay().ready()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.environment = environment
        configuration.arguments = arguments
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        // Hidden, its windows are ordered out: moving them now can't flash anything.
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = ContinuousClock.now + windowTimeout
        while Self.axWindows(of: element).isEmpty, ContinuousClock.now < deadline, !app.isTerminated {
            try await Task.sleep(for: .milliseconds(25))
        }
        try keepOffScreen(pid: app.processIdentifier)
        app.unhide()
        // The windows are on a screen, so AppKit has no reason to move them as it orders them in;
        // one more look in case it did (the moved notification and the watchdog catch later ones).
        try await Task.sleep(for: .milliseconds(25))
        sweep(app.processIdentifier)
        return app
    }

    /// Moves the app's windows to the off-screen display and keeps them there: windows it opens
    /// later and windows it moves back are moved again as soon as accessibility reports them.
    public func keepOffScreen(pid: pid_t) throws {
        guard Self.isPermitted else { throw Failure.notTrusted }
        let display = try offscreenDisplay()
        if watches[pid] == nil {
            var observer: AXObserver?
            let made = AXObserverCreate(pid, axNotified, &observer)
            guard made == .success, let observer else { throw Failure.observerFailed(pid, made.rawValue) }
            let app = AXUIElementCreateApplication(pid)
            let watch = Watch(pid: pid, app: app, observer: observer)
            watches[pid] = watch
            for notification in Self.appNotifications {
                AXObserverAddNotification(observer, app, notification as CFString, refcon())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if watchdog == nil { startWatchdog() }
        }
        _ = display
        sweep(pid)
    }

    /// The app's windows as they are now.
    public func windows(pid: pid_t) -> [HiddenWindow] {
        Self.axWindows(of: AXUIElementCreateApplication(pid)).compactMap { element in
            var id: CGWindowID = 0
            guard axWindowID(element, &id) == .success, id != 0, let frame = Self.frame(of: element) else { return nil }
            return HiddenWindow(id: id, element: element, frame: frame, title: Self.string(element, kAXTitleAttribute))
        }
    }

    /// Stops watching the app. Quit it first (or with `terminate: true`): when the display goes
    /// away, macOS moves the windows on it to a screen the user sees.
    public func release(pid: pid_t, terminate: Bool = true) async {
        if terminate, let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
            if !app.isTerminated { app.forceTerminate() }
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
        }
        unwatch(pid)
        if watches.isEmpty, display != nil {
            display = nil
            OffscreenDisplay.release()
        }
    }

    private func unwatch(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
        for notification in Self.appNotifications {
            AXObserverRemoveNotification(watch.observer, watch.app, notification as CFString)
        }
        for window in watch.windows { AXObserverRemoveNotification(watch.observer, window, kAXMovedNotification as CFString) }
        if watches.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
            knownWindowIDs = []
            suspectWindowIDs = []
            if let box {
                box.release()
                self.box = nil
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let seconds = Double(watchdogInterval.components.seconds) + Double(watchdogInterval.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: max(seconds, 0.005), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkScreens() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Looks at windows that appeared since the last tick (and ones still waiting to be moved):
    /// any of a watched app's that touches a physical screen gets its app swept at once.
    private func checkScreens() {
        let current = onScreenWindowIDs()
        let fresh = current.filter { !knownWindowIDs.contains($0) }
        knownWindowIDs = Set(current)
        let look = fresh + suspectWindowIDs.filter { knownWindowIDs.contains($0) && !fresh.contains($0) }
        guard !look.isEmpty else { return }
        var stillSuspect: Set<CGWindowID> = []
        var sweepPIDs: Set<pid_t> = []
        for window in describeWindows(look) where watches[window.pid] != nil {
            if OffscreenDisplay.isVisible(window.bounds) {
                stillSuspect.insert(window.id)
                sweepPIDs.insert(window.pid)
            }
        }
        suspectWindowIDs = stillSuspect
        for pid in sweepPIDs { sweep(pid) }
    }

    private func offscreenDisplay() throws -> OffscreenDisplay {
        if let display { return display }
        let made = try OffscreenDisplay.acquire()
        display = made
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
        guard watches[pid] != nil else { return }
        sweep(pid)
    }

    /// Puts every window of the app that a person could see onto the off-screen display, and
    /// subscribes to its moves.
    private func sweep(_ pid: pid_t) {
        guard let watch = watches[pid], let bounds = display?.bounds, !bounds.isEmpty else { return }
        let current = Self.axWindows(of: watch.app)
        for window in current where !watch.windows.contains(where: { CFEqual($0, window) }) {
            AXObserverAddNotification(watch.observer, window, kAXMovedNotification as CFString, refcon())
        }
        watch.windows = current
        for (index, window) in current.enumerated() {
            guard let frame = Self.frame(of: window), !bounds.contains(frame.origin) || OffscreenDisplay.isVisible(frame) else { continue }
            // Cascade a little so windows don't sit exactly on top of each other; stay clear of
            // the display's menu bar so AppKit has no reason to move them.
            let step = CGFloat(index % 10) * 24
            var origin = CGPoint(x: bounds.minX + 40 + step, y: bounds.minY + 60 + step)
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
    }

    // MARK: Accessibility helpers

    static func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func frame(of element: AXUIElement) -> CGRect? {
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

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
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

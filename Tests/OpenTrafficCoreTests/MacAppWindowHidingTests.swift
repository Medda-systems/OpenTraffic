import AppKit
import ApplicationServices
import ScreenCaptureKit
import Testing
@testable import OpenTrafficCore

// Mac app sharing: launching an app so its windows stay off the user's screens (on OpenTraffic's
// virtual display) yet ScreenCaptureKit can capture them, without taking focus. The end-to-end
// test needs Accessibility and Screen Recording for the process running `swift test`, and skips
// without them (as on GitHub Actions). It shares the Orbit fixture when it is built
// (`sh Examples/macapp-orbit/package.sh`) and Calculator otherwise.

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let orbit = repository.appendingPathComponent("Examples/macapp-orbit/dist/Orbit.app")
private let sharedApp = FileManager.default.fileExists(atPath: orbit.path) ? orbit : URL(fileURLWithPath: "/System/Applications/Calculator.app")
private let mayCapture = AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()

@Test func theDisplayGoesDiagonallyOffACornerTouchingNoScreenEdge() {
    let size = CGSize(width: 1920, height: 1200)
    let layouts: [[CGRect]] = [
        [CGRect(x: 0, y: 0, width: 1710, height: 1112)],
        [CGRect(x: 0, y: 0, width: 1710, height: 1112), CGRect(x: -403, y: -1440, width: 2560, height: 1440)],
        [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 1920, height: 1080), CGRect(x: -1080, y: -400, width: 1080, height: 1920)],
    ]
    for screens in layouts {
        let origins = OffscreenDisplay.cornerOrigins(for: size, around: screens)
        #expect(!origins.isEmpty)
        for origin in origins {
            let frame = CGRect(origin: origin, size: size)
            #expect(!screens.contains { $0.intersects(frame) || OffscreenDisplay.sharesEdge($0, frame) })
        }
    }
    #expect(OffscreenDisplay.cornerOrigins(for: size, around: layouts[0]).first == CGPoint(x: 1710, y: 1112))
}

@Test func touchingAtACornerIsNotSharingAnEdge() {
    let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(!OffscreenDisplay.sharesEdge(screen, CGRect(x: 100, y: 100, width: 50, height: 50)))
    #expect(!OffscreenDisplay.sharesEdge(screen, CGRect(x: -50, y: -50, width: 50, height: 50)))
    #expect(OffscreenDisplay.sharesEdge(screen, CGRect(x: 100, y: 20, width: 50, height: 50)))
    #expect(OffscreenDisplay.sharesEdge(screen, CGRect(x: 20, y: 100, width: 50, height: 50)))
    #expect(!OffscreenDisplay.sharesEdge(screen, CGRect(x: 300, y: 300, width: 50, height: 50)))
}

/// Where the windows of processes that didn't exist when sampling began were, every few milliseconds.
private final class WindowSampler: @unchecked Sendable {
    struct Sample { var time: ContinuousClock.Instant; var pid: pid_t; var id: CGWindowID; var bounds: CGRect }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var running = true
    private let existing: Set<pid_t>

    init() {
        let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        existing = Set(all.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = ContinuousClock.now
                let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                let fresh = onScreen.compactMap { entry -> Sample? in
                    guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, !existing.contains(pid),
                          let id = entry[kCGWindowNumber as String] as? CGWindowID,
                          let bounds = entry[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
                    else { return nil }
                    return Sample(time: now, pid: pid, id: id, bounds: bounds)
                }
                lock.withLock { samples += fresh }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    func stop() -> [Sample] {
        lock.withLock {
            running = false
            return samples
        }
    }
}

@MainActor
private func pressAboutItem(of pid: pid_t) -> Bool {
    func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success,
          let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
    // The app menu (after the Apple menu); its first item is "About <App>".
    let menus = children(bar as! AXUIElement)
    guard menus.count > 1, let menu = children(menus[1]).first, let about = children(menu).first else { return false }
    return AXUIElementPerformAction(about, kAXPressAction as CFString) == .success
}

@MainActor
@Test(.enabled(if: mayCapture, "Accessibility and Screen Recording for the test runner"), .timeLimit(.minutes(1)))
func aLaunchedAppStaysOffScreenUnfocusedAndCapturable() async throws {
    await MacAppFixtureTurn.shared.acquire()
    defer { MacAppFixtureTurn.shared.release() }
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let sampler = WindowSampler()
    let hider = MacAppWindowHider()
    let app = try await hider.launch(bundle: sharedApp)
    let pid = app.processIdentifier
    let launched = ContinuousClock.now
    var released = false
    defer { if !released { app.forceTerminate() } }

    let offscreen = try #require(hider.offscreenBounds)
    #expect(!OffscreenDisplay.isVisible(offscreen))
    let windows = hider.windows(pid: pid)
    try #require(!windows.isEmpty)
    for window in windows {
        #expect(!OffscreenDisplay.isVisible(window.frame), "\(window.title ?? "") at \(window.frame)")
        #expect(offscreen.intersects(window.frame))
    }

    // ScreenCaptureKit lists the windows as on screen and captures real pixels.
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let listed = content.windows.filter { $0.owningApplication?.processID == pid }
    for window in windows {
        let match = listed.first { $0.windowID == window.id }
        #expect(match?.isOnScreen == true, "window \(window.id) not listed on screen")
    }
    let first = try #require(listed.first { $0.windowID == windows[0].id })
    let configuration = SCStreamConfiguration()
    configuration.width = Int(first.frame.width) * 2
    configuration.height = Int(first.frame.height) * 2
    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: first), configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    var colors = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 9) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 9) {
            if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                colors.insert(UInt32(pixel.redComponent * 255) << 16 | UInt32(pixel.greenComponent * 255) << 8 | UInt32(pixel.blueComponent * 255))
            }
        }
    }
    #expect(colors.count > 8, "the capture looks blank")

    // A window it opens later (the About panel) goes off screen too. It usually opens centered
    // on the app's screen, the off-screen display; when it opens on a physical display that shows
    // another Space (a full-screen app), it waits there, unseen, until it can be moved.
    #expect(pressAboutItem(of: pid))
    let opened = ContinuousClock.now
    func appWindows() -> [(id: CGWindowID, bounds: CGRect, onScreen: Bool)] {
        ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid, entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
                  bounds.width > 100, bounds.height > 100 else { return nil }
            return (id, bounds, entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
    let known = Set(windows.map(\.id))
    var opening = appWindows().filter { !known.contains($0.id) }
    for _ in 0..<60 where opening.isEmpty {
        try await Task.sleep(for: .milliseconds(50))
        opening = appWindows().filter { !known.contains($0.id) }
    }
    #expect(!opening.isEmpty, "the About panel never opened")
    try await Task.sleep(for: .milliseconds(300))
    for window in appWindows() where window.onScreen {
        #expect(!OffscreenDisplay.isVisible(window.bounds), "window \(window.id) at \(window.bounds)")
    }
    for window in hider.windows(pid: pid) {
        #expect(!OffscreenDisplay.isVisible(window.frame), "\(window.title ?? "") at \(window.frame)")
    }
    if let stranded = appWindows().first(where: { !known.contains($0.id) && !$0.onScreen }) {
        print("the new window \(stranded.id) waits on another Space at \(stranded.bounds)")
    }

    // It never took focus or the menu bar.
    #expect(!app.isActive)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != pid)
    #expect(NSWorkspace.shared.menuBarOwningApplication?.processIdentifier != pid)
    let frontmostNow = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if frontmostNow != frontmost {
        // Something else (not the shared app) became active meanwhile; worth seeing, not a failure.
        print("frontmost changed from pid \(frontmost ?? 0) to \(frontmostNow ?? 0) (not the shared app)")
    }

    // Nothing of it ever showed on a physical screen while it launched; a window it opened by
    // itself later may show for a moment (it fades in) before it is moved.
    let samples = sampler.stop().filter { $0.pid == pid && !$0.bounds.isEmpty && OffscreenDisplay.isVisible($0.bounds) }
    let atLaunch = samples.filter { $0.time <= launched }
    #expect(atLaunch.isEmpty, "visible while launching: \(atLaunch.map(\.bounds))")
    let afterOpening = samples.filter { $0.time >= opened }
    if let firstSeen = afterOpening.first?.time, let lastSeen = afterOpening.last?.time {
        #expect(lastSeen - firstSeen < .milliseconds(250), "the new window stayed visible for \(lastSeen - firstSeen)")
    }

    await hider.release(pid: pid)
    released = true
    #expect(app.isTerminated)
    #expect(OffscreenDisplay.liveDisplayIDs.isEmpty)
}

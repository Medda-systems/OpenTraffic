import AppKit
import ApplicationServices
import ScreenCaptureKit
import Testing
@testable import OpenTrafficCore

// Mac app sharing: launching an app so its windows stay off the user's screens (on OpenTraffic's
// virtual display) yet ScreenCaptureKit can capture them, without taking focus. The end-to-end
// tests need Accessibility and Screen Recording for the process running `swift test`, and skip
// without them (as on GitHub Actions). They share the Orbit fixture (Examples/macapp-orbit, built
// when missing) and take a MacAppFixtureTurn for the whole test, so they wait for other Mac app
// tests, including those of parallel `swift test` runs in other checkouts.

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

@Test func theDisplayKeepsClearOfOtherProcessesDisplays() {
    let size = CGSize(width: 1920, height: 1200)
    let screens = [CGRect(x: 0, y: 0, width: 1710, height: 1112)]
    // Another OpenTraffic process's display already sits at the first corner.
    let other = CGRect(origin: CGPoint(x: 1710, y: 1112), size: size)
    let origins = OffscreenDisplay.cornerOrigins(for: size, around: screens, avoiding: [other])
    #expect(!origins.isEmpty)
    #expect(!origins.contains(CGPoint(x: 1710, y: 1112)))
    for origin in origins { #expect(!other.intersects(CGRect(origin: origin, size: size))) }
}

@Test func aStuckWindowServerCallThrowsAndLaterCallsFailAtOnceUntilItReturns() async throws {
    let calls = WindowServerCalls(label: "se.medda.opentraffic.test-calls")
    #expect(try await calls.run("quick", timeout: .seconds(1)) { 42 } == 42)
    await #expect(throws: OffscreenDisplay.Failure.unavailable("no")) {
        try await calls.run("failing", timeout: .seconds(1)) { throw OffscreenDisplay.Failure.unavailable("no") }
    }

    let stuck = DispatchSemaphore(value: 0)
    let started = ContinuousClock.now
    await #expect(throws: OffscreenDisplay.Failure.timedOut("configuring")) {
        try await calls.run("configuring", timeout: .milliseconds(100)) { stuck.wait() }
    }
    #expect(ContinuousClock.now - started < .seconds(1), "the caller waited for the stuck call")
    // Nothing queues behind the stuck call.
    let next = ContinuousClock.now
    await #expect(throws: OffscreenDisplay.Failure.windowServerNotResponding("configuring")) {
        try await calls.run("listing", timeout: .seconds(1)) { 1 }
    }
    #expect(ContinuousClock.now - next < .milliseconds(100))

    // Once it returns, calls go through again.
    stuck.signal()
    var answer: Int?
    for _ in 0..<50 where answer == nil {
        answer = try? await calls.run("listing", timeout: .seconds(1)) { 7 }
        if answer == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(answer == 7)
}

// MARK: The cross-process fixture lock

private func scratchLockPath() throws -> String {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opentraffic-turn-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("lock").path
}

/// A pid no process has: one that just exited.
private func exitedPID() throws -> pid_t {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

private func holdLock(_ path: String, as pid: pid_t) {
    mkdir(path, 0o700)
    try? "\(pid)\n".write(toFile: path + "/owner", atomically: false, encoding: .utf8)
}

@Test func theLockIsADirectoryWithTheHoldersPidKeptUntilTheProcessExits() async throws {
    let path = try scratchLockPath()
    let turn = MacAppFixtureTurn(lockPath: path)
    try await turn.acquire()
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
    #expect(turn.holder() == getpid() && turn.holdsLock)
    turn.release()
    // The next test of this process takes the turn at once; the lock stays with the process.
    #expect(turn.holder() == getpid())
    let again = ContinuousClock.now
    try await turn.acquire()
    #expect(ContinuousClock.now - again < .milliseconds(100))
    turn.release()
    turn.releaseLock()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func anotherProcesssLockIsWaitedForUntilItsHolderExits() async throws {
    let path = try scratchLockPath()
    // launchd (pid 1) is alive and never releases: the stand-in for another `swift test` run.
    holdLock(path, as: 1)
    let turn = MacAppFixtureTurn(lockPath: path)
    let taken = Task { try await turn.acquire() }
    try await Task.sleep(for: .milliseconds(400))
    #expect(turn.holder() == 1, "took a live holder's lock")
    // The other run exits (or dies) without removing it: the lock is broken.
    try? "\(try exitedPID())\n".write(toFile: path + "/owner", atomically: false, encoding: .utf8)
    try await taken.value
    #expect(turn.holder() == getpid())
    turn.release()
    turn.releaseLock()
}

@Test func aLockUntouchedForFiveMinutesIsBroken() async throws {
    let path = try scratchLockPath()
    holdLock(path, as: 1)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-MacAppFixtureTurn.staleAge - 10)], ofItemAtPath: path)
    let turn = MacAppFixtureTurn(lockPath: path)
    let started = ContinuousClock.now
    try await turn.acquire()
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(turn.holder() == getpid())
    turn.release()
    turn.releaseLock()
}

@Test func theHolderKeepsItsLockFresh() async throws {
    let path = try scratchLockPath()
    let turn = MacAppFixtureTurn(lockPath: path, heartbeat: 0.1)
    try await turn.acquire()
    turn.release()
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-MacAppFixtureTurn.staleAge - 10)], ofItemAtPath: path)
    // The heartbeat runs at utility priority: on a busy Mac it can come late.
    var age = TimeInterval.infinity
    for _ in 0..<100 where age > 5 {
        try await Task.sleep(for: .milliseconds(50))
        let touched = try #require(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        age = Date().timeIntervalSince(touched)
    }
    #expect(age < 5, "the lock wasn't touched")
    turn.releaseLock()
}

/// A ScreenCaptureKit call with a deadline, tried once more if it times out. A request can be lost
/// for good when replayd drops its connection (seen with two full `swift test` runs at once): without
/// a deadline the test, and the fixture turn it holds, would wait forever, and Swift Testing's time
/// limit can't end an await that ignores cancellation.
private func screenCaptureKit<T>(_ call: @escaping @Sendable () async throws -> T) async throws -> T {
    do {
        return try await WindowCapture.within(.seconds(10)) { WindowCapture.Unchecked(value: try await call()) }.value
    } catch WindowCaptureError.timedOut {
        print("a ScreenCaptureKit call took over 10 s; trying once more")
        return try await WindowCapture.within(.seconds(10)) { WindowCapture.Unchecked(value: try await call()) }.value
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

// The time limits allow for waiting for the turn: behind every other Mac app test of this run, and
// for a parallel run to finish.
@MainActor
@Test(.enabled(if: mayCapture, "Accessibility and Screen Recording for the test runner"), .timeLimit(.minutes(10)))
func aLaunchedAppStaysOffScreenUnfocusedAndCapturable() async throws {
    try await MacAppFixtureTurn.shared.acquire()
    defer { MacAppFixtureTurn.shared.release() }
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let sampler = WindowSampler()
    let orbit = try await OrbitFixture.launch()
    let hider = orbit.hider
    let app = orbit.running
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
    let content = try await screenCaptureKit { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
    let listed = content.windows.filter { $0.owningApplication?.processID == pid }
    for window in windows {
        let match = listed.first { $0.windowID == window.id }
        #expect(match?.isOnScreen == true, "window \(window.id) (\(window.title ?? "untitled") at \(window.frame)) not listed on screen: \(match.map { "\($0.frame)" } ?? "not listed")")
    }
    let first = try #require(listed.first { $0.windowID == windows[0].id })
    let configuration = SCStreamConfiguration()
    configuration.width = Int(first.frame.width) * 2
    configuration.height = Int(first.frame.height) * 2
    let filter = WindowCapture.Unchecked(value: SCContentFilter(desktopIndependentWindow: first))
    let settings = WindowCapture.Unchecked(value: configuration)
    let image = try await screenCaptureKit { try await SCScreenshotManager.captureImage(contentFilter: filter.value, configuration: settings.value) }
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
    // The display stays for the next share in this process.
    #expect(OffscreenDisplay.liveDisplayIDs.count == 1)
}

/// The bug this guards against: a second virtual display in one process never came online, so the
/// second hidden launch showed the app on the user's screen. Each launch here is at least the second
/// in this process when another Mac app test ran first, and the second one always is.
@MainActor
@Test(.enabled(if: mayCapture, "Accessibility and Screen Recording for the test runner"), .timeLimit(.minutes(10)))
func aSecondHiddenLaunchInOneProcessStaysOffScreen() async throws {
    try await MacAppFixtureTurn.shared.acquire()
    defer { MacAppFixtureTurn.shared.release() }
    var displays: Set<CGDirectDisplayID> = []
    for round in 1...2 {
        let sampler = WindowSampler()
        let orbit = try await OrbitFixture.launch()
        let pid = orbit.pid
        do {
            try await Task.sleep(for: .milliseconds(500))
            let offscreen = try #require(orbit.hider.offscreenBounds)
            #expect(!OffscreenDisplay.isVisible(offscreen))
            let windows = orbit.hider.windows(pid: pid)
            #expect(!windows.isEmpty, "round \(round): no windows")
            for window in windows {
                #expect(!OffscreenDisplay.isVisible(window.frame), "round \(round): \(window.title ?? "") at \(window.frame)")
                #expect(offscreen.intersects(window.frame), "round \(round): not on the off-screen display")
            }
        } catch {
            await orbit.quit()
            throw error
        }
        await orbit.quit()
        let seen = sampler.stop().filter { $0.pid == pid && !$0.bounds.isEmpty && OffscreenDisplay.isVisible($0.bounds) }
        #expect(seen.isEmpty, "round \(round): visible on a physical screen at \(Set(seen.map { "\($0.bounds)" }))")
        displays.formUnion(OffscreenDisplay.liveDisplayIDs)
    }
    #expect(displays.count == 1, "one display per process, reused: \(displays)")
}

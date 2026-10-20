import AppKit
import Foundation
import os
import Testing
@testable import OpenTrafficCore

// The Mac app session. The first suite checks the pieces that need no permissions (the isolated
// copy, the home folder and preferences, the log, the records), as on GitHub Actions. The fixture
// suite runs whole sessions on the Orbit fixture and needs Accessibility and Screen Recording; it
// skips without them and takes MacAppFixtureTurn.

private typealias Proto = MirrorProtocol

@Suite("Mac app session pieces", .serialized)
struct MacAppSessionPieceTests {
    @Test func theCopyGetsItsOwnIdentifier() {
        let app = MacApp(name: "Orbit", bundle: URL(fileURLWithPath: "/tmp/Orbit.app"), bundleIdentifier: "se.medda.orbit", projectDirectory: nil, isRunning: false)
        #expect(MacAppSession.copyIdentifier(for: app) == "se.medda.orbit.opentraffic")
        var bare = app
        bare.bundleIdentifier = nil
        bare.name = "My App 2"
        #expect(MacAppSession.copyIdentifier(for: bare) == "se.medda.opentraffic.shared.my-app-2")
    }

    @Test func entitlementsThatNeedATeamAndTheSandboxAreDropped() {
        let (kept, dropped) = MacAppSession.sharedEntitlements([
            "com.apple.security.app-sandbox": true,
            "com.apple.security.network.client": true,
            "com.apple.security.get-task-allow": true,
            "com.apple.security.application-groups": ["TEAM.group"],
            "keychain-access-groups": ["TEAM.*"],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.application-identifier": "TEAM.se.medda.orbit",
        ])
        #expect(Set(kept.keys) == ["com.apple.security.network.client", "com.apple.security.get-task-allow"])
        #expect(dropped == ["com.apple.application-identifier", "com.apple.developer.icloud-services", "com.apple.security.app-sandbox",
                            "com.apple.security.application-groups", "keychain-access-groups"])
    }

    @Test func pointerMovesAreNotRecordedButEverythingThatChangesTheAppIs() {
        let window: Proto.WindowID = 1
        #expect(MacAppSession.isRecorded(.act(.init(window: window, key: "/Window:/Button:Add", action: .press))))
        #expect(MacAppSession.isRecorded(.text(.init(window: window, text: "a"))))
        #expect(MacAppSession.isRecorded(.key(.init(window: window, code: .enter))))
        #expect(MacAppSession.isRecorded(.setText(.init(window: window, key: "k", value: "v"))))
        #expect(MacAppSession.isRecorded(.pointer(.init(window: window, kind: .down, x: 1, y: 2))))
        #expect(!MacAppSession.isRecorded(.pointer(.init(window: window, kind: .move, x: 1, y: 2))))
        #expect(MacAppSession.isRecorded(.menuAction(.init(path: ["Orders", "Mark All as Shipped"]))))
        #expect(!MacAppSession.isRecorded(.viewport(.init(w: 800, h: 600, appearance: nil))))
        #expect(!MacAppSession.isRecorded(.requestControl))
    }

    @Test func theRingKeepsTheLastItems() {
        let ring = Ring<Int>(limit: 3)
        for value in 1...5 { ring.append(value) }
        #expect(ring.items == [3, 4, 5])
    }

    @Test func theCopyIsSignedAgainWithTheKeptEntitlementsAndTheOriginalIsUntouched() throws {
        let scratch = try Scratch()
        let original = try makeStubApp(in: scratch.url, entitlements: [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.network.client": true,
            "keychain-access-groups": ["ABCDE12345.se.medda.stub"],
        ])
        let before = try Data(contentsOf: original.appendingPathComponent("Contents/Info.plist"))
        let copy = scratch.url.appendingPathComponent("session/app/Stub.app")

        let prepared = try MacAppSession.makeIsolatedCopy(of: original, at: copy, bundleIdentifier: "se.medda.stub.opentraffic")

        #expect(prepared.wasSandboxed)
        #expect(prepared.warnings.count == 1 && prepared.warnings[0].contains("keychain-access-groups"))
        #expect(Bundle(url: copy)?.bundleIdentifier == "se.medda.stub.opentraffic")
        #expect(try Data(contentsOf: original.appendingPathComponent("Contents/Info.plist")) == before)
        #expect(Bundle(url: original)?.bundleIdentifier == "se.medda.stub")
        let entitlements = MacAppSession.entitlements(of: copy)
        #expect(Set(entitlements.keys) == ["com.apple.security.network.client"])
        #expect(codesignVerifies(copy))
        // Copied again (a rebuild) over the old copy.
        _ = try MacAppSession.makeIsolatedCopy(of: original, at: copy, bundleIdentifier: "se.medda.stub.opentraffic")
        #expect(codesignVerifies(copy))
    }

    @Test func copiedDataComesFromTheRealHomeAndPreferencesGoToTheCopysDomain() async throws {
        let scratch = try Scratch()
        let realHome = scratch.url.appendingPathComponent("real-home")
        let identifier = "se.medda.opentraffic.sessiontest"
        let copyIdentifier = identifier + ".opentraffic"
        await removeDomains([identifier, copyIdentifier], waitingForCfprefsd: false)
        let realData = realHome.appendingPathComponent("Library/Application Support/Stub")
        try FileManager.default.createDirectory(at: realData, withIntermediateDirectories: true)
        try Data("orders".utf8).write(to: realData.appendingPathComponent("orders.json"))
        let byIdentifier = realHome.appendingPathComponent("Library/Application Support/\(identifier)")
        try FileManager.default.createDirectory(at: byIdentifier, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: byIdentifier.appendingPathComponent("state"))
        CFPreferencesSetAppValue("theme" as CFString, "dark" as CFString, identifier as CFString)
        CFPreferencesAppSynchronize(identifier as CFString)
        let app = MacApp(name: "Stub", bundle: scratch.url.appendingPathComponent("Stub.app"), bundleIdentifier: identifier, projectDirectory: nil, isRunning: false)

        let home = scratch.url.appendingPathComponent("session/home")
        let warnings = try MacAppSession.prepareHome(home, data: .copy, app: app, copyIdentifier: copyIdentifier, realHome: realHome.path, sandboxed: false)
        #expect(warnings.isEmpty)
        #expect(try String(contentsOf: home.appendingPathComponent("Library/Application Support/Stub/orders.json"), encoding: .utf8) == "orders")
        #expect(try String(contentsOf: home.appendingPathComponent("Library/Application Support/\(identifier)/state"), encoding: .utf8) == "cache")
        #expect(CFPreferencesCopyAppValue("theme" as CFString, copyIdentifier as CFString) as? String == "dark")

        // The copy writes; the original doesn't change.
        try Data("changed".utf8).write(to: home.appendingPathComponent("Library/Application Support/Stub/orders.json"))
        CFPreferencesSetAppValue("theme" as CFString, "light" as CFString, copyIdentifier as CFString)
        CFPreferencesAppSynchronize(copyIdentifier as CFString)
        #expect(try String(contentsOf: realData.appendingPathComponent("orders.json"), encoding: .utf8) == "orders")
        #expect(CFPreferencesCopyAppValue("theme" as CFString, identifier as CFString) as? String == "dark")

        // Empty: nothing copied, and the copy's leftover preferences are gone.
        let empty = scratch.url.appendingPathComponent("session2/home")
        #expect(try MacAppSession.prepareHome(empty, data: .empty, app: app, copyIdentifier: copyIdentifier, realHome: realHome.path, sandboxed: false).isEmpty)
        #expect(FileManager.default.fileExists(atPath: empty.appendingPathComponent("Library/Application Support").path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: empty.appendingPathComponent("Library/Application Support").path)).isEmpty)
        #expect(CFPreferencesCopyAppValue("theme" as CFString, copyIdentifier as CFString) == nil)

        // Only ever the copy's own domain is removed.
        MacAppSession.removePreferences(identifier, realHome: ElectronSandbox.realHomeDirectory)
        #expect(CFPreferencesCopyAppValue("theme" as CFString, identifier as CFString) as? String == "dark")
        await removeDomains([identifier, copyIdentifier], waitingForCfprefsd: true)
    }

    @Test func theLogFollowsAFileAnotherProcessAppendsTo() async throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let tail = try LogTail(url: file) { line in lines.withLock { $0.append(line) } }
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "echo first >> \"$0\"; sleep 0.2; printf 'second\\nthird' >> \"$0\"", file.path]
        try writer.run()
        writer.waitUntilExit()
        let deadline = ContinuousClock.now + .seconds(3)
        while lines.withLock({ $0.count }) < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(lines.withLock { $0 } == ["first", "second"])
        tail.finish()
        #expect(lines.withLock { $0 } == ["first", "second", "third"])
    }

    @Test func failuresBecomeMessagesAndPermissions() {
        #expect(MacAppSession.failure(MacAppWindowHider.Failure.notTrusted, name: "Orbit") == .permission(.accessibility))
        #expect(MacAppSession.failure(AccessibilityTreeError.notTrusted, name: "Orbit") == .permission(.accessibility))
        #expect(MacAppSession.failure(WindowCaptureError.notPermitted, name: "Orbit") == .permission(.screenRecording))
        #expect(MacAppSession.failure(MirrorServerError.noWindow, name: "Orbit") == .failed("Orbit has no window to show."))
        let stuck = MacAppSession.failure(OffscreenDisplay.Failure.timedOut("making the display"), name: "Orbit")
        #expect(stuck.localizedDescription.contains("window server isn't answering"))
        #expect(MacAppSessionError.permission(.screenRecording).localizedDescription.contains("Screen & System Audio Recording"))
        #expect(MacAppSession.Permission.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"))
    }

    @Test func aSessionThatNeverStartedCannotRestart() async {
        let app = MacApp(name: "Stub", bundle: URL(fileURLWithPath: "/nonexistent/Stub.app"), bundleIdentifier: "se.medda.stub", projectDirectory: nil, isRunning: false)
        let session = await MacAppSession(options: .init(app: app, data: .empty, assets: sessionAssets,
                                                         sessionDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        await #expect(throws: MacAppSessionError.stopped) { try await session.restart() }
        await session.stop()
        #expect(await session.state == .stopped)
    }
}

// MARK: - Whole sessions on the Orbit fixture

@MainActor
@Suite("Mac app session on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .macAppFixtureTurn, .timeLimit(.minutes(10)))
struct MacAppSessionFixtureTests {
    @Test func aSessionServesTheIsolatedCopyAndStopLeavesNothing() async throws {
        let realData = RealOrbitData()
        let sampler = WindowSampler()
        let session = try await startOrbitSession()
        let pid = try #require(session.pid)
        let sessionFolder = session.sessionDirectory
        do {
            let port = try #require(session.port)
            #expect(session.state == .running)

            // The isolated copy: its own bundle, identifier and home folder.
            let running = try #require(NSRunningApplication(processIdentifier: pid))
            #expect(running.bundleIdentifier == "se.medda.orbit.opentraffic")
            #expect(running.bundleURL?.resolvingSymlinksInPath().path.hasPrefix(sessionFolder.resolvingSymlinksInPath().path) == true)
            let environment = OrbitFixture.run("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"])
            #expect(environment.contains("CFFIXED_USER_HOME=\(session.homeDirectory.path)"))
            #expect(environment.contains("-ApplePersistenceIgnoreState YES"))
            // Off screen and in the background.
            #expect(!session.windows.isEmpty)
            #expect(session.windows.allSatisfy { !OffscreenDisplay.isVisible($0.frame) })
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != pid)

            // The server answers with hello (one window), its tree and frames.
            let viewer = SessionViewer(port: port)
            defer { viewer.close() }
            let hello = try #require(await viewer.first(within: .seconds(10)) { $0.hello != nil }?.item.hello)
            #expect(hello.app.name == "Orbit" && hello.windows.count == 1)
            #expect(await viewer.first(within: .seconds(10)) { $0.tree?.nodes.contains { $0.role == "AXButton" } == true } != nil)
            let frame = try #require(await viewer.first(within: .seconds(10)) { $0.frame?.full == true }?.item.frame)
            #expect(await viewer.first(within: .seconds(5)) { $0.tile?.seq == frame.seq } != nil)
            #expect(session.viewerCount == 1)

            // The app's own output reaches the log (its os_log lines, as in Xcode).
            let deadline = ContinuousClock.now + .seconds(5)
            while !session.recentLog.contains(where: { $0.source == .app }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(session.recentLog.contains { $0.source == .app })
            print("MacAppSession fixture: log sample:\n" + session.recentLog.prefix(8).map { "  [\($0.source.rawValue)] \($0.text.prefix(160))" }.joined(separator: "\n"))
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
        let seen = sampler.stop().filter { $0.pid == pid && !$0.bounds.isEmpty && OffscreenDisplay.isVisible($0.bounds) }
        #expect(seen.isEmpty, "visible on a physical screen at \(Set(seen.map { "\($0.bounds)" }))")
        #expect(session.state == .stopped)
        #expect(!MacAppSession.isAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: sessionFolder.path))
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        #expect(!windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid })
        #expect(CFPreferencesCopyKeyList("se.medda.orbit.opentraffic" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) == nil)
        let library = URL(fileURLWithPath: ElectronSandbox.realHomeDirectory).appendingPathComponent("Library")
        for leftover in ["Preferences/se.medda.orbit.opentraffic.plist", "Saved Application State/se.medda.orbit.opentraffic.savedState",
                         "Caches/se.medda.orbit.opentraffic", "HTTPStorages/se.medda.orbit.opentraffic"] {
            #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(leftover).path), "left behind: ~/Library/\(leftover)")
        }
        #expect(realData.unchanged(), "the real Orbit's data changed")
        // cfprefsd writes the emptied domain back to its file some seconds later; the session deletes it again.
        try await Task.sleep(for: .seconds(12))
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("Preferences/se.medda.orbit.opentraffic.plist").path),
                "cfprefsd's late copy of the emptied preferences is left behind")
    }

    @Test func restartKeepsThePortAndResetDataBringsBackTheOrders() async throws {
        let realData = RealOrbitData()
        let sampler = WindowSampler()
        let session = try await startOrbitSession()
        var copies = Set([session.pid].compactMap { $0 })
        do {
            let port = try #require(session.port)
            let viewer = SessionViewer(port: port)
            defer { viewer.close() }
            let hello = try #require(await viewer.first(within: .seconds(10)) { $0.hello != nil })
            let firstBoot = try #require(hello.item.hello?.boot)
            let initialRows = try await rowCount(viewer, after: hello.index)

            // A viewer adds an order.
            let tree = try #require(viewer.items.compactMap(\.item.tree).last)
            let field = try #require(newCustomerField(in: tree.nodes))
            try await viewer.send(.setText(.init(window: tree.window, key: field.key, value: "Ada Lovelace")))
            #expect(await viewer.first(within: .seconds(5)) { $0.tree?.nodes.first { $0.key == field.key }?.value == "Ada Lovelace" } != nil)
            try await viewer.send(.key(.init(window: tree.window, code: .enter)))
            #expect(await viewer.first(within: .seconds(5)) { $0.tree.map { rows(in: $0) } == initialRows + 1 } != nil)
            let recorded = session.recentActions
            #expect(recorded.map(\.message.type) == ["setText", "key"])
            #expect(recorded.allSatisfy { $0.boot == firstBoot })

            // Reset: the same port, a new launch, the initial orders.
            let mark = viewer.items.count
            let oldPid = session.pid
            try await session.resetData()
            copies.formUnion([session.pid].compactMap { $0 })
            #expect(session.port == port && session.state == .running && session.pid != oldPid)
            let status = await viewer.first(after: mark, within: .seconds(5)) { $0.status?.state == .restarting }
            #expect(status != nil)
            let again = try #require(await viewer.first(after: mark, within: .seconds(15)) { $0.hello.map { $0.boot != firstBoot } == true })
            #expect(try await rowCount(viewer, after: again.index) == initialRows)

            // Restart: the same port again, another launch.
            let mark2 = viewer.items.count
            let secondBoot = try #require(again.item.hello?.boot)
            try await session.restart()
            copies.formUnion([session.pid].compactMap { $0 })
            #expect(session.port == port && session.state == .running)
            #expect(copies.count == 3)
            #expect(await viewer.first(after: mark2, within: .seconds(15)) { $0.hello.map { $0.boot != secondBoot } == true } != nil)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
        // No launch (start, reset, restart) showed a window on the user's screens.
        let seen = sampler.stop().filter { copies.contains($0.pid) && !$0.bounds.isEmpty && OffscreenDisplay.isVisible($0.bounds) }
        #expect(seen.isEmpty, "visible on a physical screen at \(Set(seen.map { "\($0.bounds)" }))")
        #expect(realData.unchanged(), "the real Orbit's data changed")
        await removeDomains(["se.medda.orbit.opentraffic"], waitingForCfprefsd: true)
    }

    @Test func anAppThatQuitsIsRestartedOnceAndThenLeftCrashed() async throws {
        let session = try await startOrbitSession()
        do {
            let port = try #require(session.port)
            let viewer = SessionViewer(port: port)
            defer { viewer.close() }
            let hello = try #require(await viewer.first(within: .seconds(10)) { $0.hello != nil })
            let firstPid = try #require(session.pid)

            kill(firstPid, SIGKILL)
            #expect(await viewer.first(after: hello.index, within: .seconds(5)) { $0.status?.state == .crashed } != nil)
            let relaunched = try #require(await viewer.first(after: hello.index + 1, within: .seconds(20)) { $0.hello != nil })
            #expect(relaunched.item.hello?.boot != hello.item.hello?.boot)
            try await waitUntil(.seconds(5)) { session.state == .running && session.pid != nil }
            #expect(session.port == port)
            let secondPid = try #require(session.pid)
            #expect(secondPid != firstPid)

            // Quitting again right away: no second automatic restart.
            kill(secondPid, SIGKILL)
            try await waitUntil(.seconds(5)) { if case .crashed = session.state { true } else { false } }
            try await Task.sleep(for: .seconds(2))
            #expect(session.pid == nil)
            if case .crashed = session.state {} else { Issue.record("state is \(session.state), not crashed") }
            #expect(await viewer.first(after: relaunched.index, within: .seconds(2)) { $0.status?.state == .crashed } != nil)
            #expect(session.recentLog.contains { $0.text.contains("quit unexpectedly") })

            // A restart by hand still works.
            try await session.restart()
            #expect(session.state == .running && session.port == port)
        } catch {
            await session.stop()
            throw error
        }
        let lastPid = session.pid
        await session.stop()
        if let lastPid { #expect(!MacAppSession.isAlive(lastPid)) }
        await removeDomains(["se.medda.orbit.opentraffic"], waitingForCfprefsd: true)
    }

    @Test func leftoversOfASessionNobodyStoppedAreQuitAndDeleted() async throws {
        // As if OpenTraffic had crashed with a share running: its copy still runs, its folder is there.
        let session = try await startOrbitSession(restartsAutomatically: false)
        let pid = try #require(session.pid)
        let folder = session.sessionDirectory
        await MacAppSession.removeLeftovers(in: fixtureSessions)
        #expect(!MacAppSession.isAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try await waitUntil(.seconds(5)) { if case .crashed = session.state { true } else { false } }
        await session.stop()
        #expect(session.state == .stopped)
        await removeDomains(["se.medda.orbit.opentraffic"], waitingForCfprefsd: true)
    }
}

// MARK: - Helpers

private let sessionAssets = MirrorServer.Assets(page: Data("<!doctype html><title>Orbit</title>".utf8), script: Data(), style: Data())

/// Session folders of the fixture tests: in this checkout's .build, so a leftover from an
/// interrupted run is found (and its copy quit) by the next run of this checkout only.
private let fixtureSessions = OrbitFixture.repository.appendingPathComponent(".build/macapp-session-tests", isDirectory: true)

@MainActor
private func startOrbitSession(restartsAutomatically: Bool = true) async throws -> MacAppSession {
    try OrbitFixture.buildIfNeeded()
    await MacAppSession.removeLeftovers(in: fixtureSessions)
    let app = MacApp(name: "Orbit", bundle: OrbitFixture.app, bundleIdentifier: OrbitFixture.bundleIdentifier, projectDirectory: OrbitFixture.folder, isRunning: false)
    let session = MacAppSession(options: .init(app: app, data: .copy, assets: sessionAssets,
                                               sessionDirectory: fixtureSessions.appendingPathComponent(UUID().uuidString, isDirectory: true),
                                               restartsAutomatically: restartsAutomatically))
    let started = ContinuousClock.now
    try await session.start()
    print("MacAppSession fixture: started in \(ContinuousClock.now - started)")
    return session
}

@MainActor
private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw FixtureError("condition not met within \(timeout)") }
        try await Task.sleep(for: .milliseconds(25))
    }
}

/// The real Orbit's preferences and Application Support folder (the Electron fixture's), as they were.
private struct RealOrbitData {
    static let paths = ["Library/Preferences/se.medda.orbit.plist", "Library/Application Support/Orbit"].map {
        URL(fileURLWithPath: ElectronSandbox.realHomeDirectory).appendingPathComponent($0).path
    }
    let before = RealOrbitData.state()

    static func state() -> [String] {
        var lines: [String] = []
        let fm = FileManager.default
        for path in paths {
            var all = [path]
            if let enumerator = fm.enumerator(atPath: path) { all += enumerator.compactMap { $0 as? String }.map { path + "/" + $0 } }
            for item in all.sorted() {
                let attributes = try? fm.attributesOfItem(atPath: item)
                let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
                lines.append("\(item) \(date) \(size)")
            }
        }
        return lines
    }

    func unchanged() -> Bool { RealOrbitData.state() == before }
}

/// Orbit's order rows in a tree.
private func rows(in tree: Proto.Tree) -> Int { tree.nodes.filter { $0.role == "AXRow" }.count }

/// The number of rows once a tree after `index` lists them (Orbit fills its list a moment after launch).
private func rowCount(_ viewer: SessionViewer, after index: Int) async throws -> Int {
    let found = try #require(await viewer.first(after: index, within: .seconds(15)) { ($0.tree.map { rows(in: $0) } ?? 0) > 0 })
    return rows(in: found.item.tree!)
}

/// The New customer field: the text field in the sidebar, below the list.
private func newCustomerField(in nodes: [Proto.AXNode]) -> Proto.AXNode? {
    guard let list = nodes.first(where: { $0.role == "AXOutline" || $0.role == "AXTable" }) else { return nil }
    return nodes.first { $0.role == "AXTextField" && $0.x < list.x + list.w && $0.y >= list.y + list.h - 1 }
}

/// A viewer, as the browser page connects: everything it received, in order.
private final class SessionViewer: @unchecked Sendable {
    enum Item: Sendable {
        case message(Proto.ServerMessage)
        case tile(Proto.Tile)

        var hello: Proto.Hello? { if case .message(.hello(let h)) = self { h } else { nil } }
        var tree: Proto.Tree? { if case .message(.tree(let t)) = self { t } else { nil } }
        var frame: Proto.FrameHeader? { if case .message(.frame(let f)) = self { f } else { nil } }
        var status: Proto.Status? { if case .message(.status(let s)) = self { s } else { nil } }
        var tile: Proto.Tile? { if case .tile(let t) = self { t } else { nil } }
    }

    private let task: URLSessionWebSocketTask
    private let received = OSAllocatedUnfairLock(initialState: [Item]())

    init(port: Int) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)\(Proto.webSocketPath)")!)
        task.maximumMessageSize = 64 << 20
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let message = try? Proto.ServerMessage.decode(text) { received.withLock { $0.append(.message(message)) } }
                receive()
            case .success(.data(let data)):
                if let tile = try? Proto.Tile(decoding: data) { received.withLock { $0.append(.tile(tile)) } }
                receive()
            case .success:
                receive()
            case .failure:
                break
            }
        }
    }

    var items: [(index: Int, item: Item)] { received.withLock { Array($0.enumerated()).map { ($0.offset, $0.element) } } }

    /// The first item at or after `index` that matches, waiting up to `timeout`.
    func first(after index: Int = 0, within timeout: Duration = .seconds(5), _ match: @Sendable (Item) -> Bool) async -> (index: Int, item: Item)? {
        let deadline = ContinuousClock.now + timeout
        repeat {
            let items = received.withLock { $0 }
            if index < items.count, let found = items[index...].firstIndex(where: match) { return (found, items[found]) }
            try? await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        return nil
    }

    func send(_ message: Proto.ClientMessage) async throws { try await task.send(.string(message.jsonString())) }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// A temporary folder, deleted when the test ends.
private final class Scratch {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macapp-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A minimal .app (its executable is a copy of /usr/bin/true), signed ad hoc with `entitlements`.
private func makeStubApp(in folder: URL, entitlements: [String: Any]) throws -> URL {
    let app = folder.appendingPathComponent("Stub.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Stub").path)
    let info: [String: Any] = ["CFBundleExecutable": "Stub", "CFBundleIdentifier": "se.medda.stub", "CFBundleName": "Stub", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let file = folder.appendingPathComponent("stub.entitlements")
    try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", "--entitlements", file.path, app.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    guard sign.terminationStatus == 0 else { throw FixtureError("couldn't sign the stub app") }
    return app
}

private func codesignVerifies(_ bundle: URL) -> Bool {
    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    verify.arguments = ["--verify", "--strict", bundle.path]
    verify.standardError = FileHandle.nullDevice
    verify.standardOutput = FileHandle.nullDevice
    guard (try? verify.run()) != nil else { return false }
    verify.waitUntilExit()
    return verify.terminationStatus == 0
}

/// Removes test defaults domains and their files. cfprefsd writes an emptied domain back to its
/// file some seconds later (7.5 s measured); `waitingForCfprefsd` waits for that (up to 15 s) and
/// deletes it again, so no empty file is left in ~/Library/Preferences.
private func removeDomains(_ identifiers: [String], waitingForCfprefsd: Bool) async {
    var files: [String] = []
    for identifier in identifiers {
        let domain = identifier as CFString
        if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String], !keys.isEmpty {
            CFPreferencesSetMultiple(nil, keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesAppSynchronize(domain)
        }
        let file = ElectronSandbox.realHomeDirectory + "/Library/Preferences/\(identifier).plist"
        try? FileManager.default.removeItem(atPath: file)
        files.append(file)
    }
    guard waitingForCfprefsd else { return }
    var waiting = Set(files)
    let deadline = ContinuousClock.now + .seconds(15)
    while !waiting.isEmpty, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(250))
        for file in waiting where FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.removeItem(atPath: file)
            waiting.remove(file)
        }
    }
}

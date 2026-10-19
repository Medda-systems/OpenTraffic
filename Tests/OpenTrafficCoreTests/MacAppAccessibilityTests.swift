import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import OpenTrafficCore

// The accessibility bridge: its pure rules without any permission, then the real thing against the
// Orbit fixture (Examples/macapp-orbit), launched in its own process. The fixture tests skip when this
// process is not trusted for Accessibility (GitHub Actions); they build dist/Orbit.app when it's missing
// and always quit the copy they launched. Each takes a `MacAppFixtureTurn`, so no other test drives
// a Mac app meanwhile. They activate Orbit: AppKit leaves windows that are not on the
// active Space out of the accessibility tree entirely, and a copy launched from a terminal behind a
// full-screen app opens on another Space.

@Suite("Mac app accessibility rules")
struct MacAppAccessibilityRuleTests {
    @Test func labelPrefersDescriptionThenTitleThenStaticText() {
        #expect(AccessibilityTree.label(role: "AXButton", description: "Add", title: "Add Order", value: nil) == "Add")
        #expect(AccessibilityTree.label(role: "AXButton", description: "", title: "Add Order", value: nil) == "Add Order")
        #expect(AccessibilityTree.label(role: "AXStaticText", description: nil, title: nil, value: "12 open") == "12 open")
        // Only static text takes its label from the value: a text field's text is its value, not its name.
        #expect(AccessibilityTree.label(role: "AXTextField", description: nil, title: nil, value: "Ada") == "")
        #expect(AccessibilityTree.label(role: "AXGroup", description: nil, title: nil, value: nil) == "")
    }

    @Test func valuesAreStrings() {
        #expect(AccessibilityTree.valueString(role: "AXCheckBox", value: NSNumber(value: 1)) == "1")
        #expect(AccessibilityTree.valueString(role: "AXCheckBox", value: NSNumber(value: 0)) == "0")
        #expect(AccessibilityTree.valueString(role: "AXRadioButton", value: kCFBooleanTrue) == "1")
        #expect(AccessibilityTree.valueString(role: "AXIncrementor", value: NSNumber(value: 3)) == "3")
        #expect(AccessibilityTree.valueString(role: "AXSlider", value: NSNumber(value: 0.25)) == "0.25")
        #expect(AccessibilityTree.valueString(role: "AXTextField", value: "Ada") == "Ada")
        #expect(AccessibilityTree.valueString(role: "AXTextField", value: nil) == nil)
        #expect(AccessibilityTree.valueString(role: "AXGroup", value: [1, 2]) == nil)
        // A secret is never mirrored, not even as bullets that give away its length.
        #expect(AccessibilityTree.valueString(role: "AXSecureTextField", value: "••••") == nil)
    }

    @Test func secureFieldsKeepTheirRoleWhateverAppKitCallsThem() {
        #expect(AccessibilityTree.role("AXTextField", subrole: "AXSecureTextField") == "AXSecureTextField")
        #expect(AccessibilityTree.role("AXTextField", subrole: "AXSearchField") == "AXTextField")
        #expect(AccessibilityTree.role("AXButton", subrole: nil) == "AXButton")
    }

    @Test func framesOutOfSightAreZero() {
        let viewport = CGRect(x: 14, y: 110, width: 302, height: 380)
        let visible = CGRect(x: 14, y: 120, width: 287, height: 24)
        #expect(AccessibilityTree.visibleFrame(visible, clip: viewport) == visible)
        // Partly visible keeps its real frame; the viewer clips it like the pixels are clipped.
        let partly = CGRect(x: 14, y: 480, width: 287, height: 24)
        #expect(AccessibilityTree.visibleFrame(partly, clip: viewport) == partly)
        #expect(AccessibilityTree.visibleFrame(CGRect(x: 14, y: 872, width: 287, height: 24), clip: viewport) == .zero)
        #expect(AccessibilityTree.visibleFrame(CGRect(x: 301, y: 110, width: 0, height: 0), clip: viewport) == .zero)
        #expect(AccessibilityTree.visibleFrame(visible, clip: .null) == .zero)
        // Only a real frame wholly outside is scrolled away; its contents are not read.
        #expect(AccessibilityTree.isScrolledAway(CGRect(x: 14, y: 872, width: 287, height: 24), clip: viewport))
        #expect(!AccessibilityTree.isScrolledAway(partly, clip: viewport))
        #expect(!AccessibilityTree.isScrolledAway(CGRect(x: 0, y: 1074, width: 0, height: 0), clip: viewport))
    }

    @Test func onlyProtocolActionsInProtocolOrder() {
        let actions = AccessibilityTree.actions(["AXShowMenu", "AXRaise", "AXPress", "AXScrollToVisible", "AXIncrement"])
        #expect(actions == [.press, .increment, .showMenu, .scrollToVisible])
        #expect(AccessibilityTree.actions(["AXRaise", "AXPick"]).isEmpty)
    }

    @Test func hashFollowsContent() {
        let button = MirrorProtocol.AXNode(key: "/Window:/Button:Add", role: "AXButton", label: "Add", x: 1, y: 2, w: 3, h: 4, depth: 1, actions: [.press])
        var pressed = button
        pressed.enabled = false
        #expect(AXSnapshot.hash([button]) == AXSnapshot.hash([button]))
        #expect(AXSnapshot.hash([button]) != AXSnapshot.hash([pressed]))
        #expect(AXSnapshot.hash([button]).count == 16)
        let snapshot = AXSnapshot(windowNumber: 7, title: "", frame: .zero, nodes: [button])
        #expect(snapshot.tree(window: 1) == MirrorProtocol.Tree(window: 1, v: snapshot.v, nodes: [button]))
    }

    @Test func refusesItsOwnProcess() {
        #expect(throws: AccessibilityTreeError.ownProcess) { try AccessibilityTree(pid: getpid()) }
    }
}

@Suite("Mac app accessibility on the Orbit fixture", .serialized, .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"))
struct MacAppAccessibilityFixtureTests {
    @Test func snapshotListsTheControls() async throws {
        await MacAppFixtureTurn.shared.acquire()
        defer { MacAppFixtureTurn.shared.release() }
        let orbit = try OrbitFixture.launch()
        defer { orbit.quit() }
        let tree = try AccessibilityTree(pid: orbit.pid)
        let snapshot = try await orbit.mainSnapshot(tree)

        let root = try #require(snapshot.nodes.first)
        #expect(root.key == "/Window:" && root.role == "AXWindow" && root.depth == 0 && root.x == 0 && root.y == 0)
        #expect(snapshot.title == "Orbit Orders")
        // Keys are unique and follow the protocol's rule.
        #expect(Set(snapshot.nodes.map(\.key)).count == snapshot.nodes.count)
        for node in snapshot.nodes.dropFirst() {
            #expect(node.key.hasPrefix("/Window:/"))
            #expect(node.key.split(separator: "/", omittingEmptySubsequences: true).count == node.depth + 1)
        }

        for title in ["Add Order", "Edit Address…", "Mark as Shipped", "Delete Order"] {
            let button = try #require(snapshot.nodes.first { $0.role == "AXButton" && $0.label == title }, "button \(title)")
            #expect(button.actions.contains(.press))
            #expect(button.key.hasSuffix("/Button:\(title)"))
            #expect(button.w > 0 && button.h > 0)
        }
        let group = try #require(snapshot.nodes.first { $0.role == "AXRadioGroup" })
        let radios = snapshot.nodes.filter { $0.role == "AXRadioButton" && $0.key.hasPrefix(group.key + "/") }
        #expect(radios.map(\.label) == ["All", "Open", "Shipped"])
        #expect(radios.map(\.value) == ["1", "0", "0"])
        let stepper = try #require(snapshot.nodes.first { $0.role == "AXIncrementor" })
        #expect(stepper.actions.contains(.increment) && stepper.actions.contains(.decrement))
        let express = try #require(snapshot.nodes.first { $0.role == "AXCheckBox" && $0.label == "Express shipping" })
        #expect(express.value == "0" || express.value == "1")
        let fields = snapshot.nodes.filter { $0.role == "AXTextField" }
        #expect(fields.count >= 2)
        #expect(fields.allSatisfy { $0.value != nil })
        // The Door code SecureField: AppKit calls it an AXTextField with the subrole AXSecureTextField.
        let secure = try #require(snapshot.nodes.first { $0.role == "AXSecureTextField" })
        #expect(secure.value == nil)
        #expect(secure.key.hasSuffix("/SecureTextField:"))

        // 30 rows, the ones scrolled out of view with a zero frame and without their contents, but with keys.
        let rows = snapshot.nodes.filter { $0.role == "AXRow" }
        #expect(rows.count == 30)
        #expect(rows.contains { $0.w > 0 } && rows.contains { $0.w == 0 && $0.h == 0 })
        for row in rows where row.w == 0 { #expect(!snapshot.nodes.contains { $0.key.hasPrefix(row.key + "/") }) }
        for row in rows where row.w > 0 { #expect(snapshot.nodes.contains { $0.key.hasPrefix(row.key + "/") && $0.role == "AXStaticText" }) }

        // Right after launch the List is still measuring its rows (a row may come into view); once the app
        // is idle, two snapshots are identical (same v), and no control or row changed its key meanwhile.
        var previous = snapshot, settled: AXSnapshot?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let next = try await tree.snapshot()
            if next.v == previous.v, next.nodes == previous.nodes { settled = next; break }
            previous = next
        }
        let stable = try #require(settled, "the tree never settled")
        let controls: Set<String> = ["AXButton", "AXRadioGroup", "AXRadioButton", "AXCheckBox", "AXIncrementor", "AXTextField", "AXSecureTextField", "AXRow"]
        func controlKeys(_ snapshot: AXSnapshot) -> [String] {
            snapshot.nodes.filter { controls.contains($0.role) && !$0.key.contains("/Row:") || $0.role == "AXRow" }.map(\.key)
        }
        #expect(controlKeys(stable) == controlKeys(snapshot))
    }

    @Test func actsOnCheckboxStepperAndSegmentedControl() async throws {
        await MacAppFixtureTurn.shared.acquire()
        defer { MacAppFixtureTurn.shared.release() }
        let orbit = try OrbitFixture.launch()
        defer { orbit.quit() }
        let tree = try AccessibilityTree(pid: orbit.pid)
        var snapshot = try await orbit.mainSnapshot(tree)

        // Checkbox: press flips its value.
        let express = try #require(snapshot.nodes.first { $0.role == "AXCheckBox" && $0.label == "Express shipping" })
        try await tree.perform(key: express.key, action: .press)
        snapshot = try await orbit.waitFor(tree) { $0.node(express.key)?.value != express.value }
        #expect(snapshot.node(express.key)?.value == (express.value == "1" ? "0" : "1"))

        // Stepper: increment and decrement change the quantity shown next to it.
        let stepper = try #require(snapshot.nodes.first { $0.role == "AXIncrementor" })
        let quantity = try #require(Self.quantity(in: snapshot))
        try await tree.perform(key: stepper.key, action: .increment)
        snapshot = try await orbit.waitFor(tree) { Self.quantity(in: $0) == quantity + 1 }
        #expect(Self.quantity(in: snapshot) == quantity + 1)
        try await tree.perform(key: stepper.key, action: .decrement)
        snapshot = try await orbit.waitFor(tree) { Self.quantity(in: $0) == quantity }
        #expect(Self.quantity(in: snapshot) == quantity)

        // Segmented control: pressing Shipped selects it.
        let shipped = try #require(snapshot.nodes.first { $0.role == "AXRadioButton" && $0.label == "Shipped" })
        try await tree.perform(key: shipped.key, action: .press)
        snapshot = try await orbit.waitFor(tree) { $0.node(shipped.key)?.value == "1" }
        #expect(snapshot.node(shipped.key)?.value == "1")
        #expect(snapshot.nodes.first { $0.role == "AXRadioButton" && $0.label == "All" }?.value == "0")

        // A key that isn't in the tree is an error, not a silent no-op.
        await #expect(throws: AccessibilityTreeError.unknownKey("/Window:/Button:Nope")) {
            try await tree.perform(key: "/Window:/Button:Nope", action: .press)
        }
    }

    @Test func focusThenTypeThenPressAddsAnOrder() async throws {
        await MacAppFixtureTurn.shared.acquire()
        defer { MacAppFixtureTurn.shared.release() }
        let orbit = try OrbitFixture.launch()
        defer { orbit.quit() }
        let tree = try AccessibilityTree(pid: orbit.pid)
        var snapshot = try await orbit.mainSnapshot(tree)
        let rowsBefore = snapshot.nodes.filter { $0.role == "AXRow" }.count

        let field = try #require(snapshot.nodes.first { $0.role == "AXTextField" && $0.value == "" && $0.y > snapshot.nodes.first { $0.role == "AXRadioGroup" }!.y && $0.x < 330 })
        let add = try #require(snapshot.nodes.first { $0.role == "AXButton" && $0.label == "Add Order" })
        #expect(!add.enabled)

        try await tree.focus(key: field.key)
        snapshot = try await orbit.waitFor(tree) { $0.node(field.key)?.focused == true }
        #expect(snapshot.node(field.key)?.focused == true)

        // Typing is the input synthesis bridge's job; this stub posts key events to the app.
        TypingStub.type("Ada Tester", to: orbit.pid)
        snapshot = try await orbit.waitFor(tree) { $0.node(add.key)?.enabled == true }
        #expect(snapshot.node(field.key)?.value == "Ada Tester")
        #expect(snapshot.node(add.key)?.enabled == true)

        try await tree.perform(key: add.key, action: .press)
        snapshot = try await orbit.waitFor(tree) { $0.nodes.contains { $0.role == "AXStaticText" && $0.label == "Ada Tester" } }
        #expect(snapshot.nodes.filter { $0.role == "AXRow" }.count == rowsBefore + 1)
        #expect(snapshot.nodes.contains { $0.role == "AXStaticText" && $0.label == "Ada Tester" })
    }

    @Test func changeStreamDeliversWithin500ms() async throws {
        await MacAppFixtureTurn.shared.acquire()
        defer { MacAppFixtureTurn.shared.release() }
        let orbit = try OrbitFixture.launch()
        defer { orbit.quit() }
        let tree = try AccessibilityTree(pid: orbit.pid)
        let snapshot = try await orbit.mainSnapshot(tree)
        let express = try #require(snapshot.nodes.first { $0.role == "AXCheckBox" && $0.label == "Express shipping" })
        let shipped = try #require(snapshot.nodes.first { $0.role == "AXRadioButton" && $0.label == "Shipped" })
        let note = try #require(snapshot.nodes.first { $0.role == "AXTextField" && $0.x > 330 })

        let changes = tree.changes()
        await tree.settle()
        let received = ChangeLog()
        let listener = Task { for await change in changes { received.append(change) } }
        defer { listener.cancel() }

        // A press shows up as a change within 500 ms.
        received.clear()
        let pressed = Date()
        try await tree.perform(key: express.key, action: .press)
        let first = try #require(await received.first(within: 0.5), "no change within 500 ms of a press")
        #expect(first.date.timeIntervalSince(pressed) < 0.5)

        // Focus, value and layout changes all arrive.
        received.clear()
        try await tree.focus(key: note.key)
        #expect(await received.first(within: 2) { $0.kind == .focus } != nil, "focus change")
        received.clear()
        try await tree.perform(key: shipped.key, action: .press)
        #expect(await received.first(within: 2) { $0.kind == .value || $0.kind == .layout || $0.kind == .selection || $0.kind == .destroyed } != nil, "tree change after a filter")

        // A new window is announced: Orders > Show Statistics (⌥⌘I) through the menu bar.
        received.clear()
        try orbit.openStatistics()
        #expect(await received.first(within: 3) { $0.kind == .windowCreated || $0.kind == .focusedWindow || $0.kind == .mainWindow } != nil, "window change")
        let windows = try await tree.windows()
        #expect(windows.contains { $0.title == "Statistics" })
        #expect(windows.allSatisfy { $0.number != nil })
    }

    private static func quantity(in snapshot: AXSnapshot) -> Int? {
        let text = snapshot.nodes.lazy.compactMap { node -> String? in
            for candidate in [node.label, node.value ?? ""] where candidate.hasPrefix("Quantity: ") { return candidate }
            return nil
        }.first
        return text.flatMap { Int($0.dropFirst("Quantity: ".count)) }
    }
}

// MARK: - The fixture

/// A running copy of dist/Orbit.app, started for one test.
private struct OrbitFixture {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let folder = repository.appendingPathComponent("Examples/macapp-orbit")
    static let app = folder.appendingPathComponent("dist/Orbit.app")
    static let executable = app.appendingPathComponent("Contents/MacOS/Orbit")
    private static let buildLock = NSLock()

    let process: Process
    var pid: pid_t { process.processIdentifier }

    /// Builds the fixture when it's missing, quits leftover copies of it, and starts a fresh one with
    /// only its main window.
    static func launch() throws -> OrbitFixture {
        try buildIfNeeded()
        killLeftovers()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return OrbitFixture(process: process)
    }

    static func buildIfNeeded() throws {
        try buildLock.withLock {
            guard !FileManager.default.isExecutableFile(atPath: executable.path) else { return }
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/bin/sh")
            build.arguments = [folder.appendingPathComponent("package.sh").path]
            build.standardOutput = FileHandle.nullDevice
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0 else { throw FixtureError.buildFailed(build.terminationStatus) }
        }
    }

    /// Kills copies of this fixture (this path only) left by an earlier, interrupted run: only those
    /// started before this test process, never a copy another test of this run launched.
    static func killLeftovers() {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", executable.path]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return }
        pgrep.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ourStart = startTime(of: getpid())
        for pid in output.split(separator: "\n").compactMap({ pid_t($0) }) where pid != getpid() {
            guard let started = startTime(of: pid), let ourStart, started < ourStart else { continue }
            kill(pid, SIGKILL)
        }
    }

    private static func startTime(of pid: pid_t) -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }

    func quit() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(pid, SIGKILL); process.waitUntilExit() }
    }

    /// The main window's snapshot, once the window is up and an order is selected.
    func mainSnapshot(_ tree: AccessibilityTree) async throws -> AXSnapshot {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, try await !tree.windows().contains(where: { $0.title == "Orbit Orders" }) {
            guard process.isRunning else { throw FixtureError.exited }
            NSRunningApplication(processIdentifier: pid)?.activate()
            try await Task.sleep(for: .milliseconds(250))
        }
        return try await waitFor(tree, timeout: 5) { snapshot in
            snapshot.title == "Orbit Orders" && snapshot.nodes.contains { $0.role == "AXCheckBox" && $0.label == "Express shipping" }
        }
    }

    /// Snapshots the main window until `condition` holds (or the time is up; then the last one).
    func waitFor(_ tree: AccessibilityTree, timeout: TimeInterval = 3, _ condition: (AXSnapshot) -> Bool) async throws -> AXSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last: AXSnapshot?
        while Date() < deadline {
            guard process.isRunning else { throw FixtureError.exited }
            if let snapshot = try? await tree.snapshot(window: .title("Orbit Orders")) {
                if condition(snapshot) { return snapshot }
                last = snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let last else { throw FixtureError.noWindow }
        return last
    }

    /// Orders > Show Statistics, through the app's menu bar (outside the window tree).
    func openStatistics() throws {
        let application = AXUIElementCreateApplication(pid)
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { throw FixtureError.noMenu }
        func children(_ element: AnyObject) -> [AXUIElement] {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element as! AXUIElement, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func title(_ element: AXUIElement) -> String {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return value as? String ?? ""
        }
        guard let orders = children(bar).first(where: { title($0) == "Orders" }),
              let menu = children(orders).first,
              let item = children(menu).first(where: { title($0) == "Show Statistics" }) else { throw FixtureError.noMenu }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    enum FixtureError: Error { case buildFailed(Int32), exited, noWindow, noMenu }
}

private func < (a: timeval, b: timeval) -> Bool { (a.tv_sec, a.tv_usec) < (b.tv_sec, b.tv_usec) }

/// Stands in for the input synthesis bridge: posts the key events for some text to one process.
private enum TypingStub {
    static func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for unit in text.utf16 {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                var character = unit
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event.postToPid(pid)
            }
            usleep(8_000)
        }
    }
}

/// The changes a test has seen so far.
private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [AXChange] = []

    func append(_ change: AXChange) { lock.withLock { changes.append(change) } }
    func clear() { lock.withLock { changes.removeAll() } }

    /// The first change seen (since the last `clear`) that matches, waiting up to `seconds`.
    func first(within seconds: TimeInterval, where match: @escaping (AXChange) -> Bool = { _ in true }) async -> AXChange? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = lock.withLock({ changes.first(where: match) }) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return lock.withLock { changes.first(where: match) }
    }
}

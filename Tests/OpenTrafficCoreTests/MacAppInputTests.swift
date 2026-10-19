import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import OpenTrafficCore

// Input synthesis: the pure mappings run everywhere; the fixture tests launch the Orbit fixture
// (building it with Examples/macapp-orbit/package.sh when dist/Orbit.app is missing) without
// activating it, move its window as far off screen as macOS allows, drive it only through
// InputSynthesizer, and read frames and results through AccessibilityTree snapshots. They need
// Accessibility permission (CGEvent posting and AX reads) and skip without it, as on GitHub Actions,
// and they take MacAppFixtureTurn like every test that drives a real app.
//
// They don't launch through MacAppWindowHider: a second off-screen display made in the same test
// process never comes online, so only the first hidden launch per process stays off screen.

private typealias Key = MirrorProtocol.KeyCode

@Suite struct InputSynthesisMappingTests {
    @Test func namedKeysUseMacVirtualKeyCodes() {
        let expected: [Key: CGKeyCode] = [
            .enter: 0x24, .escape: 0x35, .tab: 0x30, .backspace: 0x33, .delete: 0x75,
            .arrowUp: 0x7E, .arrowDown: 0x7D, .arrowLeft: 0x7B, .arrowRight: 0x7C, .space: 0x31,
        ]
        for key in Key.allCases { #expect(InputSynthesizer.virtualKey(for: key) == expected[key], "\(key)") }
        #expect(InputSynthesizer.keyFlags(for: .arrowLeft).contains(.maskSecondaryFn))
        #expect(InputSynthesizer.keyFlags(for: .arrowLeft).contains(.maskNumericPad))
        #expect(InputSynthesizer.keyFlags(for: .enter).isEmpty)
    }

    @Test func modifiersBecomeEventFlags() {
        #expect(InputSynthesizer.flags(for: []).isEmpty)
        let all = InputSynthesizer.flags(for: [.cmd, .shift, .alt, .ctrl])
        #expect(all.contains([.maskCommand, .maskShift, .maskAlternate, .maskControl]))
        #expect(InputSynthesizer.flags(for: [.shift]) == .maskShift)
    }

    @Test func windowRelativePointsBecomeGlobal() {
        let window = InputSynthesizer.Window(id: 7, frame: CGRect(x: -1200, y: -1400, width: 860, height: 540))
        #expect(window.global(CGPoint(x: 10, y: 20)) == CGPoint(x: -1190, y: -1380))
        #expect(window.global(.zero) == CGPoint(x: -1200, y: -1400))
    }

    @Test func wheelDeltasFollowTheBrowserSense() {
        // Browser deltaY > 0 scrolls down; CG wheel1 > 0 scrolls up.
        #expect(InputSynthesizer.wheelDeltas(dx: 0, dy: 120) == (vertical: -120, horizontal: 0))
        #expect(InputSynthesizer.wheelDeltas(dx: -30.4, dy: -10.6) == (vertical: 11, horizontal: 30))
        #expect(InputSynthesizer.wheelDeltas(dx: 0, dy: 1e12).vertical == Int32.min)
    }

    @Test func textIsTypedInChunksOfTwentyWithoutSplittingCharacters() {
        #expect(InputSynthesizer.chunks(of: "").isEmpty)
        let long = String(repeating: "a", count: 45)
        #expect(InputSynthesizer.chunks(of: long).map(\.count) == [20, 20, 5])
        // 19 ASCII + an emoji (2 UTF-16 units) must not straddle a chunk boundary.
        let text = String(repeating: "b", count: 19) + "🚀" + "c"
        let chunks = InputSynthesizer.chunks(of: text)
        #expect(chunks.map(\.count) == [19, 3])
        #expect(chunks.allSatisfy { $0.count <= InputSynthesizer.textChunkLength })
        #expect(String(utf16CodeUnits: chunks.joined().map { $0 }, count: text.utf16.count) == text)
        // A flag is one Character of 4 UTF-16 units: kept whole.
        #expect(InputSynthesizer.chunks(of: String(repeating: "x", count: 18) + "🇸🇪").map(\.count) == [18, 4])
    }
}

@MainActor
@Suite("Input synthesis on the Orbit fixture", .serialized, .enabled(if: InputSynthesizer.isPermitted, "needs Accessibility permission"))
struct MacAppInputTests {
    @Test func clickSelectsARow() async throws {
        try await withOrbit { orbit, input in
            var snapshot = try await orbit.snapshot()
            let row = try #require(Orbit.row(named: "Alan Turing", in: snapshot))
            #expect(!row.selected)
            try input.click(at: row.center, in: try orbit.window(snapshot))
            snapshot = try await orbit.waitFor { $0.node(row.key)?.selected == true }
            #expect(snapshot.node(row.key)?.selected == true)
        }
    }

    @Test func typingAndEnterOrAddOrderAddRows() async throws {
        try await withOrbit { orbit, input in
            var snapshot = try await orbit.snapshot()
            let window = try orbit.window(snapshot)
            let rowsBefore = Orbit.rows(in: snapshot).count
            let field = try #require(Orbit.newCustomerField(in: snapshot))
            let add = try #require(snapshot.nodes.first { $0.role == "AXButton" && $0.label == "Add Order" })

            try input.click(at: field.center, in: window)
            snapshot = try await orbit.waitFor { $0.node(field.key)?.focused == true }
            #expect(snapshot.node(field.key)?.focused == true)
            let long = "Rosalind Franklin, structural biology"   // longer than one chunk
            try input.type(text: long)
            snapshot = try await orbit.waitFor { $0.node(field.key)?.value == long }
            #expect(snapshot.node(field.key)?.value == long)
            try input.press(key: .enter)
            // The new order is selected (its row may be scrolled out of view): its name shows in the detail pane.
            snapshot = try await orbit.waitFor { Orbit.rows(in: $0).count == rowsBefore + 1 && Orbit.shows(long, in: $0) }
            #expect(Orbit.rows(in: snapshot).count == rowsBefore + 1)
            #expect(Orbit.shows(long, in: snapshot))

            try input.click(at: field.center, in: window)
            try input.type(text: "Mary Jackson")
            // Add Order is enabled once the binding has the text; a click before that does nothing.
            snapshot = try await orbit.waitFor { $0.node(field.key)?.value == "Mary Jackson" && $0.node(add.key)?.enabled == true }
            #expect(snapshot.node(add.key)?.enabled == true)
            try input.click(at: add.center, in: window)
            snapshot = try await orbit.waitFor { Orbit.rows(in: $0).count == rowsBefore + 2 && Orbit.shows("Mary Jackson", in: $0) }
            #expect(Orbit.rows(in: snapshot).count == rowsBefore + 2)
            #expect(Orbit.shows("Mary Jackson", in: snapshot))
        }
    }

    @Test func replaceTextSetsASwiftUITextFieldsValue() async throws {
        try await withOrbit { orbit, input in
            var snapshot = try await orbit.snapshot()
            let window = try orbit.window(snapshot)
            // The selected order's note, in the detail pane.
            let note = try #require(snapshot.nodes.first { $0.role == "AXTextField" && $0.value == "Gift wrap" })

            for text in ["Leave at the door, ring twice", "Back door", ""] {
                try await input.replaceText(in: window, field: note.frame, with: text)
                snapshot = try await orbit.waitFor { $0.node(note.key)?.value == text }
                // The whole previous value is replaced, not appended to.
                #expect(snapshot.node(note.key)?.value == text)
            }
        }
    }

    @Test func wheelScrollsTheLongList() async throws {
        try await withOrbit { orbit, input in
            var snapshot = try await orbit.snapshot()
            let window = try orbit.window(snapshot)
            let first = try #require(Orbit.firstVisibleRowName(in: snapshot))
            let list = try #require(snapshot.nodes.first { $0.role == "AXOutline" || $0.role == "AXTable" })

            try input.move(to: list.center, in: window)
            for _ in 0..<6 {
                try input.send(MirrorProtocol.Pointer(window: window.id, kind: .wheel, x: list.center.x, y: list.center.y, dy: 80), in: window)
            }
            snapshot = try await orbit.waitFor { Orbit.firstVisibleRowName(in: $0).map { $0 != first } ?? false }
            #expect(Orbit.firstVisibleRowName(in: snapshot) != first)
        }
    }
}

/// Takes the fixture turn, launches Orbit, runs the body, checks that Orbit was never activated and
/// the host's frontmost app didn't change, and quits Orbit even when the body throws.
@MainActor
private func withOrbit(_ body: (Orbit, InputSynthesizer) async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    await MacAppFixtureTurn.shared.acquire()
    defer { MacAppFixtureTurn.shared.release() }
    let orbit = try await Orbit.launch()
    do {
        let host = try #require(Orbit.hostFrontmost())
        try await body(orbit, InputSynthesizer(pid: orbit.pid))
        orbit.expectNeverActivated(host: host, sourceLocation: sourceLocation)
    } catch {
        orbit.quit()
        throw error
    }
    orbit.quit()
}

// MARK: - The fixture, driven from outside

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtureDirectory = repository.appendingPathComponent("Examples/macapp-orbit")
private let fixtureExecutable = fixtureDirectory.appendingPathComponent("dist/Orbit.app/Contents/MacOS/Orbit")

private extension MirrorProtocol.AXNode {
    /// Window-relative frame and centre, as InputSynthesizer takes them.
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private struct Orbit {
    let process: Process
    let tree: AccessibilityTree
    var pid: pid_t { process.processIdentifier }

    /// Starts the fixture's executable directly (it doesn't activate: the host's frontmost app keeps
    /// focus), waits for its main window and moves it off screen.
    static func launch() async throws -> Orbit {
        try buildIfNeeded()
        quitLeftovers()
        let process = Process()
        process.executableURL = fixtureExecutable
        process.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let orbit: Orbit
        do {
            orbit = Orbit(process: process, tree: try AccessibilityTree(pid: process.processIdentifier))
            // The main window, once its list has rows (AXWindows is empty while the window is on
            // another Space; the snapshot's .main goes through AXMainWindow, which still finds it).
            _ = try await orbit.waitFor(timeout: .seconds(15)) { $0.title == "Orbit Orders" && !rows(in: $0).isEmpty }
        } catch {
            process.terminate()
            throw error
        }
        orbit.moveOffScreen()
        try? await Task.sleep(for: .milliseconds(300))
        return orbit
    }

    func quit() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(pid, SIGKILL); process.waitUntilExit() }
    }

    /// As far off screen as macOS allows (it keeps a corner of the window on some display).
    private func moveOffScreen() {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMainWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        var offScreen = CGPoint(x: -20000, y: -20000)
        if let position = AXValueCreate(.cgPoint, &offScreen) {
            AXUIElementSetAttributeValue(value as! AXUIElement, kAXPositionAttribute as CFString, position)
        }
    }

    func snapshot() async throws -> AXSnapshot {
        try await waitFor { $0.title == "Orbit Orders" && !Self.rows(in: $0).isEmpty }
    }

    func window(_ snapshot: AXSnapshot) throws -> InputSynthesizer.Window {
        guard let window = InputSynthesizer.Window(snapshot) else { throw FixtureError("the snapshot has no window number") }
        return window
    }

    /// Snapshots the main window until `condition` holds, or returns the last one when time is up.
    func waitFor(timeout: Duration = .seconds(3), _ condition: (AXSnapshot) -> Bool) async throws -> AXSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var last: AXSnapshot?
        while clock.now < deadline {
            guard process.isRunning else { throw FixtureError("Orbit exited") }
            if let snapshot = try? await tree.snapshot(window: .main) {
                if condition(snapshot) { return snapshot }
                last = snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let last else { throw FixtureError("Orbit's main window didn't appear") }
        return last
    }

    static func rows(in snapshot: AXSnapshot) -> [MirrorProtocol.AXNode] { snapshot.nodes.filter { $0.role == "AXRow" } }

    /// The list row whose text is `name` (rows scrolled out of view have no contents).
    static func row(named name: String, in snapshot: AXSnapshot) -> MirrorProtocol.AXNode? {
        rows(in: snapshot).first { row in
            snapshot.nodes.contains { $0.key.hasPrefix(row.key + "/") && $0.role == "AXStaticText" && $0.label == name }
        }
    }

    /// Whether some text in the window reads `text`.
    static func shows(_ text: String, in snapshot: AXSnapshot) -> Bool {
        snapshot.nodes.contains { $0.role == "AXStaticText" && $0.label == text }
    }

    static func firstVisibleRowName(in snapshot: AXSnapshot) -> String? {
        guard let row = rows(in: snapshot).first(where: { $0.w > 0 && $0.h > 0 }) else { return nil }
        return snapshot.nodes.first { $0.key.hasPrefix(row.key + "/") && $0.role == "AXStaticText" }?.label
    }

    /// The New customer field: the text field in the sidebar, below the list.
    static func newCustomerField(in snapshot: AXSnapshot) -> MirrorProtocol.AXNode? {
        guard let list = snapshot.nodes.first(where: { $0.role == "AXOutline" || $0.role == "AXTable" }) else { return nil }
        return snapshot.nodes.first { $0.role == "AXTextField" && $0.x < list.x + list.w && $0.y >= list.y + list.h - 1 }
    }

    /// The pid of the app the host user is in, read live from LaunchServices (`lsappinfo front`).
    /// The system-wide AX query is only a fallback: it fails with cannotComplete whenever the
    /// frontmost app (Chrome, for one) doesn't answer.
    static func hostFrontmost() -> pid_t? {
        let asn = run("/usr/bin/lsappinfo", ["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !asn.isEmpty, let match = run("/usr/bin/lsappinfo", ["info", "-only", "pid", asn]).firstMatch(of: /pid"?\s*=\s*(\d+)/),
           let pid = pid_t(match.1) {
            return pid
        }
        var pid: pid_t = 0
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), AXUIElementGetPid(focused as! AXUIElement, &pid) == .success { return pid }
        return nil
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Orbit never became the active app and the host's frontmost app is the one from before.
    func expectNeverActivated(host: pid_t?, sourceLocation: SourceLocation = #_sourceLocation) {
        var frontmost: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, &frontmost)
        #expect(frontmost as? Bool != true, "Orbit was activated", sourceLocation: sourceLocation)
        let now = Self.hostFrontmost()
        #expect(now != pid, "Orbit became the frontmost app", sourceLocation: sourceLocation)
        #expect(now == host, "the host's frontmost app changed from \(Self.describe(host)) to \(Self.describe(now))", sourceLocation: sourceLocation)
    }

    static func describe(_ pid: pid_t?) -> String {
        guard let pid else { return "none" }
        return "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") (\(pid))"
    }

    /// Builds dist/Orbit.app once when it is missing.
    static func buildIfNeeded() throws {
        if FileManager.default.isExecutableFile(atPath: fixtureExecutable.path) { return }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = [fixtureDirectory.appendingPathComponent("package.sh").path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        build.environment = environment
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: fixtureExecutable.path) else {
            throw FixtureError("building the Orbit fixture failed (sh Examples/macapp-orbit/package.sh)")
        }
    }

    /// Kills copies of this checkout's fixture left by an earlier, interrupted run: matched by path
    /// (other checkouts' Orbits are left alone) and started before this test process, so the Orbit
    /// another suite (window hiding, accessibility) may be running right now is left alone too.
    static func quitLeftovers() {
        let escaped = fixtureExecutable.path.replacingOccurrences(of: #"[.^$*+?()\[\]{}|\\]"#, with: #"\\$0"#, options: .regularExpression)
        guard let testsStarted = startTime(of: getpid()) else { return }
        // The fixture itself, not commands that mention its path.
        for line in run("/usr/bin/pgrep", ["-f", "^\(escaped)( |$)"]).split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid != getpid(),
                  let started = startTime(of: pid), started < testsStarted else { continue }
            kill(pid, SIGKILL)
        }
    }

    private static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

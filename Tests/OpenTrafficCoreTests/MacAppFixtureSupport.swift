import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import os
import Testing
@testable import OpenTrafficCore

/// Tests that launch and drive a real Mac app, make the off-screen display or capture windows take
/// turns. They activate apps, watch which app is frontmost and which windows appear, quit fixture
/// copies, configure displays and talk to ScreenCaptureKit, so two at once disturb each other.
/// Take a turn for the whole test:
///
///     try await MacAppFixtureTurn.shared.acquire()
///     defer { MacAppFixtureTurn.shared.release() }
///
/// Within a process the turn passes from test to test (Swift Testing runs suites in parallel).
/// Across processes (parallel `swift test` runs from other checkouts) it is a directory made with
/// `mkdir` (atomic), `$TMPDIR/opentraffic-macapp-fixture.lock`, with the holder's pid inside, and a
/// process keeps it from its first such test until it exits: each test process keeps its virtual
/// display (and its ScreenCaptureKit connection) for life, and with two of those at once replayd
/// stalls for tens of seconds per capture and the display list slowed to 3.9 s (two full runs,
/// 20 October 2026), so a parallel run's Mac app tests wait until the first run has exited. Three
/// full runs making and removing displays at once hung the Mac's display system for hours on
/// 19 October.
///
/// The holder touches the lock every `heartbeat`; a lock whose holder has exited, or untouched for
/// `staleAge` (a frozen process), is broken. The lock is removed when the process exits normally.
final class MacAppFixtureTurn: @unchecked Sendable {
    static let shared = MacAppFixtureTurn(lockPath: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opentraffic-macapp-fixture.lock").path)

    /// A lock untouched for this long is taken to be left behind.
    static let staleAge: TimeInterval = 5 * 60
    /// How often a waiting process tries again.
    static let retryInterval: Duration = .milliseconds(50)

    let lockPath: String
    /// How often the holder touches the lock.
    let heartbeat: TimeInterval
    private var ownerPath: String { lockPath + "/owner" }

    private let lock = NSLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var heartbeatTimer: DispatchSourceTimer?

    init(lockPath: String, heartbeat: TimeInterval = 30) {
        self.lockPath = lockPath
        self.heartbeat = heartbeat
    }

    /// Waits until no other test of this process holds the turn and no other process holds the
    /// lock, then holds the turn (and the lock, until this process exits).
    func acquire() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if busy { waiting.append(continuation); return false }
                busy = true
                return true
            }
            if now { continuation.resume() }
        }
        guard !holdsLock else { return }
        do {
            try await takeLock()
        } catch {
            handOn()
            throw error
        }
        startHeartbeat()
        Self.removeAtExit(self)
    }

    /// Hands the turn to the next waiting test of this process. The cross-process lock stays with
    /// this process until it exits.
    func release() {
        handOn()
    }

    /// Whether this process holds the cross-process lock.
    var holdsLock: Bool { lock.withLock { heartbeatTimer != nil } }

    /// Gives the cross-process lock up now (tests of the lock; it is otherwise removed at exit).
    func releaseLock() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in defer { heartbeatTimer = nil }; return heartbeatTimer }
        timer?.cancel()
        if holder() == getpid() {
            unlink(ownerPath)
            rmdir(lockPath)
        }
    }

    /// Hands the in-process turn to the next waiting test.
    private func handOn() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiting.isEmpty { busy = false; return nil }
            return waiting.removeFirst()
        }
        next?.resume()
    }

    private func takeLock() async throws {
        let me = getpid()
        var announced: pid_t?
        while true {
            if mkdir(lockPath, 0o700) == 0 {
                try? "\(me)\n".write(toFile: ownerPath, atomically: false, encoding: .utf8)
                return
            }
            guard errno == EEXIST else { throw FixtureError("can't make \(lockPath): \(String(cString: strerror(errno)))") }
            let holder = self.holder()
            if holder == me { return }
            if isStale(holder: holder) {
                print("MacAppFixtureTurn: breaking the stale lock \(lockPath) (holder \(holder.map(String.init) ?? "unknown"))")
                breakLock(holder: holder)
                continue
            }
            if let holder, announced != holder {
                print("MacAppFixtureTurn: waiting for pid \(holder) (another swift test run) to exit before running Mac app tests")
                announced = holder
            }
            try await Task.sleep(for: Self.retryInterval)
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + heartbeat, repeating: heartbeat)
        let path = lockPath
        timer.setEventHandler { utimes(path, nil) }
        lock.withLock { heartbeatTimer = timer }
        timer.resume()
    }

    /// The pid written in the lock (nil while the holder is still writing it).
    func holder() -> pid_t? {
        guard let text = try? String(contentsOfFile: ownerPath, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isStale(holder: pid_t?) -> Bool {
        if let holder, kill(holder, 0) != 0, errno == ESRCH { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lockPath),
              let touched = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(touched) > Self.staleAge
    }

    /// Moves the stale lock aside (atomic) and deletes it. If another process took the lock in the
    /// meantime (what was moved has a different holder), it is put back.
    private func breakLock(holder: pid_t?) {
        let aside = lockPath + ".stale-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        guard rename(lockPath, aside) == 0 else { return }
        let moved = (try? String(contentsOfFile: aside + "/owner", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if moved != holder, rename(aside, lockPath) == 0 { return }
        try? FileManager.default.removeItem(atPath: aside)
    }

    // The locks this process holds, removed when it exits (a crash leaves them; the pid check breaks those).
    private static let held = OSAllocatedUnfairLock(initialState: (registered: false, turns: [MacAppFixtureTurn]()))

    private static func removeAtExit(_ turn: MacAppFixtureTurn) {
        let register = held.withLock { state -> Bool in
            state.turns.append(turn)
            defer { state.registered = true }
            return !state.registered
        }
        if register {
            atexit { MacAppFixtureTurn.held.withLock { $0.turns }.forEach { $0.releaseLock() } }
        }
    }
}

/// `.macAppFixtureTurn` on a suite or test: every test in it holds a MacAppFixtureTurn while it runs.
struct MacAppFixtureTurnTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard !test.isSuite else { return try await function() }
        try await MacAppFixtureTurn.shared.acquire()
        defer { MacAppFixtureTurn.shared.release() }
        try await function()
    }
}

extension Trait where Self == MacAppFixtureTurnTrait {
    static var macAppFixtureTurn: Self { Self() }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The Orbit fixture

/// A running copy of Examples/macapp-orbit/dist/Orbit.app, launched for one test through
/// MacAppWindowHider: hidden, never activated, its windows on the off-screen display (where the
/// accessibility tree reads every row, unlike windows parked far off screen, and nobody sees them).
@MainActor
struct OrbitFixture {
    nonisolated static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    nonisolated static let folder = repository.appendingPathComponent("Examples/macapp-orbit")
    nonisolated static let app = folder.appendingPathComponent("dist/Orbit.app")
    nonisolated static let executable = app.appendingPathComponent("Contents/MacOS/Orbit")
    nonisolated static let bundleIdentifier = "se.medda.orbit"

    /// Session folders for this checkout's fixture tests, in the temporary folder (per checkout, so
    /// a leftover from an interrupted run is found and quit by the next run of this checkout only).
    /// Not in `.build`: a checkout under Documents, Desktop or Downloads is behind macOS's folder
    /// privacy, and the launched copy (ad hoc signed, unknown to the system) is denied the launch log
    /// `open --stdout` makes it open there, so it never starts (LaunchServices error -10810).
    nonisolated static func sessions(_ name: String) -> URL {
        let checkout = Insecure.MD5.hash(data: Data(repository.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("opentraffic-\(name)-\(checkout)", isDirectory: true)
    }

    let running: NSRunningApplication
    let hider: MacAppWindowHider
    /// Its own home folder, for this launch only.
    let home: URL
    var pid: pid_t { running.processIdentifier }
    /// Whether the process is still there (NSRunningApplication learns of an exit a little later).
    var isRunning: Bool { kill(pid, 0) == 0 }

    /// Builds the fixture when it's missing, quits copies of it left by an interrupted run, and
    /// launches a fresh one with only its main window. Take a `MacAppFixtureTurn` first.
    ///
    /// It runs with a home folder of its own: Orbit saves its orders in Application Support, and a test
    /// must start with the 30 sample orders and never write to the user's Library.
    static func launch(hider: MacAppWindowHider = MacAppWindowHider()) async throws -> OrbitFixture {
        try buildIfNeeded()
        killLeftovers()
        // Homes of launches a test didn't quit go with them.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where old.hasPrefix("opentraffic-orbit-home-") {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(old))
        }
        let home = temporary.appendingPathComponent("opentraffic-orbit-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Its window sizes are saved in se.medda.orbit's preferences, which its home doesn't isolate: an
        // unreadable frame on the command line (it wins over the saved one) makes every launch start at
        // the default size, whatever an earlier test resized the window to.
        let frames = ["orders", "statistics"].flatMap { ["-NSWindow Frame \($0)-AppWindow-1", "default"] }
        let running = try await hider.launch(bundle: app, environment: ["HOME": home.path, "CFFIXED_USER_HOME": home.path],
                                             arguments: ["-ApplePersistenceIgnoreState", "YES"] + frames)
        return OrbitFixture(running: running, hider: hider, home: home)
    }

    /// Quits the copy and stops hiding it (the off-screen display stays for the next test).
    func quit() async {
        await hider.release(pid: pid)
        if isRunning {
            kill(pid, SIGKILL)
            for _ in 0..<40 where isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        }
        try? FileManager.default.removeItem(at: home)
    }

    nonisolated private static let buildLock = NSLock()

    /// Builds dist/Orbit.app once when it is missing.
    nonisolated static func buildIfNeeded() throws {
        try buildLock.withLock {
            if FileManager.default.isExecutableFile(atPath: executable.path) { return }
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/bin/sh")
            build.arguments = [folder.appendingPathComponent("package.sh").path]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            build.environment = environment
            build.standardOutput = FileHandle.nullDevice
            build.standardError = FileHandle.nullDevice
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw FixtureError("building the Orbit fixture failed (sh Examples/macapp-orbit/package.sh)")
            }
        }
    }

    /// Kills copies of this checkout's fixture left by an earlier, interrupted run: matched by path
    /// (other checkouts' Orbits are left alone) and started before this test process (a copy this
    /// run launched is quit by its own test).
    nonisolated static func killLeftovers() {
        let escaped = executable.path.replacingOccurrences(of: #"[.^$*+?()\[\]{}|\\]"#, with: #"\\$0"#, options: .regularExpression)
        guard let testsStarted = startTime(of: getpid()) else { return }
        // The fixture itself, not commands that mention its path.
        for line in run("/usr/bin/pgrep", ["-f", "^\(escaped)( |$)"]).split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid != getpid(),
                  let started = startTime(of: pid), started < testsStarted else { continue }
            kill(pid, SIGKILL)
        }
    }

    nonisolated static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) -> String {
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
}

/// Takes the fixture turn, launches Orbit hidden, runs the body, and quits Orbit (even when the
/// body throws) before giving the turn up.
@MainActor
func withOrbitFixture<T>(_ body: (OrbitFixture) async throws -> T) async throws -> T {
    try await MacAppFixtureTurn.shared.acquire()
    defer { MacAppFixtureTurn.shared.release() }
    let orbit = try await OrbitFixture.launch()
    do {
        let result = try await body(orbit)
        await orbit.quit()
        return result
    } catch {
        await orbit.quit()
        throw error
    }
}

// MARK: - Watching where windows are

/// Where the windows of processes that didn't exist when sampling began were, every few milliseconds.
final class WindowSampler: @unchecked Sendable {
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

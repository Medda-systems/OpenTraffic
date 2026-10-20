import AppKit
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import OpenTrafficCore

// Rebuilding a shared Mac app when its sources change. The first suites need no permissions and no
// display: how the build is worked out, builds run as real processes (small shell scripts), the
// source watcher's debounce, and the replay mapping, also through a MirrorServer over stub bridges
// across a relaunch. The fixture suite builds a copy of the Orbit fixture's sources, shares it,
// changes a label and checks the new build and the restored selection; it needs Accessibility and
// Screen Recording and takes MacAppFixtureTurn. A real Xcode project is built only when
// OPENTRAFFIC_XCODE_PROJECT names one (xcodebuild takes minutes).

private typealias Proto = MirrorProtocol

/// A temporary folder, deleted when released.
private final class BuildScratch: @unchecked Sendable {
    let url: URL
    init() throws {
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macapp-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path (/private/var/…), as `pwd` and FSEvents report it.
        url = URL(fileURLWithPath: realpath(made.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? made.path, isDirectory: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, _ text: String = "") throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private func app(_ bundle: URL, name: String = "Orbit", project: URL? = nil) -> MacApp {
    MacApp(name: name, bundle: bundle, bundleIdentifier: "se.medda.orbit", projectDirectory: project, isRunning: false)
}

// MARK: - Working out the build

/// A detected build as text (URLs of folders may or may not end in a slash).
private func kindPath(_ kind: MacAppBuild.Kind?) -> String? {
    switch kind {
    case .xcode(let container)?: "xcode " + container.path
    case .swiftPM(let script)?: "swiftPM " + (script?.path ?? "-")
    case nil: nil
    }
}

@Suite("Mac app build commands")
struct MacAppBuildCommandTests {
    @Test func anXcodeProjectBuildsWithXcodebuildAndAPackageWithSwiftBuild() throws {
        let scratch = try BuildScratch()
        let derived = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/Orbit-abc/Build/Products/Debug/Orbit.app")

        // Only an .xcodeproj.
        let xcode = try scratch.folder("xcode")
        try scratch.folder("xcode/Orbit.xcodeproj")
        #expect(kindPath(MacAppBuild.detect(project: xcode, bundle: derived)) == "xcode " + xcode.appendingPathComponent("Orbit.xcodeproj").path)

        // A workspace wins over the project (CocoaPods and friends build through it).
        try scratch.folder("xcode/Orbit.xcworkspace")
        #expect(kindPath(MacAppBuild.detect(project: xcode, bundle: derived)) == "xcode " + xcode.appendingPathComponent("Orbit.xcworkspace").path)

        // Several projects: the one named like the app.
        let several = try scratch.folder("several")
        try scratch.folder("several/Helper.xcodeproj")
        try scratch.folder("several/Orbit.xcodeproj")
        try scratch.folder("several/Zeta.xcodeproj")
        #expect(kindPath(MacAppBuild.detect(project: several, bundle: derived)) == "xcode " + several.appendingPathComponent("Orbit.xcodeproj").path)

        // A Swift package with its own packaging script (as the Orbit fixture).
        let package = try scratch.folder("package")
        try scratch.file("package/Package.swift", "// swift-tools-version: 6.0")
        let script = try scratch.file("package/package.sh", "#!/bin/sh")
        let dist = package.appendingPathComponent("dist/Orbit.app")
        #expect(kindPath(MacAppBuild.detect(project: package, bundle: dist)) == "swiftPM " + script.path)

        // A package that also has an Xcode project: the app's location decides.
        try scratch.folder("package/Orbit.xcodeproj")
        #expect(kindPath(MacAppBuild.detect(project: package, bundle: dist)) == "swiftPM " + script.path)
        #expect(kindPath(MacAppBuild.detect(project: package, bundle: derived)) == "xcode " + package.appendingPathComponent("Orbit.xcodeproj").path)

        // Nothing to build.
        let empty = try scratch.folder("empty")
        try scratch.file("empty/README.md", "hi")
        #expect(MacAppBuild.detect(project: empty, bundle: dist) == nil)
    }

    @Test func xcodebuildBuildsTheDiscoveredConfigurationIntoTheSameDerivedData() {
        let defaultRoot = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData")
        let debug = MacAppBuild.xcodeProduct(URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/Orbit-abc/Build/Products/Debug/Orbit.app"),
                                             defaultDerivedData: defaultRoot)
        #expect(debug.configuration == "Debug" && !debug.catalyst && debug.derivedData == nil)
        let catalyst = MacAppBuild.xcodeProduct(URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/Orbit-abc/Build/Products/Debug-maccatalyst/Orbit.app"),
                                                defaultDerivedData: defaultRoot)
        #expect(catalyst.configuration == "Debug" && catalyst.catalyst)
        let custom = MacAppBuild.xcodeProduct(URL(fileURLWithPath: "/Users/me/src/Orbit/build/dd/Build/Products/Beta/Orbit.app"),
                                              defaultDerivedData: defaultRoot)
        #expect(custom.configuration == "Beta" && custom.derivedData?.path == "/Users/me/src/Orbit/build/dd")
        let elsewhere = MacAppBuild.xcodeProduct(URL(fileURLWithPath: "/Users/me/src/Orbit/dist/Orbit.app"), defaultDerivedData: defaultRoot)
        #expect(elsewhere.configuration == "Debug" && elsewhere.derivedData == nil)

        let project = URL(fileURLWithPath: "/Users/me/src/Orbit/Orbit.xcodeproj")
        let steps = MacAppBuild.xcodeSteps(container: project, scheme: "Orbit", configuration: "Debug", catalyst: false, derivedData: nil)
        #expect(steps == [MacAppBuild.Step(executable: "/usr/bin/xcodebuild",
                                           arguments: ["-project", "Orbit.xcodeproj", "-scheme", "Orbit", "-configuration", "Debug",
                                                       "-destination", "platform=macOS", "build"],
                                           directory: URL(fileURLWithPath: "/Users/me/src/Orbit"))])
        #expect(steps[0].display == "xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination platform=macOS build")

        let workspace = URL(fileURLWithPath: "/Users/me/src/Orbit/Orbit Space.xcworkspace")
        let catalystSteps = MacAppBuild.xcodeSteps(container: workspace, scheme: "Orbit Mac", configuration: "Debug", catalyst: true,
                                                   derivedData: URL(fileURLWithPath: "/Users/me/src/Orbit/build/dd"))
        #expect(catalystSteps[0].arguments == ["-workspace", "Orbit Space.xcworkspace", "-scheme", "Orbit Mac", "-configuration", "Debug",
                                               "-destination", "platform=macOS,variant=Mac Catalyst", "-derivedDataPath", "/Users/me/src/Orbit/build/dd", "build"])
        #expect(catalystSteps[0].display.contains("-workspace 'Orbit Space.xcworkspace' -scheme 'Orbit Mac'"))
    }

    @Test func swiftPackagesBuildWithSwiftBuildThenTheirScript() {
        let project = URL(fileURLWithPath: "/Users/me/src/Orbit")
        let script = project.appendingPathComponent("package.sh")
        let steps = MacAppBuild.swiftPMSteps(project: project, bundle: project.appendingPathComponent("dist/Orbit.app"), script: script)
        #expect(steps == [
            MacAppBuild.Step(executable: "/usr/bin/swift", arguments: ["build", "-c", "debug"], directory: project),
            MacAppBuild.Step(executable: "/bin/sh", arguments: ["package.sh"], directory: project),
        ])
        let release = MacAppBuild.swiftPMSteps(project: project, bundle: project.appendingPathComponent(".build/arm64-apple-macosx/release/Orbit.app"), script: nil)
        #expect(release == [MacAppBuild.Step(executable: "/usr/bin/swift", arguments: ["build", "-c", "release"], directory: project)])
        #expect(MacAppBuild.Plan(project: project, kind: .swiftPM(script: script), steps: steps).summary == "swift build -c debug && sh package.sh")
    }

    @Test func theSchemeIsTheOneThatMakesTheApp() {
        let project = Data(#"{"project":{"configurations":["Debug","Release"],"name":"Orbit","schemes":["OrbitKit","Orbit","OrbitTests"],"targets":["Orbit"]}}"#.utf8)
        let workspace = Data(#"{"workspace":{"name":"Orbit","schemes":["Pods-Orbit","Orbit"]}}"#.utf8)
        #expect(MacAppBuild.schemes(fromListJSON: project) == ["OrbitKit", "Orbit", "OrbitTests"])
        #expect(MacAppBuild.schemes(fromListJSON: workspace) == ["Pods-Orbit", "Orbit"])
        #expect(MacAppBuild.schemes(fromListJSON: Data("not json".utf8)).isEmpty)

        #expect(MacAppBuild.scheme(among: ["OrbitKit", "Orbit", "OrbitTests"], appName: "Orbit", executable: "Orbit") == "Orbit")
        #expect(MacAppBuild.scheme(among: ["Orbit Mac", "Shared"], appName: "Orbit", executable: "orbit mac") == "Orbit Mac")
        #expect(MacAppBuild.scheme(among: ["AppTests", "App-Package", "Orders"], appName: "Orbit", executable: nil) == "Orders")
        #expect(MacAppBuild.scheme(among: ["AppTests"], appName: "Orbit", executable: nil) == "AppTests")
        #expect(MacAppBuild.scheme(among: [], appName: "Orbit", executable: nil) == nil)
    }

    @Test func aPackagePlanNeedsNoToolsAndOtherAppsAreRefused() async throws {
        let scratch = try BuildScratch()
        let project = try scratch.folder("orbit")
        try scratch.file("orbit/Package.swift", "// swift-tools-version: 6.0")
        let plan = try await MacAppBuild.plan(for: app(project.appendingPathComponent("dist/Orbit.app")), project: project)
        #expect(plan.kind == .swiftPM(script: nil))
        #expect(plan.summary == "swift build -c debug")

        await #expect(throws: MacAppBuild.Failure.noProject(scratch.url.path)) {
            try await MacAppBuild.plan(for: app(project.appendingPathComponent("dist/Orbit.app")), project: scratch.url)
        }
        let device = SimulatorDevice(udid: "0000", name: "iPhone 17", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0")
        let simulated = MacApp(name: "Orbit", bundle: project, bundleIdentifier: nil, projectDirectory: project, isRunning: true, runtime: .simulator(device))
        await #expect(throws: MacAppBuild.Failure.simulator) { try await MacAppBuild.plan(for: simulated, project: project) }
    }

    @Test func failedBuildsAreToldByTheirErrors() {
        let output = [
            "Compiling Orbit OrdersView.swift",
            "/Users/me/src/Orbit/Sources/Orbit/OrdersView.swift:12:9: error: cannot find 'Buton' in scope",
            "/Users/me/src/Orbit/Sources/Orbit/OrdersView.swift:12:9: error: cannot find 'Buton' in scope",
            "warning: something minor",
            "** BUILD FAILED **",
        ]
        #expect(MacAppBuild.failureLines(output) == ["/Users/me/src/Orbit/Sources/Orbit/OrdersView.swift:12:9: error: cannot find 'Buton' in scope"])
        #expect(MacAppBuild.failureLines(["a", "", "b", "c"]) == ["a", "b", "c"])
        // SwiftPM's own line comes after the compiler's, and the diagnostic drawing is left out.
        #expect(MacAppBuild.failureLines([
            "error: SwiftCompile normal arm64 /x/OrdersView.swift failed with a nonzero exit code.",
            "/x/OrdersView.swift:61:17: error: cannot find 'Buton' in scope",
            "   |                 `- error: cannot find 'Buton' in scope",
            "error: Build failed",
        ]) == ["/x/OrdersView.swift:61:17: error: cannot find 'Buton' in scope",
               "error: SwiftCompile normal arm64 /x/OrdersView.swift failed with a nonzero exit code.", "error: Build failed"])
        #expect(MacAppBuild.Outcome.failed(step: "swift build -c debug", lines: ["x.swift:1:1: error: oops"]).message
                == "The build failed (swift build -c debug): x.swift:1:1: error: oops")
        #expect(MacAppBuild.isNotable("** BUILD SUCCEEDED **"))
        #expect(MacAppBuild.isNotable("Build complete! (3.2s)"))
        #expect(MacAppBuild.isNotable("x.swift:1:1: error: oops"))
        #expect(!MacAppBuild.isNotable("[3/10] Compiling Orbit OrdersView.swift"))
        #expect(!MacAppBuild.isNotable("CompileSwift normal arm64 /x.swift"))
    }
}

// MARK: - Running builds (real processes, small scripts)

@Suite("Mac app build runs", .timeLimit(.minutes(2)))
struct MacAppBuildRunTests {
    private func plan(_ scratch: BuildScratch, _ scripts: [String]) throws -> MacAppBuild.Plan {
        let steps = try scripts.enumerated().map { index, text in
            try scratch.file("step\(index).sh", text)
            return MacAppBuild.Step(executable: "/bin/sh", arguments: ["step\(index).sh"], directory: scratch.url)
        }
        return MacAppBuild.Plan(project: scratch.url, kind: .swiftPM(script: nil), steps: steps)
    }

    @Test func stepsRunInTheProjectWithTheirOutputInTheLog() async throws {
        let scratch = try BuildScratch()
        let plan = try plan(scratch, ["echo compiling; echo to-stderr >&2; pwd > where.txt; echo \"node=${ELECTRON_RUN_AS_NODE:-unset}\"",
                                      "echo 'Build complete!'"])
        let log = scratch.url.appendingPathComponent("build.log")
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let outcome = await MacAppBuild.run(plan, log: log) { line in lines.withLock { $0.append(line) } }
        #expect(outcome == .succeeded)
        #expect(Set(lines.withLock { $0 }) == ["compiling", "to-stderr", "node=unset", "Build complete!"])
        let where_ = try String(contentsOf: scratch.url.appendingPathComponent("where.txt"), encoding: .utf8)
        #expect(where_.trimmingCharacters(in: .whitespacesAndNewlines) == scratch.url.path)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("$ sh step0.sh") && text.contains("compiling") && text.contains("$ sh step1.sh") && text.contains("Build complete!"))
    }

    @Test func aFailingStepStopsTheBuildWithItsErrors() async throws {
        let scratch = try BuildScratch()
        let plan = try plan(scratch, ["echo 'Orbit.swift:3:1: error: expected declaration' >&2; echo more; exit 1", "touch ran-second"])
        let outcome = await MacAppBuild.run(plan)
        #expect(outcome == .failed(step: "sh step0.sh", lines: ["Orbit.swift:3:1: error: expected declaration"]))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("ran-second").path))

        let missing = MacAppBuild.Plan(project: scratch.url, kind: .swiftPM(script: nil),
                                       steps: [.init(executable: "/nonexistent/tool", arguments: [], directory: scratch.url)])
        guard case .failed(_, let lines) = await MacAppBuild.run(missing) else { Issue.record("a missing tool should fail"); return }
        #expect(lines.first?.hasPrefix("Couldn't run /nonexistent/tool") == true)
    }

    @Test func aBuildThatTakesTooLongIsStoppedWithItsChildren() async throws {
        let scratch = try BuildScratch()
        // The script starts a child (as xcodebuild starts compilers) and both would run for a minute.
        let plan = try plan(scratch, ["sleep 60 & echo $! > child.pid; wait"])
        let started = ContinuousClock.now
        let outcome = await MacAppBuild.run(plan, timeout: .seconds(1))
        #expect(outcome == .timedOut(step: "sh step0.sh"))
        #expect(ContinuousClock.now - started < .seconds(10))
        let child = try #require(pid_t(String(contentsOf: scratch.url.appendingPathComponent("child.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(child, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive, "the build's child process was left running")
    }

    @Test func cancellingTheTaskStopsTheBuild() async throws {
        let scratch = try BuildScratch()
        let plan = try plan(scratch, ["echo started; sleep 60"])
        let started = OSAllocatedUnfairLock(initialState: false)
        let task = Task { await MacAppBuild.run(plan) { line in if line == "started" { started.withLock { $0 = true } } } }
        for _ in 0..<200 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        let clock = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(ContinuousClock.now - clock < .seconds(5))
    }
}

/// The Orbit fixture's sources built through the real plan (`swift build`, then package.sh), and a
/// change that doesn't compile. Takes a minute or two; launches nothing.
@Suite("Mac app build of the Orbit sources", .enabled(if: ProcessInfo.processInfo.environment["OPENTRAFFIC_BUILD_ORBIT"] == "1", "set OPENTRAFFIC_BUILD_ORBIT=1"),
       .timeLimit(.minutes(10)))
struct MacAppBuildOrbitSourcesTests {
    @Test func theFixturesSourcesBuildAndABrokenEditFailsWithTheCompilersError() async throws {
        let scratch = try BuildScratch()
        let project = scratch.url.appendingPathComponent("orbit", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for item in ["Package.swift", "Sources", "package.sh"] {
            try FileManager.default.copyItem(at: OrbitFixture.folder.appendingPathComponent(item), to: project.appendingPathComponent(item))
        }
        let bundle = project.appendingPathComponent("dist/Orbit.app")
        let plan = try await MacAppBuild.plan(for: app(bundle, project: project), project: project)
        #expect(plan.summary == "swift build -c debug && sh package.sh")
        let notable = OSAllocatedUnfairLock(initialState: [String]())
        let started = ContinuousClock.now
        let outcome = await MacAppBuild.run(plan, log: scratch.url.appendingPathComponent("build.log")) { line in
            if MacAppBuild.isNotable(line) { notable.withLock { $0.append(line) } }
        }
        print("MacAppBuild Orbit sources: first build \(outcome.message) in \(ContinuousClock.now - started); notable: \(notable.withLock { $0 })")
        #expect(outcome == .succeeded)
        let stamp = try #require(BundleStamp(bundle))

        // An edit that builds: a new executable (what makes the session copy it again).
        let view = project.appendingPathComponent("Sources/Orbit/OrdersView.swift")
        let source = try String(contentsOf: view, encoding: .utf8)
        try source.replacingOccurrences(of: "Button(\"Add Order\")", with: "Button(\"Add New Order\")").write(to: view, atomically: true, encoding: .utf8)
        let again = ContinuousClock.now
        #expect(await MacAppBuild.run(plan) == .succeeded)
        print("MacAppBuild Orbit sources: rebuild after a label change in \(ContinuousClock.now - again)")
        #expect(BundleStamp(bundle) != stamp)

        // An edit that doesn't.
        try source.replacingOccurrences(of: "Button(\"Add Order\")", with: "Buton(\"Add Order\")").write(to: view, atomically: true, encoding: .utf8)
        guard case .failed(let step, let lines) = await MacAppBuild.run(plan) else { Issue.record("a broken edit built"); return }
        print("MacAppBuild Orbit sources: failure \(step): \(lines)")
        #expect(step == "swift build -c debug")
        #expect(lines.first?.contains("OrdersView.swift") == true && lines.first?.contains("error: cannot find 'Buton' in scope") == true)
    }
}

// MARK: - Watching the sources

@Suite("Mac app source watcher", .serialized, .timeLimit(.minutes(2)))
struct MacAppSourceWatcherTests {
    /// Calls of a watcher's `changed`, with when they came.
    private final class Calls: @unchecked Sendable {
        let times = OSAllocatedUnfairLock(initialState: [ContinuousClock.Instant]())
        var count: Int { times.withLock { $0.count } }
        func record() { times.withLock { $0.append(.now) } }
    }

    @Test func aBurstOfEditsIsOneChangeAfterItWentQuietForTheDelay() async throws {
        let scratch = try BuildScratch()
        try scratch.file("Sources/Orbit/OrdersView.swift", "struct A {}")
        try scratch.file("Package.swift", "// swift-tools-version: 6.0")
        let calls = Calls()
        let watcher = MacAppSourceWatcher(directory: scratch.url, delay: 1) { calls.record() }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300)) // FSEvents needs a moment to start

        // An agent saving three files, 200 ms apart.
        for (index, name) in ["OrdersView.swift", "OrderStore.swift", "OrbitApp.swift"].enumerated() {
            try scratch.file("Sources/Orbit/\(name)", "struct B\(index) {}")
            try await Task.sleep(for: .milliseconds(200))
        }
        let lastEdit = ContinuousClock.now - .milliseconds(200)
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls.count == 0, "called before the edits went quiet for a second")
        for _ in 0..<60 where calls.count == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(calls.count == 1)
        if let first = calls.times.withLock({ $0.first }) { #expect(first - lastEdit >= .milliseconds(900)) }
    }

    @Test func buildOutputAndVersionControlDontCount() async throws {
        let scratch = try BuildScratch()
        try scratch.file("Sources/Orbit/OrdersView.swift", "struct A {}")
        let calls = Calls()
        let watcher = MacAppSourceWatcher(directory: scratch.url, delay: 0.3) { calls.record() }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        for path in [".build/debug/Orbit", "DerivedData/Orbit/Build/x.o", "dist/Orbit.app/Contents/MacOS/Orbit", "build/Release/x",
                     ".git/index", "Orbit.xcodeproj/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate", ".DS_Store", "Sources/Orbit/.OrdersView.swift.swp"] {
            try scratch.file(path, "\(UUID())")
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(calls.count == 0)

        // A real source change does.
        try scratch.file("Sources/Orbit/OrdersView.swift", "struct Changed {}")
        for _ in 0..<60 where calls.count == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(calls.count == 1)
    }

    @Test func aChangeIsTakenOnce() throws {
        let scratch = try BuildScratch()
        let file = try scratch.file("Sources/A.swift", "a")
        let watcher = MacAppSourceWatcher(directory: scratch.url) {}
        #expect(!watcher.takeChange()) // the first look only takes the fingerprint
        #expect(!watcher.takeChange())
        try Data("a longer body".utf8).write(to: file)
        #expect(watcher.takeChange())
        #expect(!watcher.takeChange())
        try scratch.file("Sources/New.swift", "b")
        #expect(watcher.takeChange())
        try FileManager.default.removeItem(at: file)
        #expect(watcher.takeChange())
        try scratch.file(".build/x", "c")
        #expect(!watcher.takeChange())
    }
}

// MARK: - Replay

private func node(_ key: String, _ role: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, depth: Int = 1, label: String = "") -> Proto.AXNode {
    Proto.AXNode(key: key, role: role, label: label, x: x, y: y, w: w, h: h, depth: depth, actions: role == "AXButton" ? [.press] : [])
}

@Suite("Mac app replay mapping")
struct MacAppReplayMappingTests {
    let windows = [
        MacAppReplay.Window(id: 900, root: "/Window:", nodes: [
            "/Window:/Button:Add Order": CGRect(x: 20, y: 260, width: 90, height: 24),
            "/Window:/Outline:/Row:#3": CGRect(x: 0, y: 130, width: 300, height: 40),
            "/Window:/TextField:Customer": CGRect(x: 20, y: 20, width: 200, height: 22),
        ]),
        MacAppReplay.Window(id: 901, root: "/Window:Settings", nodes: ["/Window:Settings/CheckBox:Gift": CGRect(x: 10, y: 10, width: 60, height: 20)]),
    ]

    @Test func keysAndWindowsAreFoundAgainInTheNewLaunch() {
        let main = MacAppReplay.Target(windowRoot: "/Window:")
        // A press: the key stays, the window id is the new one.
        let press = Proto.ClientMessage.act(.init(window: 42, key: "/Window:/Button:Add Order", action: .press))
        #expect(MacAppReplay.resolve(press, target: main, in: windows)
                == .send(.act(.init(window: 900, key: "/Window:/Button:Add Order", action: .press)),
                         .init(windowRoot: "/Window:", frame: CGRect(x: 20, y: 260, width: 90, height: 24))))
        // A second window by its root.
        let gift = Proto.ClientMessage.act(.init(window: 43, key: "/Window:Settings/CheckBox:Gift", action: .press))
        guard case .send(.act(let act), _) = MacAppReplay.resolve(gift, target: .init(windowRoot: "/Window:Settings"), in: windows) else {
            Issue.record("the settings window wasn't found"); return
        }
        #expect(act.window == 901)
        // setText, text and key follow their window.
        guard case .send(.setText(let setText), _) = MacAppReplay.resolve(.setText(.init(window: 42, key: "/Window:/TextField:Customer", value: "Ada")), target: main, in: windows),
              case .send(.key(let key), _) = MacAppReplay.resolve(.key(.init(window: 42, code: .enter)), target: main, in: windows),
              case .send(.text(let text), _) = MacAppReplay.resolve(.text(.init(window: 42, text: "x")), target: main, in: windows) else {
            Issue.record("setText, key or text wasn't mapped"); return
        }
        #expect(setText.window == 900 && setText.value == "Ada" && key.window == 900 && text.window == 900)
        // Menu commands don't name a window.
        let menu = Proto.ClientMessage.menuAction(.init(path: ["File", "New Order"]))
        #expect(MacAppReplay.resolve(menu, target: nil, in: windows) == .send(menu, nil))
    }

    @Test func aClickLandsOnTheSameSpotOfItsElementWhereverItMoved() {
        // The row was at y 100 in the old launch and is at y 130 now.
        let target = MacAppReplay.Target(windowRoot: "/Window:", key: "/Window:/Outline:/Row:#3", frame: CGRect(x: 0, y: 100, width: 300, height: 40))
        let down = Proto.ClientMessage.pointer(.init(window: 42, kind: .down, x: 150, y: 120))
        guard case .send(.pointer(let pointer), let newTarget) = MacAppReplay.resolve(down, target: target, in: windows) else {
            Issue.record("the click wasn't mapped"); return
        }
        #expect(pointer.window == 900 && pointer.x == 150 && pointer.y == 150 && pointer.kind == .down)
        #expect(newTarget?.frame == CGRect(x: 0, y: 130, width: 300, height: 40))
        // A click on nothing in particular keeps its point.
        let bare = MacAppReplay.resolve(.pointer(.init(window: 42, kind: .up, x: 5, y: 5)), target: .init(windowRoot: "/Window:"), in: windows)
        #expect(bare == .send(.pointer(.init(window: 900, kind: .up, x: 5, y: 5)), .init(windowRoot: "/Window:")))
        // The deepest element under a point.
        let nodes = [node("/Window:", "AXWindow", 0, 0, 400, 300, depth: 0), node("/Window:/Outline:", "AXOutline", 0, 80, 300, 200),
                     node("/Window:/Outline:/Row:#3", "AXRow", 0, 100, 300, 40, depth: 2)]
        #expect(MacAppReplay.element(at: CGPoint(x: 150, y: 120), in: nodes)?.key == "/Window:/Outline:/Row:#3")
        #expect(MacAppReplay.element(at: CGPoint(x: 350, y: 20), in: nodes)?.key == "/Window:")
    }

    @Test func goneElementsAndWindowsAreReported() {
        let main = MacAppReplay.Target(windowRoot: "/Window:")
        #expect(MacAppReplay.resolve(.act(.init(window: 42, key: "/Window:/Button:Delete", action: .press)), target: main, in: windows)
                == .missingElement("/Window:/Button:Delete"))
        #expect(MacAppReplay.resolve(.key(.init(window: 44, code: .escape)), target: .init(windowRoot: "/Window:Inspector"), in: windows)
                == .missingWindow("/Window:Inspector"))
        #expect(MacAppReplay.resolve(.key(.init(window: 44, code: .escape)), target: nil, in: windows) == .missingWindow("an unknown window"))
        let click = MacAppReplay.Target(windowRoot: "/Window:", key: "/Window:/Outline:/Row:#9", frame: .init(x: 0, y: 0, width: 10, height: 10))
        #expect(MacAppReplay.resolve(.pointer(.init(window: 42, kind: .down, x: 1, y: 1)), target: click, in: windows) == .missingElement("/Window:/Outline:/Row:#9"))
    }

    @MainActor
    @Test func aReplayGoesInOrderWaitsForWhatOpensAndStopsAtTheFirstGoneElement() async {
        func action(_ message: Proto.ClientMessage, _ target: MacAppReplay.Target?) -> MacAppSession.RecordedAction {
            .init(date: Date(), viewer: 1, boot: "old", message: message, target: target)
        }
        let main = MacAppReplay.Target(windowRoot: "/Window:")
        let path = [
            action(.act(.init(window: 42, key: "/Window:/Button:Show Sheet", action: .press)), main),
            // A sheet the press opens, a moment later.
            action(.act(.init(window: 42, key: "/Window:/Sheet:/Button:OK", action: .press)), main),
            action(.pointer(.init(window: 42, kind: .move, x: 1, y: 1)), main), // never recorded; skipped
            action(.act(.init(window: 42, key: "/Window:/Button:Gone", action: .press)), main),
            action(.act(.init(window: 42, key: "/Window:/Button:Show Sheet", action: .press)), main),
        ]
        let sent = OSAllocatedUnfairLock(initialState: [Proto.ClientMessage]())
        let started = ContinuousClock.now
        let result = await MacAppReplay.run(
            path, gap: .milliseconds(10), elementWait: .milliseconds(400), treeWait: .seconds(1),
            windows: {
                var nodes: [String: CGRect] = ["/Window:/Button:Show Sheet": .init(x: 0, y: 0, width: 10, height: 10)]
                if ContinuousClock.now - started > .milliseconds(150) { nodes["/Window:/Sheet:/Button:OK"] = .init(x: 5, y: 5, width: 10, height: 10) }
                return [MacAppReplay.Window(id: 7, root: "/Window:", nodes: nodes)]
            },
            send: { action in sent.withLock { $0.append(action.message) } },
            isCurrent: { true })
        #expect(sent.withLock { $0 } == [
            .act(.init(window: 7, key: "/Window:/Button:Show Sheet", action: .press)),
            .act(.init(window: 7, key: "/Window:/Sheet:/Button:OK", action: .press)),
        ])
        #expect(result.report == .init(replayed: 2, total: 4, stoppedAt: "press /Window:/Button:Gone"))
        #expect(result.replayed.map { $0.message.window } == [7, 7])

        // A launch that quits ends the replay.
        let quit = await MacAppReplay.run(path, gap: .zero, elementWait: .milliseconds(100), treeWait: .milliseconds(100),
                                          windows: { [] }, send: { _ in Issue.record("sent to a launch that quit") }, isCurrent: { false })
        #expect(quit.report.stoppedAt == "the app quit" && quit.report.replayed == 0)
        // Nothing to replay.
        let none = await MacAppReplay.run([], gap: .zero, elementWait: .zero, treeWait: .zero, windows: { [] }, send: { _ in }, isCurrent: { true })
        #expect(none.report == .init(replayed: 0, total: 0))
    }
}

// MARK: - Replay through a mirror server over stub bridges, across a relaunch

private final class ReplayAccessibility: MirrorAccessibility, @unchecked Sendable {
    let window: AccessibilityTree.Window
    let nodes: [Proto.AXNode]
    let performed = OSAllocatedUnfairLock(initialState: [String]())

    init(number: UInt32, offset: Double) {
        window = AccessibilityTree.Window(number: number, title: "Orders", role: "AXWindow", subrole: "AXStandardWindow",
                                          frame: CGRect(x: -1500, y: 300, width: 400, height: 300), isMain: true, isFocused: true, isMinimized: false)
        nodes = [
            node("/Window:", "AXWindow", 0, 0, 400, 300, depth: 0),
            node("/Window:/Button:Add Order", "AXButton", 20, 250 + offset / 2, 90, 24, label: "Add Order"),
            node("/Window:/Outline:", "AXOutline", 0, 40, 300, 200),
            node("/Window:/Outline:/Row:", "AXRow", 0, 60 + offset, 300, 40, depth: 2),
            node("/Window:/Outline:/Row:#2", "AXRow", 0, 100 + offset, 300, 40, depth: 2),
            node("/Window:/TextField:Customer", "AXTextField", 20, 10, 200, 22),
        ]
    }

    func windows() async throws -> [AccessibilityTree.Window] { [window] }
    func snapshot(window selector: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        AXSnapshot(windowNumber: window.number, title: window.title, frame: window.frame, nodes: nodes)
    }
    func perform(key: String, action: Proto.Action, window: UInt32?) async throws {
        performed.withLock { $0.append("\(action.rawValue) \(key) in \(window.map(String.init) ?? "-")") }
    }
    func changes() -> AsyncStream<AXChange> { AsyncStream { _ in } }
}

private final class ReplayInput: MirrorInput, @unchecked Sendable {
    let events = OSAllocatedUnfairLock(initialState: [String]())
    func send(_ pointer: Proto.Pointer, in window: InputSynthesizer.Window) throws {
        events.withLock { $0.append("pointer \(pointer.kind.rawValue) \(Int(pointer.x)),\(Int(pointer.y)) in \(window.id)") }
    }
    func type(text: String) throws { events.withLock { $0.append("text \(text)") } }
    func send(_ key: Proto.Key) throws { events.withLock { $0.append("key \(key.code.rawValue) in \(key.window)") } }
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {
        events.withLock { $0.append("setText \(text) at \(Int(field.minY)) in \(window.id)") }
    }
}

private final class ReplayCapture: MirrorCapture, @unchecked Sendable {
    let windowID: CGWindowID
    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    init(windowID: CGWindowID) {
        self.windowID = windowID
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
    }
    func start() async throws { continuation.yield(full()) }
    func stop() async { continuation.finish() }
    func fullFrame() async -> CapturedFrame? { full() }

    private func full() -> CapturedFrame {
        let tile = Proto.Tile(window: windowID, seq: 0, x: 0, y: 0, w: 400, h: 300, format: .jpeg, data: grayJPEG())
        return CapturedFrame(window: windowID, seq: 0, full: true, width: 400, height: 300, scale: 2, tiles: [tile], encodeTime: .zero)
    }
}

private func grayJPEG() -> Data {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private func replayApp(boot: String, accessibility: ReplayAccessibility, input: ReplayInput) -> MirrorServer.App {
    MirrorServer.App(name: "Orbit", boot: boot, accessibility: accessibility, input: input) { ReplayCapture(windowID: $0) }
}

@Suite("Mac app replay through a stub mirror", .serialized, .timeLimit(.minutes(2)))
struct MacAppReplayServerTests {
    @MainActor
    @Test func actionsRecordedInOneLaunchAreAppliedToTheNextAsTheHost() async throws {
        let oldAccessibility = ReplayAccessibility(number: 42, offset: 0)
        let oldInput = ReplayInput()
        let assets = MirrorServer.Assets(page: Data("<html></html>".utf8), script: Data(), style: Data())
        // Watch only: a viewer's input would be dropped; replays are the host's own.
        let server = MirrorServer(configuration: .init(app: replayApp(boot: "one", accessibility: oldAccessibility, input: oldInput),
                                                       assets: assets, options: .init(control: .watchOnly)))
        _ = try await server.start()
        defer { Task { await server.stop() } }
        let messages = OSAllocatedUnfairLock(initialState: 0)
        let watching = Task { for await event in server.events { if case .message = event { messages.withLock { $0 += 1 } } } }
        defer { watching.cancel() }

        // What viewers did in the first launch, with where it was aimed then.
        let viewerActions: [Proto.ClientMessage] = [
            .pointer(.init(window: 42, kind: .down, x: 150, y: 110)),
            .pointer(.init(window: 42, kind: .up, x: 150, y: 110)),
            .setText(.init(window: 42, key: "/Window:/TextField:Customer", value: "Ada")),
            .key(.init(window: 42, code: .enter)),
            .act(.init(window: 42, key: "/Window:/Button:Add Order", action: .press)),
        ]
        var path: [MacAppSession.RecordedAction] = []
        for message in viewerActions {
            path.append(.init(date: Date(), viewer: 3, boot: "one", message: message, target: await server.replayTarget(for: message)))
        }
        #expect(path[0].target == .init(windowRoot: "/Window:", key: "/Window:/Outline:/Row:#2", frame: CGRect(x: 0, y: 100, width: 300, height: 40)))
        #expect(path[3].target == .init(windowRoot: "/Window:"))
        #expect(await server.replayTarget(for: .pointer(.init(window: 99, kind: .down, x: 1, y: 1))) == nil)

        // The relaunch: another window number, the list 30 points lower.
        let newAccessibility = ReplayAccessibility(number: 77, offset: 30)
        let newInput = ReplayInput()
        try await server.replace(app: replayApp(boot: "two", accessibility: newAccessibility, input: newInput))
        let windows = await server.replayWindows()
        #expect(windows.map(\.id) == [77] && windows.first?.root == "/Window:")
        #expect(windows.first?.nodes["/Window:/Outline:/Row:#2"] == CGRect(x: 0, y: 130, width: 300, height: 40))

        let result = await MacAppReplay.run(path, gap: .milliseconds(20), elementWait: .milliseconds(500), treeWait: .seconds(2),
                                            windows: { await server.replayWindows() }, send: { server.replay($0.message) }, isCurrent: { true })
        #expect(result.report == .init(replayed: 5, total: 5))
        let deadline = ContinuousClock.now + .seconds(3)
        while newAccessibility.performed.withLock({ $0.isEmpty }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(newInput.events.withLock { $0 } == ["pointer down 150,140 in 77", "pointer up 150,140 in 77", "setText Ada at 10 in 77", "key Enter in 77"])
        #expect(newAccessibility.performed.withLock { $0 } == ["press /Window:/Button:Add Order in 77"])
        #expect(oldInput.events.withLock { $0 }.isEmpty && oldAccessibility.performed.withLock { $0 }.isEmpty)
        // Replays aren't viewer messages: the session doesn't record them again.
        #expect(messages.withLock { $0 } == 0)
        // Viewport and control messages are never replayed.
        server.replay(.viewport(.init(w: 100, h: 100)))
    }
}

// MARK: - The whole loop on the Orbit fixture

@MainActor
@Suite("Rebuild and replay on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .macAppFixtureTurn, .timeLimit(.minutes(10)))
struct MacAppBuildFixtureTests {
    @Test func aChangedLabelShowsWithinAMinuteWithTheSelectedRowStillSelected() async throws {
        // A copy of the fixture's sources, built once (the real fixture stays as it is).
        let scratch = try BuildScratch()
        let project = scratch.url.appendingPathComponent("orbit", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for item in ["Package.swift", "Sources", "package.sh"] {
            try FileManager.default.copyItem(at: OrbitFixture.folder.appendingPathComponent(item), to: project.appendingPathComponent(item))
        }
        let orbit = MacApp(name: "Orbit", bundle: project.appendingPathComponent("dist/Orbit.app"), bundleIdentifier: OrbitFixture.bundleIdentifier,
                           projectDirectory: project, isRunning: false)
        let plan = try await MacAppBuild.plan(for: orbit, project: project)
        #expect(plan.summary == "swift build -c debug && sh package.sh")
        let firstBuild = await MacAppBuild.run(plan, log: scratch.url.appendingPathComponent("first-build.log"))
        try #require(firstBuild == .succeeded, "building the copied fixture: \(firstBuild.message)")

        let sessions = scratch.url.appendingPathComponent("sessions", isDirectory: true)
        let assets = MirrorServer.Assets(page: Data("<html></html>".utf8), script: Data(), style: Data())
        let session = MacAppSession(options: .init(app: orbit, data: .empty, assets: assets,
                                                   sessionDirectory: sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)))
        let port = try await session.start()
        do {
            let viewer = BuildViewer(port: port)
            defer { viewer.close() }
            let hello = try #require(await viewer.first(within: .seconds(10)) { $0.hello != nil })
            let firstBoot = try #require(hello.item.hello?.boot)
            let listed = try #require(await viewer.first(after: hello.index, within: .seconds(15)) { $0.tree?.nodes.filter { $0.role == "AXRow" }.count ?? 0 > 2 })
            let tree = try #require(listed.item.tree)
            #expect(tree.nodes.contains { $0.role == "AXButton" && $0.label == "Add Order" })

            // A viewer selects the third order with a click.
            let row = tree.nodes.filter { $0.role == "AXRow" }[2]
            let point = (x: row.x + row.w / 2, y: row.y + row.h / 2)
            try await viewer.send(.pointer(.init(window: tree.window, kind: .down, x: point.x, y: point.y)))
            try await viewer.send(.pointer(.init(window: tree.window, kind: .up, x: point.x, y: point.y)))
            #expect(await viewer.first(after: listed.index, within: .seconds(5)) { $0.tree?.nodes.first { $0.key == row.key }?.selected == true } != nil)
            try await Task.sleep(for: .milliseconds(300)) // the session records the click

            // An agent changes a label; the session builds, relaunches and replays.
            #expect(session.watchSources(plan))
            let mark = viewer.items.count
            let view = project.appendingPathComponent("Sources/Orbit/OrdersView.swift")
            let source = try String(contentsOf: view, encoding: .utf8)
            try #require(source.contains("Button(\"Add Order\")"))
            let edited = ContinuousClock.now
            try source.replacingOccurrences(of: "Button(\"Add Order\")", with: "Button(\"Add New Order\")").write(to: view, atomically: true, encoding: .utf8)

            let restarting = await viewer.first(after: mark, within: .seconds(60)) { $0.status?.state == .restarting }
            #expect(restarting != nil, "viewers weren't told it restarts")
            let again = try #require(await viewer.first(after: mark, within: .seconds(60)) { $0.hello.map { $0.boot != firstBoot } == true })
            let relabelled = await viewer.first(after: again.index, within: .seconds(60) - (ContinuousClock.now - edited)) { item in
                guard let nodes = item.tree?.nodes else { return false }
                return nodes.contains { $0.role == "AXButton" && $0.label == "Add New Order" } && nodes.first { $0.key == row.key }?.selected == true
            }
            let took = ContinuousClock.now - edited
            print("MacAppBuild fixture: the new label and the selection were back \(took) after the edit; replay \(String(describing: session.lastReplay))")
            #expect(relabelled != nil, "the new label with the row selected again didn't show within 60 s")
            #expect(took < .seconds(60))
            #expect(session.lastReplay?.stoppedAt == nil && (session.lastReplay?.replayed ?? 0) >= 2)
            #expect(await viewer.first(after: again.index, within: .seconds(5)) { $0.status?.state == .running } != nil)
            #expect(session.recentLog.contains { $0.text.hasPrefix("Built Orbit in") })

            // A change that doesn't compile: the new build keeps running and the failure is logged.
            let running = session.pid
            try source.replacingOccurrences(of: "Button(\"Add Order\")", with: "Buton(\"Add Order\")").write(to: view, atomically: true, encoding: .utf8)
            let failDeadline = ContinuousClock.now + .seconds(60)
            while session.buildState == .idle || session.buildState == .building, ContinuousClock.now < failDeadline { try await Task.sleep(for: .milliseconds(100)) }
            guard case .failed = session.buildState else { Issue.record("the broken build wasn't reported: \(session.buildState)"); throw FixtureError("no failure") }
            #expect(session.pid == running && session.state == .running)
            #expect(session.recentLog.contains { $0.text.contains("error:") })
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENTRAFFIC_XCODE_PROJECT"] != nil, "set OPENTRAFFIC_XCODE_PROJECT=<folder>:<path to the built .app>"))
    func aRealXcodeProjectIsBuiltWithTheSchemeForItsApp() async throws {
        let value = try #require(ProcessInfo.processInfo.environment["OPENTRAFFIC_XCODE_PROJECT"])
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let project = URL(fileURLWithPath: parts[0], isDirectory: true)
        let bundle = URL(fileURLWithPath: parts.count > 1 ? parts[1] : "")
        let plan = try await MacAppBuild.plan(for: app(bundle, name: bundle.deletingPathExtension().lastPathComponent), project: project)
        print("MacAppBuild: \(plan.summary)")
        let before = BundleStamp(bundle)
        let outcome = await MacAppBuild.run(plan) { line in if MacAppBuild.isNotable(line) { print("  \(line)") } }
        #expect(outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        print("MacAppBuild: stamp before \(String(describing: before)), after \(String(describing: BundleStamp(bundle)))")
    }
}

/// A viewer, as the browser page connects: everything it received, in order.
private final class BuildViewer: @unchecked Sendable {
    enum Item: Sendable {
        case message(Proto.ServerMessage)
        case binary

        var hello: Proto.Hello? { if case .message(.hello(let h)) = self { h } else { nil } }
        var tree: Proto.Tree? { if case .message(.tree(let t)) = self { t } else { nil } }
        var status: Proto.Status? { if case .message(.status(let s)) = self { s } else { nil } }
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
            case .success:
                received.withLock { $0.append(.binary) }
                receive()
            case .failure:
                break
            }
        }
    }

    var items: [(index: Int, item: Item)] { received.withLock { Array($0.enumerated()).map { ($0.offset, $0.element) } } }

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

import Foundation
import Testing
@testable import OpenTrafficCore

// Mac app discovery: fake DerivedData and fixture bundles under a temporary folder (no permissions
// needed), a real process for the running-app path, and the Orbit fixture when it's built
// (`sh Examples/macapp-orbit/package.sh`).

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtureApp = repository.appendingPathComponent("Examples/macapp-orbit/dist/Orbit.app")
private let hasFixtureApp = FileManager.default.fileExists(atPath: fixtureApp.appendingPathComponent("Contents/Info.plist").path)
private let day: TimeInterval = 24 * 3600

/// A scratch folder that looks like a Mac with projects, builds and installed apps.
private struct Workbench {
    let root: URL
    var derivedData: URL { root.appendingPathComponent("DerivedData") }
    var applications: URL { root.appendingPathComponent("Applications") }
    let now = Date()

    init() throws {
        root = ElectronDiscovery.realURL(FileManager.default.temporaryDirectory).appendingPathComponent("macapp-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func context(processes: [(pid: Int32, executable: String)] = [], excluded: Set<String> = []) -> MacAppDiscovery.Context {
        MacAppDiscovery.Context(homeDirectory: root.path, derivedData: derivedData, now: now, ownTeams: [],
                                processes: processes, installedRoots: [applications.path], excludedBundles: excluded)
    }

    /// A project folder with a Package.swift (or an .xcodeproj).
    @discardableResult
    func project(_ path: String, xcode: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let xcode {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("\(xcode).xcodeproj"), withIntermediateDirectories: true)
        } else {
            try "// swift-tools-version: 6.0\n".write(to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }
        return folder
    }

    /// A DerivedData folder for a workspace, as Xcode leaves it.
    func derivedFolder(_ name: String, workspace: URL) throws -> URL {
        let folder = derivedData.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = ["WorkspacePath": workspace.path, "LastAccessedDate": now]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: folder.appendingPathComponent("info.plist"))
        return folder
    }

    /// A macOS .app (unsigned, its executable a shell script), built `age` ago.
    @discardableResult
    func app(_ path: String, identifier: String, name: String? = nil, age: TimeInterval = 0, electron: Bool = false,
             extra: [String: Any] = [:]) throws -> URL {
        let bundle = root.appendingPathComponent(path)
        let executableName = name ?? bundle.deletingPathExtension().lastPathComponent
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleExecutable": executableName, "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
                                   "CFBundleName": executableName, "CFBundleShortVersionString": "1.0"]
        info.merge(extra) { $1 }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent(executableName)
        try "#!/bin/sh\nsleep 60\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: executable.path)
        if electron {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"), withIntermediateDirectories: true)
        }
        return bundle
    }

    func executable(of bundle: URL) -> String {
        bundle.appendingPathComponent("Contents/MacOS/\(bundle.deletingPathExtension().lastPathComponent)").path
    }
}

@Test func recentXcodeBuildsAreListedWithTheirProjects() async throws {
    let bench = try Workbench()
    defer { bench.remove() }
    let orbit = try bench.project("code/Orbit", xcode: "Orbit")
    let orbitBuilds = try bench.derivedFolder("Orbit-abc", workspace: orbit.appendingPathComponent("Orbit.xcodeproj"))
    try bench.app("DerivedData/Orbit-abc/Build/Products/Debug/Orbit.app", identifier: "com.example.orbit", age: 2 * day)
    try bench.app("DerivedData/Orbit-abc/Build/Products/Debug/OrbitUITests-Runner.app", identifier: "com.example.orbit.uitests.xctrunner")
    // The same product built from a second DerivedData folder, more recently: only the newest is listed.
    _ = try bench.derivedFolder("Orbit-def", workspace: orbit.appendingPathComponent("Orbit.xcodeproj"))
    let newer = try bench.app("DerivedData/Orbit-def/Build/Products/Debug/Orbit.app", identifier: "com.example.orbit", age: day)
    // A Swift package opened in Xcode: WorkspacePath is the package folder.
    let notes = try bench.project("code/Notes")
    _ = try bench.derivedFolder("Notes-ghi", workspace: notes)
    try bench.app("DerivedData/Notes-ghi/Build/Products/Debug-maccatalyst/Notes.app", identifier: "com.example.notes")
    // Not listed: a build older than 30 days, a project that's gone, an iOS simulator app, a release build.
    let old = try bench.project("code/Old", xcode: "Old")
    _ = try bench.derivedFolder("Old-jkl", workspace: old.appendingPathComponent("Old.xcodeproj"))
    try bench.app("DerivedData/Old-jkl/Build/Products/Debug/Old.app", identifier: "com.example.old", age: 40 * day)
    _ = try bench.derivedFolder("Gone-mno", workspace: bench.root.appendingPathComponent("code/Gone/Gone.xcodeproj"))
    try bench.app("DerivedData/Gone-mno/Build/Products/Debug/Gone.app", identifier: "com.example.gone")
    let phone = orbitBuilds.appendingPathComponent("Build/Products/Debug-iphonesimulator/OrbitPhone.app")
    try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "OrbitPhone", "CFBundleIdentifier": "com.example.phone"], format: .xml, options: 0)
        .write(to: phone.appendingPathComponent("Info.plist"))
    try bench.app("DerivedData/Orbit-abc/Build/Products/Release/OrbitRelease.app", identifier: "com.example.orbit.release")

    let apps = await MacAppDiscovery.scan(bench.context())
    #expect(apps.map(\.name) == ["Notes", "Orbit"])
    let orbitApp = try #require(apps.first { $0.name == "Orbit" })
    #expect(orbitApp.bundle.path == newer.path)
    #expect(orbitApp.projectDirectory?.path == orbit.path)
    #expect(orbitApp.bundleIdentifier == "com.example.orbit")
    #expect(orbitApp.version == "1.0")
    #expect(!orbitApp.isRunning && orbitApp.pid == nil)
    #expect(apps.first { $0.name == "Notes" }?.projectDirectory?.path == notes.path)
}

@Test func runningDebugBuildsAreListedAndEverythingElseIsNot() async throws {
    let bench = try Workbench()
    defer { bench.remove() }
    let orbit = try bench.project("code/Orbit", xcode: "Orbit")
    _ = try bench.derivedFolder("Orbit-abc", workspace: orbit.appendingPathComponent("Orbit.xcodeproj"))
    let xcodeBuild = try bench.app("DerivedData/Orbit-abc/Build/Products/Debug/Orbit.app", identifier: "com.example.orbit")
    let tool = try bench.project("code/Tool")
    let swiftPMBuild = try bench.app("code/Tool/.build/debug/Tool.app", identifier: "com.example.tool")
    let distBuild = try bench.app("code/Tool/dist/Tool Preview.app", identifier: "com.example.tool.preview")
    let loose = try bench.app("Downloads/Loose.app", identifier: "com.example.loose") // unsigned, no project
    let notRunning = try bench.app("code/Tool/dist/Idle.app", identifier: "com.example.idle")
    // Never listed, even though they're unsigned or sit in a project:
    let installed = try bench.app("Applications/Installed.app", identifier: "com.example.installed")
    let electron = try bench.app("code/Tool/dist/Desk.app", identifier: "com.example.desk", electron: true)
    let session = try bench.app("Sessions/Orbit.app", identifier: "com.example.orbit.opentraffic")
    let openTraffic = try bench.app("code/OpenTraffic/dist/OpenTraffic.app", identifier: "se.medda.opentraffic")
    let testCopy = try bench.app("scratch/OpenTraffic.app", identifier: "se.medda.opentraffic.e2e")
    let thisProcess = try bench.app("scratch/Self.app", identifier: "com.example.self")
    let daemon = try bench.app("code/Tool/dist/Daemon.app", identifier: "com.example.daemon", extra: ["LSBackgroundOnly": true])
    let helper = try bench.app("code/Tool/dist/Host.app/Contents/Library/LoginItems/Helper.app", identifier: "com.example.helper")

    let processes: [(pid: Int32, executable: String)] = [
        (101, bench.executable(of: xcodeBuild)), (99, bench.executable(of: xcodeBuild)), // two instances: the oldest pid
        (102, bench.executable(of: swiftPMBuild)), (103, bench.executable(of: distBuild)), (104, bench.executable(of: loose)),
        (105, bench.executable(of: installed)), (106, bench.executable(of: electron)), (107, bench.executable(of: session)),
        (108, bench.executable(of: openTraffic)), (109, bench.executable(of: testCopy)), (110, bench.executable(of: thisProcess)),
        (111, bench.executable(of: daemon)), (112, bench.executable(of: helper)),
        (113, "/System/Applications/Calculator.app/Contents/MacOS/Calculator"), (114, "/usr/bin/swift"),
    ]
    let apps = await MacAppDiscovery.scan(bench.context(processes: processes, excluded: [thisProcess.path]))
    #expect(Set(apps.map(\.bundle.path)) == Set([xcodeBuild, swiftPMBuild, distBuild, loose].map(\.path)))
    // The running Xcode build is the same product as the DerivedData build: listed once, as running.
    let orbitApp = try #require(apps.first { $0.bundle.path == xcodeBuild.path })
    #expect(orbitApp.isRunning && orbitApp.pid == 99)
    #expect(orbitApp.projectDirectory?.path == orbit.path)
    #expect(apps.first { $0.bundle.path == swiftPMBuild.path }?.projectDirectory?.path == tool.path)
    #expect(apps.first { $0.bundle.path == distBuild.path }?.projectDirectory?.path == tool.path)
    #expect(apps.first { $0.bundle.path == distBuild.path }?.name == "Tool Preview")
    #expect(apps.first { $0.bundle.path == loose.path }?.projectDirectory == nil)
    #expect(apps.allSatisfy { $0.isRunning })
    #expect(!apps.contains { $0.bundle.path == notRunning.path })
}

@Test func resolveAcceptsYourBuildsAndSaysWhyNotOtherwise() throws {
    let bench = try Workbench()
    defer { bench.remove() }
    let tool = try bench.project("code/Tool")
    let build = try bench.app("code/Tool/dist/Tool.app", identifier: "com.example.tool")
    let processes: [(pid: Int32, executable: String)] = [(321, bench.executable(of: build))]
    let app = try MacAppDiscovery.resolve(path: build.path + "/", context: bench.context(processes: processes))
    #expect(app.bundle.path == build.path && app.projectDirectory?.path == tool.path && app.pid == 321 && app.isRunning)
    let viaHome = try MacAppDiscovery.resolve(path: "~/code/Tool/dist/Tool.app", context: bench.context())
    #expect(viaHome.bundle.path == build.path && !viaHome.isRunning)
    // Unsigned, outside any project: yours (you built it, nobody else ships unsigned apps).
    let loose = try bench.app("Downloads/Loose.app", identifier: "com.example.loose")
    #expect(try MacAppDiscovery.resolve(path: loose.path, context: bench.context()).projectDirectory == nil)

    func refusal(_ path: String) -> String? {
        do { _ = try MacAppDiscovery.resolve(path: path, context: bench.context()); return nil } catch { return (error as? MacAppRefusal)?.message }
    }
    #expect(refusal(bench.root.appendingPathComponent("nowhere/Missing.app").path)?.hasPrefix("There is no app at") == true)
    #expect(refusal(tool.path)?.contains("is not a Mac app") == true)
    let electron = try bench.app("code/Tool/dist/Desk.app", identifier: "com.example.desk", electron: true)
    #expect(refusal(electron.path) == "Desk is an Electron app: share it from Electron Apps instead.")
    let session = try bench.app("Sessions/Tool.app", identifier: "com.example.tool.opentraffic")
    #expect(refusal(session.path) == "Tool is a copy OpenTraffic made for a share session, not your app.")
    let openTraffic = try bench.app("code/OpenTraffic/dist/OpenTraffic.app", identifier: "se.medda.opentraffic")
    #expect(refusal(openTraffic.path) == "OpenTraffic can't share itself.")
    // macOS's own apps have no team ID, which CodeSignature reads as ad hoc: the Apple anchor decides.
    #expect(refusal("/System/Applications/Calculator.app")?.contains("part of macOS or made by Apple") == true)
}

@Test func onlyYourSigningTeamsMakeASignedAppYours() {
    let teams: Set<String> = ["ABCDE12345"]
    #expect(MacAppDiscovery.refusal("Orbit", project: nil, signer: .init(.team("ABCDE12345")), ownTeams: teams) == nil)
    #expect(MacAppDiscovery.refusal("Orbit", project: nil, signer: .init(.adHoc), ownTeams: teams) == nil)
    #expect(MacAppDiscovery.refusal("Orbit", project: nil, signer: .init(.unsigned), ownTeams: teams) == nil)
    #expect(MacAppDiscovery.refusal("Chat", project: nil, signer: .init(.team("QQQQQ11111")), ownTeams: teams)
        == "Chat is signed by another developer (team QQQQQ11111), not by one of your signing identities; only apps you build can be shared.")
    #expect(MacAppDiscovery.refusal("Odd", project: nil, signer: .init(.unreadable), ownTeams: teams)?.contains("can't be read") == true)
    // In a project folder, a build signed for distribution by someone else's team is still your build...
    #expect(MacAppDiscovery.refusal("Orbit", project: URL(fileURLWithPath: "/code/Orbit"), signer: .init(.team("ZZZZZ99999")), ownTeams: teams) == nil)
    // ...but Apple's code never is.
    #expect(MacAppDiscovery.refusal("Calculator", project: URL(fileURLWithPath: "/code/x"), signer: .init(.adHoc, isApple: true), ownTeams: teams) != nil)
    #expect(MacAppDiscovery.Signer.of(URL(fileURLWithPath: "/System/Applications/Calculator.app")).isApple)
}

@Test func workspacePathsNameTheProjectFolder() {
    #expect(MacAppDiscovery.projectFolder(forWorkspace: URL(fileURLWithPath: "/code/Orbit/Orbit.xcodeproj")).path == "/code/Orbit")
    #expect(MacAppDiscovery.projectFolder(forWorkspace: URL(fileURLWithPath: "/code/Orbit/Orbit.xcodeproj/project.xcworkspace")).path == "/code/Orbit")
    #expect(MacAppDiscovery.projectFolder(forWorkspace: URL(fileURLWithPath: "/code/Notes")).path == "/code/Notes")
}

// MARK: This Mac

/// A tiny real program in an unsigned-by-hand (linker ad hoc signed) .app inside a SwiftPM project's
/// .build folder, compiled once; nil when there's no C compiler.
private let liveBench: (root: URL, project: URL, bundle: URL)? = {
    let root = ElectronDiscovery.realURL(FileManager.default.temporaryDirectory).appendingPathComponent("macapp-live-\(UUID().uuidString)")
    let project = root.appendingPathComponent("Live")
    let bundle = project.appendingPathComponent(".build/debug/Live.app")
    let macOS = bundle.appendingPathComponent("Contents/MacOS")
    do {
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let info: [String: Any] = ["CFBundleExecutable": "Live", "CFBundleIdentifier": "com.example.live", "CFBundlePackageType": "APPL", "CFBundleName": "Live"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let source = root.appendingPathComponent("live.c")
        try "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        guard ToolOutput.run("/usr/bin/xcrun", ["clang", "-o", macOS.appendingPathComponent("Live").path, source.path], timeout: 60) != nil else { return nil }
        return (root, project, bundle)
    } catch {
        return nil
    }
}()

@Test(.enabled(if: liveBench != nil, "needs a C compiler (Xcode or the command line tools)"))
func aRunningBuildIsFoundAmongThisMacsProcesses() async throws {
    let live = try #require(liveBench)
    defer { try? FileManager.default.removeItem(at: live.root) }
    let process = Process()
    process.executableURL = live.bundle.appendingPathComponent("Contents/MacOS/Live")
    try process.run()
    defer { process.terminate() }
    let context = MacAppDiscovery.Context(derivedData: live.root.appendingPathComponent("NoDerivedData"), ownTeams: [])
    var found: MacApp?
    for _ in 0..<20 where found == nil {
        found = await MacAppDiscovery.scan(context).first { $0.bundle.path == live.bundle.path }
        if found == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    let app = try #require(found)
    #expect(app.isRunning && app.pid == process.processIdentifier)
    #expect(app.projectDirectory?.path == live.project.path)
    #expect(app.name == "Live")
}

@Test func installedAndOtherPeoplesAppsNeverShowUpOnThisMac() async {
    let apps = await MacAppDiscovery.scan(MacAppDiscovery.Context(ownTeams: []))
    for app in apps {
        #expect(!app.bundle.path.hasPrefix("/Applications/") && !app.bundle.path.hasPrefix("/System/"), "\(app.bundle.path)")
        #expect(!(app.bundleIdentifier ?? "").hasSuffix(".opentraffic"), "\(app.bundle.path)")
        #expect(!(app.bundleIdentifier ?? "").hasPrefix("se.medda.opentraffic"), "\(app.bundle.path)")
        #expect(!(app.bundleIdentifier ?? "").hasPrefix("com.apple."), "\(app.bundle.path)")
        #expect(!FileManager.default.fileExists(atPath: app.bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path), "\(app.bundle.path)")
    }
}

@Test(.enabled(if: hasFixtureApp, "sh Examples/macapp-orbit/package.sh"))
func theOrbitFixtureIsYoursWithItsSourceFolder() throws {
    let app = try MacAppDiscovery.resolve(path: fixtureApp.path, context: MacAppDiscovery.Context(ownTeams: []))
    #expect(app.bundleIdentifier == "se.medda.orbit")
    #expect(app.projectDirectory?.path == ElectronDiscovery.realURL(repository.appendingPathComponent("Examples/macapp-orbit")).path)
}

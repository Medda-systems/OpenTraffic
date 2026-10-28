import Foundation
import Testing
@testable import OpenTrafficCore

// The sandbox shared Mac app copies run in (MacAppSandbox): the profile's rules, how a copy is wrapped
// so it only starts inside it, and, with sandbox-exec, that macOS enforces it: a process in it can't
// read or write a file outside its session folder, and can in its home.

@Suite("Mac app sandbox")
struct MacAppSandboxTests {
    private static let policy = MacAppSandbox.Policy(
        homeDirectory: "/Users/me",
        session: "/private/tmp/ot-session",
        writable: ["/private/tmp/ot-session/home", "/private/tmp/ot-session/tmp"],
        preferencesDomain: "com.apple.TextEdit.opentraffic",
        privateFolders: ["/private/tmp", "/private/var/folders/xy/abc"]
    )

    @Test func theProfileOnlyOpensTheSessionAndWhatAppsNeed() {
        let profile = MacAppSandbox.profile(Self.policy)
        func position(_ rule: String) -> String.Index? { profile.range(of: rule)?.lowerBound }
        // Nothing of the home folder, /Users, other volumes, other apps' temporary files.
        let home = #"(deny file-read* (subpath "/Users") (subpath "/Volumes") (subpath "/Users/me"))"#
        let temporary = #"(deny file-read* (subpath "/private/tmp") (subpath "/private/var/folders/xy/abc"))"#
        #expect(profile.contains(home) && profile.contains(temporary))
        // The session is read, after those denials (the later rule wins); its parents only looked up.
        let session = #"(allow file-read* (subpath "/private/tmp/ot-session"))"#
        #expect(position(temporary)! < position(session)!)
        #expect(profile.contains(#"(allow file-read-metadata (literal "/private/tmp"))"#))
        #expect(!profile.contains(#"(allow file-read* (subpath "/private/tmp"))"#))
        // In the home folder: the way to the preferences, fonts and keyboard layouts; nothing else.
        for parent in ["/Users", "/Users/me", "/Users/me/Library", "/Users/me/Library/Preferences"] {
            #expect(profile.contains("(allow file-read-metadata (literal \"\(parent)\"))"), "\(parent)")
        }
        #expect(profile.contains(#"(allow file-read* (subpath "/Users/me/Library/Fonts"))"#))
        #expect(profile.contains(#"(allow file-read* (subpath "/Users/me/Library/Keyboard Layouts"))"#))
        let homeReads = profile.split(separator: "\n").filter { $0.hasPrefix("(allow file-read* (subpath \"/Users") }
        #expect(homeReads.count == 2)
        // Writes: only its home and temporary folders (and /dev), after denying every other.
        let writes = profile.split(separator: "\n").filter { $0.hasPrefix("(allow file-write*") }
        #expect(writes == [#"(allow file-write* (subpath "/private/tmp/ot-session/home"))"#,
                           #"(allow file-write* (subpath "/private/tmp/ot-session/tmp"))"#,
                           #"(allow file-write* (subpath "/dev"))"#])
        #expect(position(#"(deny file-write* (subpath "/"))"#)! < position(String(writes[0]))!)
        // Its own preferences; others' only read, Apple's and the global ones.
        #expect(profile.contains(#"(allow user-preference-read user-preference-write (preference-domain "com.apple.TextEdit.opentraffic"))"#))
        #expect(position("(deny user-preference-read user-preference-write)")! < position("(allow user-preference-read user-preference-write")!)
        #expect(profile.contains(#"(preference-domain-prefix "com.apple.")"#))
        // No Open and Save dialogs (macOS shows them from a service outside the sandbox), nor AppKit's
        // other services that reach files for an app.
        #expect(profile.contains(#"(xpc-service-name "com.apple.appkit.xpc.openAndSavePanelService")"#))
        #expect(MacAppSandbox.refusedServices.allSatisfy { profile.contains("(xpc-service-name \"\($0)\")") })
        // No keychain, no other app doing it for the copy.
        #expect(profile.contains(#"(global-name "com.apple.securityd")"#))
        #expect(profile.contains("(deny lsopen)") && profile.contains("(deny appleevent-send)"))
        // Unix sockets: none of the user's agents (ssh-agent, OpenTraffic's API), only the system's few.
        #expect(position("(deny network-outbound (remote unix-socket))")! < position(#"(remote unix-socket (path-literal "/private/var/run/mDNSResponder"))"#)!)
        #expect(profile.contains(#"(allow network-outbound (remote unix-socket (subpath "/private/tmp/ot-session")))"#))
        #expect(profile.hasPrefix("(version 1)\n(allow default)\n"))
    }

    @Test func theDefaultPolicyKeepsOutTheUsersOwnTemporaryFolder() throws {
        let policy = MacAppSandbox.Policy(session: "/private/tmp/s", writable: [], preferencesDomain: "x.opentraffic")
        let folder = try #require(MacAppSandbox.userDirectory())
        #expect(policy.privateFolders.contains(folder))
        #expect(NSTemporaryDirectory().hasPrefix(folder) || ("/private" + NSTemporaryDirectory()).hasPrefix(ElectronSandbox.real(folder)))
        #expect(policy.homeDirectory == ElectronSandbox.realHomeDirectory)
    }

    @Test func everyBundleMacOSMayStartIsWrapped() throws {
        let scratch = try SandboxScratch()
        let app = try makeStubApp(in: scratch.url, entitlements: [:])
        for nested in ["Contents/XPCServices/Worker.xpc", "Contents/Library/LoginItems/Helper.app",
                       "Contents/Library/LoginItems/Helper.app/Contents/XPCServices/Fetch.xpc"] {
            let bundle = app.appendingPathComponent(nested)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let name = bundle.deletingPathExtension().lastPathComponent
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: bundle.appendingPathComponent("Contents/MacOS/\(name)").path)
            let info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "se.medda.stub.\(name.lowercased())"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        // A link to a bundle isn't one of its own.
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/Worker.xpc").path,
                                                   withDestinationPath: "../XPCServices/Worker.xpc")
        let bundles = MacAppSandbox.startableBundles(in: app).map { $0.path.replacingOccurrences(of: app.path, with: "") }
        #expect(bundles == ["", "/Contents/XPCServices/Worker.xpc", "/Contents/Library/LoginItems/Helper.app",
                            "/Contents/Library/LoginItems/Helper.app/Contents/XPCServices/Fetch.xpc"])

        let copy = scratch.url.appendingPathComponent("session/app/Stub.app")
        let profile = scratch.url.appendingPathComponent("session/sandbox.sb")
        _ = try MacAppSession.makeIsolatedCopy(of: app, at: copy, bundleIdentifier: "se.medda.stub.opentraffic", sandboxProfile: profile)
        for bundle in MacAppSandbox.startableBundles(in: copy) {
            let info = try #require(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))
            #expect(info["CFBundleExecutable"] as? String == MacAppSandbox.launcherName, "\(bundle.lastPathComponent)")
            let script = try String(contentsOf: bundle.appendingPathComponent("Contents/MacOS/\(MacAppSandbox.launcherName)"), encoding: .utf8)
            #expect(script.contains("exec /usr/bin/sandbox-exec -f '\(profile.path)' '\(bundle.path)/Contents/MacOS/"))
        }
        #expect(codesignVerifies(copy))
        // Wrapping it again (a bundle that already starts with the launcher) is refused, not doubled.
        #expect(throws: MacAppSessionError.self) { try MacAppSandbox.wrap(copy, profile: profile) }
    }

    @Test func theLauncherQuotesPaths() {
        let script = MacAppSandbox.launcherScript(profile: URL(fileURLWithPath: "/tmp/it's here/sandbox.sb"),
                                                  executable: URL(fileURLWithPath: "/tmp/A B.app/Contents/MacOS/A B"))
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains(#"exec /usr/bin/sandbox-exec -f '/tmp/it'\''s here/sandbox.sb' '/tmp/A B.app/Contents/MacOS/A B' "$@""#))
    }

    /// The real thing: a wrapped stub app, started by its launcher, under the profile a session writes.
    /// The "host's files" are a canary in the scratch folder (in the user's temporary folder, which the
    /// profile keeps out like the home folder) and the real home folder's listing.
    @Test(.enabled(if: MacAppSandbox.isAvailable))
    func aWrappedCopyCantReadOrWriteOutsideItsSession() throws {
        let scratch = try SandboxScratch()
        let host = scratch.url.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let canary = host.appendingPathComponent("canary.txt")
        try Data("the host's".utf8).write(to: canary)
        let session = scratch.url.appendingPathComponent("session")
        let home = session.appendingPathComponent("home")
        let tmp = session.appendingPathComponent("tmp")
        for folder in [home, tmp] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        // A Unix socket of the host's, like ssh-agent's or OpenTraffic's own API (a short path: sun_path).
        let socketPath = "/private/tmp/ot-sandbox-\(getpid()).sock"
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-lkU", socketPath]
        try listener.run()
        defer { listener.terminate(); unlink(socketPath) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) { usleep(10_000) }
        let reach = Process()
        reach.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        reach.arguments = ["-U", socketPath]
        reach.standardInput = FileHandle.nullDevice
        reach.standardOutput = FileHandle.nullDevice
        try reach.run()
        reach.waitUntilExit()
        #expect(reach.terminationStatus == 0, "outside the sandbox, the socket answers")
        // The stub's executable is a script that tries everything and says how it went.
        let app = session.appendingPathComponent("app/Probe.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let probe = """
        #!/bin/sh
        cat '\(canary.path)' >/dev/null 2>&1 && echo read-canary || echo no-read-canary
        (echo overwritten > '\(canary.path)') 2>/dev/null && echo wrote-canary || echo no-write-canary
        ls '\(ElectronSandbox.realHomeDirectory)/' >/dev/null 2>&1 && echo listed-home || echo no-list-home
        (echo saved > '\(home.path)/saved.txt') 2>/dev/null && echo wrote-home || echo no-write-home
        (echo x > '\(session.path)/sandbox.sb') 2>/dev/null && echo wrote-profile || echo no-write-profile
        /usr/bin/nc -U '\(socketPath)' </dev/null >/dev/null 2>&1 && echo reached-socket || echo no-socket
        """
        try Data(probe.utf8).write(to: app.appendingPathComponent("Contents/MacOS/Probe"))
        chmod(app.appendingPathComponent("Contents/MacOS/Probe").path, 0o755)
        let info: [String: Any] = ["CFBundleExecutable": "Probe", "CFBundleIdentifier": "se.medda.probe"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))

        let profile = session.appendingPathComponent("sandbox.sb")
        let policy = MacAppSandbox.Policy(session: session.path, writable: [home.path, tmp.path], preferencesDomain: "se.medda.probe.opentraffic")
        try Data(MacAppSandbox.profile(policy).utf8).write(to: profile)
        try MacAppSandbox.wrap(app, profile: profile)

        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/\(MacAppSandbox.launcherName)")
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(said.split(separator: "\n") == ["no-read-canary", "no-write-canary", "no-list-home", "wrote-home", "no-write-profile", "no-socket"])
        #expect(try String(contentsOf: canary, encoding: .utf8) == "the host's")
        #expect(try String(contentsOf: home.appendingPathComponent("saved.txt"), encoding: .utf8) == "saved\n")

        // Without its profile, the launcher starts nothing.
        try FileManager.default.removeItem(at: profile)
        let bare = Process()
        bare.executableURL = process.executableURL
        let bareOutput = Pipe()
        bare.standardOutput = bareOutput
        bare.standardError = FileHandle.nullDevice
        try bare.run()
        let bareSaid = String(decoding: bareOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        bare.waitUntilExit()
        #expect(bare.terminationStatus != 0 && bareSaid.isEmpty)
    }

    @Test(.enabled(if: MacAppSandbox.isAvailable))
    func aProcessInTheSandboxIsSeenAsSandboxed() throws {
        #expect(!MacAppSandbox.isSandboxed(getpid()))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MacAppSandbox.sandboxExec)
        process.arguments = ["-p", "(version 1)(allow default)", "/bin/sleep", "5"]
        try process.run()
        defer { process.terminate() }
        var sandboxed = false
        for _ in 0..<100 where !sandboxed {
            usleep(20_000)
            sandboxed = MacAppSandbox.isSandboxed(process.processIdentifier)
        }
        #expect(sandboxed)
    }
}

private final class SandboxScratch {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: ElectronSandbox.real(NSTemporaryDirectory())).appendingPathComponent("macapp-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

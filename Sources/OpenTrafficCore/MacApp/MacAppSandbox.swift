import Darwin
import Foundation

/// The macOS sandbox (Seatbelt) every shared Mac app's copy runs in, so whatever viewers make it do,
/// it can't read or write your files outside its session folder.
///
/// Not the App Sandbox: its Open and Save panels are the Powerbox, which hands the app whatever file
/// the person at the panel picks, and here that's a viewer. A Seatbelt profile has no such way out. On
/// macOS 27 every app's Open and Save panel comes from that same service, outside any sandbox of the
/// app's, so the profile refuses it (`refusedServices`): a copy shows no Open or Save dialog.
///
/// How a copy gets into it: `wrap` makes the copy's executable (`CFBundleExecutable`) a small script,
/// `opentraffic-sandbox`, that `exec`s `/usr/bin/sandbox-exec` with the session's profile, which `exec`s
/// the app's own executable. macOS still launches the copy as an app (hidden, as a new instance, with
/// its environment), and the process keeps its pid through both `exec`s, but the app's own code only
/// ever starts inside the sandbox: when the profile can't be applied, nothing of the app runs. The
/// app's XPC services and the apps inside it (helpers, login items) are wrapped the same way, since
/// macOS starts those on their own rather than as children of the copy. `isSandboxed` checks a launched
/// copy, and the session stops one that isn't.
///
/// What the profile lets the copy do (`profile`):
///
/// - read and write its home folder and temporary folder in the session folder; read the rest of the
///   session folder (its .app);
/// - read what isn't anyone's files: macOS (/System, /Library, /usr, /bin, …), /Applications, /opt;
/// - in your home folder only: look up the folders on the way to the session folder and to your
///   preferences (not list them), and read `~/Library/Fonts` and `~/Library/Keyboard Layouts`, so text
///   shows in your fonts and typing follows your keyboard;
/// - preferences (through cfprefsd, which asks the sandbox): read and write its own domain, read the
///   global one and Apple's (`com.apple.*`: appearance, keyboard, accessibility settings);
///
/// and what it refuses: reading or writing anything else in /Users (your home folder: Desktop,
/// Documents, Downloads, iCloud Drive, other apps' data and containers, App Group folders, keychains,
/// `~/.ssh`; and other users' and /Users/Shared) and on /Volumes, reading other apps' temporary files and
/// caches (/tmp, /var/tmp, your per-user folder in /var/folders), writing anywhere else at all, other
/// apps' preferences, the keychain, AppKit's services that reach your files for it (Open and Save
/// panels, `refusedServices`), opening apps, files or links through Launch Services or sending
/// Apple events (another app would do what the copy may not), and connecting to local Unix sockets
/// other than the system's name lookup, log and printing (ssh-agent, OpenTraffic's own API socket,
/// Docker's). The network is open as for the app itself, local TCP servers included.
public enum MacAppSandbox {
    public struct Policy: Sendable, Equatable {
        /// The user's real home folder (from the user database).
        public var homeDirectory: String
        /// The session folder: read.
        public var session: String
        /// The copy's home and temporary folders, in the session folder: read and written.
        public var writable: [String]
        /// The copy's preferences domain (`<id>.opentraffic`).
        public var preferencesDomain: String
        /// Folders in the home folder it may read (`~/Library/Fonts`, `~/Library/Keyboard Layouts`).
        public var readable: [String]
        /// Other folders it may not read: other apps' temporary files and caches.
        public var privateFolders: [String]

        public init(homeDirectory: String = ElectronSandbox.realHomeDirectory, session: String, writable: [String], preferencesDomain: String,
                    readable: [String]? = nil, privateFolders: [String]? = nil) {
            self.homeDirectory = homeDirectory
            self.session = session
            self.writable = writable
            self.preferencesDomain = preferencesDomain
            let library = URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library")
            self.readable = readable ?? ["Fonts", "Keyboard Layouts"].map { library.appendingPathComponent($0).path }
            self.privateFolders = privateFolders ?? (["/private/tmp", "/private/var/tmp"] + (MacAppSandbox.userDirectory().map { [$0] } ?? []))
        }
    }

    /// AppKit's XPC services that act on your files (or media, or screen) for an app, outside its
    /// sandbox: refused (`profile`). The Open and Save panel first of all (macOS 27 shows it from
    /// `com.apple.appkit.xpc.openAndSavePanelService` even for apps outside the App Sandbox), so a copy
    /// shows no Open or Save dialog; an in-process one (`NSUseRemoteSavePanel` off) crashes TextEdit as
    /// soon as it meets a folder it may not read (DesktopServices' container fetcher).
    public static let refusedServices = [
        "com.apple.appkit.xpc.openAndSavePanelService",
        "com.apple.appkit.xpc.documentPopoverViewService",
        "com.apple.appkit.xpc.VersionsUIHelper",
        "com.apple.MediaLibraryBrowser",
        "com.apple.appkit.xpc.sandboxedServiceRunner",
        "com.apple.automator.xpc.workflowServiceRunner",
        "com.apple.appkit.xpc.ColorSampler",
    ]

    /// Apps known not to work in the sandbox, by bundle identifier, with why: refused before a share
    /// starts (MacAppDiscovery.knownProblem). Measured on macOS 27.
    public static let incompatibleApps: [String: String] = [
        // Its document windows never show without the Open and Save panel service (File > New makes a
        // window that stays ordered out); at launch it shows only its update alert.
        "app.cyan.markedit": "needs macOS's Open and Save dialog service to show its documents, which OpenTraffic's sandbox refuses to shared copies (it would show them your files)",
    ]

    /// The name of the script that starts a copy inside the sandbox (its `CFBundleExecutable`).
    public static let launcherName = "opentraffic-sandbox"
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    /// Whether this Mac can run copies in the sandbox at all.
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: sandboxExec) }

    public static func profile(_ policy: Policy) -> String {
        let quoted = ElectronSandbox.quoted
        let real = ElectronSandbox.real
        let home = real(policy.homeDirectory)
        let session = real(policy.session)
        let preferences = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences").path
        var lines = [
            "(version 1)",
            "(allow default)",
            "",
            "; Files: nothing of anyone's home folder or other volumes, nor other apps' temporary files.",
            "(deny file-read* (subpath \"/Users\") (subpath \"/Volumes\") (subpath \(quoted(home))))",
        ]
        let privateFolders = policy.privateFolders.map(real).filter { $0 != "/" && !$0.isEmpty }
        if !privateFolders.isEmpty {
            lines.append("(deny file-read* " + privateFolders.map { "(subpath \(quoted($0)))" }.joined(separator: " ") + ")")
        }
        lines.append("; The folders on the way to the session and to the preferences can be looked up, not listed.")
        for parent in ElectronSandbox.parents(of: [policy.session, preferences + "/x"]) {
            lines.append("(allow file-read-metadata (literal \(quoted(parent))))")
        }
        for folder in policy.readable { lines.append("(allow file-read* (subpath \(quoted(real(folder)))))") }
        lines += [
            "(allow file-read* (subpath \(quoted(session))))",
            "",
            "; Writes: only its home and temporary folders.",
            "(deny file-write* (subpath \"/\"))",
        ]
        for folder in policy.writable { lines.append("(allow file-write* (subpath \(quoted(real(folder)))))") }
        lines += [
            "(allow file-write* (subpath \"/dev\"))",
            "",
            "; Preferences: its own; read the global ones and Apple's.",
            "(deny user-preference-read user-preference-write)",
            "(allow user-preference-read user-preference-write (preference-domain \(quoted(policy.preferencesDomain))))",
            "(allow user-preference-read (preference-domain \"kCFPreferencesAnyApplication\") (preference-domain-prefix \"com.apple.\"))",
            "",
            "; No Open and Save dialogs: macOS shows them from a service of its own, outside this sandbox, that",
            "; lists, previews, renames and makes folders among your files for whoever uses it. Nor the other",
            "; AppKit services that reach your files, media or screen for it: a document's title popover",
            "; (moving it), Browse All Versions, the media browser, Services and Automator workflows, the",
            "; color sampler.",
            "(deny mach-lookup " + Self.refusedServices.map { "(xpc-service-name \(quoted($0)))" }.joined(separator: " ") + ")",
            "",
            "; No keychain.",
            "(deny mach-lookup (global-name \"com.apple.securityd\") (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.security.agent\") (global-name \"com.apple.secd\"))",
            "",
            "; Nothing another app would do for it: no opening apps, files or links, no Apple events, no",
            "; local Unix sockets but the system's name lookup, log and printing, and its own (not ssh-agent,",
            "; OpenTraffic's own API, Docker's or any other agent's).",
            "(deny lsopen)",
            "(deny appleevent-send)",
            "(deny network-outbound (remote unix-socket))",
            "(allow network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")) (remote unix-socket (path-literal \"/private/var/run/syslog\")) (remote unix-socket (path-literal \"/private/var/run/cupsd\")))",
            "(allow network-outbound (remote unix-socket (subpath \(quoted(session)))))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The per-user folder in /var/folders (temporary files `T`, caches `C`, `0`), nil when unknown.
    static func userDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(cString: buffer)
        guard path.hasPrefix("/var/folders/") || path.hasPrefix("/private/var/folders/") else { return nil }
        // …/0/ is DARWIN_USER_DIR; its parent holds T and C too.
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    // MARK: Wrapping a copy

    /// The script a wrapped bundle starts with.
    static func launcherScript(profile: URL, executable: URL) -> String {
        func shell(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/sh
        # OpenTraffic runs this shared copy inside its sandbox: nothing of the app runs without it.
        exec \(sandboxExec) -f \(shell(profile.path)) \(shell(executable.path)) "$@"

        """
    }

    /// The bundles in a copy that macOS may start: the copy itself, then its XPC services and the apps
    /// inside it (helpers, login items, an updater in a framework), deepest last.
    static func startableBundles(in copy: URL) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        if let items = fm.enumerator(at: copy.appendingPathComponent("Contents", isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let item as URL in items {
                guard ["app", "xpc"].contains(item.pathExtension.lowercased()),
                      (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                found.append(item)
            }
        }
        return [copy] + found.sorted { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// Makes `bundle` start inside the sandbox of `profile`: its executable becomes `launcherName`,
    /// which runs the app's own executable (returned) under `sandbox-exec`. Throws when the bundle has
    /// no executable to wrap: then it can't be started sandboxed.
    @discardableResult
    static func wrap(_ bundle: URL, profile: URL) throws -> URL {
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: infoURL),
              var info = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != launcherName
        else { throw MacAppSessionError.failed("\(bundle.lastPathComponent) has no executable OpenTraffic can start in its sandbox.") }
        let folder = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let executable = folder.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MacAppSessionError.failed("\(bundle.lastPathComponent) has no executable OpenTraffic can start in its sandbox.")
        }
        let launcher = folder.appendingPathComponent(launcherName)
        try Data(launcherScript(profile: profile, executable: executable).utf8).write(to: launcher)
        guard chmod(launcher.path, 0o755) == 0 else { throw MacAppSessionError.failed("Couldn't make \(bundle.lastPathComponent)'s sandbox launcher executable.") }
        info["CFBundleExecutable"] = launcherName
        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: infoURL)
        return executable
    }

    // MARK: Checking a process

    private typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    private static let sandboxCheck: SandboxCheck? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: SandboxCheck.self)
    }()

    /// Whether a process runs in a sandbox (`sandbox_check` with no operation). False when unknown.
    public static func isSandboxed(_ pid: pid_t) -> Bool {
        guard let sandboxCheck else { return false }
        return sandboxCheck(pid, nil, 0) == 1
    }
}

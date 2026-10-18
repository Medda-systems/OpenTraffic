import Darwin
import Foundation
import Security

/// An Electron app running on this Mac that OpenTraffic can share: its renderer goes to viewers'
/// browsers, its main process runs in a sandboxed copy (see `ElectronHostSession`).
public struct ElectronApp: Sendable, Equatable, Identifiable {
    /// The app's folder (where its package.json is): what identifies it across restarts.
    public var id: String { (bundle ?? appDirectory).path }
    public var pid: Int32
    /// productName, otherwise name, from package.json.
    public var name: String
    public var version: String?
    public var appDirectory: URL
    /// The main entry, from package.json's "main" (index.js when there's none).
    public var mainEntry: URL
    /// The Electron binary the app runs on; the sandboxed copy runs on it too, in Node mode.
    public var electronBinary: URL
    /// Where the app keeps its data (~/Library/Application Support/<name>).
    public var userDataDirectory: URL
    /// The outermost folder of the project (a monorepo's root): what the sandboxed copy may read.
    public var projectRoot: URL
    /// Local ports the running app was told about in its environment (ELECTRON_RENDERER_URL=...).
    public var environmentPorts: [Int]
    /// Environment the sandboxed copy gets from the running app: dev-mode settings, not secrets.
    public var environment: [String: String]
    /// The project's own icon, when it has one.
    public var iconFile: URL?
    /// A finished app (an .app with its code in app.asar), not a project in development: its
    /// `appDirectory` is the app.asar, its main entry comes from the package.json inside.
    public var bundle: URL?
    public var isPackaged: Bool { bundle != nil }

    public init(
        pid: Int32, name: String, version: String?, appDirectory: URL, mainEntry: URL, electronBinary: URL,
        userDataDirectory: URL, projectRoot: URL, environmentPorts: [Int], environment: [String: String], iconFile: URL?,
        bundle: URL? = nil
    ) {
        self.bundle = bundle
        self.pid = pid
        self.name = name
        self.version = version
        self.appDirectory = appDirectory
        self.mainEntry = mainEntry
        self.electronBinary = electronBinary
        self.userDataDirectory = userDataDirectory
        self.projectRoot = projectRoot
        self.environmentPorts = environmentPorts
        self.environment = environment
        self.iconFile = iconFile
    }
}

/// Finds Electron apps being developed on this Mac: processes running a project's own Electron
/// (`node_modules/electron/dist/Electron.app`), as `electron .`, electron-vite and Forge start them.
public enum ElectronDiscovery {
    /// Every Electron app in development, one per project (the main process, not its helpers).
    public static func scan(homeDirectory: String = ElectronSandbox.realHomeDirectory) -> [ElectronApp] {
        var apps: [String: ElectronApp] = [:]
        for pid in allProcessIDs() {
            guard let executable = executablePath(pid) else { continue }
            let app: ElectronApp?
            if isDevelopmentElectron(executable) {
                guard let (arguments, environment) = ProcessArguments.read(pid),
                      !arguments.contains(where: { $0.hasPrefix("--type=") }) else { continue }
                app = resolve(pid: pid, executable: executable, arguments: arguments, environment: environment,
                              workingDirectory: ProcessDirectory.of(pid), homeDirectory: homeDirectory)
            } else if let bundle = BundleCache.shared.ownElectronBundle(forExecutable: executable) {
                app = finishedApp(bundle: bundle, pid: pid, homeDirectory: homeDirectory)
            } else {
                continue
            }
            guard let app else { continue }
            if let existing = apps[app.id], existing.pid < app.pid { continue }
            apps[app.id] = app
        }
        return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Electron binary npm installs into a project.
    public static func isDevelopmentElectron(_ executable: String) -> Bool {
        executable.hasSuffix("/Electron.app/Contents/MacOS/Electron") && executable.contains("/node_modules/")
    }

    /// The app a process runs, from its arguments (`Electron .`, `Electron path/to/main.js`), folder and environment.
    public static func resolve(
        pid: Int32, executable: String, arguments: [String], environment: [String: String],
        workingDirectory: URL?, homeDirectory: String
    ) -> ElectronApp? {
        let base = workingDirectory ?? URL(fileURLWithPath: environment["PWD"] ?? "/", isDirectory: true)
        let target = arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "."
        let targetURL = target.hasPrefix("/") ? URL(fileURLWithPath: target) : base.appendingPathComponent(target)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else { return nil }
        let appDirectory: URL
        var mainEntry: URL?
        if isDirectory.boolValue {
            appDirectory = realURL(targetURL)
        } else {
            guard let folder = nearestPackageFolder(from: targetURL.deletingLastPathComponent()) else { return nil }
            appDirectory = realURL(folder)
            mainEntry = realURL(targetURL)
        }
        guard let package = readPackage(appDirectory) else { return nil }
        let main = mainEntry ?? resolveMain(package["main"] as? String, in: appDirectory)
        guard let main, FileManager.default.fileExists(atPath: main.path) else { return nil }
        let name = (package["productName"] as? String) ?? (package["name"] as? String) ?? appDirectory.lastPathComponent
        let kept = sandboxEnvironment(environment)
        return ElectronApp(
            pid: pid,
            name: name,
            version: package["version"] as? String,
            appDirectory: appDirectory,
            mainEntry: main,
            electronBinary: URL(fileURLWithPath: executable),
            userDataDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Application Support").appendingPathComponent(name),
            projectRoot: projectRoot(of: appDirectory, homeDirectory: homeDirectory),
            environmentPorts: localPorts(in: kept),
            environment: kept,
            iconFile: projectIcon(in: appDirectory)
        )
    }

    // MARK: Pieces

    /// A path as the system resolves it (/tmp → /private/tmp), so the same folder always compares equal.
    public static func realURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Whether `folder` is `root` or inside it.
    public static func isInside(_ folder: URL, _ root: URL) -> Bool {
        let folder = realURL(folder).path, root = realURL(root).path
        return folder == root || folder.hasPrefix(root + "/")
    }

    static func readPackage(_ directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func nearestPackageFolder(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("package.json").path) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// package.json's main, like Node resolves it: a file, the file plus .js, or a folder's index.js.
    static func resolveMain(_ main: String?, in directory: URL) -> URL? {
        let base = directory.appendingPathComponent(main ?? "index.js").standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? base.appendingPathComponent("index.js") : base
        }
        for ext in ["js", "cjs", "mjs"] where FileManager.default.fileExists(atPath: base.path + "." + ext) {
            return URL(fileURLWithPath: base.path + "." + ext)
        }
        return base
    }

    /// The outermost folder above `directory` that's still part of the project (a monorepo's root,
    /// where hoisted node_modules are), never the home folder itself.
    static func projectRoot(of directory: URL, homeDirectory: String) -> URL {
        var root = directory.standardizedFileURL
        var current = root.deletingLastPathComponent()
        let markers = ["package.json", "node_modules", ".git", "pnpm-workspace.yaml"]
        while current.path.hasPrefix(homeDirectory + "/"), current.path != homeDirectory {
            if markers.contains(where: { FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }) { root = current }
            current.deleteLastPathComponent()
        }
        return root
    }

    static func projectIcon(in directory: URL) -> URL? {
        let candidates = ["build/icon.png", "resources/icon.png", "assets/icon.png", "src/assets/icon.png", "public/icon.png", "icon.png", "build/icon.icns", "resources/icon.icns"]
        return candidates.map { directory.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What the sandboxed copy keeps of the running app's environment: the settings a dev script
    /// sets for it (renderer URL, ports, NODE_ENV, VITE_*), never anything that looks like a secret.
    public static func sandboxEnvironment(_ environment: [String: String]) -> [String: String] {
        let secret = try! NSRegularExpression(pattern: "(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|_KEY$|^KEY$|AUTH|COOKIE|SESSION)", options: [.caseInsensitive])
        let wanted = try! NSRegularExpression(pattern: "^(ELECTRON_RENDERER_URL|ELECTRON_START_URL|ELECTRON_IS_DEV|NODE_ENV|DEBUG|VITE_.+|MAIN_WINDOW_.+|ELECTRON_VITE_.+|.+_(URL|PORT|HOST|ORIGIN|ENV|MODE))$")
        return environment.filter { name, value in
            let range = NSRange(name.startIndex..., in: name)
            guard wanted.firstMatch(in: name, range: range) != nil, secret.firstMatch(in: name, range: range) == nil else { return false }
            // URLs only when they're local: a remote URL can carry credentials.
            if value.contains("://") { return localPort(inURL: value) != nil }
            return value.count <= 256
        }
    }

    /// Local ports in environment values: http://localhost:5173 → 5173, and *_PORT=5198.
    public static func localPorts(in environment: [String: String]) -> [Int] {
        var ports = Set<Int>()
        for (name, value) in environment {
            if let port = localPort(inURL: value) { ports.insert(port) }
            if name.hasSuffix("_PORT"), let port = Int(value), (1...65_535).contains(port) { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func localPort(inURL value: String) -> Int? {
        guard let url = URL(string: value), let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) else { return nil }
        if let port = url.port { return port }
        return url.scheme == "https" ? 443 : 80
    }

    /// Ports a project's .env files name (PORT=8080, API_URL=http://localhost:8000): local services
    /// the app is configured to use.
    public static func envFilePorts(in directory: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var ports = Set<Int>()
        for name in names where name == ".env" || name.hasPrefix(".env.") {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
            var values: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<equals].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                values[key] = value
            }
            ports.formUnion(localPorts(in: values))
        }
        return ports.sorted()
    }

    // MARK: Processes

    static func allProcessIDs() -> [Int32] {
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func executablePath(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size, info.pbi_uid == getuid() else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// A process's arguments and environment (KERN_PROCARGS2), for processes of this user.
public enum ProcessArguments {
    public static func read(_ pid: Int32) -> ([String], [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return parse(Array(bytes.prefix(size)))
    }

    /// argc, the executable path, padding, then argc arguments and the environment, NUL-separated.
    public static func parse(_ bytes: [UInt8]) -> ([String], [String: String])? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        guard count > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var strings: [String] = []
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            if index == start { break } // the end of the environment
            strings.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        guard strings.count >= count else { return nil }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(count) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (Array(strings.prefix(count)), environment)
    }
}

extension ElectronDiscovery {
    /// The app in `directory` when it isn't running (a saved share started again): its own Electron
    /// from node_modules (here or in a parent folder), and `environment` for what the dev script would set.
    public static func app(atDirectory directory: URL, environment: [String: String], homeDirectory: String = ElectronSandbox.realHomeDirectory) -> ElectronApp? {
        var current = directory.standardizedFileURL
        while current.path != "/" {
            let binary = current.appendingPathComponent("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return resolve(pid: 0, executable: binary.path, arguments: [binary.path, directory.path], environment: environment,
                               workingDirectory: directory, homeDirectory: homeDirectory)
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}

// MARK: Finished apps

extension ElectronDiscovery {
    /// A finished Electron app: an .app whose code is in Contents/Resources/app.asar (or app/).
    public static func finishedApp(bundle: URL, pid: Int32 = 0, homeDirectory: String = ElectronSandbox.realHomeDirectory) -> ElectronApp? {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let code = [resources.appendingPathComponent("app.asar"), resources.appendingPathComponent("app")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let code, let info = Bundle(url: bundle)?.infoDictionary,
              let executable = info["CFBundleExecutable"] as? String else { return nil }
        let name = (info["CFBundleDisplayName"] as? String)?.nilIfEmpty ?? (info["CFBundleName"] as? String)?.nilIfEmpty ?? bundle.deletingPathExtension().lastPathComponent
        return ElectronApp(
            pid: pid,
            name: name,
            version: info["CFBundleShortVersionString"] as? String,
            appDirectory: code,
            mainEntry: code, // resolved inside app.asar by the host
            electronBinary: bundle.appendingPathComponent("Contents/MacOS/\(executable)"),
            userDataDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Application Support").appendingPathComponent(name),
            projectRoot: bundle,
            environmentPorts: [],
            environment: [:],
            iconFile: nil,
            bundle: bundle
        )
    }

    /// The .app an executable belongs to, when it's its main executable (not a helper's).
    static func appBundle(forExecutable executable: String) -> URL? {
        let parts = executable.components(separatedBy: "/Contents/MacOS/")
        guard parts.count == 2, parts[0].hasSuffix(".app"), !parts[1].contains("/"), !parts[0].contains(".app/") else { return nil }
        return URL(fileURLWithPath: parts[0], isDirectory: true)
    }

    static func isElectronBundle(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            && (fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/app.asar").path)
                || fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/app").path))
    }

    /// The project a finished app was built from, when it sits in that project's folder (dist/, out/).
    public static func sourceFolder(of bundle: URL) -> URL? {
        nearestPackageFolder(from: bundle.deletingLastPathComponent())
    }

    /// Whether a finished app is yours to share: built from a project on this Mac (it sits in a
    /// project's folder), not signed (or signed ad hoc), or signed by one of your own signing
    /// identities. Apps you only installed, signed by their makers, aren't.
    public static func isOwnBuild(_ bundle: URL, ownTeams: Set<String>) -> Bool {
        if nearestPackageFolder(from: bundle.deletingLastPathComponent()) != nil { return true }
        switch CodeSignature.team(of: bundle) {
        case .unsigned, .adHoc: return true
        case .team(let team): return ownTeams.contains(team)
        case .unreadable: return false
        }
    }
}

/// Which .app paths are Electron apps of yours: worked out once per path.
final class BundleCache: @unchecked Sendable {
    static let shared = BundleCache()
    private let lock = NSLock()
    private var verdicts: [String: URL?] = [:]
    private var teams: Set<String>?

    func ownElectronBundle(forExecutable executable: String) -> URL? {
        guard let bundle = ElectronDiscovery.appBundle(forExecutable: executable) else { return nil }
        if let known = lock.withLock({ verdicts[bundle.path] }) { return known }
        let own = ElectronDiscovery.isElectronBundle(bundle) && ElectronDiscovery.isOwnBuild(bundle, ownTeams: ownTeams())
        let verdict: URL? = own ? bundle : nil
        lock.withLock { verdicts[bundle.path] = verdict }
        return verdict
    }

    private func ownTeams() -> Set<String> {
        if let teams = lock.withLock({ teams }) { return teams }
        let found = CodeSignature.ownTeams()
        lock.withLock { teams = found }
        return found
    }
}

/// Code signatures, for telling your own builds from apps you installed.
public enum CodeSignature {
    public enum Signer: Equatable { case unsigned, adHoc, team(String), unreadable }

    public static func team(of bundle: URL) -> Signer {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return .unreadable }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess, let info = information as? [String: Any] else { return .unreadable }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty { return .team(team) }
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & 0x0002 != 0 { return .adHoc } // kSecCodeSignatureAdhoc
        return info[kSecCodeInfoIdentifier as String] == nil ? .unsigned : .adHoc
    }

    /// The team IDs of the code-signing identities in your keychain ("Developer ID Application: You (TEAMID)").
    public static func ownTeams() -> Set<String> {
        guard let output = ToolOutput.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], timeout: 5) else { return [] }
        return parseTeams(output)
    }

    static func parseTeams(_ output: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\(([A-Z0-9]{10})\)"#)
        return Set(pattern.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match in
            Range(match.range(at: 1), in: output).map { String(output[$0]) }
        })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Which server a localhost address means

extension ElectronDiscovery {
    /// The loopback address to reach `port` on for an app's "localhost" URL. Two servers can share a
    /// port number on IPv4 and IPv6 (a Vite dev server on [::1]:5173, another app on 127.0.0.1:5173):
    /// the one run from the app's project wins, then IPv4.
    public static func loopbackHost(forPort port: Int, projectRoot: URL?) -> String {
        guard let output = ToolOutput.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pcn"], timeout: 3) else { return "127.0.0.1" }
        return pickLoopbackHost(LocalListenerParser.parseLsof(output).filter { $0.port == port }, projectRoot: projectRoot) { ProcessDirectory.of($0) }
    }

    static func pickLoopbackHost(_ sockets: [ListeningSocket], projectRoot: URL?, directory: (Int32) -> URL?) -> String {
        func address(_ host: String) -> String {
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            switch bare {
            case "*", "0.0.0.0": return "127.0.0.1"
            case "::": return "::1"
            default: return bare
            }
        }
        let loopback = sockets.filter { ["127.0.0.1", "::1", "*", "0.0.0.0", "::"].contains($0.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) }
        if let root = projectRoot?.standardizedFileURL.path,
           let own = loopback.first(where: { socket in
               guard let pid = socket.pid, let folder = directory(pid) else { return false }
               return isInside(folder, URL(fileURLWithPath: root))
           }) {
            return address(own.host)
        }
        if loopback.contains(where: { address($0.host) == "127.0.0.1" }) { return "127.0.0.1" }
        return loopback.first.map { address($0.host) } ?? "127.0.0.1"
    }
}

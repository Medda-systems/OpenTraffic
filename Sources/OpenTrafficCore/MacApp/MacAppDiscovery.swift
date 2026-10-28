import Darwin
import Foundation
import Security

/// A native Mac app you are building (SwiftUI, AppKit, Catalyst) that OpenTraffic can share: a debug
/// build that is running, or a recent build Xcode or SwiftPM left in a build folder. An iPhone (or
/// iPad, watch, TV, Vision) app you've built and installed in a booted Simulator is one too, with
/// `runtime: .simulator(device)` (see SimulatorDiscovery).
public struct MacApp: Sendable, Equatable, Hashable, Identifiable {
    /// Where the app runs.
    public enum Runtime: Sendable, Equatable, Hashable {
        /// On this Mac.
        case mac
        /// In a booted Simulator device; `bundle` is the copy installed in that device.
        case simulator(SimulatorDevice)
    }

    /// What identifies the app across launches and rebuilds, and what a saved share keeps: the .app's
    /// path for a Mac app, `simulator:<udid>/<bundle id>` for a simulator app (its installed copy
    /// moves with every install).
    public var id: String {
        if let simulator, let bundleIdentifier { return SimulatorDiscovery.appID(udid: simulator.udid, bundleIdentifier: bundleIdentifier) }
        return bundle.path
    }
    /// CFBundleDisplayName, otherwise CFBundleName, otherwise the bundle's file name.
    public var name: String
    public var bundle: URL
    public var bundleIdentifier: String?
    public var version: String?
    /// The folder of the project the app is built from (where its Package.swift or .xcodeproj is),
    /// when it is known: what an agent edits to fix a comment.
    public var projectDirectory: URL?
    public var isRunning: Bool
    /// The running instance (the oldest one when several run), nil when the app isn't running.
    public var pid: Int32?
    /// The bundle's .icns, when it has one as a file (an asset-catalog icon has none: ask NSWorkspace).
    public var iconFile: URL?
    /// When the app was last built (its executable's modification date).
    public var builtAt: Date?
    public var runtime: Runtime
    /// An app installed on this Mac or made by another developer (TextEdit, an App Store app), not one
    /// you're building: listed under Installed, shared as a copy like your own, never rebuilt.
    public var isInstalled: Bool

    /// The Simulator device the app is installed in, nil for a Mac app.
    public var simulator: SimulatorDevice? {
        if case .simulator(let device) = runtime { return device }
        return nil
    }

    public init(
        name: String, bundle: URL, bundleIdentifier: String?, version: String? = nil, projectDirectory: URL?,
        isRunning: Bool, pid: Int32? = nil, iconFile: URL? = nil, builtAt: Date? = nil, runtime: Runtime = .mac,
        isInstalled: Bool = false
    ) {
        self.name = name
        self.bundle = bundle
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.projectDirectory = projectDirectory
        self.isRunning = isRunning
        self.pid = pid
        self.iconFile = iconFile
        self.builtAt = builtAt
        self.runtime = runtime
        self.isInstalled = isInstalled
    }
}

/// Why an .app can't be shared as a Mac app, said so that a person knows what to do instead.
public struct MacAppRefusal: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Finds the Mac apps you are building: running debug builds and recent Xcode builds, each with the
/// project folder it comes from, plus the apps you chose or shared before (`remembered`) and the
/// installed apps that are running (TextEdit, an App Store app, another developer's app: `isInstalled`).
/// Electron apps, OpenTraffic itself, the copies OpenTraffic runs for share sessions, parts of macOS
/// that aren't apps you use (the Finder, the Dock) and apps known not to work as a copy are never offered.
public enum MacAppDiscovery {
    /// Where to look and what counts as yours; `current` is this Mac, tests pass their own.
    public struct Context: Sendable {
        public var homeDirectory: String
        /// Xcode's DerivedData folder.
        public var derivedData: URL
        public var now: Date
        /// Builds older than this aren't listed (running apps always are).
        public var maxBuildAge: TimeInterval
        /// The team IDs of your signing identities; nil reads them from the keychain (once).
        public var ownTeams: Set<String>?
        /// The processes to look at as (pid, executable path); nil lists this user's processes.
        public var processes: [(pid: Int32, executable: String)]?
        /// Folders installed apps live in.
        public var installedRoots: [String]
        /// .app paths never offered (OpenTraffic itself).
        public var excludedBundles: Set<String>

        public init(
            homeDirectory: String = ElectronSandbox.realHomeDirectory, derivedData: URL? = nil, now: Date = Date(),
            maxBuildAge: TimeInterval = 30 * 24 * 3600, ownTeams: Set<String>? = nil,
            processes: [(pid: Int32, executable: String)]? = nil, installedRoots: [String]? = nil,
            excludedBundles: Set<String>? = nil
        ) {
            self.homeDirectory = homeDirectory
            self.derivedData = derivedData ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Developer/Xcode/DerivedData")
            self.now = now
            self.maxBuildAge = maxBuildAge
            self.ownTeams = ownTeams
            self.processes = processes
            self.installedRoots = installedRoots ?? ["/Applications", "/System", "/Library", homeDirectory + "/Applications"]
            self.excludedBundles = excludedBundles ?? MacAppDiscovery.ownBundles()
        }

        public static var current: Context { Context() }

        var teams: Set<String> { ownTeams ?? SignatureCache.shared.ownTeams() }
    }

    /// Every Mac app you are building (running ones first, then recent builds, each by name), then the
    /// installed apps that are running (`isInstalled`), by name.
    public static func scan(_ context: Context = .current) async -> [MacApp] {
        var context = context
        if context.processes == nil { context.processes = userProcesses() } // looked at once
        let running = runningApps(context)
        var apps = running
        let runningPaths = Set(running.map(\.id))
        let runningProducts = Set(running.map(productKey))
        for build in recentBuilds(context) where !runningPaths.contains(build.id) && !runningProducts.contains(productKey(build)) {
            apps.append(build)
        }
        apps.sort { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let listed = Set(apps.map(\.id))
        return apps + runningInstalledApps(context).filter { !listed.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app at `path` (an .app you name explicitly), or a refusal that says why. Any macOS
    /// application is accepted: your builds (in a project folder, unsigned or ad hoc signed, or signed
    /// by one of your own signing identities) and installed apps or other developers' (`isInstalled`),
    /// except OpenTraffic itself, its session copies, Electron apps, parts of macOS that aren't apps you
    /// use, and apps known not to work as a copy (`knownProblem`).
    public static func resolve(path: String, context: Context = .current) throws -> MacApp {
        let expanded = path.hasPrefix("~") ? context.homeDirectory + path.dropFirst() : path
        let url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MacAppRefusal("There is no app at \(path).")
        }
        let bundle = ElectronDiscovery.realURL(url)
        guard isDirectory.boolValue, bundle.pathExtension == "app", let info = macInfo(bundle) else {
            throw MacAppRefusal("\(bundle.lastPathComponent) is not a Mac app: give the path of an .app built for macOS.")
        }
        let name = displayName(bundle, info)
        if let reason = exclusion(bundle, info: info, context: context) { throw MacAppRefusal(reason(name)) }
        var project = projectDirectory(of: bundle, context: context)
        let yours = refusal(name, project: project, signer: SignatureCache.shared.signer(bundle), ownTeams: context.teams) == nil
        let installed = !yours || (project == nil && isInstalled(bundle, context: context))
        if let reason = knownProblem(bundle, info: info, installed: installed) { throw MacAppRefusal(reason(name)) }
        // Comments on another developer's app aren't fixed in whatever folder happens to hold it.
        if !yours { project = nil }
        return app(bundle: bundle, info: info, project: project, pid: runningPID(of: bundle, context: context), installed: installed)
    }

    /// The apps at `paths` (chosen with Choose App… or shared before) that can still be shared, in the
    /// order given and each once, by `resolve`'s rules: an app that's gone or that `resolve` refuses is
    /// left out. Unlike builds `scan` finds, they're listed whether they run or not, wherever they were
    /// built (a `swift build` or a package script's `dist/`).
    public static func remembered(_ paths: [String], context: Context = .current) -> [MacApp] {
        guard !paths.isEmpty else { return [] }
        var context = context
        if context.processes == nil { context.processes = userProcesses() } // looked at once, not per app
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let app = try? resolve(path: path, context: context), seen.insert(app.id).inserted else { return nil }
            return app
        }
    }

    // MARK: Running apps

    /// Running apps whose bundle is a debug build of yours.
    public static func runningApps(_ context: Context) -> [MacApp] {
        var found: [String: MacApp] = [:]
        for (pid, executable) in context.processes ?? userProcesses() {
            guard let bundleURL = ElectronDiscovery.appBundle(forExecutable: executable) else { continue }
            let bundle = ElectronDiscovery.realURL(bundleURL)
            if let existing = found[bundle.path], let other = existing.pid, other < pid { continue }
            guard let info = macInfo(bundle), exclusion(bundle, info: info, context: context) == nil,
                  !isInstalled(bundle, context: context), info["LSBackgroundOnly"] as? Bool != true else { continue }
            let project = projectDirectory(of: bundle, context: context)
            let debugBuild = isXcodeProduct(bundle, context: context) || buildFolderProject(of: bundle) != nil
            guard debugBuild || SignatureCache.shared.signer(bundle).isLocal else { continue }
            found[bundle.path] = app(bundle: bundle, info: info, project: project, pid: pid)
        }
        return Array(found.values)
    }

    /// Running apps that aren't builds of yours: installed ones (in /Applications, part of macOS, on a
    /// disk image) and other developers' apps anywhere, `isInstalled`. Only apps with a place in the
    /// Dock: not background or menu bar apps (LSUIElement), not parts of macOS that aren't apps you
    /// use (`isSystemComponent`), and not the apps `knownProblem` refuses.
    public static func runningInstalledApps(_ context: Context) -> [MacApp] {
        let own = Set(runningApps(context).map(\.bundle.path))
        var found: [String: MacApp] = [:]
        for (pid, executable) in context.processes ?? userProcesses() {
            guard let bundleURL = ElectronDiscovery.appBundle(forExecutable: executable) else { continue }
            let bundle = ElectronDiscovery.realURL(bundleURL)
            guard !own.contains(bundle.path) else { continue }
            if let existing = found[bundle.path], let other = existing.pid, other < pid { continue }
            guard !isNested(bundle), let info = macInfo(bundle), exclusion(bundle, info: info, context: context) == nil,
                  info["LSBackgroundOnly"] as? Bool != true, !isAgent(info), !isSystemComponent(bundle),
                  knownProblem(bundle, info: info, installed: true) == nil else { continue }
            let project = projectDirectory(of: bundle, context: context)
            if !isInstalled(bundle, context: context),
               refusal("", project: project, signer: SignatureCache.shared.signer(bundle), ownTeams: context.teams) == nil {
                continue // yours, though not a build runningApps lists (a signed release build of yours)
            }
            found[bundle.path] = app(bundle: bundle, info: info, project: nil, pid: pid, installed: true)
        }
        return Array(found.values)
    }

    /// A menu bar or background agent (LSUIElement): no Dock icon, usually no window of its own.
    static func isAgent(_ info: [String: Any]) -> Bool {
        if let flag = info["LSUIElement"] as? Bool { return flag }
        if let flag = info["LSUIElement"] as? String { return flag == "1" || flag.lowercased() == "true" }
        return false
    }

    // MARK: Xcode builds

    /// The newest macOS app per product in DerivedData's Build/Products/Debug*, built within
    /// `maxBuildAge`, with the project folder from DerivedData's info.plist (WorkspacePath).
    public static func recentBuilds(_ context: Context) -> [MacApp] {
        let fm = FileManager.default
        var newest: [String: MacApp] = [:]
        for folder in (try? fm.contentsOfDirectory(at: context.derivedData, includingPropertiesForKeys: nil)) ?? [] {
            guard let workspace = workspacePath(of: folder) else { continue }
            let project = projectFolder(forWorkspace: workspace)
            guard fm.fileExists(atPath: project.path) else { continue } // the project is gone: a stale build
            let products = folder.appendingPathComponent("Build/Products")
            for configuration in (try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
            where configuration.lastPathComponent.hasPrefix("Debug") {
                for item in (try? fm.contentsOfDirectory(at: configuration, includingPropertiesForKeys: nil)) ?? []
                where item.pathExtension == "app" && !item.lastPathComponent.hasSuffix("-Runner.app") {
                    let bundle = ElectronDiscovery.realURL(item)
                    guard let info = macInfo(bundle), exclusion(bundle, info: info, context: context) == nil,
                          let built = buildDate(bundle, info), context.now.timeIntervalSince(built) <= context.maxBuildAge else { continue }
                    let candidate = app(bundle: bundle, info: info, project: project, pid: nil)
                    let key = productKey(candidate)
                    if let existing = newest[key], let other = existing.builtAt, other >= built { continue }
                    newest[key] = candidate
                }
            }
        }
        return Array(newest.values)
    }

    /// DerivedData's record of the workspace or project a folder's builds come from.
    static func workspacePath(of derivedDataFolder: URL) -> URL? {
        guard let data = try? Data(contentsOf: derivedDataFolder.appendingPathComponent("info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = plist["WorkspacePath"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The folder a workspace path stands for: Orbit/Orbit.xcodeproj → Orbit; a Swift package's folder as is.
    static func projectFolder(forWorkspace workspace: URL) -> URL {
        var folder = workspace.standardizedFileURL
        while ["xcodeproj", "xcworkspace"].contains(folder.pathExtension) { folder.deleteLastPathComponent() }
        return folder
    }

    // MARK: Project folders

    /// The project an app is built from: DerivedData's WorkspacePath for Xcode builds, the folder
    /// holding `.build/` or `dist/` for SwiftPM and script builds, else the nearest folder above the
    /// app that looks like a project (Package.swift, .xcodeproj, .git), never the home folder itself.
    public static func projectDirectory(of bundle: URL, context: Context) -> URL? {
        if isXcodeProduct(bundle, context: context) {
            let relative = bundle.path.dropFirst(context.derivedData.path.count + 1)
            guard let name = relative.split(separator: "/").first,
                  let workspace = workspacePath(of: context.derivedData.appendingPathComponent(String(name))) else { return nil }
            let folder = projectFolder(forWorkspace: workspace)
            return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
        }
        if let project = buildFolderProject(of: bundle) { return project }
        var current = bundle.deletingLastPathComponent().standardizedFileURL
        let home = ElectronDiscovery.realURL(URL(fileURLWithPath: context.homeDirectory)).path
        while current.path != "/", current.path != home, current.path != context.homeDirectory {
            if isProjectFolder(current) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// The project folder an app's `.build/` or `dist/` folder belongs to.
    static func buildFolderProject(of bundle: URL) -> URL? {
        var current = bundle.deletingLastPathComponent().standardizedFileURL
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            if [".build", "dist"].contains(current.lastPathComponent), isProjectFolder(parent) { return parent }
            current = parent
        }
        return nil
    }

    static func isProjectFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        if ["Package.swift", ".git", "project.yml", "Project.swift"].contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return true }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// Whether an app is one of Xcode's debug products in DerivedData.
    static func isXcodeProduct(_ bundle: URL, context: Context) -> Bool {
        let derived = ElectronDiscovery.realURL(context.derivedData).path
        let path = bundle.path
        guard path.hasPrefix(derived + "/"), !path.contains("/Index.noindex/") else { return false }
        return path.dropFirst(derived.count).contains("/Build/Products/Debug")
    }

    // MARK: Yours or not

    /// Why an app isn't one you build (nil when it is), by the Electron feature's rule
    /// (`ElectronDiscovery.isOwnBuild`): built in a project folder, not signed or signed ad hoc, or
    /// signed by one of your identities. Apple's own apps carry no team ID (CodeSignature reads them
    /// as ad hoc), so code anchored to Apple is never yours. An app that isn't yours is still shared,
    /// as an installed app (`MacApp.isInstalled`): no project, never rebuilt.
    public static func refusal(_ name: String, project: URL?, signer: Signer, ownTeams: Set<String>) -> String? {
        if signer.isApple { return "\(name) is part of macOS or made by Apple." }
        if project != nil { return nil }
        switch signer.signer {
        case .unsigned, .adHoc: return nil
        case .team(let team) where ownTeams.contains(team): return nil
        case .team(let team):
            return "\(name) is signed by another developer (team \(team)), not by one of your signing identities."
        case .unreadable:
            return "\(name)'s code signature can't be read, so OpenTraffic can't tell whether you built it."
        }
    }

    /// An app's signer, and whether its code is anchored to Apple (macOS's own apps).
    public struct Signer: Equatable {
        public var signer: CodeSignature.Signer
        public var isApple: Bool
        public init(_ signer: CodeSignature.Signer, isApple: Bool = false) {
            self.signer = signer
            self.isApple = isApple
        }
        /// Built on this Mac: not signed, or signed ad hoc (and not Apple's).
        var isLocal: Bool {
            guard !isApple else { return false }
            switch signer {
            case .unsigned, .adHoc: return true
            default: return false
            }
        }

        public static func of(_ bundle: URL) -> Signer {
            Signer(CodeSignature.team(of: bundle), isApple: isAnchoredToApple(bundle))
        }

        static func isAnchoredToApple(_ bundle: URL) -> Bool {
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess else { return false }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess
        }
    }

    /// Why an app is never offered, whoever built it (nil when it may be).
    static func exclusion(_ bundle: URL, info: [String: Any], context: Context) -> ((String) -> String)? {
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        if context.excludedBundles.contains(bundle.path) || identifier == "se.medda.opentraffic" || identifier.hasPrefix("se.medda.opentraffic.") {
            return { _ in "OpenTraffic can't share itself." }
        }
        if identifier.hasSuffix(".opentraffic") {
            return { "\($0) is a copy OpenTraffic made for a share session, not your app." }
        }
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            return { "\($0) is an Electron app: share it from Electron Apps instead." }
        }
        if let type = info["CFBundlePackageType"] as? String, type != "APPL" {
            return { "\($0) is not an application." }
        }
        return nil
    }

    /// Parts of macOS that run as apps but aren't apps a person uses on their own (the Finder, the
    /// Dock, Siri, Control Center, setup assistants): /System/Library and /Library/Apple. Listing them
    /// would only clutter Installed, and a copy of one would fight the real one.
    static func isSystemComponent(_ bundle: URL) -> Bool {
        let path = bundle.path
        return path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/System/iOSSupport/")
    }

    /// An app inside another bundle (a crash reporter in a framework, a helper in an app's Library):
    /// part of something else, not an app of its own.
    static func isNested(_ bundle: URL) -> Bool {
        let bundleExtensions: Set<String> = ["app", "framework", "bundle", "plugin", "xpc", "appex", "kext", "systemextension"]
        return bundle.deletingLastPathComponent().pathComponents.contains { bundleExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// Why an app is known not to work as a copy (nil when nothing is known), checked before a share
    /// starts so the host hears it up front instead of seeing the copy crash:
    ///
    /// - parts of macOS that aren't apps a person uses (`isSystemComponent`);
    /// - an installed app (or another developer's) that uses CloudKit: CloudKit stops a process that
    ///   isn't signed with the app's iCloud entitlement, which only its developer can sign, so the
    ///   copy quits as it starts (MindNode, measured). Your own builds may use CloudKit only later, or
    ///   not at all in a debug build; they get the warning about entitlements the copy runs without.
    static func knownProblem(_ bundle: URL, info: [String: Any], installed: Bool) -> ((String) -> String)? {
        if isSystemComponent(bundle) {
            return { "\($0) is part of macOS itself; a copy of it can't run on its own." }
        }
        if installed, usesCloudKit(MacAppSession.entitlements(of: bundle)) {
            return { "\($0) keeps its data in iCloud (CloudKit), which only \($0) itself, signed by its developer, may use: a copy of it quits as it starts. OpenTraffic can't share it." }
        }
        return nil
    }

    /// Whether an app's entitlements ask for CloudKit.
    static func usesCloudKit(_ entitlements: [String: Any]) -> Bool {
        let services = entitlements["com.apple.developer.icloud-services"]
        if let list = services as? [String] { return list.contains { $0.hasPrefix("CloudKit") } }
        if let one = services as? String { return one == "*" || one.hasPrefix("CloudKit") }
        return false
    }

    /// Installed apps: in /Applications (yours or anyone's), part of macOS, on a mounted disk image,
    /// or run from a quarantine copy.
    static func isInstalled(_ bundle: URL, context: Context) -> Bool {
        let path = bundle.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") { return true }
        return context.installedRoots.contains { root in
            let real = ElectronDiscovery.realURL(URL(fileURLWithPath: root)).path
            return path.hasPrefix(real + "/") || path.hasPrefix(root + "/")
        }
    }

    // MARK: Pieces

    /// A macOS bundle's Info.plist (Contents/Info.plist with an executable), nil for anything else
    /// (an iOS app's Info.plist sits at its root).
    static func macInfo(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/\(executable)").path) else { return nil }
        return info
    }

    static func displayName(_ bundle: URL, _ info: [String: Any]) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info[key] as? String, !name.isEmpty { return name }
        }
        return bundle.deletingPathExtension().lastPathComponent
    }

    static func buildDate(_ bundle: URL, _ info: [String: Any]) -> Date? {
        guard let executable = info["CFBundleExecutable"] as? String else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent("Contents/MacOS/\(executable)").path)
        return attributes?[.modificationDate] as? Date
    }

    static func iconFile(_ bundle: URL, _ info: [String: Any]) -> URL? {
        guard let name = info["CFBundleIconFile"] as? String, !name.isEmpty else { return nil }
        let file = bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(name.hasSuffix(".icns") ? name : name + ".icns")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static func app(bundle: URL, info: [String: Any], project: URL?, pid: Int32?, installed: Bool = false) -> MacApp {
        MacApp(
            name: displayName(bundle, info),
            bundle: bundle,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            version: info["CFBundleShortVersionString"] as? String,
            projectDirectory: project.map(ElectronDiscovery.realURL),
            isRunning: pid != nil,
            pid: pid,
            iconFile: iconFile(bundle, info),
            builtAt: buildDate(bundle, info),
            isInstalled: installed
        )
    }

    /// The same product built twice (a running copy, a newer build elsewhere) is listed once.
    static func productKey(_ app: MacApp) -> String {
        (app.bundleIdentifier ?? app.name).lowercased()
    }

    static func runningPID(of bundle: URL, context: Context) -> Int32? {
        (context.processes ?? userProcesses())
            .filter { ElectronDiscovery.appBundle(forExecutable: $0.executable).map(ElectronDiscovery.realURL)?.path == bundle.path }
            .map(\.pid).min()
    }

    static func userProcesses() -> [(pid: Int32, executable: String)] {
        ElectronDiscovery.allProcessIDs().compactMap { pid in ElectronDiscovery.executablePath(pid).map { (pid, $0) } }
    }

    /// OpenTraffic's own bundle, when this process runs from one.
    static func ownBundles() -> Set<String> {
        let main = Bundle.main.bundleURL
        return main.pathExtension == "app" ? [ElectronDiscovery.realURL(main).path] : []
    }
}

/// Signatures worked out once per bundle (and again when it's rebuilt), and your signing teams once.
final class SignatureCache: @unchecked Sendable {
    static let shared = SignatureCache()
    private let lock = NSLock()
    private var signers: [String: (Date?, MacAppDiscovery.Signer)] = [:]
    private var teams: Set<String>?

    func signer(_ bundle: URL) -> MacAppDiscovery.Signer {
        let executable = MacAppDiscovery.macInfo(bundle).flatMap { MacAppDiscovery.buildDate(bundle, $0) }
        if let (date, known) = lock.withLock({ signers[bundle.path] }), date == executable { return known }
        let signer = MacAppDiscovery.Signer.of(bundle)
        lock.withLock { signers[bundle.path] = (executable, signer) }
        return signer
    }

    func ownTeams() -> Set<String> {
        if let teams = lock.withLock({ teams }) { return teams }
        let found = CodeSignature.ownTeams()
        lock.withLock { teams = found }
        return found
    }
}

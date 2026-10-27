import CoreGraphics
import Darwin
import Foundation

/// Building a shared Mac app from its project after its sources changed (an agent's fix, the user's
/// own edit), so the session can restart the copy with the new build.
///
///     let plan = try await MacAppBuild.plan(for: app, project: folder)  // xcodebuild … or swift build
///     let outcome = await MacAppBuild.run(plan, log: file) { line in … }
///
/// Xcode projects (an `.xcworkspace`, else an `.xcodeproj`) build with `xcodebuild` for the scheme
/// that makes the app, in the configuration of the discovered build (`Debug`), into the DerivedData
/// folder the app was found in, so the product path stays the one the session copies from. Swift
/// packages build with `swift build`, followed by the project's own `package.sh` when it has one
/// (it puts the executable into an .app, as the Orbit fixture's does).
public enum MacAppBuild {
    /// One command of a build.
    public struct Step: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var directory: URL

        public init(executable: String, arguments: [String], directory: URL) {
            self.executable = executable; self.arguments = arguments; self.directory = directory
        }

        /// The command as a person would type it (for the log).
        public var display: String {
            ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).map(MacAppBuild.quoted).joined(separator: " ")
        }
    }

    /// How the project is built.
    public enum Kind: Sendable, Equatable {
        /// An Xcode project or workspace (`container`).
        case xcode(container: URL)
        /// A Swift package; `script` is its own packaging script (package.sh), run after `swift build`.
        case swiftPM(script: URL?)
    }

    public struct Plan: Sendable, Equatable {
        /// The project folder (watched for changes; commands run there).
        public var project: URL
        public var kind: Kind
        public var steps: [Step]

        public init(project: URL, kind: Kind, steps: [Step]) {
            self.project = project; self.kind = kind; self.steps = steps
        }

        /// `xcodebuild -scheme Orbit … build`, or `swift build … && sh package.sh`.
        public var summary: String { steps.map(\.display).joined(separator: " && ") }
    }

    public enum Outcome: Sendable, Equatable {
        case succeeded
        /// The step that failed, with the lines that say why (errors first, else the output's end).
        case failed(step: String, lines: [String])
        case timedOut(step: String)
        case cancelled

        /// One line for the card and the log.
        public var message: String {
            switch self {
            case .succeeded: "The build succeeded."
            case .failed(let step, let lines):
                "The build failed (\(step))" + (lines.first.map { ": \($0)" } ?? ".")
            case .timedOut(let step): "The build took too long and was stopped (\(step))."
            case .cancelled: "The build was stopped."
            }
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No Xcode project, workspace or Package.swift in the folder.
        case noProject(String)
        /// `xcodebuild -list` found no scheme to build.
        case noScheme(String)
        /// The app comes from a Simulator: not built here.
        case simulator

        public var description: String {
            switch self {
            case .noProject(let folder): "There's no Xcode project or Swift package in \(folder) to build the app from."
            case .noScheme(let detail): "Couldn't tell which scheme builds the app: \(detail)"
            case .simulator: "Apps in a Simulator aren't rebuilt by OpenTraffic."
            }
        }
    }

    /// How long a build may run (a real project's first build can take minutes; the old app keeps
    /// serving meanwhile).
    public static let defaultTimeout: Duration = .seconds(15 * 60)
    /// How many of a failed build's lines are kept for the log.
    static let failureLineLimit = 20

    // MARK: Detecting the project

    /// How to build `bundle` from `project`: Xcode for apps in a DerivedData-style `Build/Products`
    /// folder (or projects without Package.swift), SwiftPM for packages.
    public static func detect(project: URL, bundle: URL) -> Kind? {
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(atPath: project.path)) ?? [])
            .map { URL(fileURLWithPath: project.path).appendingPathComponent($0, isDirectory: false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let name = bundle.deletingPathExtension().lastPathComponent
        func pick(_ ext: String) -> URL? {
            let found = items.filter { $0.pathExtension == ext }
            return found.first { $0.deletingPathExtension().lastPathComponent == name } ?? found.first
        }
        let container = pick("xcworkspace") ?? pick("xcodeproj")
        let package = fm.fileExists(atPath: project.appendingPathComponent("Package.swift").path)
        let fromXcode = bundle.path.contains("/Build/Products/")
        if let container, fromXcode || !package { return .xcode(container: container) }
        if package {
            let script = project.appendingPathComponent("package.sh")
            return .swiftPM(script: fm.fileExists(atPath: script.path) ? script : nil)
        }
        return nil
    }

    /// The build configuration of an Xcode product (`…/Build/Products/Debug/App.app` → `Debug`),
    /// whether it was built for Mac Catalyst, and the DerivedData folder when it isn't Xcode's default
    /// one (then `-derivedDataPath` keeps the product where the session found it).
    static func xcodeProduct(_ bundle: URL, defaultDerivedData: URL = MacAppDiscovery.Context().derivedData)
        -> (configuration: String, catalyst: Bool, derivedData: URL?) {
        let path = bundle.standardizedFileURL.path
        guard let range = path.range(of: "/Build/Products/") else { return ("Debug", false, nil) }
        let folder = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? "Debug"
        let catalyst = folder.hasSuffix("-maccatalyst")
        let configuration = folder.split(separator: "-").first.map(String.init) ?? "Debug"
        let root = URL(fileURLWithPath: String(path[..<range.lowerBound]))
        let defaultRoot = defaultDerivedData.standardizedFileURL.path + "/"
        let custom = root.path.hasPrefix(defaultRoot) ? nil : root
        return (configuration.isEmpty ? "Debug" : configuration, catalyst, custom)
    }

    /// The `xcodebuild` command for one scheme.
    static func xcodeSteps(container: URL, scheme: String, configuration: String, catalyst: Bool, derivedData: URL?) -> [Step] {
        var arguments = [container.pathExtension == "xcworkspace" ? "-workspace" : "-project", container.lastPathComponent,
                         "-scheme", scheme, "-configuration", configuration,
                         "-destination", catalyst ? "platform=macOS,variant=Mac Catalyst" : "platform=macOS"]
        if let derivedData { arguments += ["-derivedDataPath", derivedData.path] }
        arguments.append("build")
        return [Step(executable: "/usr/bin/xcodebuild", arguments: arguments, directory: URL(fileURLWithPath: container.deletingLastPathComponent().path))]
    }

    /// `swift build` (release when the app came from a release build), then the package's script.
    static func swiftPMSteps(project: URL, bundle: URL, script: URL?) -> [Step] {
        let release = bundle.path.contains("/release/")
        var steps = [Step(executable: "/usr/bin/swift", arguments: ["build", "-c", release ? "release" : "debug"], directory: project)]
        if let script { steps.append(Step(executable: "/bin/sh", arguments: [script.lastPathComponent], directory: project)) }
        return steps
    }

    /// The schemes in `xcodebuild -list -json` output.
    static func schemes(fromListJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let body = (object["workspace"] ?? object["project"]) as? [String: Any]
        return body?["schemes"] as? [String] ?? []
    }

    /// The scheme that builds the app: the one named like the app or its executable, else the only
    /// scheme that isn't a test or package scheme, else the first.
    static func scheme(among schemes: [String], appName: String, executable: String?) -> String? {
        let names = [appName, executable].compactMap { $0?.lowercased() }
        if let exact = schemes.first(where: { names.contains($0.lowercased()) }) { return exact }
        let likely = schemes.filter { !$0.hasSuffix("Tests") && !$0.hasSuffix("-Package") && !$0.hasSuffix("UITests") }
        return likely.first ?? schemes.first
    }

    /// Works out the build for `app` from `project` (`xcodebuild -list` for an Xcode project, which
    /// can take a few seconds).
    public static func plan(for app: MacApp, project: URL, timeout: Duration = .seconds(60)) async throws -> Plan {
        if app.simulator != nil { throw Failure.simulator }
        guard let kind = detect(project: project, bundle: app.bundle) else { throw Failure.noProject(project.path) }
        switch kind {
        case .swiftPM(let script):
            return Plan(project: project, kind: kind, steps: swiftPMSteps(project: project, bundle: app.bundle, script: script))
        case .xcode(let container):
            let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
            let list = Step(executable: "/usr/bin/xcodebuild", arguments: ["-list", "-json", flag, container.lastPathComponent],
                            directory: URL(fileURLWithPath: container.deletingLastPathComponent().path))
            let captured = OutputCollector()
            let outcome = await run(list, timeout: timeout, collector: captured, line: { _ in })
            guard outcome == .succeeded else {
                throw Failure.noScheme("xcodebuild -list said: " + captured.tail(3).joined(separator: " "))
            }
            let executable = (NSDictionary(contentsOf: app.bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleExecutable"] as? String)
            let all = schemes(fromListJSON: captured.standardOutput)
            guard let scheme = scheme(among: all, appName: app.name, executable: executable) else {
                throw Failure.noScheme("\(container.lastPathComponent) lists none.")
            }
            let product = xcodeProduct(app.bundle)
            return Plan(project: project, kind: kind, steps: xcodeSteps(container: container, scheme: scheme, configuration: product.configuration,
                                                                         catalyst: product.catalyst, derivedData: product.derivedData))
        }
    }

    // MARK: Running a build

    /// Runs the plan's steps one after another; every output line goes to `log` (a file, appended)
    /// and to `line`. Stops at the first failing step. Cancelling the task stops the build.
    public static func run(_ plan: Plan, log: URL? = nil, timeout: Duration = defaultTimeout,
                           line: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        let file = log.flatMap { url -> FileHandle? in
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            return handle
        }
        defer { try? file?.close() }
        let deadline = ContinuousClock.now + timeout
        for step in plan.steps {
            let collector = OutputCollector()
            file?.write(Data("$ \(step.display)\n".utf8))
            let remaining = deadline - ContinuousClock.now
            let outcome = await run(step, timeout: remaining, collector: collector) { text in
                file?.write(Data((text + "\n").utf8))
                line(text)
            }
            switch outcome {
            case .succeeded: continue
            case .failed(let step, _): return .failed(step: step, lines: failureLines(collector.lines))
            default: return outcome
            }
        }
        return .succeeded
    }

    /// The lines that say why a build failed: the compiler's `error:` lines (deduplicated, those with a
    /// file and line first), else the last lines of its output.
    static func failureLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        // Without the compiler's diagnostic drawings (`|   `- error: …`).
        let errors = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ($0.contains("error:") || $0.hasPrefix("error ")) && !$0.hasPrefix("|") }
            .filter { seen.insert($0).inserted }
        // `file:line:column: error: …` first: they say what's wrong; the tool's own lines come after.
        let located = errors.filter { $0.range(of: #":\d+:\d+: error:"#, options: .regularExpression) != nil }
        let ordered = located + errors.filter { !located.contains($0) }
        if !ordered.isEmpty { return Array(ordered.prefix(failureLineLimit)) }
        return Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(failureLineLimit))
    }

    /// A line without terminal escape sequences (colors, `ESC[1;31m`).
    static func plain(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        return line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    /// Whether an output line is worth the share's log (the full output is in the build's own log
    /// file): errors and the result (`** BUILD SUCCEEDED **`, `Build complete!`, a script's `Built …`).
    public static func isNotable(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return false }
        if text.contains("error:") || text.hasPrefix("** ") { return true }
        return ["Build complete", "Built "].contains { text.hasPrefix($0) }
    }

    /// Output of one step: its lines (both streams, in arrival order) and standard output alone.
    final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        private var output = Data()

        func add(line: String) { lock.withLock { all.append(line); if all.count > 5000 { all.removeFirst(all.count - 5000) } } }
        func add(standardOutput data: Data) { lock.withLock { output.append(data) } }
        var lines: [String] { lock.withLock { all } }
        var standardOutput: Data { lock.withLock { output } }
        func tail(_ count: Int) -> [String] { Array(lines.filter { !$0.isEmpty }.suffix(count)) }
    }

    /// Runs one command in its own process group (so a timeout or cancel stops its compilers and
    /// scripts too), with the user's environment less `ELECTRON_RUN_AS_NODE`.
    static func run(_ step: Step, timeout: Duration, collector: OutputCollector, line: @escaping @Sendable (String) -> Void) async -> Outcome {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        // Packaging scripts call tools by name; an app opened from Finder has a short PATH.
        let path = environment["PATH"] ?? ""
        let needed = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"].filter { !path.split(separator: ":").contains(Substring($0)) }
        environment["PATH"] = ([path] + needed).filter { !$0.isEmpty }.joined(separator: ":")
        environment["NSUnbufferedIO"] = "YES"

        let out = Pipe(), err = Pipe()
        let pid: pid_t
        do {
            pid = try spawn(step, environment: environment, output: out.fileHandleForWriting.fileDescriptor, error: err.fileHandleForWriting.fileDescriptor)
        } catch {
            let text = "Couldn't run \(step.executable): \(error)"
            collector.add(line: text)
            return .failed(step: step.display, lines: [text])
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let readers = (0..<2).map { _ in
            LineReader { raw in
                // The compiler colors its diagnostics even into a pipe: plain text for the log, the
                // card and the error lines (`file:line:col: error:` must read as such).
                let text = plain(raw)
                guard !text.isEmpty else { return }
                collector.add(line: text)
                line(text)
            }
        }
        let drained = DispatchGroup()
        for (index, pipe) in [out, err].enumerated() {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    readers[index].feed(Data([0x0A]))
                    drained.leave()
                    return
                }
                if index == 0 { collector.add(standardOutput: data) }
                readers[index].feed(data)
            }
        }
        let stopper = Stopper(pid: pid)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timer = DispatchWorkItem { stopper.stop(.timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(seconds, 0), execute: timer)
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                    continuation.resume(returning: status)
                }
            }
        } onCancel: {
            stopper.stop(.cancelled)
        }
        timer.cancel()
        // What the build printed last, before the outcome is decided (a grandchild that keeps the
        // pipe open is not waited for long).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = drained.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
        switch stopper.reason {
        case .cancelled?: return .cancelled
        case .timedOut?: return .timedOut(step: step.display)
        case nil: break
        }
        let exited = status & 0x7f == 0
        return exited && (status >> 8) & 0xff == 0 ? .succeeded : .failed(step: step.display, lines: [])
    }

    /// posix_spawn with a process group of its own, standard input from /dev/null and the given
    /// output and error; no other descriptors are inherited.
    private static func spawn(_ step: Step, environment: [String: String], output: Int32, error: Int32) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Signals this process ignores or blocks (a test runner ignores SIGINT) would be inherited, and
        // a build that ignores SIGINT can't be stopped cleanly.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, error, 2)
        posix_spawn_file_actions_addchdir_np(&actions, step.directory.path)
        let arguments = ([step.executable] + step.arguments).map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, step.executable, &actions, &attributes, arguments, variables)
        guard result == 0 else { throw MacAppBuild.SpawnError(code: result) }
        return pid
    }

    struct SpawnError: Error, CustomStringConvertible {
        var code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    /// Stops a build's process group once: SIGINT (xcodebuild and swift build cancel cleanly), SIGKILL
    /// 5 s later if anything of it is left.
    private final class Stopper: @unchecked Sendable {
        enum Reason { case cancelled, timedOut }
        private let lock = NSLock()
        private var _reason: Reason?
        let pid: pid_t

        init(pid: pid_t) { self.pid = pid }

        var reason: Reason? { lock.withLock { _reason } }

        func stop(_ reason: Reason) {
            let first = lock.withLock { () -> Bool in
                guard _reason == nil else { return false }
                _reason = reason
                return true
            }
            guard first else { return }
            let group = pid
            killpg(group, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { killpg(group, SIGKILL) }
        }
    }

    static func quoted(_ argument: String) -> String {
        argument.isEmpty || argument.contains(where: { " \"'$\\".contains($0) }) ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" : argument
    }
}

// MARK: - Watching the sources

/// Watches a Mac app's project folder and calls `changed` once a burst of changes has been quiet
/// for `delay` (1 s), when its source files really differ from the last time (dates and sizes).
/// Build output (.build, DerivedData, build, dist), version control and Xcode's per-user state
/// don't count. Thread-safe; stops when released.
public final class MacAppSourceWatcher: @unchecked Sendable {
    /// Folders whose changes are never a source change.
    public static let ignoredFolders: Set<String> = ProjectWatcher.ignoredFolders.union(["DerivedData", "build", "dist", "xcuserdata", "Pods"])

    public let directory: URL
    private let changed: @Sendable () -> Void
    private let lock = NSLock()
    /// Nil until the first fingerprint is taken (in the background, so a big project doesn't hold up
    /// the caller).
    private var baseline: [String: [Double]]?
    private var watcher: ProjectWatcher?

    public init(directory: URL, delay: TimeInterval = 1, changed: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.changed = changed
        watcher = ProjectWatcher(directory: directory, delay: delay, ignoring: Self.ignoredFolders) { [weak self] in
            if self?.takeChange() == true { self?.changed() }
        }
    }

    deinit { stop() }

    /// Starts watching; false if the folder can't be watched.
    @discardableResult
    public func start() -> Bool {
        guard lock.withLock({ watcher })?.start() == true else { return false }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let first = Self.fingerprint(self.directory)
            self.lock.withLock { if self.baseline == nil { self.baseline = first } }
        }
        return true
    }

    public func stop() { lock.withLock { watcher }?.stop() }

    /// Whether the sources changed since the last change was taken (and takes it). The watcher calls
    /// this itself; call it to check at once (an agent finished its work). Reads the folder: call it
    /// off the main thread. The first call only takes the fingerprint when `start` hasn't yet.
    public func takeChange() -> Bool {
        let current = Self.fingerprint(directory)
        return lock.withLock {
            guard let baseline else {
                self.baseline = current
                return false
            }
            guard current != baseline else { return false }
            self.baseline = current
            return true
        }
    }

    /// Every file's modification date and size, outside the ignored folders and hidden files, at most
    /// 8 folders deep and 20 000 files.
    static func fingerprint(_ root: URL) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if enumerator.level > 8 || ignoredFolders.contains(url.lastPathComponent) || url.pathExtension == "xcresult" { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent.hasSuffix("~") { continue }
            result[url.path] = [values.contentModificationDate?.timeIntervalSince1970 ?? 0, Double(values.fileSize ?? 0)]
            if result.count >= 20_000 { break }
        }
        return result
    }
}

// MARK: - Replaying what viewers did

/// Putting viewers back where they were after a relaunch: the viewer actions of the last launch are
/// sent again to the new launch, their windows and elements found again by key (keys are label
/// paths, the same in every launch of the same build; a window's id is not).
public enum MacAppReplay {
    /// Where an action was aimed when a viewer sent it.
    public struct Target: Sendable, Equatable {
        /// The window's key root (`/Window:` for the main window).
        public var windowRoot: String
        /// The element: the key of `act` and `setText`, the deepest element under a pointer event.
        public var key: String?
        /// That element's frame in the window (points), so a click lands on the same spot of it.
        public var frame: CGRect?

        public init(windowRoot: String, key: String? = nil, frame: CGRect? = nil) {
            self.windowRoot = windowRoot; self.key = key; self.frame = frame
        }
    }

    /// A window of the new launch, as the mirror sees it.
    public struct Window: Sendable, Equatable {
        public var id: MirrorProtocol.WindowID
        public var root: String
        /// Every element's frame in the window, by key.
        public var nodes: [String: CGRect]

        public init(id: MirrorProtocol.WindowID, root: String, nodes: [String: CGRect]) {
            self.id = id; self.root = root; self.nodes = nodes
        }
    }

    public enum Resolution: Sendable, Equatable {
        /// Send this (the window and the point made right for the new launch).
        case send(MirrorProtocol.ClientMessage, Target?)
        /// The window it was aimed at isn't there (yet).
        case missingWindow(String)
        /// The element it was aimed at isn't there (yet).
        case missingElement(String)

        public var isSend: Bool { if case .send = self { true } else { false } }
    }

    /// Recorded actions that are replayed: everything `MacAppSession.isRecorded` keeps (pointer moves
    /// aren't recorded at all).
    public static func replays(_ message: MirrorProtocol.ClientMessage) -> Bool {
        MacAppSession.isRecorded(message)
    }

    /// The action `message` (aimed at `target` when it was sent) for the new launch's `windows`.
    public static func resolve(_ message: MirrorProtocol.ClientMessage, target: Target?, in windows: [Window]) -> Resolution {
        if case .menuAction = message { return .send(message, nil) }
        guard message.window != nil else { return .send(message, nil) }
        guard let target else { return .missingWindow("an unknown window") }
        guard let window = windows.first(where: { $0.root == target.windowRoot }) else { return .missingWindow(target.windowRoot) }
        var newTarget = target
        func element(_ key: String) -> CGRect? { window.nodes[key] }
        switch message {
        case .act(var act):
            guard let frame = element(act.key) else { return .missingElement(act.key) }
            act.window = window.id
            newTarget.frame = frame
            return .send(.act(act), newTarget)
        case .setText(var setText):
            guard let frame = element(setText.key) else { return .missingElement(setText.key) }
            setText.window = window.id
            newTarget.frame = frame
            return .send(.setText(setText), newTarget)
        case .pointer(var pointer):
            pointer.window = window.id
            if let key = target.key {
                guard let frame = element(key) else { return .missingElement(key) }
                // The same spot of the same element, wherever it is now.
                let old = target.frame ?? frame
                pointer.x = clamp(frame.minX + (pointer.x - old.minX), frame.minX, frame.maxX)
                pointer.y = clamp(frame.minY + (pointer.y - old.minY), frame.minY, frame.maxY)
                newTarget.frame = frame
            }
            return .send(.pointer(pointer), newTarget)
        case .text(var text):
            text.window = window.id
            return .send(.text(text), newTarget)
        case .key(var key):
            key.window = window.id
            return .send(.key(key), newTarget)
        case .windowAction(var action):
            action.window = window.id
            return .send(.windowAction(action), newTarget)
        case .viewport, .requestControl, .releaseControl, .menuAction:
            return .send(message, nil)
        }
    }

    /// Sends `path` again, in order: waits up to `treeWait` for the first tree, then for each action
    /// finds its window and element in `windows()` (waiting up to `elementWait`, e.g. for a sheet an
    /// earlier action opens), `send`s it made right for the new launch (its message and new target)
    /// and waits `gap`. Stops at the first action whose window or element doesn't appear, or when
    /// `isCurrent` turns false (the launch quit). Returns the report and the actions sent.
    @MainActor public static func run(_ path: [MacAppSession.RecordedAction], gap: Duration, elementWait: Duration, treeWait: Duration,
                                      windows: () async -> [Window], send: (MacAppSession.RecordedAction) -> Void,
                                      isCurrent: () -> Bool) async -> (report: MacAppSession.ReplayReport, replayed: [MacAppSession.RecordedAction]) {
        let path = path.filter { replays($0.message) }
        guard !path.isEmpty else { return (.init(replayed: 0, total: 0), []) }
        var current = await windows()
        let treeDeadline = ContinuousClock.now + treeWait
        while current.first?.nodes.isEmpty ?? true, ContinuousClock.now < treeDeadline, isCurrent() {
            try? await Task.sleep(for: .milliseconds(50))
            current = await windows()
        }
        var sent: [MacAppSession.RecordedAction] = []
        for (index, action) in path.enumerated() {
            var resolution = resolve(action.message, target: action.target, in: current)
            let deadline = ContinuousClock.now + elementWait
            while !resolution.isSend, ContinuousClock.now < deadline, isCurrent() {
                try? await Task.sleep(for: .milliseconds(50))
                current = await windows()
                resolution = resolve(action.message, target: action.target, in: current)
            }
            guard isCurrent() else { return (.init(replayed: index, total: path.count, stoppedAt: "the app quit"), sent) }
            guard case .send(let message, let target) = resolution else {
                return (.init(replayed: index, total: path.count, stoppedAt: describe(action.message, target: action.target)), sent)
            }
            var replayed = action
            replayed.message = message
            replayed.target = target ?? action.target
            send(replayed)
            sent.append(replayed)
            try? await Task.sleep(for: gap)
            current = await windows()
        }
        return (.init(replayed: path.count, total: path.count), sent)
    }

    /// The deepest element at a window-relative point (the last in tree order that contains it).
    public static func element(at point: CGPoint, in nodes: [MirrorProtocol.AXNode]) -> MirrorProtocol.AXNode? {
        nodes.last { $0.w > 0 && $0.h > 0 && CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(point) }
    }

    /// An action in a few words, for the log: `press /Window:/Button:Add Order`.
    public static func describe(_ message: MirrorProtocol.ClientMessage, target: Target?) -> String {
        switch message {
        case .act(let act): "\(act.action.rawValue) \(act.key)"
        case .setText(let setText): "set the text of \(setText.key)"
        case .pointer(let pointer): "\(pointer.kind.rawValue) on \(target?.key ?? target?.windowRoot ?? "the window")"
        case .text: "typing"
        case .key(let key): "the \(key.code.rawValue) key"
        case .menuAction(let action): "the menu item \(action.path.joined(separator: " > "))"
        case .windowAction(let action): "\(action.action.rawValue) \(target?.windowRoot ?? "a window")"
        case .viewport, .requestControl, .releaseControl: message.type
        }
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), max(low, high)) }
}

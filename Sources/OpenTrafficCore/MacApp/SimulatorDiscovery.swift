import Foundation
import os

/// A booted iOS (or watchOS, tvOS, visionOS) Simulator device, as `simctl list devices` describes it.
public struct SimulatorDevice: Sendable, Hashable, Codable {
    public var udid: String
    /// What the device is called in Simulator.app and Xcode: "iPhone 17".
    public var name: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    public var runtimeIdentifier: String
    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17`, nil when simctl doesn't say.
    public var deviceTypeIdentifier: String?
    /// The device's data folder (`…/CoreSimulator/Devices/<udid>/data`), nil when simctl doesn't say.
    public var dataPath: URL?

    public init(udid: String, name: String, runtimeIdentifier: String, deviceTypeIdentifier: String? = nil, dataPath: URL? = nil) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.dataPath = dataPath
    }

    /// "iOS 27.0" for `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    public var runtimeName: String {
        let last = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        var parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return last }
        let platform = parts.removeFirst()
        return "\(platform == "xrOS" ? "visionOS" : platform) \(parts.joined(separator: "."))"
    }

    /// "iPhone 17 Simulator": how the menu bar names it.
    public var label: String { "\(name) Simulator" }
}

/// Finds the booted Simulator devices and the apps you've built and installed in them, as `MacApp`s
/// with `runtime: .simulator(device)`, so they're offered next to your Mac apps.
///
/// Discovery never boots, shuts down or launches anything, and it doesn't run `simctl` at all unless
/// a simulator is running (a `launchd_sim` process, or Simulator.app): on a Mac without Xcode, or
/// whose simulator service is stuck, the scan finds nothing and says nothing. Every `simctl` call has
/// a deadline, and results (failures included) are kept for a while so the 4-second menu bar refresh
/// doesn't call it every time.
public enum SimulatorDiscovery {
    /// The Simulator app's bundle identifier.
    public static let simulatorAppIdentifier = "com.apple.iphonesimulator"
    /// Devices OpenTraffic makes for "Share with Empty Data" are called "OpenTraffic · iPhone 17";
    /// they're never offered themselves.
    public static let dedicatedDevicePrefix = "OpenTraffic · "

    public struct Context: Sendable {
        /// `xcrun`; tests give a fake one.
        public var xcrun: String
        /// Xcode's DerivedData folder, where the builds the installed apps come from are.
        public var derivedData: URL
        /// The processes to look at as (pid, executable path); nil lists this user's processes.
        public var processes: [(pid: Int32, executable: String)]?
        /// Run simctl even when no simulator process is seen (tests with a fake xcrun).
        public var skipsProcessCheck: Bool
        /// How long one simctl call may take.
        public var timeout: TimeInterval
        public var cache: SimulatorCache

        public init(
            xcrun: String = "/usr/bin/xcrun", homeDirectory: String = ElectronSandbox.realHomeDirectory, derivedData: URL? = nil,
            processes: [(pid: Int32, executable: String)]? = nil, skipsProcessCheck: Bool = false, timeout: TimeInterval = 8,
            cache: SimulatorCache = .shared
        ) {
            self.xcrun = xcrun
            self.derivedData = derivedData ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Developer/Xcode/DerivedData")
            self.processes = processes
            self.skipsProcessCheck = skipsProcessCheck
            self.timeout = timeout
            self.cache = cache
        }

        /// This Mac. A debug build can be pointed at a fake xcrun and DerivedData with
        /// OPENTRAFFIC_TEST_XCRUN and OPENTRAFFIC_TEST_DERIVED_DATA (for screenshots of the menu bar
        /// without a booted simulator).
        public static var current: Context {
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if let fake = environment["OPENTRAFFIC_TEST_XCRUN"], !fake.isEmpty {
                return Context(xcrun: fake, derivedData: environment["OPENTRAFFIC_TEST_DERIVED_DATA"].map { URL(fileURLWithPath: $0) },
                               skipsProcessCheck: true)
            }
            #endif
            return Context()
        }

        var simctl: Simctl { Simctl(xcrun: xcrun) }
    }

    // MARK: Scanning

    /// Your apps in the booted simulators, by name then device. Never throws: nothing booted, no
    /// Xcode, or a simctl that fails or hangs all give `[]`.
    public static func scan(_ context: Context = .current) -> [MacApp] {
        let processes = context.processes ?? MacAppDiscovery.userProcesses()
        let devices = bootedDevices(context, processes: processes)
        guard !devices.isEmpty else { return [] }
        let builds = simulatorBuilds(context)
        var apps: [MacApp] = []
        for device in devices {
            for listed in installedApps(on: device, context: context) {
                guard let app = app(listed, on: device, builds: builds, processes: processes) else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return (a.simulator?.name ?? "").localizedStandardCompare(b.simulator?.name ?? "") == .orderedAscending
        }
    }

    /// The booted devices (not OpenTraffic's own), or none when no simulator process runs.
    public static func bootedDevices(_ context: Context, processes: [(pid: Int32, executable: String)]? = nil) -> [SimulatorDevice] {
        let gate = context.skipsProcessCheck ? [] : simulatorProcesses(processes ?? context.processes ?? MacAppDiscovery.userProcesses())
        guard context.skipsProcessCheck || !gate.isEmpty else { return [] }
        let key = gate.map(String.init).joined(separator: ",")
        let devices = context.cache.devices(key: key) {
            context.simctl.output(["list", "devices", "booted", "-j"], timeout: context.timeout).flatMap(parseDevices)
        } ?? []
        return devices.filter { $0.state == "Booted" && !$0.device.name.hasPrefix(dedicatedDevicePrefix) }.map(\.device)
    }

    /// The pids of `launchd_sim` (one per booted device) and Simulator.app: without either, nothing is booted.
    static func simulatorProcesses(_ processes: [(pid: Int32, executable: String)]) -> [Int32] {
        processes.filter { isLaunchdSim($0.executable) || isSimulatorApp($0.executable) }.map(\.pid).sorted()
    }

    static func isLaunchdSim(_ executable: String) -> Bool { executable.hasSuffix("/launchd_sim") }
    static func isSimulatorApp(_ executable: String) -> Bool { executable.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") }

    /// Simulator.app's pid, when it runs: the app whose device windows a Simulator share mirrors.
    public static func simulatorAppPID(processes: [(pid: Int32, executable: String)]? = nil) -> Int32? {
        (processes ?? MacAppDiscovery.userProcesses()).filter { isSimulatorApp($0.executable) }.map(\.pid).min()
    }

    // MARK: simctl output

    /// A device in `simctl list devices -j` with its state ("Booted", "Shutdown", …).
    public struct ListedDevice: Sendable, Equatable {
        public var device: SimulatorDevice
        public var state: String
    }

    /// `simctl list devices [booted] -j`: `{"devices": {"<runtime id>": [{"udid", "name", "state", …}]}}`.
    public static func parseDevices(_ json: String) -> [ListedDevice]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let runtimes = object["devices"] as? [String: Any] else { return nil }
        var devices: [ListedDevice] = []
        for (runtime, list) in runtimes {
            for entry in list as? [[String: Any]] ?? [] {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String,
                      entry["isAvailable"] as? Bool != false else { continue }
                let device = SimulatorDevice(
                    udid: udid, name: name, runtimeIdentifier: runtime,
                    deviceTypeIdentifier: entry["deviceTypeIdentifier"] as? String,
                    dataPath: (entry["dataPath"] as? String).map { URL(fileURLWithPath: $0) }
                )
                devices.append(ListedDevice(device: device, state: entry["state"] as? String ?? ""))
            }
        }
        return devices.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
    }

    /// An app `simctl listapps` reports.
    public struct ListedApp: Sendable, Equatable {
        public var bundleIdentifier: String
        public var name: String
        /// "User" for apps installed with Xcode or `simctl install`, "System" for Apple's.
        public var type: String
        /// The installed copy inside the device.
        public var path: URL
        public var executable: String?
    }

    /// `simctl listapps <udid>`: an old-style (OpenStep) property list, keyed by bundle identifier.
    public static func parseApps(_ text: String) -> [ListedApp]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any] else { return nil }
        return plist.compactMap { key, value -> ListedApp? in
            guard let entry = value as? [String: Any] else { return nil }
            let path = (entry["Path"] as? String).map { URL(fileURLWithPath: $0) }
                ?? (entry["Bundle"] as? String).flatMap(URL.init(string:)).map { URL(fileURLWithPath: $0.path) }
            guard let path else { return nil }
            let identifier = entry["CFBundleIdentifier"] as? String ?? key
            let name = [entry["CFBundleDisplayName"], entry["CFBundleName"]].compactMap { $0 as? String }.first { !$0.isEmpty }
                ?? path.deletingPathExtension().lastPathComponent
            return ListedApp(bundleIdentifier: identifier, name: name, type: entry["ApplicationType"] as? String ?? "",
                             path: path, executable: entry["CFBundleExecutable"] as? String)
        }
        .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    /// The apps installed in a device (kept until something is installed or removed, or for a minute).
    static func installedApps(on device: SimulatorDevice, context: Context) -> [ListedApp] {
        let bundles = device.dataPath?.appendingPathComponent("Containers/Bundle/Application")
        let changed = bundles.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let key = "\(device.udid)|\(changed?.timeIntervalSince1970 ?? 0)"
        return context.cache.apps(udid: device.udid, key: key) {
            context.simctl.output(["listapps", device.udid], timeout: context.timeout).flatMap(parseApps)
        } ?? []
    }

    // MARK: Yours or not

    /// A simulator build in DerivedData (Build/Products/<configuration>-iphonesimulator) and its project.
    struct Build {
        var bundle: URL
        var project: URL
        var builtAt: Date?
    }

    /// The newest simulator build per bundle identifier in DerivedData, whose project still exists.
    static func simulatorBuilds(_ context: Context) -> [String: Build] {
        let fm = FileManager.default
        var newest: [String: Build] = [:]
        for folder in (try? fm.contentsOfDirectory(at: context.derivedData, includingPropertiesForKeys: nil)) ?? [] {
            guard let workspace = MacAppDiscovery.workspacePath(of: folder) else { continue }
            let project = MacAppDiscovery.projectFolder(forWorkspace: workspace)
            guard fm.fileExists(atPath: project.path) else { continue }
            let products = folder.appendingPathComponent("Build/Products")
            for configuration in (try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
            where configuration.lastPathComponent.hasSuffix("simulator") {
                for item in (try? fm.contentsOfDirectory(at: configuration, includingPropertiesForKeys: nil)) ?? []
                where item.pathExtension == "app" {
                    guard let info = info(of: item), let identifier = info["CFBundleIdentifier"] as? String else { continue }
                    let built = executableDate(item, info)
                    if let existing = newest[identifier], (existing.builtAt ?? .distantPast) >= (built ?? .distantPast) { continue }
                    newest[identifier] = Build(bundle: item, project: ElectronDiscovery.realURL(project), builtAt: built)
                }
            }
        }
        return newest
    }

    /// The app as a MacApp when it's yours: installed by you (ApplicationType User, not Apple's) and
    /// built in one of your projects (a simulator build with its bundle identifier in DerivedData).
    /// Apps installed from elsewhere (App Store–style downloads, Expo Go, other people's builds) aren't offered.
    static func app(_ listed: ListedApp, on device: SimulatorDevice, builds: [String: Build],
                    processes: [(pid: Int32, executable: String)]) -> MacApp? {
        guard listed.type == "User", !listed.bundleIdentifier.hasPrefix("com.apple."),
              let build = builds[listed.bundleIdentifier] else { return nil }
        let info = info(of: listed.path) ?? info(of: build.bundle) ?? [:]
        let prefix = listed.path.path + "/"
        let pid = processes.filter { $0.executable.hasPrefix(prefix) }.map(\.pid).min()
        return MacApp(
            name: listed.name,
            bundle: listed.path,
            bundleIdentifier: listed.bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            projectDirectory: build.project,
            isRunning: pid != nil,
            pid: pid,
            iconFile: iconFile(listed.path, info) ?? iconFile(build.bundle, info),
            builtAt: build.builtAt,
            runtime: .simulator(device)
        )
    }

    /// An iOS bundle's Info.plist (at the bundle's root).
    static func info(of bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func executableDate(_ bundle: URL, _ info: [String: Any]) -> Date? {
        guard let executable = info["CFBundleExecutable"] as? String else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(executable).path))?[.modificationDate] as? Date
    }

    /// The largest PNG of the app's primary icon (`AppIcon60x60@3x.png`), when the bundle has one as a file.
    static func iconFile(_ bundle: URL, _ info: [String: Any]) -> URL? {
        let icons = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = (icons?["CFBundleIconFiles"] as? [String] ?? []) + [icons?["CFBundleIconName"] as? String, "AppIcon"].compactMap { $0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let candidates = files.filter { file in file.pathExtension == "png" && names.contains { file.lastPathComponent.hasPrefix($0) } }
        func size(_ file: URL) -> Int { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return candidates.max { size($0) < size($1) }
    }

    // MARK: Identity

    /// A simulator app's id: `simulator:<udid>/<bundle id>`. Unlike a Mac app's (its .app path), the
    /// installed copy's path changes with every install, so the device and bundle id name it.
    public static func appID(udid: String, bundleIdentifier: String) -> String {
        "simulator:\(udid)/\(bundleIdentifier)"
    }

    /// The device and bundle id in an id made by `appID`, nil for anything else (a Mac app's path).
    public static func parseAppID(_ id: String) -> (udid: String, bundleIdentifier: String)? {
        guard id.hasPrefix("simulator:") else { return nil }
        let rest = id.dropFirst("simulator:".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let udid = String(rest[..<slash]), bundle = String(rest[rest.index(after: slash)...])
        return udid.isEmpty || bundle.isEmpty ? nil : (udid, bundle)
    }

    /// The app a saved share names (`simulator:<udid>/<bundle id>`): on that device when it's booted,
    /// otherwise on another booted device that has it. Refused with a message when none has.
    public static func resolve(id: String, context: Context = .current) throws -> MacApp {
        guard let (udid, bundleIdentifier) = parseAppID(id) else { throw MacAppRefusal("\(id) is not an app in the Simulator.") }
        let apps = scan(context).filter { $0.bundleIdentifier == bundleIdentifier }
        if let app = apps.first(where: { $0.simulator?.udid == udid }) ?? apps.first { return app }
        throw MacAppRefusal("\(bundleIdentifier) isn't installed in a booted simulator. Run it from Xcode in the Simulator, then share it again.")
    }
}

// MARK: - Launching

/// Where a Simulator share's app runs, and how to stop it.
public struct SimulatorLaunch: Sendable, Equatable {
    /// The device the app runs in: the booted one (real data) or OpenTraffic's own (empty data).
    public var device: SimulatorDevice
    public var bundleIdentifier: String
    /// The app's process (in the simulator, visible on this Mac), when simctl reported it.
    public var pid: Int32?
    /// The app runs in your own simulator, on its real data: what viewers do changes it.
    public var usesRealData: Bool
}

/// Starts a simulator app for a share.
///
/// - `.copy` (real data) launches the app in the booted device you run it in, with
///   `simctl launch --terminate-running-process`. iOS has no way to give one launch its own data
///   (no `SIMCTL_CHILD_` setting does that), so this is the simulator's **real data**: what viewers
///   do is what you'll see in your simulator afterwards.
/// - `.empty` uses a device of OpenTraffic's own, "OpenTraffic · iPhone 17", of the same type and iOS
///   version (made with `simctl create` the first time, erased before every share), boots it, installs
///   the app from your device and launches it: a first launch, and your simulator is left alone.
///   (`simctl clone` would copy your device's data, and it needs the device shut down.)
public enum SimulatorLauncher {
    /// With `output`, the app's standard output and error are appended to that file.
    public static func launch(_ app: MacApp, data: MacAppSession.DataSource, simctl: Simctl = Simctl(), output: URL? = nil) throws -> SimulatorLaunch {
        guard let device = app.simulator, let bundleIdentifier = app.bundleIdentifier else {
            throw MacAppRefusal("\(app.name) is not an app in the Simulator.")
        }
        switch data {
        case .copy:
            let printed = try simctl.run(["launch", "--terminate-running-process"] + outputArguments(output) + [device.udid, bundleIdentifier], timeout: 60)
            return SimulatorLaunch(device: device, bundleIdentifier: bundleIdentifier, pid: launchedPID(printed), usesRealData: true)
        case .empty:
            let own = try dedicatedDevice(for: device, simctl: simctl)
            if own.state != "Shutdown" { try simctl.run(["shutdown", own.device.udid], timeout: 60) }
            try simctl.run(["erase", own.device.udid], timeout: 120)
            // Boots it and waits until it can take an install.
            try simctl.run(["bootstatus", own.device.udid, "-b"], timeout: 300)
            try simctl.run(["install", own.device.udid, app.bundle.path], timeout: 180)
            let printed = try simctl.run(["launch"] + outputArguments(output) + [own.device.udid, bundleIdentifier], timeout: 60)
            return SimulatorLaunch(device: own.device, bundleIdentifier: bundleIdentifier, pid: launchedPID(printed), usesRealData: false)
        }
    }

    /// Quits the app; OpenTraffic's own device is shut down too (it stays for the next share).
    public static func stop(_ launch: SimulatorLaunch, simctl: Simctl = Simctl()) {
        _ = try? simctl.run(["terminate", launch.device.udid, launch.bundleIdentifier], timeout: 30)
        if !launch.usesRealData { _ = try? simctl.run(["shutdown", launch.device.udid], timeout: 60) }
    }

    /// "OpenTraffic · iPhone 17" for this device's type and runtime: the existing one, or a new one.
    static func dedicatedDevice(for device: SimulatorDevice, simctl: Simctl) throws -> SimulatorDiscovery.ListedDevice {
        let name = SimulatorDiscovery.dedicatedDevicePrefix + device.name
        let listed = SimulatorDiscovery.parseDevices(try simctl.run(["list", "devices", "-j"], timeout: 30)) ?? []
        if let existing = listed.first(where: { $0.device.name == name && $0.device.runtimeIdentifier == device.runtimeIdentifier }) {
            return existing
        }
        guard let type = device.deviceTypeIdentifier else {
            throw MacAppRefusal("simctl didn't say what kind of device \(device.name) is, so OpenTraffic can't make an empty one like it.")
        }
        let udid = try simctl.run(["create", name, type, device.runtimeIdentifier], timeout: 60).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw MacAppRefusal("simctl didn't make the device \(name).") }
        return .init(device: SimulatorDevice(udid: udid, name: name, runtimeIdentifier: device.runtimeIdentifier, deviceTypeIdentifier: type), state: "Shutdown")
    }

    /// `--stdout=<file> --stderr=<file>`: simctl appends the app's output there.
    static func outputArguments(_ output: URL?) -> [String] {
        guard let output else { return [] }
        return ["--stdout=\(output.path)", "--stderr=\(output.path)"]
    }

    /// `se.medda.orbit: 12345` → 12345.
    static func launchedPID(_ output: String) -> Int32? {
        output.split(whereSeparator: \.isNewline).last.flatMap { line in
            line.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        }
    }
}

// MARK: - simctl

/// `xcrun simctl`, each call with a deadline.
public struct Simctl: Sendable {
    public var xcrun: String
    public init(xcrun: String = "/usr/bin/xcrun") { self.xcrun = xcrun }

    /// The command's output; throws with simctl's own message when it fails or takes longer than `timeout`.
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval, input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = ["simctl"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let command = "simctl \(arguments.first ?? "")"
        do { try process.run() } catch { throw MacAppRefusal("\(command) can't run: Xcode isn't installed (\(error.localizedDescription)).") }
        if let stdin, let input {
            // Small (a pasteboard's text): written whole, then closed so the tool sees its end.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        // Both pipes are read here, on this thread, so a full pipe can't block the tool and nothing
        // waits for a thread pool. Reading stops at the pipes' end, or once the tool has exited and
        // nothing more is waiting: a process started at the same moment elsewhere in OpenTraffic can
        // inherit the pipes and keep them open long after simctl is done.
        let deadline = Date().addingTimeInterval(timeout)
        let streams = Self.collect([output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor],
                                   until: deadline) { !process.isRunning }
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            throw MacAppRefusal("\(command) didn't finish within \(Int(timeout)) seconds.")
        }
        let data = streams[0], errorData = streams[1]
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacAppRefusal("\(command) failed\(message.isEmpty ? " (status \(process.terminationStatus))" : ": \(message)")")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// What can be read from each of `descriptors`: until their end, until `finished()` and nothing
    /// arrives for 50 ms, or until `deadline`.
    static func collect(_ descriptors: [Int32], until deadline: Date, finished: () -> Bool) -> [Data] {
        var data = descriptors.map { _ in Data() }
        var open = Set(descriptors.indices)
        var buffer = [UInt8](repeating: 0, count: 65536)
        // The tool has exited: what it wrote on its way out is in the pipes, nothing more is coming.
        var lastLook = false
        while !open.isEmpty, Date() < deadline {
            var requests = open.sorted().map { pollfd(fd: descriptors[$0], events: Int16(POLLIN), revents: 0) }
            let ready = poll(&requests, nfds_t(requests.count), lastLook ? 0 : 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if lastLook { break }
                // The tool can exit between a poll that saw nothing and this check, its output written
                // just before: one more look (seen as lost simctl output on a loaded Mac).
                if finished() { lastLook = true }
                continue
            }
            for request in requests where request.revents != 0 {
                guard let index = descriptors.firstIndex(of: request.fd) else { continue }
                let count = Darwin.read(request.fd, &buffer, buffer.count)
                if count > 0 {
                    data[index].append(contentsOf: buffer[0..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    open.remove(index) // the end, or an error
                }
            }
        }
        return data
    }

    /// The output, or nil when the call fails or times out.
    func output(_ arguments: [String], timeout: TimeInterval) -> String? {
        try? run(arguments, timeout: timeout)
    }
}

/// simctl answers kept between scans: the booted devices until a simulator process starts or stops,
/// a device's apps until something is installed or removed, each for at most a minute. Failures are
/// kept too, so a simctl that hangs costs one timeout a minute, not one per scan.
public final class SimulatorCache: @unchecked Sendable {
    public static let shared = SimulatorCache()
    public init(maxAge: TimeInterval = 60) { self.maxAge = maxAge }

    private let maxAge: TimeInterval
    private let lock = NSLock()
    private var bootedDevices: (key: String, at: Date, value: [SimulatorDiscovery.ListedDevice]?)?
    private var deviceApps: [String: (key: String, at: Date, value: [SimulatorDiscovery.ListedApp]?)] = [:]

    func devices(key: String, load: () -> [SimulatorDiscovery.ListedDevice]?) -> [SimulatorDiscovery.ListedDevice]? {
        if let cached = lock.withLock({ bootedDevices }), cached.key == key, Date().timeIntervalSince(cached.at) < maxAge { return cached.value }
        let value = load()
        lock.withLock { bootedDevices = (key, Date(), value) }
        return value
    }

    func apps(udid: String, key: String, load: () -> [SimulatorDiscovery.ListedApp]?) -> [SimulatorDiscovery.ListedApp]? {
        if let cached = lock.withLock({ deviceApps[udid] }), cached.key == key, Date().timeIntervalSince(cached.at) < maxAge { return cached.value }
        let value = load()
        lock.withLock { deviceApps[udid] = (key, Date(), value) }
        return value
    }
}

import Foundation
import Testing
@testable import OpenTrafficCore

// Simulator discovery and launching against a fake `xcrun` that answers with simctl's own output
// formats (no simulator or Xcode needed), plus a real listing when a simulator happens to be booted.

/// `xcrun simctl list devices booted -j` with two booted iPhones and OpenTraffic's own device.
private let bootedJSON = """
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
      {
        "lastBootedAt" : "2026-10-20T08:12:44Z",
        "dataPath" : "$ROOT/Devices/A1B2C3D4-0000-4000-8000-000000000017/data",
        "dataPathSize" : 1234567,
        "logPath" : "$ROOT/Logs/A1B2C3D4-0000-4000-8000-000000000017",
        "udid" : "A1B2C3D4-0000-4000-8000-000000000017",
        "isAvailable" : true,
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        "state" : "Booted",
        "name" : "iPhone 17"
      },
      {
        "dataPath" : "$ROOT/Devices/A1B2C3D4-0000-4000-8000-0000000000AA/data",
        "udid" : "A1B2C3D4-0000-4000-8000-0000000000AA",
        "isAvailable" : true,
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-Air",
        "state" : "Booted",
        "name" : "iPhone Air"
      },
      {
        "dataPath" : "$ROOT/Devices/0E000000-0000-4000-8000-00000000BEEF/data",
        "udid" : "0E000000-0000-4000-8000-00000000BEEF",
        "isAvailable" : true,
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        "state" : "Booted",
        "name" : "OpenTraffic · iPhone 17"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-12-0" : [

    ]
  }
}
"""

/// `xcrun simctl listapps <udid>`: an OpenStep property list. Orbit is yours (built in DerivedData),
/// Expo Go is a user app you didn't build, Maps is Apple's.
private func listappsText(device: String, includeOrbit: Bool = true) -> String {
    let orbit = includeOrbit ? """
        "se.medda.orbit.ios" =     {
            ApplicationType = User;
            Bundle = "file://$ROOT/Devices/\(device)/data/Containers/Bundle/Application/5F6E/Orbit.app/";
            CFBundleDisplayName = Orbit;
            CFBundleExecutable = Orbit;
            CFBundleIdentifier = "se.medda.orbit.ios";
            CFBundleName = Orbit;
            CFBundleVersion = 7;
            DataContainer = "file://$ROOT/Devices/\(device)/data/Containers/Data/Application/77AA/";
            GroupContainers =         {
            };
            Path = "$ROOT/Devices/\(device)/data/Containers/Bundle/Application/5F6E/Orbit.app";
            SBAppTags =         (
            );
        };
    """ : ""
    return """
    {
        "com.apple.Maps" =     {
            ApplicationType = System;
            Bundle = "file:///Library/Developer/CoreSimulator/Volumes/iOS_27A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS%2027.0.simruntime/Contents/Resources/RuntimeRoot/Applications/Maps.app/";
            CFBundleDisplayName = Maps;
            CFBundleExecutable = Maps;
            CFBundleIdentifier = "com.apple.Maps";
            CFBundleName = Maps;
            CFBundleVersion = "1.0";
            GroupContainers =         {
            };
            Path = "/Library/Developer/CoreSimulator/Volumes/iOS_27A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/Applications/Maps.app";
            SBAppTags =         (
            );
        };
        "host.exp.Exponent" =     {
            ApplicationType = User;
            Bundle = "file://$ROOT/Devices/\(device)/data/Containers/Bundle/Application/9C1D/Expo%20Go.app/";
            CFBundleDisplayName = "Expo Go";
            CFBundleExecutable = Exponent;
            CFBundleIdentifier = "host.exp.Exponent";
            CFBundleName = Exponent;
            CFBundleVersion = "2.31.2";
            Path = "$ROOT/Devices/\(device)/data/Containers/Bundle/Application/9C1D/Expo Go.app";
        };
    \(orbit)
    }
    """
}

private let iPhone17 = "A1B2C3D4-0000-4000-8000-000000000017"
private let iPhoneAir = "A1B2C3D4-0000-4000-8000-0000000000AA"
private let dedicated = "0E000000-0000-4000-8000-00000000BEEF"

/// A scratch folder with a fake xcrun, DerivedData with Orbit's simulator build, and device folders.
private struct Bench {
    let root: URL
    var derivedData: URL { root.appendingPathComponent("DerivedData") }
    var project: URL { root.appendingPathComponent("code/orbit") }
    var xcrun: String { root.appendingPathComponent("bin/xcrun").path }
    var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// `script` is the body of the fake xcrun's `case "$1"` (the simctl subcommand), after the defaults.
    init(xcrunCases: String = "", allDevicesJSON: String? = nil) throws {
        root = ElectronDiscovery.realURL(FileManager.default.temporaryDirectory).appendingPathComponent("simulator-discovery-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try write(bootedJSON, to: "booted.json")
        try write(allDevicesJSON ?? bootedJSON, to: "all.json")
        try write(listappsText(device: iPhone17), to: "apps-\(iPhone17).plist")
        try write(listappsText(device: iPhoneAir, includeOrbit: false), to: "apps-\(iPhoneAir).plist")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(root.path)/calls.log'
        [ "$1" = simctl ] || exit 64
        shift
        case "$1" in
        \(xcrunCases)
        list) if [ "$3" = booted ]; then cat '\(root.path)/booted.json'; else cat '\(root.path)/all.json'; fi ;;
        listapps) cat "\(root.path)/apps-$2.plist" ;;
        create) echo 'NEW00000-0000-4000-8000-000000000001' ;;
        launch) for last in "$@"; do :; done; echo "$last: 4242" ;;
        *) ;;
        esac
        """
        try write(script, to: "bin/xcrun")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun)

        // Orbit's simulator build in DerivedData, from the project in code/orbit.
        try fm.createDirectory(at: project.appendingPathComponent("Orbit.xcodeproj"), withIntermediateDirectories: true)
        let derived = derivedData.appendingPathComponent("Orbit-abcdef")
        try fm.createDirectory(at: derived, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": project.appendingPathComponent("Orbit.xcodeproj").path], format: .xml, options: 0)
            .write(to: derived.appendingPathComponent("info.plist"))
        try iOSApp(derived.appendingPathComponent("Build/Products/Debug-iphonesimulator/Orbit.app"), identifier: "se.medda.orbit.ios")
        // Expo Go's build is nowhere on this Mac; the installed copies are in the device.
        for device in [iPhone17, iPhoneAir] {
            let bundles = root.appendingPathComponent("Devices/\(device)/data/Containers/Bundle/Application")
            if device == iPhone17 { try iOSApp(bundles.appendingPathComponent("5F6E/Orbit.app"), identifier: "se.medda.orbit.ios", icon: true) }
            try iOSApp(bundles.appendingPathComponent("9C1D/Expo Go.app"), identifier: "host.exp.Exponent", executable: "Exponent")
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, to name: String) throws {
        try text.replacingOccurrences(of: "$ROOT", with: root.path).write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// An iOS .app: Info.plist and the executable at its root, and an icon PNG when asked.
    func iOSApp(_ bundle: URL, identifier: String, executable: String = "Orbit", icon: Bool = false) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleExecutable": executable, "CFBundleIdentifier": identifier, "CFBundleShortVersionString": "2.1"]
        if icon {
            info["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"], "CFBundleIconName": "AppIcon"]]
            try Data(repeating: 1, count: 100).write(to: bundle.appendingPathComponent("AppIcon60x60@2x.png"))
            try Data(repeating: 1, count: 300).write(to: bundle.appendingPathComponent("AppIcon60x60@3x.png"))
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try "#!/bin/sh\n".write(to: bundle.appendingPathComponent(executable), atomically: true, encoding: .utf8)
    }

    /// The processes of a Mac with two booted devices (their launchd_sim) and Orbit running in the iPhone 17.
    var processes: [(pid: Int32, executable: String)] {
        let launchd = "/Library/Developer/CoreSimulator/Volumes/iOS_27A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim"
        return [
            (501, launchd), (502, launchd),
            (777, root.appendingPathComponent("Devices/\(iPhone17)/data/Containers/Bundle/Application/5F6E/Orbit.app/Orbit").path),
            (900, "/bin/zsh"),
        ]
    }

    func context(processes: [(pid: Int32, executable: String)]? = nil, skipsProcessCheck: Bool = false, timeout: TimeInterval = 8) -> SimulatorDiscovery.Context {
        SimulatorDiscovery.Context(xcrun: xcrun, derivedData: derivedData, processes: processes ?? self.processes,
                                   skipsProcessCheck: skipsProcessCheck, timeout: timeout, cache: SimulatorCache())
    }
}

@Suite("Simulator discovery")
struct SimulatorDiscoveryTests {
    @Test func simctlsDeviceListIsRead() throws {
        let devices = try #require(SimulatorDiscovery.parseDevices(bootedJSON.replacingOccurrences(of: "$ROOT", with: "/Users/me/Library/Developer/CoreSimulator")))
        #expect(devices.map(\.device.name) == ["iPhone 17", "iPhone Air", "OpenTraffic · iPhone 17"])
        let iPhone = devices[0].device
        #expect(devices[0].state == "Booted")
        #expect(iPhone.udid == iPhone17)
        #expect(iPhone.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(iPhone.runtimeName == "iOS 27.0")
        #expect(iPhone.label == "iPhone 17 Simulator")
        #expect(iPhone.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        #expect(iPhone.dataPath?.path == "/Users/me/Library/Developer/CoreSimulator/Devices/\(iPhone17)/data")
        #expect(SimulatorDiscovery.parseDevices("xcrun: error: unable to find utility \"simctl\"") == nil)
        #expect(SimulatorDiscovery.parseDevices(#"{"devices": {}}"#) == [])
        #expect(SimulatorDevice(udid: "x", name: "Vision Pro", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-3-0").runtimeName == "visionOS 3.0")
    }

    @Test func simctlsAppListIsRead() throws {
        let apps = try #require(SimulatorDiscovery.parseApps(listappsText(device: iPhone17).replacingOccurrences(of: "$ROOT", with: "/Users/me/sim")))
        #expect(apps.map(\.bundleIdentifier) == ["com.apple.Maps", "host.exp.Exponent", "se.medda.orbit.ios"])
        let orbit = apps[2]
        #expect(orbit.name == "Orbit")
        #expect(orbit.type == "User")
        #expect(orbit.executable == "Orbit")
        #expect(orbit.path.path == "/Users/me/sim/Devices/\(iPhone17)/data/Containers/Bundle/Application/5F6E/Orbit.app")
        #expect(apps[1].name == "Expo Go")
        #expect(apps[1].path.lastPathComponent == "Expo Go.app")
        #expect(apps[0].type == "System")
        #expect(SimulatorDiscovery.parseApps("not a plist {{{") == nil)
    }

    @Test func yourAppsInBootedSimulatorsAreListedWithTheirDevice() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let apps = SimulatorDiscovery.scan(bench.context())
        // Only Orbit: Maps is Apple's, Expo Go wasn't built here, and OpenTraffic's own device isn't offered.
        #expect(apps.map(\.name) == ["Orbit"])
        let orbit = try #require(apps.first)
        #expect(orbit.simulator?.name == "iPhone 17")
        #expect(orbit.simulator?.label == "iPhone 17 Simulator")
        #expect(orbit.simulator?.runtimeName == "iOS 27.0")
        #expect(orbit.runtime == .simulator(try #require(orbit.simulator)))
        #expect(orbit.bundleIdentifier == "se.medda.orbit.ios")
        #expect(orbit.id == "simulator:\(iPhone17)/se.medda.orbit.ios")
        #expect(orbit.bundle.path.hasSuffix("Devices/\(iPhone17)/data/Containers/Bundle/Application/5F6E/Orbit.app"))
        #expect(orbit.projectDirectory?.path == bench.project.path)
        #expect(orbit.version == "2.1")
        #expect(orbit.isRunning)
        #expect(orbit.pid == 777)
        #expect(orbit.iconFile?.lastPathComponent == "AppIcon60x60@3x.png")
        #expect(orbit.builtAt != nil)
        // listapps ran for both booted devices, never for OpenTraffic's own.
        #expect(bench.calls == ["simctl list devices booted -j", "simctl listapps \(iPhone17)", "simctl listapps \(iPhoneAir)"])
    }

    @Test func theSameAppInTwoDevicesIsListedTwice() throws {
        let bench = try Bench()
        defer { bench.remove() }
        try bench.write(listappsText(device: iPhoneAir), to: "apps-\(iPhoneAir).plist")
        let apps = SimulatorDiscovery.scan(bench.context())
        // Running first, then by name and device.
        #expect(apps.map { "\($0.name) · \($0.simulator?.name ?? "")" } == ["Orbit · iPhone 17", "Orbit · iPhone Air"])
        #expect(Set(apps.map(\.id)).count == 2)
        #expect(apps[1].isRunning == false)
    }

    @Test func theAPIListsAnAppInTheSimulatorWithItsDevice() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let orbit = try #require(SimulatorDiscovery.scan(bench.context()).first)
        let listed = APIMacApp(orbit, sharedAs: nil)
        #expect(listed.kind == "macapp")
        #expect(listed.device == "iPhone 17 Simulator")
        #expect(listed.projectDirectory == bench.project.path)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(listed)) as? [String: Any])
        #expect(json["device"] as? String == "iPhone 17 Simulator")
        let mac = MacApp(name: "Orbit", bundle: URL(fileURLWithPath: "/Users/me/code/orbit/dist/Orbit.app"), bundleIdentifier: "se.medda.orbit",
                         projectDirectory: nil, isRunning: false)
        #expect(APIMacApp(mac, sharedAs: nil).device == nil)
    }

    @Test func aMacAppKeepsItsPathAsItsID() {
        let app = MacApp(name: "Orbit", bundle: URL(fileURLWithPath: "/Users/me/code/orbit/dist/Orbit.app"), bundleIdentifier: "se.medda.orbit",
                         projectDirectory: nil, isRunning: false)
        #expect(app.runtime == .mac)
        #expect(app.simulator == nil)
        #expect(app.id == "/Users/me/code/orbit/dist/Orbit.app")
    }

    @Test func nothingRunsSimctlWhenNoSimulatorIsRunning() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let quiet: [(pid: Int32, executable: String)] = [(900, "/bin/zsh"), (901, "/Applications/Xcode.app/Contents/MacOS/Xcode")]
        #expect(SimulatorDiscovery.scan(bench.context(processes: quiet)).isEmpty)
        #expect(bench.calls.isEmpty)
        // Simulator.app alone (no launchd_sim seen) is reason enough to ask.
        let simulatorApp = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
        #expect(SimulatorDiscovery.scan(bench.context(processes: quiet + [(950, simulatorApp)])).map(\.name) == ["Orbit"])
        #expect(SimulatorDiscovery.simulatorAppPID(processes: quiet + [(950, simulatorApp)]) == 950)
        #expect(SimulatorDiscovery.simulatorAppPID(processes: quiet) == nil)
    }

    @Test func missingOrBrokenXcodeGivesNoRowsAndNoErrors() throws {
        let bench = try Bench(xcrunCases: #"list|listapps) echo 'xcrun: error: unable to find utility "simctl", not a developer tool or in PATH' >&2; exit 72 ;;"#)
        defer { bench.remove() }
        #expect(SimulatorDiscovery.scan(bench.context()).isEmpty)
        var missing = bench.context()
        missing.xcrun = bench.root.appendingPathComponent("bin/no-such-xcrun").path
        #expect(SimulatorDiscovery.scan(missing).isEmpty)
        // A device whose app list fails is skipped; the others still show.
        let partly = try Bench(xcrunCases: "listapps) [ \"$2\" = \(iPhoneAir) ] && exit 1; cat \"$(dirname \"$0\")/../apps-$2.plist\" ;;")
        defer { partly.remove() }
        #expect(SimulatorDiscovery.scan(partly.context()).map(\.name) == ["Orbit"])
        #expect(partly.calls.contains("simctl listapps \(iPhoneAir)"))
    }

    @Test func aHangingSimctlCostsOneTimeoutAndIsRemembered() throws {
        let bench = try Bench(xcrunCases: "list) sleep 20 ;;") // a child that outlives the deadline
        defer { bench.remove() }
        let context = bench.context(timeout: 1)
        let started = Date()
        #expect(SimulatorDiscovery.scan(context).isEmpty)
        #expect(Date().timeIntervalSince(started) < 6)
        let again = Date()
        #expect(SimulatorDiscovery.scan(context).isEmpty)
        #expect(Date().timeIntervalSince(again) < 0.5)
        #expect(bench.calls == ["simctl list devices booted -j"])
    }

    @Test func listingsAreKeptUntilAnInstallOrABootChangesThem() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let context = bench.context()
        _ = SimulatorDiscovery.scan(context)
        _ = SimulatorDiscovery.scan(context)
        #expect(bench.calls.count == 3) // list + two listapps, once
        // Installing something changes the device's bundle folder: its apps are listed again.
        let bundles = bench.root.appendingPathComponent("Devices/\(iPhone17)/data/Containers/Bundle/Application")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: bundles.path)
        _ = SimulatorDiscovery.scan(context)
        #expect(bench.calls.suffix(1) == ["simctl listapps \(iPhone17)"])
        // A device booting or shutting down changes the launchd_sim processes: the devices are listed again.
        var fewer = context
        fewer.processes = Array(bench.processes.dropFirst())
        _ = SimulatorDiscovery.scan(fewer)
        #expect(bench.calls.suffix(1) == ["simctl list devices booted -j"])
    }

    @Test func appIDsNameTheDeviceAndTheBundle() throws {
        let id = SimulatorDiscovery.appID(udid: iPhone17, bundleIdentifier: "se.medda.orbit.ios")
        let parsed = try #require(SimulatorDiscovery.parseAppID(id))
        #expect(parsed.udid == iPhone17)
        #expect(parsed.bundleIdentifier == "se.medda.orbit.ios")
        #expect(SimulatorDiscovery.parseAppID("/Users/me/code/orbit/dist/Orbit.app") == nil)
        #expect(SimulatorDiscovery.parseAppID("simulator:/se.medda.orbit") == nil)
        #expect(SimulatorDiscovery.parseAppID("simulator:\(iPhone17)/") == nil)
    }

    @Test func aSavedShareFindsItsAppOnItsDeviceOrAnotherBootedOne() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let app = try SimulatorDiscovery.resolve(id: "simulator:\(iPhone17)/se.medda.orbit.ios", context: bench.context())
        #expect(app.simulator?.udid == iPhone17)
        // Saved on a device that isn't booted now: the booted one that has the app.
        let moved = try SimulatorDiscovery.resolve(id: "simulator:FFFF0000-0000-4000-8000-000000000000/se.medda.orbit.ios", context: bench.context())
        #expect(moved.simulator?.udid == iPhone17)
        #expect(throws: MacAppRefusal.self) { try SimulatorDiscovery.resolve(id: "simulator:\(iPhone17)/com.example.gone", context: bench.context()) }
        #expect(throws: MacAppRefusal.self) { try SimulatorDiscovery.resolve(id: "/Applications/Orbit.app", context: bench.context()) }
    }

    // MARK: Launching

    private func orbit(_ bench: Bench) throws -> MacApp {
        try #require(SimulatorDiscovery.scan(bench.context()).first)
    }

    @Test func realDataLaunchesInTheBootedDevice() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let app = try orbit(bench)
        let launch = try SimulatorLauncher.launch(app, data: .copy, simctl: Simctl(xcrun: bench.xcrun))
        #expect(launch.device.udid == iPhone17)
        #expect(launch.usesRealData)
        #expect(launch.pid == 4242)
        #expect(bench.calls.suffix(1) == ["simctl launch --terminate-running-process \(iPhone17) se.medda.orbit.ios"])
        SimulatorLauncher.stop(launch, simctl: Simctl(xcrun: bench.xcrun))
        // Your own simulator keeps running.
        #expect(bench.calls.suffix(1) == ["simctl terminate \(iPhone17) se.medda.orbit.ios"])
    }

    @Test func emptyDataMakesOpenTrafficsOwnDeviceLikeYours() throws {
        let bench = try Bench(allDevicesJSON: #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": []}}"#)
        defer { bench.remove() }
        let app = try orbit(bench)
        let before = bench.calls.count
        let launch = try SimulatorLauncher.launch(app, data: .empty, simctl: Simctl(xcrun: bench.xcrun))
        let new = "NEW00000-0000-4000-8000-000000000001"
        #expect(Array(bench.calls.dropFirst(before)) == [
            "simctl list devices -j",
            "simctl create OpenTraffic · iPhone 17 com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "simctl erase \(new)",
            "simctl bootstatus \(new) -b",
            "simctl install \(new) \(app.bundle.path)",
            "simctl launch \(new) se.medda.orbit.ios",
        ])
        #expect(launch.device.udid == new)
        #expect(launch.device.name == "OpenTraffic · iPhone 17")
        #expect(!launch.usesRealData)
        #expect(launch.pid == 4242)
        SimulatorLauncher.stop(launch, simctl: Simctl(xcrun: bench.xcrun))
        #expect(bench.calls.suffix(2) == ["simctl terminate \(new) se.medda.orbit.ios", "simctl shutdown \(new)"])
    }

    @Test func emptyDataReusesOpenTrafficsDeviceAndStartsItOver() throws {
        // OpenTraffic's device already exists and is still booted from an earlier share.
        let bench = try Bench()
        defer { bench.remove() }
        let app = try orbit(bench)
        let before = bench.calls.count
        let launch = try SimulatorLauncher.launch(app, data: .empty, simctl: Simctl(xcrun: bench.xcrun))
        #expect(Array(bench.calls.dropFirst(before)) == [
            "simctl list devices -j",
            "simctl shutdown \(dedicated)",
            "simctl erase \(dedicated)",
            "simctl bootstatus \(dedicated) -b",
            "simctl install \(dedicated) \(app.bundle.path)",
            "simctl launch \(dedicated) se.medda.orbit.ios",
        ])
        #expect(launch.device.udid == dedicated)
    }

    @Test func aFailedStepSaysWhatSimctlSaid() throws {
        let bench = try Bench(xcrunCases: #"install) echo 'An error was encountered processing the command (domain=IXUserPresentableErrorDomain, code=1): This app could not be installed at this time.' >&2; exit 1 ;;"#)
        defer { bench.remove() }
        let app = try orbit(bench)
        let error = try #require(throws: MacAppRefusal.self) { try SimulatorLauncher.launch(app, data: .empty, simctl: Simctl(xcrun: bench.xcrun)) }
        #expect(error.message.hasPrefix("simctl install failed: An error was encountered"))
        let mac = MacApp(name: "Orbit", bundle: URL(fileURLWithPath: "/tmp/Orbit.app"), bundleIdentifier: "se.medda.orbit", projectDirectory: nil, isRunning: false)
        #expect(throws: MacAppRefusal.self) { try SimulatorLauncher.launch(mac, data: .copy, simctl: Simctl(xcrun: bench.xcrun)) }
    }

    @Test func launchedPIDsAreRead() {
        #expect(SimulatorLauncher.launchedPID("se.medda.orbit.ios: 31337\n") == 31337)
        #expect(SimulatorLauncher.launchedPID("") == nil)
    }

    // MARK: This Mac

    /// A real listing, only when a simulator is booted here (nothing is booted or launched by the test).
    @Test(.enabled(if: !SimulatorDiscovery.simulatorProcesses(MacAppDiscovery.userProcesses()).isEmpty, "no simulator is running on this Mac"))
    func aRealBootedSimulatorIsListed() {
        let context = SimulatorDiscovery.Context(timeout: 30, cache: SimulatorCache())
        let devices = SimulatorDiscovery.bootedDevices(context)
        #expect(!devices.isEmpty)
        for device in devices {
            #expect(!device.udid.isEmpty && !device.name.isEmpty)
        }
        // Whatever is listed is in one of those devices, and has a project folder.
        for app in SimulatorDiscovery.scan(context) {
            #expect(devices.contains { $0.udid == app.simulator?.udid })
            #expect(app.projectDirectory != nil)
        }
    }
}

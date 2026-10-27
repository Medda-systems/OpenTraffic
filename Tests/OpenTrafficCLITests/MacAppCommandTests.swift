import Foundation
import Testing
@testable import opentraffic_cli

// Sharing Mac apps from the terminal: `opentraffic share Orbit`, `restart Orbit --app`, `services`.

@Test func shareTellsPortsAddressesAndAppsApart() {
    #expect(ShareTarget("5173") == .port(5173))
    #expect(ShareTarget("localhost:3000") == .url("localhost:3000"))
    #expect(ShareTarget("localhost") == .url("localhost"))
    #expect(ShareTarget("http://127.0.0.1:8080/app") == .url("http://127.0.0.1:8080/app"))
    #expect(ShareTarget("raspberrypi.local:8080") == .url("raspberrypi.local:8080"))
    #expect(ShareTarget("app.example.com") == .url("app.example.com"))
    // A word, or words, name a Mac app as `opentraffic services` lists it.
    #expect(ShareTarget("Orbit") == .appName("Orbit"))
    #expect(ShareTarget("Field Notes") == .appName("Field Notes"))
    #expect(ShareTarget("Notes 2.0") == .appName("Notes 2.0"))
    // An .app by its path, relative to where the command runs, made absolute.
    #expect(ShareTarget("dist/mac-arm64/Orbit.app", currentDirectory: "/Users/me/code/orbit") == .appPath("/Users/me/code/orbit/dist/mac-arm64/Orbit.app"))
    #expect(ShareTarget("/Users/me/code/Orbit/build/Orbit.app/") == .appPath("/Users/me/code/Orbit/build/Orbit.app"))
    #expect(ShareTarget("../build/Orbit.app", currentDirectory: "/Users/me/code/Orbit/src") == .appPath("/Users/me/code/Orbit/build/Orbit.app"))
    #expect(ShareTarget("~/code/Orbit.app") == .appPath(NSHomeDirectory() + "/code/Orbit.app"))
    #expect(ShareTarget("Orbit").isApp && ShareTarget("/a/Orbit.app").isApp)
    #expect(!ShareTarget("3000").isApp && !ShareTarget("localhost:3000").isApp)
}

@Test func shareAndRestartTakeTheMacAppOptions() throws {
    let share = try Invocation.parse(["share", "Orbit", "--via", "opentunnel", "--empty-data"])
    #expect(share.arguments == ["Orbit"])
    #expect(share.flags == ["empty-data"])
    #expect(share.options == ["via": "opentunnel"])
    #expect(try Invocation.parse(["share", "Field Notes"]).arguments == ["Field Notes"])
    #expect(try Invocation.parse(["restart", "Orbit", "--app"]).flags == ["app"])
    #expect(try Invocation.parse(["restart", "Orbit", "--reset-data"]).flags == ["reset-data"])
    #expect(try Invocation.parse(["restart", "Orbit"]).flags.isEmpty)
    #expect(throws: CLIError.self) { try Invocation.parse(["restart", "Orbit", "--empty-data"]) }
    #expect(throws: CLIError.self) { try Invocation.parse(["start", "Orbit", "--app"]) }
}

@Test func helpExplainsMacApps() throws {
    let share = try #require(Commands.spec(named: "share"))
    #expect(share.usage.hasPrefix("share <port|host:port|url|App.app|app name>"))
    #expect(share.summary.contains("Mac app"))
    #expect(share.details.contains("Mac apps: share a native app you're building"))
    #expect(share.details.contains("--empty-data"))
    let restart = try #require(Commands.spec(named: "restart"))
    #expect(restart.usage == "restart <share> [--app | --reset-data]")
    #expect(restart.details.contains("--app") && restart.details.contains("--reset-data"))
    #expect(try #require(Commands.spec(named: "services")).summary.contains("Mac apps"))
}

@Test func readsMacAppsFromTheAPI() throws {
    let services = Data(#"""
    {"services":[{"port":3000,"url":"http://localhost:3000"}],
     "apps":[{"kind":"macapp","name":"Orbit","bundle":"/Users/me/code/Orbit/build/Orbit.app","projectDirectory":"/Users/me/code/Orbit","running":true,"builtAt":"2026-10-20T08:00:00Z","sharedAs":"Orbit"}]}
    """#.utf8)
    let body = try JSON.decoder.decode(ServicesBody.self, from: services)
    #expect(body.apps?.first?.kind == "macapp")
    #expect(body.apps?.first?.projectDirectory == "/Users/me/code/Orbit")
    #expect(body.apps?.first?.builtAt != nil)
    // Older versions of OpenTraffic list only web servers.
    #expect(try JSON.decoder.decode(ServicesBody.self, from: Data(#"{"services":[]}"#.utf8)).apps == nil)

    let share = Data(#"""
    {"id":"22222222-3333-4444-5555-666666666666","name":"Orbit","provider":"opentunnel","kind":"opentunnel","state":"running",
     "localURL":"http://127.0.0.1/","publicURL":"https://orbit.opentunnel.xyz","collaboration":true,"people":[],"openComments":0,"comments":0,
     "macApp":{"path":"/Users/me/code/Orbit/build/Orbit.app","name":"Orbit","data":"empty","state":"running","viewers":2}}
    """#.utf8)
    let decoded = try JSON.decoder.decode(Share.self, from: share)
    #expect(decoded.macApp?.name == "Orbit")
    #expect(decoded.macApp?.data == "empty")
    #expect(decoded.macApp?.viewers == 2)
    #expect(decoded.macApp?.warning == nil)
}

@Test func readsAppsInTheSimulatorWithTheirDevice() throws {
    let services = Data(#"""
    {"services":[],
     "apps":[{"kind":"macapp","name":"Orbit","bundle":"/Users/me/Library/Developer/CoreSimulator/Devices/A1B2/data/Containers/Bundle/Application/5F6E/Orbit.app","projectDirectory":"/Users/me/code/Orbit","running":false,"sharedAs":null,"device":"iPhone 17 Simulator"},
             {"kind":"macapp","name":"Orbit","bundle":"/Users/me/code/Orbit/build/Orbit.app","running":true}]}
    """#.utf8)
    let apps = try #require(try JSON.decoder.decode(ServicesBody.self, from: services).apps)
    #expect(apps.map(\.device) == ["iPhone 17 Simulator", nil])
}

@Test func setTakesTheMacAppViewerOptions() throws {
    let set = try Invocation.parse(["set", "Orbit", "--control", "watch-only", "--appearance", "dark", "--window-size", "app"])
    #expect(set.options == ["control": "watch-only", "appearance": "dark", "window-size": "app"])
    #expect(try parseChoice("Watch-Only", option: "control", ["everyone": "everyone", "watch-only": "watchOnly", "ask": "askToControl"]) == "watchOnly")
    #expect(try parseChoice("fit", option: "window-size", ["fit": "fitViewer", "app": "app"]) == "fitViewer")
    #expect(throws: CLIError.self) { try parseChoice("nobody", option: "control", ["everyone": "everyone", "watch-only": "watchOnly"]) }
    let details = try #require(Commands.spec(named: "set")).details
    #expect(details.contains("--control everyone|watch-only|ask") && details.contains("--appearance") && details.contains("--window-size"))
}

@Test func controlAnswersRequestsFromTheTerminal() throws {
    #expect(try Invocation.parse(["control", "Orbit", "allow"]).arguments == ["Orbit", "allow"])
    #expect(try Invocation.parse(["control", "Orbit", "allow", "3"]).arguments == ["Orbit", "allow", "3"])
    #expect(try Invocation.parse(["control", "Orbit", "deny", "Ada", "Lovelace"]).arguments == ["Orbit", "deny", "Ada", "Lovelace"])
    #expect(try Invocation.parse(["control", "Orbit", "take-back", "--json"]).flags == ["json"])
    #expect(throws: CLIError.self) { try Invocation.parse(["control", "Orbit"]) }
    let spec = try #require(Commands.spec(named: "control"))
    #expect(spec.usage == "control <share> allow [viewer] | deny [viewer] | take-back")
    #expect(spec.details.contains("--control ask") && spec.details.contains("take-back"))
}

@Test func readsWhoControlsASharedMacApp() throws {
    let share = Data(#"""
    {"id":"22222222-3333-4444-5555-666666666666","name":"Orbit","provider":"opentunnel","kind":"opentunnel","state":"running",
     "localURL":"http://127.0.0.1/","publicURL":"https://orbit.opentunnel.xyz","collaboration":true,"people":[],"openComments":0,"comments":0,
     "macApp":{"path":"/Users/me/code/Orbit/build/Orbit.app","name":"Orbit","data":"copy","state":"running","viewers":3,
       "control":{"mode":"askToControl","holder":{"viewer":3,"name":"Ada","since":"2026-10-27T10:00:00Z","connected":true},
                  "requests":[{"viewer":5,"name":"Bob","since":"2026-10-27T10:02:30.250Z"},{"viewer":6,"since":"2026-10-27T10:03:00Z"}]}}}
    """#.utf8)
    let control = try #require(try JSON.decoder.decode(Share.self, from: share).macApp?.control)
    #expect(control.mode == "askToControl")
    #expect(control.holder?.name == "Ada" && control.holder?.connected == true)
    #expect(control.requests.map(\.viewer) == [5, 6])
    #expect(control.requests[1].name == nil)
    let event = Data(#"""
    {"seq":4,"type":"control.requested","at":"2026-10-27T10:02:30Z","share":{"name":"Orbit"},"viewer":{"viewer":5,"name":"Bob","since":"2026-10-27T10:02:30Z"}}
    """#.utf8)
    #expect(try JSON.decoder.decode(Event.self, from: event).viewer?.viewer == 5)
}

@Test func statusSaysWhoHasControlAndWhoAsks() throws {
    let context = Context(invocation: Invocation(command: "status", arguments: ["Orbit"]), client: Client(location: AppLocation(environment: [:])), style: Style(color: false))
    let now = Date()
    let asking = MacAppControl(mode: "askToControl", holder: ControlViewer(viewer: 3, name: "Ada", since: now, connected: false),
                               requests: [ControlViewer(viewer: 5, name: "Bob", since: now.addingTimeInterval(-300), connected: nil)])
    let rows = context.controlRows(asking, app: "Orbit", share: "Orbit E2E")
    #expect(rows.map(\.0) == ["Control", "Asks", ""])
    #expect(rows[0].1.hasPrefix("ask to control · Ada (3) has control since "))
    #expect(rows[0].1.hasSuffix(", away (they get it back when they return)"))
    #expect(rows[1].1 == "Bob (5) asks to control it, 5 min ago")
    #expect(rows[2].1 == "Answer with `opentraffic control \"Orbit E2E\" allow 5` or `deny 5`.")
    #expect(context.controlRows(MacAppControl(mode: "askToControl", holder: nil, requests: []), app: "Orbit", share: "Orbit").map(\.1) == ["ask to control · only you control Orbit"])
    #expect(context.controlRows(MacAppControl(mode: "watchOnly", holder: nil, requests: []), app: "Orbit", share: "Orbit").map(\.1) == ["viewers only watch"])
    #expect(context.controlRows(MacAppControl(mode: "everyone", holder: nil, requests: []), app: "Orbit", share: "Orbit").map(\.1) == ["every viewer"])
}

import Foundation
import Testing
@testable import opentraffic_cli

@Test func noArgumentsListsShares() throws {
    #expect(try Invocation.parse([]) == Invocation(command: "list"))
}

@Test func keepsTheOriginalShareSyntax() throws {
    let invocation = try Invocation.parse(["share", "5173", "--via", "opentunnel", "--name", "My app", "--collab"])
    #expect(invocation.command == "share")
    #expect(invocation.arguments == ["5173"])
    #expect(invocation.options == ["via": "opentunnel", "name": "My app"])
    #expect(invocation.flags == ["collab"])
}

@Test func keepsStopAllAndProjects() throws {
    #expect(try Invocation.parse(["stop", "--all"]).flags == ["all"])
    let project = try Invocation.parse(["project", "start", "Demo day"])
    #expect(project.command == "project")
    #expect(project.arguments == ["start", "Demo day"])
}

@Test func readsInlineValuesAndShortOptions() throws {
    let share = try Invocation.parse(["share", "3000", "--via=domain", "--hostname=app.example.com", "--replace-dns"])
    #expect(share.options == ["via": "domain", "hostname": "app.example.com"])
    #expect(share.flags == ["replace-dns"])
    let logs = try Invocation.parse(["logs", "Orbit", "-n", "50", "-f"])
    #expect(logs.options == ["lines": "50"])
    #expect(logs.flags == ["follow"])
}

@Test func aliasesNameTheSameCommand() throws {
    #expect(try Invocation.parse(["ls"]).command == "list")
    #expect(try Invocation.parse(["rm", "Orbit", "--yes"]).command == "remove")
    #expect(try Invocation.parse(["info", "Orbit"]).command == "status")
}

@Test func jsonWorksWithEveryCommand() throws {
    #expect(try Invocation.parse(["services", "--json"]).json)
    #expect(try Invocation.parse(["status", "Orbit", "-j"]).json)
}

@Test func helpForACommand() throws {
    #expect(try Invocation.parse(["share", "--help"]) == Invocation(command: "help", arguments: ["share"]))
    #expect(try Invocation.parse(["--help"]) == Invocation(command: "help"))
    #expect(try Invocation.parse(["-v"]) == Invocation(command: "version"))
}

@Test func doubleDashEndsOptions() throws {
    let reply = try Invocation.parse(["reply", "Orbit", "abc", "--", "--not-an-option", "text"])
    #expect(reply.arguments == ["Orbit", "abc", "--not-an-option", "text"])
}

@Test func negativeNumbersAreArguments() throws {
    #expect(try Invocation.parse(["reply", "Orbit", "abc", "-1"]).arguments == ["Orbit", "abc", "-1"])
}

@Test func wrongUseExitsWithUsage() {
    func status(_ arguments: [String]) -> Int32? {
        do {
            _ = try Invocation.parse(arguments)
            return nil
        } catch let error as CLIError {
            return error.status
        } catch {
            return -1
        }
    }
    #expect(status(["frobnicate"]) == 2)
    #expect(status(["share"]) == 2)
    #expect(status(["share", "3000", "--via"]) == 2)
    #expect(status(["share", "3000", "--bogus"]) == 2)
    #expect(status(["stop", "--all=yes"]) == 2)
    #expect(status(["rename", "Orbit"]) == 2)
}

@Test func switchesReadOnAndOff() throws {
    #expect(try parseSwitch("on", option: "collab"))
    #expect(try !parseSwitch("OFF", option: "collab"))
    #expect(throws: CLIError.self) { try parseSwitch("maybe", option: "collab") }
}

@Test func everyCommandHasHelpAndUniqueNames() {
    var names = Set<String>()
    for spec in Commands.all {
        #expect(!spec.summary.isEmpty)
        #expect(spec.usage.hasPrefix(spec.name))
        for name in [spec.name] + spec.aliases {
            #expect(names.insert(name).inserted, "\(name) is used twice")
        }
    }
}

@Test func localAddressesAreShort() {
    #expect(Format.local("http://localhost:5173") == ":5173")
    #expect(Format.local("http://127.0.0.1:3000/app") == ":3000/app")
    #expect(Format.local("http://raspberrypi.local:8080") == "raspberrypi.local:8080")
}

@Test func agesReadNaturally() {
    let now = Date()
    #expect(Format.age(since: now.addingTimeInterval(-20), now: now) == "just now")
    #expect(Format.age(since: now.addingTimeInterval(-12 * 60), now: now) == "12 min")
    #expect(Format.age(since: now.addingTimeInterval(-3 * 3600), now: now) == "3 h")
    #expect(Format.age(since: now.addingTimeInterval(-86400 * 2), now: now) == "2 days")
    #expect(Format.ago(now.addingTimeInterval(-20), now: now) == "just now")
    #expect(Format.ago(now.addingTimeInterval(-12 * 60), now: now) == "12 min ago")
}

@Test func tablesAlignIgnoringColor() {
    var table = Table(header: ["NAME", "STATE"])
    table.rows = [["\u{1B}[1mOrbit\u{1B}[0m", "live"], ["API", "stopped"]]
    let lines = table.render(style: Style(color: false)).split(separator: "\n")
    #expect(lines[0] == "NAME   STATE")
    #expect(lines[1].hasSuffix("  live"))
    #expect(lines[2] == "API    stopped")
}

@Test func qrCodeIsSquareWithAQuietZone() throws {
    let lines = try #require(QRCode.lines(for: "https://orbit.example.opentunnel.xyz"))
    let width = lines[0].count
    #expect(lines.allSatisfy { $0.count == width })
    // Rows of two modules each: about half as many rows as columns.
    #expect(abs(lines.count * 2 - width) <= 1)
    #expect(lines[0].allSatisfy { $0 == "█" })
}

@Test func findsTheAppItCameIn() {
    let location = AppLocation(environment: [:], executable: URL(fileURLWithPath: "/nonexistent/OpenTraffic.app/Contents/MacOS/opentraffic-cli"))
    // Not a real bundle: falls back to the installed app's identity and the default port.
    #expect(location.appURL == nil)
    #expect(location.bundleID == "se.medda.opentraffic")
    let custom = AppLocation(environment: ["OPENTRAFFIC_API_PORT": "47799", "OPENTRAFFIC_BUNDLE_ID": "se.medda.opentraffic.demo", "OPENTRAFFIC_API_TOKEN_FILE": "~/token"], executable: URL(fileURLWithPath: "/tmp/x"))
    #expect(custom.port == 47799)
    #expect(custom.bundleID == "se.medda.opentraffic.demo")
    #expect(custom.tokenFile.path.hasSuffix("/token"))
}

@Test func browserErrorsNameEachPlaceOnce() {
    func group(_ paths: [String], _ source: String?) -> ErrorGroup {
        ErrorGroup(message: "x is not defined", kind: "error", source: source, count: 1, lastAt: Date(), paths: paths)
    }
    // An inline script's source is its page.
    #expect(group(["/"], "/").location == "/")
    #expect(group(["/", "/about"], "/assets/app.js").location == "/, /about · /assets/app.js")
    #expect(group(["/"], nil).location == "/")
    #expect(group(["/"], "").location == "/")
}

@Test func apiFieldsBecomeCommandOptionsInErrors() {
    let body = Data(#"{"error":{"code":"dns_record_exists","message":"A DNS record for app.example.com already exists and points to 1.2.3.4. Send replaceDNS: true to replace it, or pick another hostname."}}"#.utf8)
    #expect(Client.errorMessage(in: body) == "A DNS record for app.example.com already exists and points to 1.2.3.4. Add --replace-dns to replace it, or pick another hostname.")
    let other = Data(#"{"error":{"code":"not_ready","message":"Send replaceDNS: true to replace it"}}"#.utf8)
    #expect(Client.errorMessage(in: other) == "Send replaceDNS: true to replace it")
}

import Foundation
import Testing
@testable import opentraffic_cli

// Sharing Electron apps from the terminal: a dev server by its port, a finished app by its path.

@Test func shareSendsTheNameOfAnElectronApp() throws {
    let share = try Invocation.parse(["share", "dist/Orbit.app", "--via", "opentunnel", "--name", "Electron Orbit E2E"])
    #expect(share.arguments == ["dist/Orbit.app"])
    #expect(share.options == ["via": "opentunnel", "name": "Electron Orbit E2E"])
    // The .app path goes to OpenTraffic as `url`, which tells a finished Electron app from a Mac app.
    #expect(ShareTarget(share.arguments[0], currentDirectory: "/Users/me/code/orbit") == .appPath("/Users/me/code/orbit/dist/Orbit.app"))
    #expect(try Invocation.parse(["share", "5199", "--name", "Electron Orbit E2E"]).options["name"] == "Electron Orbit E2E")
    #expect(try #require(Commands.spec(named: "share")).details.contains("Electron apps"))
}

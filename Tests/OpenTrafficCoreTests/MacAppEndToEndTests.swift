import Foundation
import Testing

// The whole Mac app sharing journey, end to end: script/macapp-e2e.mjs builds the Orbit fixture,
// launches an isolated OpenTraffic copy, shares Orbit through it and drives the shared page from
// headless Chrome (docs/macapp-e2e.md). It needs that copy, Google Chrome, a network that reaches the
// tunnel and the copy's Accessibility and Screen Recording permissions, so it only runs when asked:
//
//     OPENTRAFFIC_E2E=1 swift test --filter MacAppEndToEndTests
//
// OPENTRAFFIC_E2E_ARGS passes options to the script (for example `--build` or `--via quick`).

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENTRAFFIC_E2E"] == "1", "set OPENTRAFFIC_E2E=1 to run the end-to-end journey"),
       .timeLimit(.minutes(60)))
struct MacAppEndToEndTests {
    @Test func theWholeJourneyPassesInTheBrowser() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("script/macapp-e2e.mjs")
        let extra = ProcessInfo.processInfo.environment["OPENTRAFFIC_E2E_ARGS"]?.split(separator: " ").map(String.init) ?? []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path] + extra
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        print(text)
        let failed = text.split(separator: "\n").first { $0.hasPrefix("FAILED at step") }.map(String.init)
        #expect(process.terminationStatus == 0, "\(failed ?? "macapp-e2e.mjs exited \(process.terminationStatus)")")
    }
}

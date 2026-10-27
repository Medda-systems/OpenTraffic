import Foundation
import Testing

// The whole Electron app sharing journey, end to end: script/electron-e2e.mjs installs the
// electron-orbit fixture, launches an isolated OpenTraffic copy, shares the fixture's dev server through
// it and drives the shared page from headless Chrome (docs/electron-e2e.md). It needs that copy, Google
// Chrome, npm and a network that reaches the tunnel, so it only runs when asked:
//
//     OPENTRAFFIC_E2E=1 swift test --filter ElectronEndToEndTests
//
// OPENTRAFFIC_E2E_ARGS passes options to the script (for example `--build` or `--via quick`).

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENTRAFFIC_E2E"] == "1", "set OPENTRAFFIC_E2E=1 to run the end-to-end journey"),
       .timeLimit(.minutes(60)))
struct ElectronEndToEndTests {
    @Test func theWholeJourneyPassesInTheBrowser() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("script/electron-e2e.mjs")
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
        #expect(process.terminationStatus == 0, "\(failed ?? "electron-e2e.mjs exited \(process.terminationStatus)")")
    }
}

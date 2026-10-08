import Foundation
import Testing
@testable import OpenTrafficCore

private func discovered(
    id: UUID = UUID(),
    pid: Int32,
    start: UInt64,
    executable: String,
    localURL: String?,
    publicURL: String
) -> DiscoveredQuickTunnel {
    DiscoveredQuickTunnel(
        id: id,
        identity: ProcessIdentity(pid: pid, startTimeMicroseconds: start),
        executablePath: executable,
        localURL: localURL,
        publicURL: publicURL,
        logFilePath: nil,
        logEntries: [],
        metricsPort: nil,
        lastSeen: Date()
    )
}

@Test func preferenceKeySurvivesPIDAndCellarVersionChangesForSameOrigin() {
    let first = discovered(
        pid: 10,
        start: 100,
        executable: "/opt/homebrew/Cellar/cloudflared/1/bin/cloudflared",
        localURL: "http://localhost:8130",
        publicURL: "https://first.trycloudflare.com"
    )
    let restarted = discovered(
        pid: 99,
        start: 900,
        executable: "/opt/homebrew/Cellar/cloudflared/2/bin/cloudflared",
        localURL: "http://localhost:8130",
        publicURL: "https://second.trycloudflare.com"
    )
    #expect(first.preferenceKey == restarted.preferenceKey)

    let unknownOne = discovered(pid: 1, start: 1, executable: "/usr/local/bin/cloudflared", localURL: nil, publicURL: "https://one.trycloudflare.com")
    let unknownTwo = discovered(pid: 2, start: 2, executable: "/usr/local/bin/cloudflared", localURL: nil, publicURL: "https://two.trycloudflare.com")
    #expect(unknownOne.preferenceKey != unknownTwo.preferenceKey)
}

@Test func persistsAliasesAndHiddenDiscoveryState() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = DiscoveryPreferencesPersistence(fileURL: directory.appending(path: "preferences.json"))
    let expected = DiscoveryPreferencesState(entries: [
        DiscoveryPreference(
            key: "cloudflared|http://localhost:8130",
            alias: "My local API",
            isHidden: true,
            origin: "http://localhost:8130",
            executablePath: "/opt/homebrew/bin/cloudflared"
        )
    ])
    try persistence.save(expected)
    #expect(try persistence.load() == expected)
}

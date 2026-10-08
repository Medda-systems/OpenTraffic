import Foundation
import Testing
@testable import OpenTrafficCore

private final class FixtureProcessProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProcessSnapshot]

    init(_ snapshots: [ProcessSnapshot]) { stored = snapshots }

    func snapshots() -> [ProcessSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ snapshots: [ProcessSnapshot]) {
        lock.lock()
        stored = snapshots
        lock.unlock()
    }
}

private actor FixtureMetadataProvider: ExternalTunnelMetadataProviding {
    private var values: [ProcessIdentity: ExternalTunnelMetadata]

    init(_ values: [ProcessIdentity: ExternalTunnelMetadata]) { self.values = values }

    func metadata(for candidate: QuickTunnelCandidate) async -> ExternalTunnelMetadata {
        values[candidate.snapshot.identity] ?? ExternalTunnelMetadata(publicURL: nil)
    }

    func set(_ metadata: ExternalTunnelMetadata, for identity: ProcessIdentity) {
        values[identity] = metadata
    }
}

private struct NoopSignaler: ProcessSignaling {
    func sendTerminate(to pid: Int32) throws {}
}

private func snapshot(
    pid: Int32 = 42,
    start: UInt64 = 100,
    executable: String = "/opt/homebrew/bin/cloudflared",
    arguments: [String]
) -> ProcessSnapshot {
    ProcessSnapshot(
        identity: .init(pid: pid, startTimeMicroseconds: start),
        uid: 501,
        executablePath: executable,
        arguments: arguments
    )
}

@Test func classifierAcceptsQuickURLFormsAndRejectsNamedOrCredentialProcesses() {
    let splitURL = snapshot(arguments: ["cloudflared", "tunnel", "--url", "http://localhost:3000"])
    #expect(ExternalTunnelClassifier.classify(splitURL)?.localURL == "http://localhost:3000")

    let equalsURL = snapshot(arguments: ["cloudflared", "tunnel", "--url=https://127.0.0.1:8443", "--logfile=/tmp/cloudflared.log"])
    let classified = ExternalTunnelClassifier.classify(equalsURL)
    #expect(classified?.localURL == "https://127.0.0.1:8443")
    #expect(classified?.logFilePath == "/tmp/cloudflared.log")

    #expect(ExternalTunnelClassifier.classify(snapshot(arguments: ["cloudflared", "tunnel", "run", "named"])) == nil)
    #expect(ExternalTunnelClassifier.classify(snapshot(arguments: ["cloudflared", "tunnel", "--token=secret"])) == nil)
    #expect(ExternalTunnelClassifier.classify(snapshot(arguments: ["cloudflared", "tunnel", "--name", "named"])) == nil)
    #expect(ExternalTunnelClassifier.classify(snapshot(executable: "/tmp/not-cloudflared", arguments: ["cloudflared", "tunnel", "--url", "http://localhost:1"])) == nil)
}

@Test func scanDeduplicatesPreservesIdentityAcrossTransientMetadataAndRemovesExitedProcess() async throws {
    let process = snapshot(arguments: ["cloudflared", "tunnel", "--url", "http://localhost:3000"])
    let processes = FixtureProcessProvider([process, process])
    let metadata = FixtureMetadataProvider([
        process.identity: ExternalTunnelMetadata(publicURL: "https://example.trycloudflare.com", metricsPort: 20241)
    ])
    let discovery = ExternalTunnelDiscovery(
        processProvider: processes,
        metadataProvider: metadata,
        signaler: NoopSignaler()
    )

    let first = await discovery.scan(excludingProcessIDs: [])
    #expect(first.count == 1)
    let stableID = try #require(first.first?.id)

    await metadata.set(ExternalTunnelMetadata(publicURL: nil), for: process.identity)
    #expect(await discovery.scan(excludingProcessIDs: []).isEmpty)
    await metadata.set(ExternalTunnelMetadata(publicURL: "https://example.trycloudflare.com"), for: process.identity)
    #expect(await discovery.scan(excludingProcessIDs: []).first?.id == stableID)

    processes.set([])
    #expect(await discovery.scan(excludingProcessIDs: []).isEmpty)
    let reusedPID = snapshot(pid: process.identity.pid, start: process.identity.startTimeMicroseconds + 1, arguments: process.arguments)
    processes.set([reusedPID])
    await metadata.set(ExternalTunnelMetadata(publicURL: "https://replacement.trycloudflare.com"), for: reusedPID.identity)
    #expect(await discovery.scan(excludingProcessIDs: []).first?.id != stableID)
}

@Test func scanExcludesAppOwnedProcessIDs() async {
    let process = snapshot(pid: 77, arguments: ["cloudflared", "tunnel", "--url", "http://localhost:3000"])
    let discovery = ExternalTunnelDiscovery(
        processProvider: FixtureProcessProvider([process]),
        metadataProvider: FixtureMetadataProvider([
            process.identity: ExternalTunnelMetadata(publicURL: "https://owned.trycloudflare.com")
        ]),
        signaler: NoopSignaler()
    )
    #expect(await discovery.scan(excludingProcessIDs: [77]).isEmpty)
}

@Test func detectsOnlyOrphanedConnectorsFromOtherOpenTrafficRuns() {
    let current = "/var/folders/xx/T/OpenTraffic-11111111-1111-1111-1111-111111111111"
    let old = "/var/folders/xx/T/OpenTraffic-22222222-2222-2222-2222-222222222222"
    func snapshot(_ pid: Int32, parent: Int32, _ arguments: [String]) -> ProcessSnapshot {
        ProcessSnapshot(identity: ProcessIdentity(pid: pid, startTimeMicroseconds: 1), uid: 501, executablePath: "/opt/homebrew/bin/ngrok", arguments: arguments, parentPID: parent)
    }
    let snapshots = [
        snapshot(10, parent: 1, ["ngrok", "http", "http://localhost:3000", "--config", "/Users/me/ngrok.yml,\(old)/ngrok-ABC.yml"]),
        snapshot(11, parent: 1, ["cloudflared", "tunnel", "--config", "\(old)/empty.yml", "run"]),
        snapshot(12, parent: 1, ["cloudflared", "tunnel", "--config", "\(current)/empty.yml", "run"]),
        snapshot(13, parent: 4242, ["cloudflared", "tunnel", "--config", "\(old)/empty.yml", "run"]),
        snapshot(14, parent: 1, ["cloudflared", "tunnel", "--url", "http://localhost:8080"]),
        snapshot(15, parent: 1, ["ngrok", "http", "3000"]),
    ]
    let orphans = OrphanedConnectorDetector.orphans(in: snapshots, currentRunDirectory: current)
    #expect(orphans.map(\.identity.pid) == [10, 11])
}

@Test func runFoldersFromBeforeTheRenameAreStillRecognized() {
    let id = "8C1F2E7A-4B7D-4E0B-9A51-3F7C2D9E6B10"
    #expect(OrphanedConnectorDetector.runDirectory(in: "/var/folders/xx/T/OpenTraffic-\(id)/config.yml") == "/var/folders/xx/T/OpenTraffic-\(id)")
    #expect(OrphanedConnectorDetector.runDirectory(in: "/var/folders/xx/T/TunnelBar-\(id)/config.yml") == "/var/folders/xx/T/TunnelBar-\(id)")
    #expect(OrphanedConnectorDetector.runDirectory(in: "/var/folders/xx/T/Other-\(id)/config.yml") == nil)
}

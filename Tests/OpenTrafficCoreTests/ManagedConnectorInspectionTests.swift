import Foundation
import Testing
@testable import OpenTrafficCore

private final class InspectionProcessProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProcessSnapshot]

    init(_ snapshots: [ProcessSnapshot]) { stored = snapshots }

    func snapshots() -> [ProcessSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ snapshots: [ProcessSnapshot]) {
        lock.lock(); stored = snapshots; lock.unlock()
    }
}

private final class InspectionSocketChecker: ProcessSocketOwnershipChecking, @unchecked Sendable {
    private let lock = NSLock()
    var results: [String?]

    init(results: [String?]) { self.results = results }

    func loopbackHost(pid: Int32, port: UInt16) -> String? {
        lock.lock(); defer { lock.unlock() }
        return results.isEmpty ? nil : results.removeFirst()
    }
}

private struct InspectionFetcher: ConnectorLoopbackFetching {
    let configuration: Data?
    let metrics: Data?

    func data(host: String, port: UInt16, path: String) async -> Data? {
        path == "config" ? configuration : metrics
    }
}

private func inspectionSnapshot(start: UInt64 = 100) -> ProcessSnapshot {
    ProcessSnapshot(
        identity: ProcessIdentity(pid: 444, startTimeMicroseconds: start),
        uid: 501,
        executablePath: "/opt/homebrew/bin/cloudflared",
        arguments: ["cloudflared", "tunnel", "run"]
    )
}

@Test func resolvesExactRemoteHostnameAndRejectsAmbiguousQuickRoutes() {
    let config = CloudflareTunnelConfiguration(ingress: [
        CloudflareIngress(hostname: "other.example.com", service: "http://localhost:9000"),
        CloudflareIngress(hostname: "app.example.com", service: "http://127.0.0.1:8130"),
        CloudflareIngress(service: "http_status:404"),
    ])
    #expect(ManagedIngressResolver.origin(kind: .remote, hostname: "APP.EXAMPLE.COM.", configuration: config) == "http://127.0.0.1:8130")
    #expect(ManagedIngressResolver.origin(kind: .remote, hostname: "missing.example.com", configuration: config) == nil)
    #expect(ManagedIngressResolver.origin(kind: .quick, hostname: nil, configuration: config) == nil)

    let soleQuick = CloudflareTunnelConfiguration(ingress: [
        CloudflareIngress(service: "http://127.0.0.1:8130"),
        CloudflareIngress(service: "http_status:404"),
    ])
    #expect(ManagedIngressResolver.origin(kind: .quick, hostname: nil, configuration: soleQuick) == "http://127.0.0.1:8130")

    let ambiguousRemote = CloudflareTunnelConfiguration(ingress: [
        CloudflareIngress(hostname: "app.example.com", service: "http://127.0.0.1:8130"),
        CloudflareIngress(hostname: "app.example.com", service: "http://127.0.0.1:9000"),
        CloudflareIngress(service: "http_status:404"),
    ])
    #expect(ManagedIngressResolver.origin(kind: .remote, hostname: "app.example.com", configuration: ambiguousRemote) == nil)
}

@Test func inspectorRejectsStaleProcessIdentityAndPortReuse() async {
    let snapshot = inspectionSnapshot()
    let config = Data(#"{"version":1,"config":{"ingress":[{"hostname":"app.example.com","service":"http://127.0.0.1:8130"},{"service":"http_status:404"}]}}"#.utf8)
    let metrics = Data("cloudflared_tunnel_total_requests 35\n".utf8)

    let staleProvider = InspectionProcessProvider([inspectionSnapshot(start: 999)])
    let staleInspector = ManagedConnectorInspector(
        processProvider: staleProvider,
        socketChecker: InspectionSocketChecker(results: ["127.0.0.1"]),
        fetcher: InspectionFetcher(configuration: config, metrics: metrics)
    )
    #expect(await staleInspector.inspect(identity: OwnedConnectorIdentity(process: snapshot.identity, generation: 7), metricsPort: 20_244) == nil)

    let portReuseInspector = ManagedConnectorInspector(
        processProvider: InspectionProcessProvider([snapshot]),
        socketChecker: InspectionSocketChecker(results: ["127.0.0.1", nil]),
        fetcher: InspectionFetcher(configuration: config, metrics: metrics)
    )
    #expect(await portReuseInspector.inspect(identity: OwnedConnectorIdentity(process: snapshot.identity, generation: 7), metricsPort: 20_244) == nil)
}

@Test func inspectorReturnsConfigurationAndStatisticsOnlyForVerifiedOwnership() async throws {
    let snapshot = inspectionSnapshot()
    let config = Data(#"{"version":1,"config":{"ingress":[{"hostname":"app.example.com","service":"http://127.0.0.1:8130"},{"service":"http_status:404"}]}}"#.utf8)
    let metrics = Data("cloudflared_tunnel_total_requests 35\n".utf8)
    let inspector = ManagedConnectorInspector(
        processProvider: InspectionProcessProvider([snapshot]),
        socketChecker: InspectionSocketChecker(results: ["127.0.0.1", "127.0.0.1"]),
        fetcher: InspectionFetcher(configuration: config, metrics: metrics)
    )
    let result = try #require(await inspector.inspect(
        identity: OwnedConnectorIdentity(process: snapshot.identity, generation: 7),
        metricsPort: 20_244
    ))
    #expect(result.statistics?.totalRequests == 35)
    #expect(result.configuration?.ingress.first?.service == "http://127.0.0.1:8130")
}

@Test func effectiveOriginFallsBackAndRetainsLastKnownWithoutChangingSavedIntent() {
    let saved = EffectiveOriginResolver.resolve(savedURL: "http://localhost:3000", cached: nil)
    #expect(saved.url == "http://localhost:3000")
    #expect(saved.source == .savedConfiguration)

    let verifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let live = EffectiveOrigin(url: "http://127.0.0.1:8130", source: .liveConnector, updatedAt: verifiedAt)
    let lastKnown = EffectiveOriginResolver.markUnavailable(live)
    #expect(lastKnown?.url == "http://127.0.0.1:8130")
    #expect(lastKnown?.source == .lastKnownLiveConnector)
    #expect(lastKnown?.updatedAt == verifiedAt)
    #expect(saved.url == "http://localhost:3000")
}

@Test func persistsVerifiedEffectiveOriginSeparately() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = EffectiveOriginPersistence(fileURL: directory.appending(path: "effective.json"))
    let expected = [PersistedEffectiveOrigin(
        tunnelID: UUID(),
        url: "http://127.0.0.1:8130",
        verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )]
    try persistence.save(expected)
    #expect(try persistence.load() == expected)
}

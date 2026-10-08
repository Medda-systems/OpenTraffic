import Foundation
import Testing
@testable import OpenTrafficCore

@Test func displayStateFollowsConnectorTransitions() {
    #expect(TunnelDisplayState.resolve(health: .healthy, connector: .starting, hasError: false) == .starting)
    #expect(TunnelDisplayState.resolve(health: .healthy, connector: .stopping, hasError: false) == .stopping)
    #expect(TunnelDisplayState.resolve(health: .unknown, connector: .failed, hasError: true) == .attention)
}

@Test func displayStateDistinguishesQuietStopFromFailedStop() {
    #expect(TunnelDisplayState.resolve(health: .stopped, connector: .stopped, hasError: false) == .stopped)
    #expect(TunnelDisplayState.resolve(health: .stopped, connector: .stopped, hasError: true) == .attention)
    #expect(TunnelDisplayState.resolve(health: .failed, connector: .stopped, hasError: false) == .attention)
}

@Test func runningDisplayStateDependsOnHealth() {
    #expect(TunnelDisplayState.resolve(health: .healthy, connector: .running, hasError: false) == .online)
    #expect(TunnelDisplayState.resolve(health: .working, connector: .running, hasError: false) == .checking)
    #expect(TunnelDisplayState.resolve(health: .unknown, connector: .running, hasError: false) == .checking)
    #expect(TunnelDisplayState.resolve(health: .failed, connector: .running, hasError: false) == .attention)
}

@Test func responseClassesGroupAndSortCodes() {
    let summary = ResponseClassCount.summarize(["200": 10, "204": 2, "404": 3, "502": 1, "bogus": 9, "999": 4])
    #expect(summary == [
        ResponseClassCount(label: "2xx", count: 12),
        ResponseClassCount(label: "4xx", count: 3),
        ResponseClassCount(label: "5xx", count: 1),
    ])
    #expect(ResponseClassCount.summarize([:]).isEmpty)
}

@Test func requestHistoryIsBoundedAndComputesDeltas() {
    var history = RequestHistory(capacity: 3)
    let start = Date(timeIntervalSince1970: 0)
    for (offset, total) in [10, 15, 15, 22].enumerated() {
        history.record(total: Int64(total), at: start.addingTimeInterval(Double(offset)))
    }
    #expect(history.samples.map(\.total) == [15, 15, 22])
    #expect(history.deltas.map(\.count) == [0, 7])
}

@Test func requestHistoryResetsWhenCounterGoesBackwards() {
    var history = RequestHistory()
    history.record(total: 40)
    history.record(total: 50)
    history.record(total: 3)
    #expect(history.samples.map(\.total) == [3])
    #expect(history.deltas.isEmpty)
}

@Test func loopbackPortRecognizesLocalHostsAndDefaultPorts() {
    #expect(ShareSuggestions.loopbackPort(of: "http://localhost:5173") == 5173)
    #expect(ShareSuggestions.loopbackPort(of: "http://127.0.0.1:3000/") == 3000)
    #expect(ShareSuggestions.loopbackPort(of: "http://[::1]:8080") == 8080)
    #expect(ShareSuggestions.loopbackPort(of: "https://localhost") == 443)
    #expect(ShareSuggestions.loopbackPort(of: "http://example.com:3000") == nil)
    #expect(ShareSuggestions.loopbackPort(of: "tcp://localhost:22") == nil)
    #expect(ShareSuggestions.loopbackPort(of: nil) == nil)
}

@Test func unsharedServicesExcludeActivelyPublishedPorts() {
    let services = [
        DiscoveredLocalService(port: 3000),
        DiscoveredLocalService(port: 5173),
        DiscoveredLocalService(port: 8000),
    ]
    let unshared = ShareSuggestions.unshared(services, activeOrigins: ["http://127.0.0.1:5173", nil, "http://example.com:8000"])
    #expect(unshared.map(\.port) == [3000, 8000])
}

@Test func unsharedServicesExcludeConnectorMetricsListeners() {
    let services = [
        DiscoveredLocalService(port: 20241, processName: "cloudflared"),
        DiscoveredLocalService(port: 63795, processName: "ngrok"),
        DiscoveredLocalService(port: 3000, processName: "node"),
    ]
    #expect(ShareSuggestions.unshared(services, activeOrigins: []).map(\.port) == [3000])
}

@Test func sharingReusesAnExistingQuickTunnelForThePort() {
    let quick = TunnelDefinition(name: "Vite", kind: .quick, localURL: "http://localhost:5173")
    let remote = TunnelDefinition(name: "Prod", kind: .remote, localURL: "http://localhost:3000")
    let definitions = [remote, quick]
    #expect(ShareSuggestions.existingTunnel(for: DiscoveredLocalService(port: 5173), in: definitions)?.id == quick.id)
    #expect(ShareSuggestions.existingTunnel(for: DiscoveredLocalService(port: 3000), in: definitions) == nil)
}

@Test func existingTunnelKindsDecodeUnchanged() throws {
    let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Old","kind":"quick","localURL":"http://localhost:3000"},{"id":"16FD2706-8BAF-433B-82EB-8C7FADA847DA","name":"Site","kind":"remote","localURL":"http://localhost:8080","hostname":"app.example.dev"}]"#
    let definitions = try JSONDecoder().decode([TunnelDefinition].self, from: Data(json.utf8))
    #expect(definitions.map(\.kind) == [.quick, .remote])
    #expect(definitions.allSatisfy { $0.kind.provider == .cloudflare })
}

@Test func kindCapabilitiesMatchCloudflareBehavior() {
    #expect(TunnelKind.quick.hasEphemeralURL && !TunnelKind.quick.usesCloudflareAccount && !TunnelKind.quick.reportsEdgeStatus)
    #expect(!TunnelKind.remote.hasEphemeralURL && TunnelKind.remote.usesCloudflareAccount && TunnelKind.remote.reportsEdgeStatus)
    #expect(HealthCheckKind.edge.title(for: .cloudflare) == "Cloudflare")
    #expect(HealthCheckKind.edge.title(for: .tailscale) == "Tailnet")
}

@Test func executableLocatorPrefersCustomPathThenCommonLocations() {
    let present: Set<String> = ["/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    #expect(ExecutableLocator.resolve(.tailscale, isExecutable: present.contains)?.path == "/usr/local/bin/tailscale")
    #expect(ExecutableLocator.resolve(.tailscale, customPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale", isExecutable: present.contains)?.path == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    #expect(ExecutableLocator.resolve(.ngrok, isExecutable: present.contains) == nil)
    #expect(ExecutableLocator.commonPaths(for: .cloudflare).first == "/opt/homebrew/bin/cloudflared")
}

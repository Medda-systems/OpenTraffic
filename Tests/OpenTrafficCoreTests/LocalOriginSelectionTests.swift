import Foundation
import Testing
@testable import OpenTrafficCore

private struct ReachableOriginTransport: HTTPTransport {
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.httpMethod == "HEAD")
        #expect(request.timeoutInterval == 2)
        return (
            Data(),
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}

private struct UnreachableOriginTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

private func externalOrigin(id: UUID, url: String) -> DiscoveredQuickTunnel {
    DiscoveredQuickTunnel(
        id: id,
        identity: ProcessIdentity(pid: 42, startTimeMicroseconds: 100),
        executablePath: "/opt/homebrew/bin/cloudflared",
        localURL: url,
        publicURL: "https://example.trycloudflare.com",
        logFilePath: nil,
        logEntries: [],
        metricsPort: 20_241,
        lastSeen: Date()
    )
}

@Test func selectedDiscoveredOriginSeedsCreateInsteadOfUnrelatedDefaultPort() {
    let saved = TunnelDefinition(name: "Local site", kind: .quick, localURL: "http://localhost:3000")
    let externalID = UUID()
    let external = externalOrigin(id: externalID, url: "http://127.0.0.1:8130")
    let seed = LocalOriginResolver.selectedSeed(
        selectedID: externalID,
        definitions: [saved],
        discovered: [external],
        discoveredAliases: [external.preferenceKey: "Demo-App"]
    )
    #expect(seed?.name == "Demo-App")
    #expect(seed?.url == "http://127.0.0.1:8130")
    #expect(seed?.url != "http://localhost:3000")
}

@Test func noSelectionProducesNoSilentOriginDefault() {
    let saved = TunnelDefinition(name: "Local site", kind: .quick, localURL: "http://localhost:3000")
    #expect(LocalOriginResolver.selectedSeed(selectedID: nil, definitions: [saved], discovered: []) == nil)
}

@Test func originOptionsDeduplicateURLsAndPreserveAliases() {
    let managed = TunnelDefinition(name: "Managed", kind: .quick, localURL: "http://localhost:8130")
    let external = externalOrigin(id: UUID(), url: "http://localhost:8130")
    let other = externalOrigin(id: UUID(), url: "http://localhost:9000")
    let options = LocalOriginResolver.options(
        definitions: [managed],
        discovered: [external, other],
        discoveredAliases: [other.preferenceKey: "Other API"]
    )
    #expect(options.count == 2)
    #expect(options[0].name == "Managed")
    #expect(options[1].name == "Other API")
}

@Test func duplicateSelectedOriginUsesRetainedPickerIDButKeepsSelectedName() throws {
    let retained = LocalOriginOption(id: "managed", name: "Managed", url: "http://localhost:8130")
    let selected = LocalOriginOption(id: "discovered", name: "Demo-App", url: "http://localhost:8130")
    let seed = try #require(LocalOriginResolver.pickerSeed(selected: selected, options: [retained]))
    #expect(seed.id == "managed")
    #expect(seed.name == "Demo-App")
    #expect(seed.url == "http://localhost:8130")
}

@Test func reachabilityTreatsAnyHTTPResponseAsListening() async {
    let checker = LocalOriginReachabilityChecker(transport: ReachableOriginTransport(statusCode: 503))
    #expect(await checker.check("http://127.0.0.1:8130") == .reachable(statusCode: 503))
}

@Test func reachabilityReturnsActionableInvalidAndOfflineMessages() async {
    let checker = LocalOriginReachabilityChecker(transport: UnreachableOriginTransport())
    let invalid = await checker.check("")
    if case .invalid(let message) = invalid {
        #expect(message.contains("valid HTTP or HTTPS"))
    } else {
        Issue.record("Expected invalid origin result")
    }
    let offline = await checker.check("http://localhost:3000")
    if case .unreachable(let message) = offline {
        #expect(message.contains("http://localhost:3000"))
        #expect(message.contains("explicitly continue"))
    } else {
        Issue.record("Expected unreachable origin result")
    }
}

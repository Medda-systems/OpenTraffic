import Foundation
import Testing
@testable import OpenTrafficCore

@Test func overallIsHealthyWhenAllChecksPass() {
    let checks = [
        TunnelHealthCheck(kind: .localOrigin, state: .ok),
        TunnelHealthCheck(kind: .connector, state: .ok),
        TunnelHealthCheck(kind: .edge, state: .ok),
        TunnelHealthCheck(kind: .dns, state: .ok),
        TunnelHealthCheck(kind: .publicSite, state: .ok),
    ]
    #expect(TunnelHealthEvaluator.overall(checks: checks) == .healthy)
}

@Test func overallTreatsSkippedNonConnectorChecksAsHealthy() {
    let checks = [
        TunnelHealthCheck(kind: .localOrigin, state: .ok),
        TunnelHealthCheck(kind: .connector, state: .ok),
        TunnelHealthCheck(kind: .edge, state: .skipped),
        TunnelHealthCheck(kind: .dns, state: .skipped),
        TunnelHealthCheck(kind: .publicSite, state: .ok),
    ]
    #expect(TunnelHealthEvaluator.overall(checks: checks) == .healthy)
}

@Test func overallFailsOnAnyFailedCheck() {
    let checks = [
        TunnelHealthCheck(kind: .localOrigin, state: .ok),
        TunnelHealthCheck(kind: .connector, state: .ok),
        TunnelHealthCheck(kind: .edge, state: .ok),
        TunnelHealthCheck(kind: .dns, state: .failed, detail: "No DNS record"),
        TunnelHealthCheck(kind: .publicSite, state: .ok),
    ]
    #expect(TunnelHealthEvaluator.overall(checks: checks) == .failed)
}

@Test func overallIsStoppedWhenConnectorIsSkippedWithoutFailures() {
    let checks = [
        TunnelHealthCheck(kind: .localOrigin, state: .skipped),
        TunnelHealthCheck(kind: .connector, state: .skipped),
        TunnelHealthCheck(kind: .edge, state: .skipped),
        TunnelHealthCheck(kind: .dns, state: .skipped),
        TunnelHealthCheck(kind: .publicSite, state: .skipped),
    ]
    #expect(TunnelHealthEvaluator.overall(checks: checks) == .stopped)
}

@Test func overallIsWorkingWhenAConnectorIsStarting() {
    let checks = [
        TunnelHealthCheck(kind: .localOrigin, state: .ok),
        TunnelHealthCheck(kind: .connector, state: .working),
        TunnelHealthCheck(kind: .edge, state: .skipped),
    ]
    #expect(TunnelHealthEvaluator.overall(checks: checks) == .working)
}

@Test func overallIsUnknownWithoutChecks() {
    #expect(TunnelHealthEvaluator.overall(checks: []) == .unknown)
}

@Test func detectorIgnoresSuccessfulSites() {
    let probe = PublicSiteProbe(statusCode: 200, bodyExcerpt: "<title>App</title>")
    #expect(PublicSiteBlockDetector.hint(hostname: "app.example.com", probe: probe) == nil)
    #expect(PublicSiteBlockDetector.hint(hostname: "app.example.com", probe: PublicSiteProbe(statusCode: 301)) == nil)
    #expect(PublicSiteBlockDetector.hint(hostname: "app.example.com", probe: PublicSiteProbe(transportError: "offline")) == nil)
}

@Test func detectorIdentifiesViteHostBlock() {
    let body = #"Blocked request. This host ("app.example.com") is not allowed. To allow this host, add "app.example.com" to `server.allowedHosts` in vite.config.js."#
    let hint = PublicSiteBlockDetector.hint(hostname: "app.example.com", probe: PublicSiteProbe(statusCode: 403, bodyExcerpt: body))
    #expect(hint?.contains("Vite") == true)
    #expect(hint?.contains("allowedHosts") == true)
    #expect(hint?.contains("app.example.com") == true)
}

@Test func detectorIdentifiesNextDjangoAndRailsHostBlocks() {
    let next = PublicSiteBlockDetector.hint(
        hostname: "app.example.com",
        probe: PublicSiteProbe(statusCode: 403, bodyExcerpt: "Invalid Host header")
    )
    #expect(next?.contains("Next.js") == true)
    let django = PublicSiteBlockDetector.hint(
        hostname: "app.example.com",
        probe: PublicSiteProbe(statusCode: 400, bodyExcerpt: "DisallowedHost at /")
    )
    #expect(django?.contains("Django") == true)
    let rails = PublicSiteBlockDetector.hint(
        hostname: "app.example.com",
        probe: PublicSiteProbe(statusCode: 403, bodyExcerpt: "Blocked host: app.example.com")
    )
    #expect(rails?.contains("app.example.com") == true)
}

@Test func detectorFallsBackToStatusCodes() {
    #expect(PublicSiteBlockDetector.hint(hostname: "app.example.com", probe: PublicSiteProbe(statusCode: 403))?.contains("403") == true)
    #expect(PublicSiteBlockDetector.hint(hostname: "app.example.com", probe: PublicSiteProbe(statusCode: 502))?.contains("502") == true)
}

@Test func decodesDoHResponses() throws {
    let exists = try JSONDecoder().decode(DoHResponse.self, from: Data(#"{"Status":0,"Answer":[{"name":"app.example.com.","type":1,"data":"203.0.113.1"}]}"# .utf8))
    #expect(exists.status == 0)
    let missing = try JSONDecoder().decode(DoHResponse.self, from: Data(#"{"Status":3}"#.utf8))
    #expect(missing.status == 3)
}

@Test func composesHostnamesFromSubdomainAndZone() {
    #expect(TunnelHostname.compose(subdomain: "Landing", zoneName: "example.com") == "landing.example.com")
    #expect(TunnelHostname.compose(subdomain: "", zoneName: "example.com") == "example.com")
    #expect(TunnelHostname.compose(subdomain: "  app. ", zoneName: ".Example.COM. ") == "app.example.com")
}

@Test func stripsZoneSuffixFromSubdomainInput() {
    #expect(TunnelHostname.subdomain(of: "landing.example.com", zoneName: "example.com") == "landing")
    #expect(TunnelHostname.subdomain(of: "example.com", zoneName: "example.com") == "")
    #expect(TunnelHostname.subdomain(of: "other.example.org", zoneName: "example.com") == "other.example.org")
}

@Test func validatesSubdomainLabels() {
    #expect(TunnelHostname.validateSubdomain("") == nil)
    #expect(TunnelHostname.validateSubdomain("app") == nil)
    #expect(TunnelHostname.validateSubdomain("shop.eu") == nil)
    #expect(TunnelHostname.validateSubdomain("-app") != nil)
    #expect(TunnelHostname.validateSubdomain("app-") != nil)
    #expect(TunnelHostname.validateSubdomain("has space") != nil)
    #expect(TunnelHostname.validateSubdomain("under_score") != nil)
}

@Test func setupProgressStepsHaveStableOrder() {
    #expect(SetupProgressStep.tunnelSteps().map(\.id) == ["create", "ingress", "dns"])
    #expect(SetupProgressStep.applySteps().map(\.id) == ["ingress", "dns"])
}

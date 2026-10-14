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

// MARK: Quick Tunnels on filtered networks

@Test func dnsFilterRedirectingTryCloudflareIsDetected() {
    // Telenor's "Nätskydd" answers with a CNAME to its block page; Cloudflare's DNS knows better.
    let filtered = SystemDNSAnswer.addresses(["52.223.20.176", "35.71.190.33"], canonicalName: "natskydd.telenor.se")
    let network = QuickTunnelNetwork.assess(system: filtered, doh: ["104.16.230.132", "104.16.231.132"])
    #expect(network == .filtered(to: "natskydd.telenor.se"))
    #expect(network.warning?.contains("redirects api.trycloudflare.com to natskydd.telenor.se") == true)
    #expect(network.warning?.contains("1.1.1.1") == true)
    // Without DNS over HTTPS, the answer alone gives it away.
    #expect(QuickTunnelNetwork.assess(system: filtered, doh: nil).isFiltered)
    // A sinkhole address.
    #expect(QuickTunnelNetwork.assess(system: .addresses(["0.0.0.0"], canonicalName: "api.trycloudflare.com"), doh: nil) == .filtered(to: nil))
    // "No such name", though the name exists.
    #expect(QuickTunnelNetwork.assess(system: .notFound, doh: ["104.16.230.132"]) == .filtered(to: nil))
}

@Test func unfilteredOrUnknownNetworksAreNotBlamed() {
    let cloudflare = SystemDNSAnswer.addresses(["104.16.230.132", "2606:4700::6810:e684"], canonicalName: "api.trycloudflare.com")
    #expect(QuickTunnelNetwork.assess(system: cloudflare, doh: ["104.16.231.132"]) == .ok)
    #expect(QuickTunnelNetwork.assess(system: cloudflare, doh: nil) == .ok)
    #expect(QuickTunnelNetwork.assess(system: .addresses(["198.51.100.7"], canonicalName: nil), doh: ["198.51.100.7"]) == .ok)
    #expect(QuickTunnelNetwork.assess(system: .failed, doh: ["104.16.230.132"]) == .unknown)
    #expect(QuickTunnelNetwork.assess(system: .notFound, doh: nil) == .unknown)
    #expect(QuickTunnelNetwork.ok.warning == nil)
}

@Test func knowsCloudflareAddresses() {
    #expect(CloudflareAddresses.contains("104.16.230.132"))
    #expect(CloudflareAddresses.contains("172.67.1.1"))
    #expect(CloudflareAddresses.contains("2606:4700::6810:e684"))
    #expect(!CloudflareAddresses.contains("52.223.20.176"))
    #expect(!CloudflareAddresses.contains("104.24.0.0x"))
    #expect(!CloudflareAddresses.contains("2001:db8::1"))
}

@Test func healthLooksAgainQuicklyWhileAShareStarts() {
    #expect(HealthRecheck.delay(sinceStart: 2) == 1)
    #expect(HealthRecheck.delay(sinceStart: 30) == 3)
    #expect(HealthRecheck.delay(sinceStart: 90) == 8)
    #expect(HealthRecheck.delay(sinceStart: nil) == 8)
}

@Test func tellsProviderErrorPagesFromTheAppsOwnAnswer() {
    #expect(PublicSiteBlockDetector.isProviderError(probe: PublicSiteProbe(statusCode: 404, bodyExcerpt: "ERR_NGROK_3200: The endpoint is offline")))
    #expect(PublicSiteBlockDetector.isProviderError(probe: PublicSiteProbe(statusCode: 530, bodyExcerpt: "error code: 1033")))
    #expect(PublicSiteBlockDetector.isProviderError(probe: PublicSiteProbe(statusCode: 502, bodyExcerpt: "")))
    #expect(!PublicSiteBlockDetector.isProviderError(probe: PublicSiteProbe(statusCode: 404, bodyExcerpt: #"{"error":"not found"}"#)))
}

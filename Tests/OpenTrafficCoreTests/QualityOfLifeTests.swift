import Foundation
import Testing
@testable import OpenTrafficCore

@Test func newDefinitionFieldsDecodeWithDefaults() throws {
    let json = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Old","kind":"quick","localURL":"http://localhost:5173"}"#
    let definition = try JSONDecoder().decode(TunnelDefinition.self, from: Data(json.utf8))
    #expect(!definition.rewriteHostHeader)
    #expect(definition.savedPaths.isEmpty)
    #expect(definition.originHostHeader == "localhost:5173")
    let roundTrip = try JSONDecoder().decode(TunnelDefinition.self, from: JSONEncoder().encode(
        TunnelDefinition(name: "x", kind: .ngrok, localURL: "http://127.0.0.1:3000", rewriteHostHeader: true, savedPaths: ["/hook"])
    ))
    #expect(roundTrip.rewriteHostHeader && roundTrip.savedPaths == ["/hook"])
}

@Test func hostRewriteSupportFollowsProviderCapabilities() {
    func share(_ kind: TunnelKind, _ localURL: String = "http://localhost:5173") -> TunnelDefinition {
        TunnelDefinition(name: "x", kind: kind, localURL: localURL)
    }
    #expect(share(.quick).supportsHostHeaderRewrite)
    #expect(share(.remote).supportsHostHeaderRewrite)
    #expect(share(.ngrok, "https://localhost:8443").supportsHostHeaderRewrite)
    #expect(share(.opentunnel).supportsHostHeaderRewrite)
    // Tailscale shares get it from OpenTraffic's proxy, which only speaks plain HTTP to the local service.
    #expect(share(.tailscale).supportsHostHeaderRewrite)
    #expect(!share(.tailscale, "https://localhost:8443").supportsHostHeaderRewrite)
}

@Test func detectsWhichFrameworkBlockedTheHost() {
    func probe(_ status: Int, _ body: String) -> PublicSiteProbe { PublicSiteProbe(statusCode: status, bodyExcerpt: body) }
    #expect(PublicSiteBlockDetector.blockingFramework(probe: probe(403, "Blocked request. This host (\"x.ngrok-free.dev\") is not allowed. To allow this host, add it to server.allowedHosts in vite.config.js.")) == .vite)
    #expect(PublicSiteBlockDetector.blockingFramework(probe: probe(400, "Invalid Host header")) == .nextjs)
    #expect(PublicSiteBlockDetector.blockingFramework(probe: probe(400, "DisallowedHost at /")) == .django)
    #expect(PublicSiteBlockDetector.blockingFramework(probe: probe(403, "Blocked host: x.example")) == .rails)
    #expect(PublicSiteBlockDetector.blockingFramework(probe: probe(200, "is not allowed vite")) == nil)
    #expect(BlockingFramework.vite.snippet(hostname: "a.b").contains("allowedHosts: ['a.b']"))
    #expect(BlockingFramework.django.snippet(hostname: "a.b").contains("'a.b'"))
}

@Test func buildsNgrokTrafficPolicies() {
    #expect(NgrokTrafficPolicy.yaml(hostHeader: nil) == nil)
    let host = NgrokTrafficPolicy.yaml(hostHeader: "localhost:5173")
    #expect(host == "on_http_request:\n  - actions:\n      - type: add-headers\n        config:\n          headers:\n            host: \"localhost:5173\"\n")
    let both = NgrokTrafficPolicy.yaml(hostHeader: "localhost:5173", basicAuthCredentials: [#"guest:p"w\d"#])
    #expect(both?.contains("type: basic-auth") == true)
    #expect(both?.contains(#"- "guest:p\"w\\d""#) == true)
    #expect(both.map { $0.range(of: "basic-auth")!.lowerBound < $0.range(of: "add-headers")!.lowerBound } == true)
}

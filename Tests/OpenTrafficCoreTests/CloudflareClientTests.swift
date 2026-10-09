import Foundation
import Testing
@testable import OpenTrafficCore

private actor PagingTransport: HTTPTransport {
    var requestedURLs: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestedURLs.append(request.url!)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let page = components.queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
        let body: String
        if request.url!.path.hasSuffix("/cfd_tunnel") {
            body = page == "1"
                ? #"{"success":true,"result":[{"id":"one","name":"First","status":"healthy","config_src":"cloudflare"}],"result_info":{"page":1,"per_page":1,"total_count":2}}"#
                : #"{"success":true,"result":[{"id":"two","name":"Second","status":"inactive","config_src":"cloudflare"}],"result_info":{"page":2,"per_page":1,"total_count":2}}"#
        } else {
            body = #"{"success":true,"result":[],"result_info":{"count":0,"page":1,"per_page":50,"total_count":0}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func urls() -> [URL] { requestedURLs }
}

private struct ErrorTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor MutationTransport: HTTPTransport {
    struct Captured: Sendable {
        let method: String
        let path: String
        let body: Data?
        let authorization: String?
    }
    var captured: [Captured] = []
    var configurationJSON = #"{"ingress":[]}"#
    var dnsRecordsJSON = "[]"

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(.init(
            method: request.httpMethod ?? "GET",
            path: request.url!.path,
            body: request.httpBody,
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let body: String
        if path.hasSuffix("/token") {
            body = #"{"success":true,"errors":[],"result":"connector-secret"}"#
        } else if path.hasSuffix("/cfd_tunnel") && method == "POST" {
            body = #"{"success":true,"errors":[],"result":{"id":"created-id","name":"Development","status":"inactive","config_src":"cloudflare"}}"#
        } else if path.hasSuffix("/configurations") && method == "PUT" {
            body = #"{"success":true,"errors":[],"result":{"account_id":"account-id","tunnel_id":"created-id","version":1}}"#
        } else if path.hasSuffix("/configurations") {
            body = #"{"success":true,"errors":[],"result":{"config":\#(configurationJSON)}}"#
        } else if path.contains("/dns_records/") && method == "DELETE" {
            body = #"{"success":true,"errors":[],"result":{"id":"deleted"}}"#
        } else if path.contains("/dns_records/") && method == "PATCH" {
            body = #"{"success":true,"errors":[],"result":{"id":"dns-id","name":"dev.example.com","type":"CNAME","content":"created-id.cfargotunnel.com","proxied":true}}"#
        } else if path.hasSuffix("/dns_records") && method == "POST" {
            body = #"{"success":true,"errors":[],"result":{"id":"dns-id","name":"dev.example.com","type":"CNAME","content":"created-id.cfargotunnel.com","proxied":true}}"#
        } else if path.hasSuffix("/dns_records") {
            body = #"{"success":true,"errors":[],"result":\#(dnsRecordsJSON),"result_info":{"page":1,"per_page":100,"total_pages":1}}"#
        } else {
            body = #"{"success":false,"errors":[{"message":"unexpected path"}],"result":null}"#
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func requests() -> [Captured] { captured }
    func setConfigurationJSON(_ value: String) { configurationJSON = value }
    func setDNSRecordsJSON(_ value: String) { dnsRecordsJSON = value }
}

private struct FixedTransport: HTTPTransport {
    let status: Int
    let body: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func listsEveryTunnelPageWithoutTotalPagesField() async throws {
    let transport = PagingTransport()
    let client = CloudflareClient(
        accountID: "account",
        token: "secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )
    let tunnels = try await client.listTunnels()
    #expect(tunnels.map(\.id) == ["one", "two"])
    let urls = await transport.urls()
    #expect(urls.count == 2)
    #expect(urls.allSatisfy { $0.absoluteString.contains("is_deleted=false") })
}

@Test func surfacesCloudflareErrorMessageWithoutToken() async {
    let client = CloudflareClient(
        accountID: "account",
        token: "do-not-leak",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: ErrorTransport()
    )
    do {
        _ = try await client.listTunnels()
        Issue.record("Expected API error")
    } catch {
        #expect(error.localizedDescription.contains("Authentication error"))
        #expect(!error.localizedDescription.contains("do-not-leak"))
    }
}

@Test func getsConnectorTokenAndBuildsRemoteTunnelConfigurationAndDNSRequests() async throws {
    let transport = MutationTransport()
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    #expect(try await client.connectorToken(id: "existing-id") == "connector-secret")
    let tunnel = try await client.createRemoteTunnel(name: "Development")
    #expect(tunnel.id == "created-id")
    try await client.applyHostnameConfiguration(tunnelID: tunnel.id, hostname: "dev.example.com", service: "http://localhost:3000")
    try await client.ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: tunnel.id)

    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET", "POST", "GET", "PUT", "GET", "POST"])
    #expect(requests.map(\.path) == [
        "/client/v4/accounts/account-id/cfd_tunnel/existing-id/token",
        "/client/v4/accounts/account-id/cfd_tunnel",
        "/client/v4/accounts/account-id/cfd_tunnel/created-id/configurations",
        "/client/v4/accounts/account-id/cfd_tunnel/created-id/configurations",
        "/client/v4/zones/zone-id/dns_records",
        "/client/v4/zones/zone-id/dns_records",
    ])
    #expect(requests.allSatisfy { $0.authorization == "Bearer api-secret" })

    let createBody = try #require(requests[1].body)
    let createJSON = try #require(try JSONSerialization.jsonObject(with: createBody) as? [String: Any])
    #expect(createJSON["config_src"] as? String == "cloudflare")
    let configBody = try #require(requests[3].body)
    let configJSON = try #require(try JSONSerialization.jsonObject(with: configBody) as? [String: Any])
    let config = try #require(configJSON["config"] as? [String: Any])
    let ingress = try #require(config["ingress"] as? [[String: Any]])
    #expect(ingress.count == 2)
    #expect(ingress[0]["hostname"] as? String == "dev.example.com")
    #expect(ingress[0]["service"] as? String == "http://localhost:3000")
    #expect(ingress[1]["hostname"] == nil)
    #expect(ingress[1]["service"] as? String == "http_status:404")
    let dnsBody = try #require(requests[5].body)
    let dnsJSON = try #require(try JSONSerialization.jsonObject(with: dnsBody) as? [String: Any])
    #expect(dnsJSON["type"] as? String == "CNAME")
    #expect(dnsJSON["name"] as? String == "dev.example.com")
    #expect(dnsJSON["content"] as? String == "created-id.cfargotunnel.com")
    #expect(dnsJSON["proxied"] as? Bool == true)
}

@Test func appliesHostnameConfigurationKeepingOtherIngressRules() async throws {
    let transport = MutationTransport()
    await transport.setConfigurationJSON(
        #"{"ingress":[{"hostname":"other.example.com","service":"http://localhost:9000"},{"hostname":"dev.example.com","service":"http://localhost:1111"},{"service":"http_status:404"}]}"#
    )
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    try await client.applyHostnameConfiguration(tunnelID: "created-id", hostname: "DEV.example.com.", service: "http://localhost:3000")

    let requests = await transport.requests()
    let configBody = try #require(requests.last?.body)
    let configJSON = try #require(try JSONSerialization.jsonObject(with: configBody) as? [String: Any])
    let config = try #require(configJSON["config"] as? [String: Any])
    let ingress = try #require(config["ingress"] as? [[String: Any]])
    #expect(ingress.count == 3)
    #expect(ingress[0]["hostname"] as? String == "other.example.com")
    #expect(ingress[0]["service"] as? String == "http://localhost:9000")
    #expect(ingress[1]["hostname"] as? String == "DEV.example.com.")
    #expect(ingress[1]["service"] as? String == "http://localhost:3000")
    #expect(ingress[2]["service"] as? String == "http_status:404")
}

@Test func addsCatchAllWhenConfigurationHasNone() async throws {
    let transport = MutationTransport()
    await transport.setConfigurationJSON(#"{"ingress":[]}"#)
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    try await client.applyHostnameConfiguration(tunnelID: "created-id", hostname: "dev.example.com", service: "http://localhost:3000")

    let requests = await transport.requests()
    let configBody = try #require(requests.last?.body)
    let configJSON = try #require(try JSONSerialization.jsonObject(with: configBody) as? [String: Any])
    let config = try #require(configJSON["config"] as? [String: Any])
    let ingress = try #require(config["ingress"] as? [[String: Any]])
    #expect(ingress.count == 2)
    #expect(ingress.last?["service"] as? String == "http_status:404")
}

@Test func normalizesTrailingSlashInIngressService() throws {
    #expect(try CloudflareClient.ingressService(from: "http://localhost:5174/") == "http://localhost:5174")
    #expect(try CloudflareClient.ingressService(from: "https://localhost:8443/") == "https://localhost:8443")
    #expect(try CloudflareClient.ingressService(from: "http://127.0.0.1:8130") == "http://127.0.0.1:8130")
    #expect(try CloudflareClient.ingressService(from: "http://[::1]:8080/") == "http://[::1]:8080")
    #expect(try CloudflareClient.ingressService(from: "unix:///tmp/origin.sock") == "unix:///tmp/origin.sock")
}

@Test func rejectsIngressServiceWithPath() {
    do {
        _ = try CloudflareClient.ingressService(from: "http://localhost:5174/app")
        Issue.record("Expected a path rejection")
    } catch {
        #expect(error.localizedDescription.contains("path"))
        #expect(error.localizedDescription.contains("http://localhost:5174"))
    }
}

@Test func sendsNormalizedIngressServiceToCloudflare() async throws {
    let transport = MutationTransport()
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    try await client.applyHostnameConfiguration(tunnelID: "created-id", hostname: "dev.example.com", service: "http://localhost:5174/")

    let requests = await transport.requests()
    let configBody = try #require(requests.last?.body)
    let configJSON = try #require(try JSONSerialization.jsonObject(with: configBody) as? [String: Any])
    let config = try #require(configJSON["config"] as? [String: Any])
    let ingress = try #require(config["ingress"] as? [[String: Any]])
    #expect(ingress[0]["service"] as? String == "http://localhost:5174")
}

@Test func readsEmptyTunnelConfigurationWithoutFailing() async throws {
    let transport = MutationTransport()
    await transport.setConfigurationJSON("{}")
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    let configuration = try await client.tunnelConfiguration(id: "created-id")
    #expect(configuration.ingress.isEmpty)
}

@Test func createsDNSRecordWhenNoneExists() async throws {
    let transport = MutationTransport()
    await transport.setDNSRecordsJSON("[]")
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    try await client.ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: "created-id")

    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET", "POST"])
}

@Test func keepsDNSRecordThatAlreadyPointsAtTheTunnel() async throws {
    let transport = MutationTransport()
    await transport.setDNSRecordsJSON(#"[{"id":"dns-id","name":"dev.example.com","type":"CNAME","content":"CREATED-ID.cfargotunnel.com","proxied":true}]"#)
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    try await client.ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: "created-id")

    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET"])
}

@Test func refusesDNSRecordThatPointsElsewhere() async throws {
    let transport = MutationTransport()
    await transport.setDNSRecordsJSON(#"[{"id":"dns-id","name":"dev.example.com","type":"A","content":"203.0.113.10"}]"#)
    let client = CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )

    do {
        try await client.ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: "created-id")
        Issue.record("Expected a conflict error")
    } catch {
        #expect(error.localizedDescription.contains("already exists"))
        #expect(error.localizedDescription.contains("203.0.113.10"))
    }
    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET"])
}

private func dnsClient(_ transport: MutationTransport) -> CloudflareClient {
    CloudflareClient(
        accountID: "account-id",
        token: "api-secret",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: transport
    )
}

@Test func pointsAnExistingCNAMEAtTheTunnelWhenAskedToReplace() async throws {
    let transport = MutationTransport()
    await transport.setDNSRecordsJSON(#"[{"id":"old-id","name":"dev.example.com","type":"CNAME","content":"removed-id.cfargotunnel.com","proxied":true}]"#)

    try await dnsClient(transport).ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: "created-id", replacing: true)

    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET", "PATCH"])
    #expect(requests.last?.path.hasSuffix("/dns_records/old-id") == true)
    let body = try #require(requests.last?.body.flatMap { String(data: $0, encoding: .utf8) })
    #expect(body.contains("created-id.cfargotunnel.com"))
}

@Test func swapsAddressRecordsForTheTunnelWhenAskedToReplace() async throws {
    let transport = MutationTransport()
    await transport.setDNSRecordsJSON(#"[{"id":"a-id","name":"dev.example.com","type":"A","content":"203.0.113.10"},{"id":"aaaa-id","name":"dev.example.com","type":"AAAA","content":"2001:db8::1"}]"#)

    try await dnsClient(transport).ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: "created-id", replacing: true)

    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET", "DELETE", "DELETE", "POST"])
    #expect(requests[1].path.hasSuffix("/dns_records/a-id"))
    #expect(requests[2].path.hasSuffix("/dns_records/aaaa-id"))
}

@Test func neverRemovesOtherRecordTypesWhenReplacing() async throws {
    let transport = MutationTransport()
    await transport.setDNSRecordsJSON(#"[{"id":"a-id","name":"dev.example.com","type":"A","content":"203.0.113.10"},{"id":"txt-id","name":"dev.example.com","type":"TXT","content":"verification"}]"#)

    do {
        try await dnsClient(transport).ensureDNSRoute(zoneID: "zone-id", hostname: "dev.example.com", tunnelID: "created-id", replacing: true)
        Issue.record("Expected the TXT record to block the replacement")
    } catch {
        #expect(error.localizedDescription.contains("TXT"))
    }
    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET"])
}

@Test func surfacesUnexpectedResponseInsteadOfBlankAPIError() async {
    let client = CloudflareClient(
        accountID: "account",
        token: "do-not-leak",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: FixedTransport(status: 200, body: #"{"success":true,"errors":[],"result":{"id":"not-a-tunnel-list"}}"#)
    )
    do {
        _ = try await client.listTunnels()
        Issue.record("Expected decode error")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("unexpected response"))
        #expect(message.contains("HTTP 200"))
        #expect(!message.hasSuffix("Cloudflare API: "))
        #expect(!message.contains("do-not-leak"))
    }
}

@Test func surfacesMessagesWhenErrorListIsEmpty() async {
    let client = CloudflareClient(
        accountID: "account",
        token: "do-not-leak",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: FixedTransport(status: 403, body: #"{"success":false,"errors":[],"messages":[{"code":1,"message":"Plan upgrade required"}],"result":null}"#)
    )
    do {
        _ = try await client.listTunnels()
        Issue.record("Expected API error")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("Plan upgrade required"))
        #expect(message.contains("403"))
    }
}

@Test func surfacesEmptyResponseBodyWithStatusCode() async {
    let client = CloudflareClient(
        accountID: "account",
        token: "do-not-leak",
        baseURL: URL(string: "https://example.test/client/v4")!,
        transport: FixedTransport(status: 502, body: "")
    )
    do {
        _ = try await client.listTunnels()
        Issue.record("Expected API error")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("502"))
        #expect(message.contains("response body was empty"))
    }
}

@Test func matchesOnlySavedHostnameWhenSyncingRemoteIngressMetadata() {
    let configuration = CloudflareTunnelConfiguration(ingress: [
        CloudflareIngress(hostname: "other.example.com", service: "http://localhost:9999"),
        CloudflareIngress(hostname: "APP.EXAMPLE.COM.", service: "http://127.0.0.1:8130"),
        CloudflareIngress(service: "http_status:404"),
    ])
    let match = RemoteIngressMetadataResolver.matching(hostname: "app.example.com", in: configuration)
    #expect(match?.hostname == "APP.EXAMPLE.COM.")
    #expect(match?.service == "http://127.0.0.1:8130")
    #expect(RemoteIngressMetadataResolver.matching(hostname: "missing.example.com", in: configuration) == nil)
    #expect(RemoteIngressMetadataResolver.matching(hostname: nil, in: configuration) == nil)
}

@Test func rewritingOneHostnameKeepsEveryOtherSettingVerbatim() async throws {
    let transport = MutationTransport()
    await transport.setConfigurationJSON(#"""
    {"warp-routing":{"enabled":true},"originRequest":{"connectTimeout":30},
     "ingress":[
      {"hostname":"other.example.com","service":"https://localhost:9443","originRequest":{"noTLSVerify":true,"httpHostHeader":"internal.test"}},
      {"hostname":"dev.example.com","path":"^/api","service":"http://localhost:8000"},
      {"hostname":"dev.example.com","service":"http://localhost:1111","originRequest":{"connectTimeout":5}},
      {"service":"http_status:404"}]}
    """#)
    let client = CloudflareClient(accountID: "account-id", token: "api-secret", baseURL: URL(string: "https://example.test/client/v4")!, transport: transport)

    try await client.applyHostnameConfiguration(tunnelID: "created-id", hostname: "dev.example.com", service: "http://localhost:3000", hostHeader: .set("localhost:3000"))

    let body = try #require(await transport.requests().last?.body)
    let config = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["config"] as? [String: Any])
    #expect((config["warp-routing"] as? [String: Any])?["enabled"] as? Bool == true)
    #expect((config["originRequest"] as? [String: Any])?["connectTimeout"] as? Int == 30)
    let ingress = try #require(config["ingress"] as? [[String: Any]])
    #expect(ingress.count == 4)
    let other = (ingress[0]["originRequest"] as? [String: Any])
    #expect(other?["noTLSVerify"] as? Bool == true)
    #expect(other?["httpHostHeader"] as? String == "internal.test")
    #expect(ingress[1]["path"] as? String == "^/api")
    #expect(ingress[1]["service"] as? String == "http://localhost:8000")
    #expect(ingress[2]["service"] as? String == "http://localhost:3000")
    let ours = ingress[2]["originRequest"] as? [String: Any]
    #expect(ours?["connectTimeout"] as? Int == 5)
    #expect(ours?["httpHostHeader"] as? String == "localhost:3000")
    #expect(ingress[3]["service"] as? String == "http_status:404")
}

@Test func removingHostHeaderLeavesOtherOriginSettings() async throws {
    let transport = MutationTransport()
    await transport.setConfigurationJSON(#"{"ingress":[{"hostname":"dev.example.com","service":"http://localhost:1111","originRequest":{"httpHostHeader":"x","connectTimeout":5}},{"service":"http_status:404"}]}"#)
    let client = CloudflareClient(accountID: "account-id", token: "api-secret", baseURL: URL(string: "https://example.test/client/v4")!, transport: transport)
    try await client.applyHostnameConfiguration(tunnelID: "created-id", hostname: "dev.example.com", service: "http://localhost:3000", hostHeader: .remove)
    let body = try #require(await transport.requests().last?.body)
    let config = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["config"] as? [String: Any])
    let rule = try #require((config["ingress"] as? [[String: Any]])?.first)
    #expect((rule["originRequest"] as? [String: Any])?["httpHostHeader"] == nil)
    #expect((rule["originRequest"] as? [String: Any])?["connectTimeout"] as? Int == 5)
}

@Test func wildcardAndCatchAllRulesCoverHostnamesWithoutTheirOwnRule() {
    let wildcard = CloudflareTunnelConfiguration(ingress: [
        CloudflareIngress(hostname: "api.example.com", service: "http://localhost:9000"),
        CloudflareIngress(hostname: "*.example.com", service: "http://localhost:5174"),
        CloudflareIngress(service: "http_status:404"),
    ])
    #expect(RemoteIngressMetadataResolver.matching(hostname: "landing.example.com", in: wildcard)?.service == "http://localhost:5174")
    #expect(RemoteIngressMetadataResolver.matching(hostname: "api.example.com", in: wildcard)?.service == "http://localhost:9000")
    #expect(RemoteIngressMetadataResolver.matching(hostname: "landing.other.dev", in: wildcard) == nil)

    let catchAll = CloudflareTunnelConfiguration(ingress: [
        CloudflareIngress(hostname: "*", service: "http://localhost:3000"),
    ])
    let match = RemoteIngressMetadataResolver.matching(hostname: "landing.example.com", in: catchAll)
    #expect(match?.service == "http://localhost:3000")
    #expect(match.map { RemoteIngressMetadataResolver.namesHostname($0, "landing.example.com") } == false)

    let unnamedCatchAll = CloudflareTunnelConfiguration(ingress: [CloudflareIngress(service: "http://localhost:3000")])
    #expect(RemoteIngressMetadataResolver.matching(hostname: "landing.example.com", in: unnamedCatchAll)?.service == "http://localhost:3000")
}

import Foundation
import Testing
@testable import OpenTrafficCore

@Test func protectionRoundTripsAndDefaultsToNone() throws {
    let old = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Old","kind":"ngrok","localURL":"http://localhost:5173"}"#
    #expect(try JSONDecoder().decode(TunnelDefinition.self, from: Data(old.utf8)).protection == .none)
    for protection: ShareProtection in [.password(username: "guest"), .login(.google, allowedEmails: ["a@b.co"]), .login(.cloudflareEmail, allowedEmails: ["x@y.dev"])] {
        let definition = TunnelDefinition(name: "x", kind: .ngrok, localURL: "http://localhost:1", protection: protection, accessApplicationID: "app")
        let decoded = try JSONDecoder().decode(TunnelDefinition.self, from: JSONEncoder().encode(definition))
        #expect(decoded.protection == protection)
        #expect(decoded.accessApplicationID == "app")
    }
}

@Test func protectionOptionsFollowProvider() {
    // OpenTraffic's proxy checks the password for shares that can't be configured.
    #expect(TunnelKind.quick.protectionOptions == [.none, .password])
    #expect(TunnelKind.opentunnel.protectionOptions == [.none, .password])
    #expect(TunnelKind.quick.passwordInProxy && TunnelKind.opentunnel.passwordInProxy && !TunnelKind.ngrok.passwordInProxy)
    #expect(TunnelKind.tailscale.protectionOptions.isEmpty)
    #expect(TunnelKind.ngrok.protectionOptions == [.none, .password, .google, .github])
    #expect(TunnelKind.remote.protectionOptions == [.none, .cloudflareEmail])
}

@Test func emailListsAreStrict() {
    #expect(EmailList.parse("Alice@Example.com, bob@example.co.uk\nalice@example.com") == ["alice@example.com", "bob@example.co.uk"])
    #expect(EmailList.parse("") == [])
    #expect(EmailList.parse("not-an-email") == nil)
    #expect(EmailList.parse("x@y.com', 'evil") == nil)
    #expect(EmailList.parse("a@b.com']) || true || (['x@y.com") == nil)
}

@Test func generatedPasswordsAreLongAndUnambiguous() {
    let password = SharePassword.generate()
    #expect(password.count == 20)
    #expect(password.allSatisfy { $0.isLetter || $0.isNumber })
    #expect(!password.contains("0") && !password.contains("O") && !password.contains("l") && !password.contains("1"))
    #expect(SharePassword.generate() != password)
    #expect(SharePassword.generate(length: 3).count == 8)
}

@Test func ngrokPolicyForSignInWithAllowList() throws {
    let yaml = try #require(NgrokTrafficPolicy.yaml(hostHeader: nil, oauth: (.google, ["alice@example.com", "bob@example.com"])))
    #expect(yaml == """
    on_http_request:
      - actions:
          - type: oauth
            config:
              provider: google
      - expressions:
          - "!(actions.ngrok.oauth.identity.email.lowerAscii() in ['alice@example.com', 'bob@example.com'])"
        actions:
          - type: deny
            config:
              status_code: 403

    """)
    let open = try #require(NgrokTrafficPolicy.yaml(hostHeader: nil, oauth: (.github, [])))
    #expect(open.contains("provider: github") && !open.contains("deny"))
    #expect(NgrokTrafficPolicy.yaml(hostHeader: nil, oauth: (.cloudflareEmail, ["a@b.co"])) == nil)
    let password = try #require(NgrokTrafficPolicy.yaml(hostHeader: "localhost:3000", basicAuthCredentials: ["guest:abcdefgh12"]))
    #expect(password.contains("type: basic-auth") && password.contains("type: add-headers"))
}

private actor AccessTransport: HTTPTransport {
    var captured: [(method: String, path: String, body: Data?)] = []
    let status: Int
    init(status: Int = 200) { self.status = status }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append((request.httpMethod ?? "GET", request.url!.path, request.httpBody))
        let body = status == 200
            ? (request.httpMethod == "GET" ? #"{"success":true,"errors":[],"result":[]}"# : #"{"success":true,"errors":[],"result":{"id":"app-123"}}"#)
            : #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func requests() -> [(method: String, path: String, body: Data?)] { captured }
}

@Test func createsAccessApplicationWithEmailAllowPolicy() async throws {
    let transport = AccessTransport()
    let client = CloudflareClient(accountID: "acct", token: "t", baseURL: URL(string: "https://example.test/client/v4")!, transport: transport)
    let id = try await client.createAccessApplication(name: "Docs", hostname: "docs.example.dev", allowedEmails: ["a@x.com", "b@y.com"])
    #expect(id == "app-123")
    let request = try #require(await transport.requests().first)
    #expect(request.method == "POST")
    #expect(request.path == "/client/v4/accounts/acct/access/apps")
    let body = try #require(request.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["type"] as? String == "self_hosted")
    #expect(json["domain"] as? String == "docs.example.dev")
    #expect(json["session_duration"] as? String == "24h")
    let policy = try #require((json["policies"] as? [[String: Any]])?.first)
    #expect(policy["decision"] as? String == "allow")
    let include = try #require(policy["include"] as? [[String: Any]])
    #expect(include.compactMap { ($0["email"] as? [String: String])?["email"] } == ["a@x.com", "b@y.com"])

    try await client.deleteAccessApplication(id: "app-123")
    #expect(await transport.requests().last?.method == "DELETE")
    #expect(await transport.requests().last?.path == "/client/v4/accounts/acct/access/apps/app-123")
}

@Test func detectsMissingAccessPermission() async {
    let denied = CloudflareClient(accountID: "acct", token: "t", baseURL: URL(string: "https://example.test/client/v4")!, transport: AccessTransport(status: 403))
    #expect(await denied.canManageAccessApplications() == false)
    let allowed = CloudflareClient(accountID: "acct", token: "t", baseURL: URL(string: "https://example.test/client/v4")!, transport: AccessTransport())
    #expect(await allowed.canManageAccessApplications() == true)
}

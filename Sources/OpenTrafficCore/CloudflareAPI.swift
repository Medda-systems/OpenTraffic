import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenTrafficError.api("Cloudflare returned an invalid response.")
        }
        return (data, http)
    }
}

public struct CloudflareClient: Sendable {
    public let accountID: String
    private let token: String
    private let baseURL: URL
    private let transport: any HTTPTransport

    public init(
        accountID: String,
        token: String,
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.accountID = accountID
        self.token = token
        self.baseURL = baseURL
        self.transport = transport
    }

    public func listTunnels() async throws -> [CloudflareTunnel] {
        var page = 1
        var all: [CloudflareTunnel] = []
        while true {
            let response: APIEnvelope<[CloudflareTunnel]> = try await send(
                path: "/accounts/\(accountID)/cfd_tunnel",
                query: [
                    URLQueryItem(name: "is_deleted", value: "false"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "1000"),
                ]
            )
            all.append(contentsOf: response.result)
            guard shouldLoadNextPage(info: response.resultInfo, returned: response.result.count, page: page, defaultPageSize: 1000) else { break }
            page += 1
        }
        return all
    }

    public func tunnelConfiguration(id: String) async throws -> CloudflareTunnelConfiguration {
        let response: APIEnvelope<ConfigurationResult> = try await send(
            path: "/accounts/\(accountID)/cfd_tunnel/\(id)/configurations"
        )
        return response.result.config
    }

    public func connectorToken(id: String) async throws -> String {
        let response: APIEnvelope<String> = try await send(
            path: "/accounts/\(accountID)/cfd_tunnel/\(id)/token"
        )
        return response.result
    }

    public func listZones() async throws -> [CloudflareZone] {
        var page = 1
        var all: [CloudflareZone] = []
        while true {
            let response: APIEnvelope<[CloudflareZone]> = try await send(
                path: "/zones",
                query: [
                    URLQueryItem(name: "account.id", value: accountID),
                    URLQueryItem(name: "status", value: "active"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "50"),
                ]
            )
            all.append(contentsOf: response.result)
            guard shouldLoadNextPage(info: response.resultInfo, returned: response.result.count, page: page, defaultPageSize: 50) else { break }
            page += 1
        }
        return all
    }

    public func createRemoteTunnel(name: String) async throws -> CloudflareTunnel {
        try await send(
            path: "/accounts/\(accountID)/cfd_tunnel",
            method: "POST",
            body: ["name": name, "config_src": "cloudflare"]
        ).result
    }

    /// Tunnel names are unique per account, and removing a share leaves its tunnel in place, so a name can
    /// already be taken (often by an earlier share of the same name): numbers it, as Finder does.
    public func createRemoteTunnel(uniquelyNamed name: String) async throws -> CloudflareTunnel {
        for attempt in 1...20 {
            do {
                return try await createRemoteTunnel(name: attempt == 1 ? name : "\(name) \(attempt)")
            } catch where attempt < 20 && error.localizedDescription.localizedCaseInsensitiveContains("already have a tunnel with this name") {
                continue
            }
        }
        throw OpenTrafficError.api("Couldn't find a free tunnel name for “\(name)” in your Cloudflare account.")
    }

    /// How to treat the rule's `originRequest.httpHostHeader` when (re)writing it.
    public enum HostHeaderChange: Sendable, Equatable {
        case keep
        case set(String)
        case remove
    }

    /// Points `hostname` at `service`, keeping every other rule, the matched rule's own extra settings,
    /// path-specific rules for the same hostname, and config-level settings exactly as they were.
    public func applyHostnameConfiguration(
        tunnelID: String,
        hostname: String,
        service: String,
        hostHeader: HostHeaderChange = .keep
    ) async throws {
        let ingressService = try Self.ingressService(from: service)
        let current = try await tunnelConfiguration(id: tunnelID)
        let previous = current.ingress.first { rule in
            rule.path == nil && rule.hostname.map { Self.hostnamesMatch($0, hostname) } == true
        }
        var additional = previous?.additional ?? [:]
        var originRequest = additional["originRequest"]?.objectValue ?? [:]
        switch hostHeader {
        case .keep: break
        case .set(let value): originRequest["httpHostHeader"] = .string(value)
        case .remove: originRequest["httpHostHeader"] = nil
        }
        additional["originRequest"] = originRequest.isEmpty ? nil : .object(originRequest)
        let rule = CloudflareIngress(hostname: hostname, service: ingressService, additional: additional)

        var ingress: [CloudflareIngress] = []
        var inserted = false
        for existing in current.ingress {
            if let existingHostname = existing.hostname {
                if Self.hostnamesMatch(existingHostname, hostname), existing.path == nil {
                    if !inserted {
                        ingress.append(rule)
                        inserted = true
                    }
                } else {
                    ingress.append(existing)
                }
            } else {
                if !inserted {
                    ingress.append(rule)
                    inserted = true
                }
                ingress.append(existing)
            }
        }
        if !inserted {
            ingress.append(rule)
        }
        if !ingress.contains(where: { $0.hostname == nil }) {
            ingress.append(CloudflareIngress(service: "http_status:404"))
        }
        let body = ConfigurationRequest(config: CloudflareTunnelConfiguration(ingress: ingress, additional: current.additional))
        let _: APIEnvelope<ConfigurationResult> = try await send(
            path: "/accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations",
            method: "PUT",
            body: body
        )
    }

    /// Creates a self-hosted Access application for `hostname` that lets only `allowedEmails` in,
    /// signing in with an emailed one-time code. Returns the application ID.
    public func createAccessApplication(name: String, hostname: String, allowedEmails: [String]) async throws -> String {
        let response: APIEnvelope<AccessApplicationResult> = try await send(
            path: "/accounts/\(accountID)/access/apps",
            method: "POST",
            body: Self.accessApplicationBody(name: name, hostname: hostname, allowedEmails: allowedEmails)
        )
        return response.result.id
    }

    /// Replaces an existing application's settings and policy in place, so the site is never left
    /// without a policy while emails change.
    public func updateAccessApplication(id: String, name: String, hostname: String, allowedEmails: [String]) async throws {
        let _: APIEnvelope<AccessApplicationResult> = try await send(
            path: "/accounts/\(accountID)/access/apps/\(id)",
            method: "PUT",
            body: Self.accessApplicationBody(name: name, hostname: hostname, allowedEmails: allowedEmails)
        )
    }

    private static func accessApplicationBody(name: String, hostname: String, allowedEmails: [String]) -> AccessApplicationRequest {
        AccessApplicationRequest(
            type: "self_hosted",
            name: name,
            domain: hostname,
            sessionDuration: "24h",
            policies: [.init(
                name: "OpenTraffic allowed emails",
                decision: "allow",
                include: allowedEmails.map { .init(email: .init(email: $0)) },
                precedence: 1
            )]
        )
    }

    public func deleteAccessApplication(id: String) async throws {
        let _: APIEnvelope<AccessApplicationResult?> = try await send(
            path: "/accounts/\(accountID)/access/apps/\(id)",
            method: "DELETE"
        )
    }

    /// Read-only probe: whether this token can at least read Access applications (nil when it can't be
    /// determined). Creating them additionally needs Edit permission, which can't be probed without writing.
    public func canManageAccessApplications() async -> Bool? {
        do {
            let _: APIEnvelope<[AccessApplicationResult]> = try await send(path: "/accounts/\(accountID)/access/apps")
            return true
        } catch let error as OpenTrafficError {
            if case .api(let message) = error, message.contains("403") || message.localizedCaseInsensitiveContains("auth") {
                return false
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Points `hostname` at the tunnel with a proxied CNAME. A record that already points elsewhere is an
    /// error, unless `replacing` is set: then an existing CNAME is pointed at the tunnel, and A and AAAA
    /// records are swapped for the CNAME. Other records at the name (TXT, MX, …) are never removed.
    public func ensureDNSRoute(zoneID: String, hostname: String, tunnelID: String, replacing: Bool = false) async throws {
        let target = "\(tunnelID).cfargotunnel.com"
        let existing = try await dnsRecords(zoneID: zoneID, name: hostname)
        if existing.contains(where: { ($0.content ?? "").caseInsensitiveCompare(target) == .orderedSame }) {
            return
        }
        let body = DNSRecordRequest(type: "CNAME", name: hostname, content: target, proxied: true, comment: "Managed by OpenTraffic")
        if let record = existing.first {
            guard replacing else {
                throw OpenTrafficError.api("A DNS record for \(hostname) already exists and points to \(record.content?.nilIfBlank ?? "another target").")
            }
            let addresses = existing.filter { Self.replaceableTypes.contains(($0.type ?? "").uppercased()) }
            let others = Set(existing.map { ($0.type ?? "?").uppercased() }).subtracting(Self.replaceableTypes)
            guard others.isEmpty else {
                throw OpenTrafficError.api("\(hostname) also has \(others.sorted().joined(separator: ", ")) records, which OpenTraffic won't remove. Remove them in Cloudflare, or choose another hostname.")
            }
            if let cname = addresses.first(where: { $0.type?.uppercased() == "CNAME" }), let id = cname.id {
                let _: APIEnvelope<CloudflareDNSRecord> = try await send(path: "/zones/\(zoneID)/dns_records/\(id)", method: "PATCH", body: body)
                return
            }
            for record in addresses {
                guard let id = record.id else { continue }
                let _: APIEnvelope<CloudflareDNSRecord?> = try await send(path: "/zones/\(zoneID)/dns_records/\(id)", method: "DELETE")
            }
        }
        let _: APIEnvelope<CloudflareDNSRecord> = try await send(
            path: "/zones/\(zoneID)/dns_records",
            method: "POST",
            body: body
        )
    }

    /// The records a tunnel's CNAME can stand in for.
    private static let replaceableTypes: Set<String> = ["A", "AAAA", "CNAME"]

    public func dnsRecord(zoneID: String, hostname: String) async throws -> CloudflareDNSRecord? {
        try await dnsRecords(zoneID: zoneID, name: hostname).first
    }

    private func dnsRecords(zoneID: String, name: String) async throws -> [CloudflareDNSRecord] {        var page = 1
        var all: [CloudflareDNSRecord] = []
        while true {
            let response: APIEnvelope<[CloudflareDNSRecord]> = try await send(
                path: "/zones/\(zoneID)/dns_records",
                query: [
                    URLQueryItem(name: "name", value: name),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "100"),
                ]
            )
            all.append(contentsOf: response.result)
            guard shouldLoadNextPage(info: response.resultInfo, returned: response.result.count, page: page, defaultPageSize: 100) else { break }
            page += 1
        }
        return all.filter { $0.name == nil || Self.hostnamesMatch($0.name ?? "", name) }
    }

    static func hostnamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeHostname(lhs) == normalizeHostname(rhs)
    }

    public static func ingressService(from localURL: String) throws -> String {
        let trimmed = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            throw OpenTrafficError.invalidLocalURL
        }
        guard ["http", "https"].contains(scheme) else { return trimmed }
        guard components.path.isEmpty || components.path == "/" else {
            let port = components.port.map { ":\($0)" } ?? ""
            throw OpenTrafficError.api("Cloudflare ingress rules cannot proxy to a path on the origin service. Use \(scheme)://\(components.host ?? "localhost")\(port) without a path.")
        }
        var normalized = components
        normalized.path = ""
        return normalized.url?.absoluteString ?? trimmed
    }

    private static func normalizeHostname(_ hostname: String) -> String {
        hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func send<Result: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET"
    ) async throws -> APIEnvelope<Result> {
        try await send(path: path, query: query, method: method, bodyData: nil)
    }

    private func shouldLoadNextPage(info: ResultInfo?, returned: Int, page: Int, defaultPageSize: Int) -> Bool {
        if let totalPages = info?.totalPages { return page < totalPages }
        if let totalCount = info?.totalCount {
            let perPage = max(1, info?.perPage ?? defaultPageSize)
            return page * perPage < totalCount
        }
        let perPage = info?.perPage ?? defaultPageSize
        return returned >= perPage
    }

    private func send<Result: Decodable, Body: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        body: Body
    ) async throws -> APIEnvelope<Result> {
        let data = try JSONEncoder().encode(body)
        return try await send(path: path, query: query, method: method, bodyData: data)
    }

    private func send<Result: Decodable>(
        path: String,
        query: [URLQueryItem],
        method: String,
        bodyData: Data?
    ) async throws -> APIEnvelope<Result> {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw OpenTrafficError.api("Could not create the Cloudflare API URL.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw OpenTrafficError.api("Could not create the Cloudflare API URL.") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transport.data(for: request)
        let decoder = JSONDecoder()
        if (200..<300).contains(response.statusCode),
           let envelope = try? decoder.decode(APIEnvelope<Result>.self, from: data),
           envelope.success {
            return envelope
        }

        if let errorEnvelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
            let details = ((errorEnvelope.errors ?? []) + (errorEnvelope.messages ?? []))
                .compactMap(\.message)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !details.isEmpty {
                throw OpenTrafficError.api("Cloudflare API (HTTP \(response.statusCode)): \(details)")
            }
        }
        if (200..<300).contains(response.statusCode) {
            throw OpenTrafficError.api("Cloudflare returned an unexpected response (HTTP \(response.statusCode)): \(Self.bodyExcerpt(data))")
        }
        throw OpenTrafficError.api("Cloudflare API (HTTP \(response.statusCode)): \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)). \(Self.bodyExcerpt(data))")
    }

    private static func bodyExcerpt(_ data: Data) -> String {
        guard !data.isEmpty else { return "The response body was empty." }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return text + (data.count > 300 ? " …" : "")
    }
}

public struct APIEnvelope<Result: Decodable>: Decodable {
    public let success: Bool
    public let result: Result
    public let resultInfo: ResultInfo?

    enum CodingKeys: String, CodingKey {
        case success, result
        case resultInfo = "result_info"
    }
}

public struct ResultInfo: Decodable {
    public let page: Int?
    public let perPage: Int?
    public let totalCount: Int?
    public let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case totalCount = "total_count"
        case totalPages = "total_pages"
    }
}

private struct APIErrorEnvelope: Decodable {
    let errors: [APIError]?
    let messages: [APIError]?
}

private struct APIError: Decodable {
    let message: String?
}

private struct ConfigurationResult: Codable {
    let config: CloudflareTunnelConfiguration

    enum CodingKeys: String, CodingKey {
        case config
    }

    init(config: CloudflareTunnelConfiguration) {
        self.config = config
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        config = try container.decodeIfPresent(CloudflareTunnelConfiguration.self, forKey: .config)
            ?? CloudflareTunnelConfiguration(ingress: [])
    }
}

private struct ConfigurationRequest: Encodable {
    let config: CloudflareTunnelConfiguration
}

private struct DNSRecordRequest: Encodable {
    let type: String
    let name: String
    let content: String
    let proxied: Bool
    let comment: String
}

public struct CloudflareDNSRecord: Decodable, Hashable, Sendable {
    public let id: String?
    public let type: String?
    public let name: String?
    public let content: String?
    public let proxied: Bool?
}

private struct AccessApplicationRequest: Encodable {
    struct Policy: Encodable {
        struct Rule: Encodable {
            struct Email: Encodable { let email: String }
            let email: Email
        }
        let name: String
        let decision: String
        let include: [Rule]
        let precedence: Int
    }

    let type: String
    let name: String
    let domain: String
    let sessionDuration: String
    let policies: [Policy]

    enum CodingKeys: String, CodingKey {
        case type, name, domain, policies
        case sessionDuration = "session_duration"
    }
}

private struct AccessApplicationResult: Decodable {
    let id: String
}

import Foundation
import os

public enum HealthCheckKind: String, Sendable, Equatable {
    case localOrigin
    case connector
    /// The provider's network: Cloudflare's tunnel status, ngrok's edge, or the tailnet.
    case edge
    case dns
    case publicSite

    public var title: String {
        title(for: .cloudflare)
    }

    public func title(for provider: TunnelProvider) -> String {
        switch self {
        case .localOrigin: "Local service"
        case .connector: provider == .tailscale ? "Tailscale share" : "Connector"
        case .edge: provider.edgeTitle
        case .dns: "DNS"
        case .publicSite: "Public site"
        }
    }
}

public enum HealthCheckState: Sendable, Equatable {
    case ok
    case working
    case failed
    case skipped
}

/// A specific, fixable cause behind a failed check.
public enum HealthRemedy: Sendable, Equatable {
    /// The local dev server rejected the public hostname.
    case hostBlocked(BlockingFramework)
}

public enum BlockingFramework: String, Sendable, Equatable, CaseIterable {
    case vite, nextjs, django, rails, unknown

    public var title: String {
        switch self {
        case .vite: "Vite"
        case .nextjs: "Next.js"
        case .django: "Django"
        case .rails: "Rails"
        case .unknown: "Your dev server"
        }
    }

    /// The configuration that allows `hostname`, for when a Host rewrite isn't possible or wanted.
    public func snippet(hostname: String) -> String {
        switch self {
        case .vite:
            "// vite.config.js\nexport default defineConfig({\n  server: {\n    allowedHosts: ['\(hostname)'],\n  },\n})"
        case .nextjs:
            "// next.config.js\nmodule.exports = {\n  allowedDevOrigins: ['\(hostname)'],\n}"
        case .django:
            "# settings.py\nALLOWED_HOSTS = ['localhost', '127.0.0.1', '\(hostname)']"
        case .rails:
            "# config/environments/development.rb\nconfig.hosts << \"\(hostname)\""
        case .unknown:
            "Allow the host \"\(hostname)\" in your dev server's allowed-hosts setting."
        }
    }
}

public struct TunnelHealthCheck: Sendable, Equatable, Identifiable {
    public let kind: HealthCheckKind
    public let state: HealthCheckState
    public let detail: String?
    public let remedy: HealthRemedy?

    public init(kind: HealthCheckKind, state: HealthCheckState, detail: String? = nil, remedy: HealthRemedy? = nil) {
        self.kind = kind
        self.state = state
        self.detail = detail
        self.remedy = remedy
    }

    public var id: HealthCheckKind { kind }
}

public enum TunnelHealthState: Sendable, Equatable {
    case healthy
    case working
    case failed
    case stopped
    case unknown

    public var label: String {
        switch self {
        case .healthy: "Healthy"
        case .working: "Checking"
        case .failed: "Needs attention"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }
}

public struct TunnelHealth: Sendable, Equatable {
    public let checks: [TunnelHealthCheck]
    public let updatedAt: Date

    public init(checks: [TunnelHealthCheck], updatedAt: Date = Date()) {
        self.checks = checks
        self.updatedAt = updatedAt
    }
}

public enum TunnelHealthEvaluator {
    public static func overall(checks: [TunnelHealthCheck]) -> TunnelHealthState {
        if checks.isEmpty { return .unknown }
        if checks.contains(where: { $0.state == .failed }) { return .failed }
        if checks.first(where: { $0.kind == .connector })?.state == .skipped { return .stopped }
        if checks.contains(where: { $0.state == .working }) { return .working }
        return .healthy
    }
}

public struct PublicSiteProbe: Sendable, Equatable {
    public let statusCode: Int?
    public let bodyExcerpt: String?
    public let transportError: String?
    /// This Mac's resolver had no address for the hostname.
    public let hostNotFound: Bool

    public init(statusCode: Int? = nil, bodyExcerpt: String? = nil, transportError: String? = nil, hostNotFound: Bool = false) {
        self.statusCode = statusCode
        self.bodyExcerpt = bodyExcerpt
        self.transportError = transportError
        self.hostNotFound = hostNotFound
    }
}

public enum SiteHealthChecker {
    public static func probePublicSite(_ url: URL, timeout: TimeInterval = 8) async -> PublicSiteProbe {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let excerpt = String(decoding: data.prefix(48 * 1024), as: UTF8.self)
            return PublicSiteProbe(statusCode: (response as? HTTPURLResponse)?.statusCode, bodyExcerpt: excerpt)
        } catch {
            let notFound = (error as? URLError)?.code == .cannotFindHost || (error as? URLError)?.code == .dnsLookupFailed
            return PublicSiteProbe(transportError: error.localizedDescription, hostNotFound: notFound)
        }
    }

    public static func probeDNS(_ hostname: String, timeout: TimeInterval = 5) async -> Bool? {
        guard let status = await queryDoH(hostname, timeout: timeout)?.status else { return nil }
        if status == 0 { return true }
        if status == 3 { return false }
        return nil
    }

    /// The hostname's IPv4 addresses according to Cloudflare's DNS over HTTPS, which local DNS
    /// filters can't rewrite; nil when it couldn't be asked.
    public static func resolveDoH(_ hostname: String, timeout: TimeInterval = 5) async -> [String]? {
        guard let response = await queryDoH(hostname, timeout: timeout), response.status == 0 else { return nil }
        return (response.answer ?? []).filter { $0.type == 1 }.map(\.data)
    }

    private static func queryDoH(_ hostname: String, timeout: TimeInterval) async -> DoHResponse? {
        guard var components = URLComponents(string: "https://cloudflare-dns.com/dns-query") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "name", value: hostname),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(DoHResponse.self, from: data)
    }
}

struct DoHResponse: Decodable {
    struct Answer: Decodable {
        let type: Int
        let data: String
    }

    let status: Int?
    let answer: [Answer]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case answer = "Answer"
    }
}

/// What this Mac's own DNS resolver (the network's, a router's, or a filter's) answers for a hostname.
public enum SystemDNSAnswer: Sendable, Equatable {
    /// `canonicalName`: where a CNAME led, when the resolver says.
    case addresses([String], canonicalName: String?)
    case notFound
    /// No answer in time, or no network.
    case failed

    public static func lookup(_ hostname: String, timeout: TimeInterval = 4) async -> SystemDNSAnswer {
        await withCheckedContinuation { continuation in
            // getaddrinfo can't be cancelled; whichever finishes first answers, the other is ignored.
            let answered = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (SystemDNSAnswer) -> Void = { answer in
                guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: answer)
            }
            DispatchQueue.global().async { finish(resolve(hostname)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failed) }
        }
    }

    private static func resolve(_ hostname: String) -> SystemDNSAnswer {
        var hints = addrinfo()
        hints.ai_flags = AI_CANONNAME
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, "443", &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        guard status == 0 else { return status == EAI_NONAME ? .notFound : .failed }
        var addresses: [String] = []
        var canonicalName: String?
        var next = list
        while let info = next?.pointee {
            if canonicalName == nil, let name = info.ai_canonname { canonicalName = String(cString: name) }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = info.ai_addr,
               getnameinfo(address, info.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !addresses.contains(text) { addresses.append(text) }
            }
            next = info.ai_next
        }
        return .addresses(addresses, canonicalName: canonicalName)
    }
}

/// Whether this network lets cloudflared ask api.trycloudflare.com for a temporary address. Some
/// ISP and router DNS filters answer that name with their own block page instead.
public enum QuickTunnelNetwork: Sendable, Equatable {
    case ok
    /// The network's DNS sends api.trycloudflare.com elsewhere (`to`: where, when it says).
    case filtered(to: String?)
    /// Couldn't tell (no network, or nothing answered).
    case unknown

    public static let hostname = "api.trycloudflare.com"

    public var isFiltered: Bool {
        if case .filtered = self { true } else { false }
    }

    /// What to tell the user, when the network blocks temporary tunnels.
    public var warning: String? {
        guard case .filtered(let to) = self else { return nil }
        return "Your network blocks Cloudflare's temporary tunnels (its DNS filter redirects \(Self.hostname)\(to.map { " to \($0)" } ?? "")). Turn off the filter, use another DNS server such as 1.1.1.1, or share with another provider."
    }

    /// Asks this Mac's resolver and Cloudflare's DNS over HTTPS at the same time, and compares.
    public static func check(timeout: TimeInterval = 4) async -> QuickTunnelNetwork {
        async let system = SystemDNSAnswer.lookup(hostname, timeout: timeout)
        async let doh = SiteHealthChecker.resolveDoH(hostname, timeout: timeout)
        return await assess(system: system, doh: doh)
    }

    /// `doh`: the addresses DNS over HTTPS gave, or nil when it couldn't be asked.
    public static func assess(system: SystemDNSAnswer, doh: [String]?) -> QuickTunnelNetwork {
        switch system {
        case .addresses(let addresses, let canonicalName):
            if let doh, !Set(addresses).isDisjoint(with: doh) { return .ok }
            let name = canonicalName?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let name, !name.isEmpty, name != hostname, !CloudflareAddresses.isCloudflareName(name) {
                return .filtered(to: name)
            }
            if !addresses.isEmpty, !addresses.contains(where: CloudflareAddresses.contains) { return .filtered(to: nil) }
            return addresses.isEmpty ? .unknown : .ok
        case .notFound:
            // The name exists (DNS over HTTPS knows it), yet the network's DNS says it doesn't.
            return doh?.isEmpty == false ? .filtered(to: nil) : .unknown
        case .failed:
            return .unknown
        }
    }
}

/// Cloudflare's published address ranges (cloudflare.com/ips).
public enum CloudflareAddresses {
    static let ranges: [(prefix: [UInt8], bits: Int)] = [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
        "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
        "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
        "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
        "2a06:98c0::/29", "2c0f:f248::/32",
    ].compactMap { cidr in
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), let bytes = bytes(of: String(parts[0])) else { return nil }
        return (bytes, bits)
    }

    public static func contains(_ address: String) -> Bool {
        guard let bytes = bytes(of: address) else { return false }
        return ranges.contains { range in
            guard range.prefix.count == bytes.count else { return false }
            for bit in 0..<range.bits where (bytes[bit / 8] ^ range.prefix[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 {
                return false
            }
            return true
        }
    }

    public static func isCloudflareName(_ name: String) -> Bool {
        ["trycloudflare.com", "cloudflare.com", "cloudflare.net"].contains { name == $0 || name.hasSuffix(".\($0)") }
    }

    /// An IPv4 or IPv6 address as its 4 or 16 bytes.
    static func bytes(of address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}

/// How soon to look again while a share is starting: every second at first, then less often.
public enum HealthRecheck {
    public static func delay(sinceStart elapsed: TimeInterval?) -> TimeInterval {
        guard let elapsed else { return 8 }
        if elapsed < 20 { return 1 }
        if elapsed < 60 { return 3 }
        return 8
    }
}

public enum PublicSiteBlockDetector {
    /// The provider's own error page (no connector yet, tunnel offline), not the shared app's answer.
    public static func isProviderError(probe: PublicSiteProbe) -> Bool {
        let body = (probe.bodyExcerpt ?? "").lowercased()
        let markers = ["err_ngrok", "ngrok-error", "error code: 1033", "error 1033", "argo tunnel error",
                       "cloudflare tunnel error", "tunnel not found", "no tunnel", "opentunnel: no route",
                       "route not found", "bad gateway"]
        return markers.contains { body.contains($0) } || probe.statusCode == 502 || probe.statusCode == 530
    }

    /// Which dev server rejected the public hostname, when the response says so.
    public static func blockingFramework(probe: PublicSiteProbe) -> BlockingFramework? {
        guard let statusCode = probe.statusCode, !(200..<400).contains(statusCode) else { return nil }
        let body = (probe.bodyExcerpt ?? "").lowercased()
        if body.contains("is not allowed") && (body.contains("allowedhosts") || body.contains("vite")) { return .vite }
        if body.contains("invalid host header") { return .nextjs }
        if body.contains("disallowedhost") || body.contains("allowed_hosts") { return .django }
        if body.contains("blocked host") { return .rails }
        return nil
    }

    public static func hint(hostname: String, probe: PublicSiteProbe) -> String? {
        guard let statusCode = probe.statusCode else { return nil }
        if (200..<400).contains(statusCode) { return nil }
        let body = (probe.bodyExcerpt ?? "").lowercased()
        if body.contains("is not allowed") && (body.contains("allowedhosts") || body.contains("vite")) {
            return "Blocked by the Vite dev server. Add \"\(hostname)\" to server.allowedHosts in vite.config.js, then it restarts automatically."
        }
        if body.contains("invalid host header") {
            return "Blocked by the Next.js dev server (invalid host header). Allow \"\(hostname)\" in your Next.js configuration."
        }
        if body.contains("disallowedhost") || body.contains("allowed_hosts") {
            return "Blocked by Django (DisallowedHost). Add \"\(hostname)\" to ALLOWED_HOSTS."
        }
        if body.contains("blocked host") {
            return "Blocked by the origin framework (blocked host). Allow \"\(hostname)\" in its host authorization settings."
        }
        switch statusCode {
        case 403:
            return "The public site returned HTTP 403."
        case 404:
            return "The public site returned HTTP 404."
        case 429:
            return "The public site is rate limiting requests (HTTP 429)."
        case 500...599:
            return "The public site returned HTTP \(statusCode). The origin may be crashing, or the connector may not be serving this hostname yet."
        default:
            return "The public site returned HTTP \(statusCode)."
        }
    }
}

public enum TunnelHostname {
    public static func compose(subdomain: String, zoneName: String) -> String {
        let sub = subdomain.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let zone = zoneName.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if sub.isEmpty { return zone }
        return "\(sub).\(zone)"
    }

    public static func subdomain(of hostname: String, zoneName: String) -> String {
        let host = hostname.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let zone = zoneName.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host == zone { return "" }
        if host.hasSuffix(".\(zone)") { return String(host.dropLast(zone.count + 1)) }
        return host
    }

    public static func validateSubdomain(_ value: String) -> String? {
        let trimmed = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.isEmpty { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            if label.isEmpty || label.count > 63 { return "Use a valid subdomain, such as app or shop.eu." }
            if label.hasPrefix("-") || label.hasSuffix("-") { return "Use a valid subdomain, such as app or shop.eu." }
            if !label.unicodeScalars.allSatisfy(allowed.contains) {
                return "Use only letters, numbers, and hyphens in the subdomain."
            }
        }
        return nil
    }
}

public enum SetupProgressState: Sendable, Equatable {
    case pending
    case active
    case done
    case failed(message: String)
}

public struct SetupProgressStep: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public var state: SetupProgressState

    public init(id: String, title: String, state: SetupProgressState = .pending) {
        self.id = id
        self.title = title
        self.state = state
    }

    public static func tunnelSteps() -> [SetupProgressStep] {
        [
            SetupProgressStep(id: "create", title: "Create tunnel"),
            SetupProgressStep(id: "ingress", title: "Write ingress"),
            SetupProgressStep(id: "dns", title: "Create DNS"),
        ]
    }

    public static func applySteps() -> [SetupProgressStep] {
        [
            SetupProgressStep(id: "ingress", title: "Write ingress"),
            SetupProgressStep(id: "dns", title: "Create DNS"),
        ]
    }
}

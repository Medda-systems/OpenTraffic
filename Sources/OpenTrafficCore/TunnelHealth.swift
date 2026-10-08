import Foundation

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

    public init(statusCode: Int? = nil, bodyExcerpt: String? = nil, transportError: String? = nil) {
        self.statusCode = statusCode
        self.bodyExcerpt = bodyExcerpt
        self.transportError = transportError
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
            return PublicSiteProbe(transportError: error.localizedDescription)
        }
    }

    public static func probeDNS(_ hostname: String, timeout: TimeInterval = 5) async -> Bool? {
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
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(DoHResponse.self, from: data),
              let status = response.status else { return nil }
        if status == 0 { return true }
        if status == 3 { return false }
        return nil
    }
}

struct DoHResponse: Decodable {
    let status: Int?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
    }
}

public enum PublicSiteBlockDetector {
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

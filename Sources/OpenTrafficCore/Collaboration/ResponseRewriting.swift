import Foundation

/// Adjusts a page's Content-Security-Policy only as far as needed for OpenTraffic's own
/// `/__opentraffic/` scripts and connections to load (see specs/collab-plan.md, 3.2).
public enum ContentSecurityPolicyAdjuster {
    public struct Result: Equatable, Sendable {
        public let header: String
        /// Whether OpenTraffic's script tags must carry `nonce`.
        public let needsNonce: Bool
    }

    /// `origin` is the page's scheme and host as the browser sees it, e.g. `https://abc.trycloudflare.com`.
    public static func adjust(_ header: String, origin: String, nonce: String) -> Result {
        var directives = parse(header)
        var needsNonce = false
        let scriptName = ["script-src-elem", "script-src", "default-src"].first { directives[$0] != nil }
        if let scriptName, var sources = directives[scriptName], !allowsOwnScripts(sources) {
            if sources.contains("'strict-dynamic'") || sources.contains(where: isNonceOrHash) {
                sources.append("'nonce-\(nonce)'")
                needsNonce = true
            } else {
                sources += ["\(origin)/__opentraffic/bridge.js", "\(origin)/__opentraffic/electron/preload.js", "\(origin)/__opentraffic/collab.js"]
            }
            if scriptName == "default-src", directives["script-src"] == nil {
                directives["script-src"] = sources
                directives.order.append("script-src")
            } else {
                directives[scriptName] = sources
            }
        }
        let connectName = ["connect-src", "default-src"].first { directives[$0] != nil }
        if let connectName, var sources = directives[connectName], !sources.contains("'self'") {
            let socketOrigin = origin.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            sources += ["\(origin)/__opentraffic/", "\(socketOrigin)/__opentraffic/"]
            if connectName == "default-src", directives["connect-src"] == nil {
                directives["connect-src"] = sources
                directives.order.append("connect-src")
            } else {
                directives[connectName] = sources
            }
        }
        return Result(header: directives.serialized, needsNonce: needsNonce)
    }

    /// Loopback ports a policy lets the page connect to (`ws://localhost:7880` → 7880): candidates
    /// for the localhost bridge.
    public static func loopbackPorts(in header: String) -> Set<Int> {
        let directives = parse(header)
        let sources = directives["connect-src"] ?? directives["default-src"] ?? []
        return Set(sources.compactMap { source in
            guard let url = URL(string: source), let host = url.host?.lowercased(),
                  LoopbackURLRewriter.isLoopback(host), let port = url.port else { return nil }
            return port
        })
    }

    private static func allowsOwnScripts(_ sources: [String]) -> Bool {
        sources.contains("'self'") && !sources.contains("'strict-dynamic'")
    }

    private static func isNonceOrHash(_ source: String) -> Bool {
        let lowered = source.lowercased()
        return lowered.hasPrefix("'nonce-") || lowered.hasPrefix("'sha256-") || lowered.hasPrefix("'sha384-") || lowered.hasPrefix("'sha512-")
    }

    struct Directives {
        var order: [String] = []
        var values: [String: [String]] = [:]

        subscript(name: String) -> [String]? {
            get { values[name] }
            set { values[name] = newValue }
        }

        var serialized: String {
            order.compactMap { name in values[name].map { ([name] + $0).joined(separator: " ") } }.joined(separator: "; ")
        }
    }

    static func parse(_ header: String) -> Directives {
        var directives = Directives()
        for part in header.split(separator: ";") {
            let tokens = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = tokens.first?.lowercased(), directives[name] == nil else { continue }
            directives.order.append(name)
            directives[name] = Array(tokens.dropFirst())
        }
        return directives
    }
}

/// Points URLs at the page's own local services back through the tunnel (see specs, 3.1–3.2).
public struct LoopbackURLRewriter: Sendable {
    public let appPort: Int
    public let bridgedPorts: Set<Int>

    public init(appPort: Int, bridgedPorts: Set<Int>) {
        self.appPort = appPort
        self.bridgedPorts = bridgedPorts
    }

    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" || host.hasSuffix(".localhost")
    }

    /// A same-site replacement for a redirect target, or nil to leave it unchanged. `bridgedFrom` is the
    /// bridged port the response came from, so its relative redirects stay under that port's prefix.
    public func location(_ value: String, bridgedFrom: Int? = nil) -> String? {
        if value.hasPrefix("/"), !value.hasPrefix("//") {
            return bridgedFrom.map { "/__opentraffic/port/\($0)\(value)" }
        }
        guard let components = URLComponents(string: value), let host = components.host, Self.isLoopback(host) else { return nil }
        let scheme = components.scheme?.lowercased() ?? "http"
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        // `http://localhost:5173//evil.com/x` must not become the protocol-relative `//evil.com/x`.
        var rest = "/" + components.percentEncodedPath.drop { $0 == "/" }
        if let query = components.percentEncodedQuery { rest += "?\(query)" }
        if let fragment = components.percentEncodedFragment { rest += "#\(fragment)" }
        if port == appPort { return rest }
        if bridgedPorts.contains(port) { return "/__opentraffic/port/\(port)\(rest)" }
        return nil
    }

    /// `Set-Cookie` without a `Domain=localhost` / loopback attribute, so the cookie sticks to the tunnel host.
    public static func setCookie(_ value: String) -> String {
        let attributes = value.split(separator: ";", omittingEmptySubsequences: false)
        let kept = attributes.enumerated().filter { index, attribute in
            guard index > 0 else { return true }
            let parts = attribute.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "domain" else { return true }
            return !isLoopback(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        return kept.map { String($0.element) }.joined(separator: ";")
    }
}

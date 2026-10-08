import Foundation

/// How OpenTraffic launches and talks to an ngrok agent.
public enum NgrokAgent {
    /// ngrok's default configuration file on macOS, which holds the user's authtoken.
    public static var defaultConfigURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ngrok", isDirectory: true)
            .appendingPathComponent("ngrok.yml")
    }

    /// Whether a config file declares an authtoken. Only the key is checked; the value is never read into memory beyond this scan.
    public static func hasAuthtoken(configText: String) -> Bool {
        configText.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("authtoken:") && trimmed.dropFirst("authtoken:".count).trimmingCharacters(in: .whitespaces).count > 1
        }
    }

    /// An extra config layered after the user's, giving this agent its own inspection address so
    /// several agents (and ngrok started in Terminal) never compete for port 4040.
    public static func overlayConfig(apiPort: UInt16) -> String {
        "version: \"3\"\nagent:\n  web_addr: 127.0.0.1:\(apiPort)\n"
    }

    public static func arguments(localURL: String, domain: String?, configPaths: [String]) -> [String] {
        var arguments = ["http", localURL, "--log", "stdout", "--log-format", "json", "--config", configPaths.joined(separator: ",")]
        if let domain = domain?.nilIfBlank {
            arguments += ["--url", domain.contains("://") ? domain : "https://\(domain)"]
        }
        return arguments
    }

    /// The public URL from the agent's "started tunnel" log line.
    public static func publicURL(fromLogMessage message: String, rawLine: String?) -> String? {
        guard message == "started tunnel",
              let rawLine,
              let object = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
              let url = object["url"] as? String,
              url.lowercased().hasPrefix("https://") else { return nil }
        return url
    }

    /// Whether restarting could help. Account, plan, and configuration errors won't fix themselves.
    public static func isRetryable(_ text: String) -> Bool {
        !["ERR_NGROK_334", "ERR_NGROK_4018", "ERR_NGROK_108", "ERR_NGROK_320", "ERR_NGROK_319"].contains { text.contains($0) }
    }

    /// Turns ngrok's error codes into something actionable.
    public static func explain(_ text: String) -> String {
        if text.contains("ERR_NGROK_334") {
            return "Your ngrok domain is already online in another ngrok session. The free plan serves one ngrok share at a time — stop the other one (in OpenTraffic or Terminal) first."
        }
        if text.contains("ERR_NGROK_4018") {
            return "ngrok needs your authtoken. Copy it from dashboard.ngrok.com and run `ngrok config add-authtoken <token>` in Terminal."
        }
        if text.contains("ERR_NGROK_108") {
            return "Your ngrok plan allows only one agent session at a time. Stop ngrok running elsewhere, then start again."
        }
        if text.contains("ERR_NGROK_8012") {
            return "ngrok reached the tunnel but your local service didn't answer."
        }
        if text.contains("ERR_NGROK_320") || text.contains("ERR_NGROK_319") {
            return "That domain isn't reserved on your ngrok account. Leave the domain empty to use your free domain, or reserve it at dashboard.ngrok.com."
        }
        let firstLine = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return firstLine ?? "ngrok stopped unexpectedly."
    }
}

/// A tunnel from the agent's `/api/tunnels`.
public struct NgrokTunnelInfo: Equatable, Sendable {
    public let publicURL: String
    public let address: String?
    public let totalConnections: Int64?
    public let totalRequests: Int64?
    public let requestsPerMinute: Double?

    public static func parse(_ data: Data) -> [NgrokTunnelInfo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tunnels = object["tunnels"] as? [[String: Any]] else { return [] }
        return tunnels.compactMap { tunnel in
            guard let url = tunnel["public_url"] as? String else { return nil }
            let metrics = tunnel["metrics"] as? [String: Any] ?? [:]
            let conns = metrics["conns"] as? [String: Any] ?? [:]
            let http = metrics["http"] as? [String: Any] ?? [:]
            return NgrokTunnelInfo(
                publicURL: url,
                address: (tunnel["config"] as? [String: Any])?["addr"] as? String,
                totalConnections: (conns["count"] as? NSNumber)?.int64Value,
                totalRequests: (http["count"] as? NSNumber)?.int64Value,
                // ngrok's rate1 is a one-minute moving average per second.
                requestsPerMinute: (http["rate1"] as? NSNumber).map { $0.doubleValue * 60 }
            )
        }
    }
}

/// One captured request from the agent's `/api/requests/http`.
public struct NgrokRequest: Identifiable, Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public let headers: [(name: String, values: [String])]
        public let raw: Data

        public static func == (lhs: Message, rhs: Message) -> Bool {
            lhs.raw == rhs.raw && lhs.headers.map(\.name) == rhs.headers.map(\.name)
        }

        /// Everything after the blank line that ends the headers.
        public var body: Data {
            let separator = Data("\r\n\r\n".utf8)
            guard let range = raw.range(of: separator) else { return Data() }
            return raw[range.upperBound...]
        }
    }

    public let id: String
    public let start: Date?
    public let duration: TimeInterval?
    public let method: String
    public let uri: String
    public let statusCode: Int?
    public let isReplay: Bool
    public let request: Message
    public let response: Message?

    public static func parse(_ data: Data) -> [NgrokRequest] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requests = object["requests"] as? [[String: Any]] else { return [] }
        return requests.compactMap { item in
            guard let id = item["id"] as? String,
                  let request = item["request"] as? [String: Any] else { return nil }
            let response = item["response"] as? [String: Any]
            return NgrokRequest(
                id: id,
                start: (item["start"] as? String).flatMap(Self.parseDate),
                duration: (item["duration"] as? NSNumber).map { $0.doubleValue / 1_000_000_000 },
                method: request["method"] as? String ?? "?",
                uri: request["uri"] as? String ?? "/",
                statusCode: (response?["status_code"] as? NSNumber)?.intValue,
                isReplay: (item["remote_addr"] as? String) == "replayed",
                request: Self.message(request),
                response: response.map(Self.message)
            )
        }
    }

    /// Header names whose values are hidden until the user reveals them.
    public static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token",
    ]

    public static func isSensitive(_ header: String) -> Bool {
        sensitiveHeaders.contains(header.lowercased())
    }

    /// A curl command reproducing the request against the public URL, with sensitive headers left out.
    public func curlCommand(baseURL: String) -> String {
        // The method comes from whoever sent the request, so it's quoted like everything else.
        var parts = ["curl", "-X", shellQuote(method), shellQuote(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + uri)]
        for header in request.headers where !Self.isSensitive(header.name) && !["host", "content-length", "accept-encoding"].contains(header.name.lowercased()) {
            for value in header.values { parts += ["-H", shellQuote("\(header.name): \(value)")] }
        }
        if !request.body.isEmpty, let body = String(data: request.body, encoding: .utf8) {
            parts += ["--data-binary", shellQuote(body)]
        }
        return parts.joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func message(_ object: [String: Any]) -> Message {
        let headers = (object["headers"] as? [String: [String]] ?? [:])
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (name: $0.key, values: $0.value) }
        let raw = (object["raw"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        return Message(headers: headers, raw: raw)
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: value)
    }
}

/// Generates the ngrok traffic policy for a share's options.
public enum NgrokTrafficPolicy {
    /// YAML for the policy, or nil when no option needs one.
    public static func yaml(
        hostHeader: String?,
        basicAuthCredentials: [String] = [],
        oauth: (provider: LoginProvider, allowedEmails: [String])? = nil
    ) -> String? {
        var actions: [String] = []
        if !basicAuthCredentials.isEmpty {
            let credentials = basicAuthCredentials.map { "          - \(quote($0))" }.joined(separator: "\n")
            actions.append("      - type: basic-auth\n        config:\n          credentials:\n\(credentials)")
        }
        if let oauth, oauth.provider != .cloudflareEmail {
            actions.append("      - type: oauth\n        config:\n          provider: \(oauth.provider.rawValue)")
        }
        if let hostHeader {
            actions.append("      - type: add-headers\n        config:\n          headers:\n            host: \(quote(hostHeader))")
        }
        guard !actions.isEmpty else { return nil }
        var rules = ["  - actions:\n" + actions.joined(separator: "\n")]
        // Signed in but not on the list: refuse. Emails are pre-validated by EmailList, so they're safe to embed.
        if let oauth, oauth.provider != .cloudflareEmail, !oauth.allowedEmails.isEmpty {
            let list = oauth.allowedEmails.map { "'\($0)'" }.joined(separator: ", ")
            rules.append("  - expressions:\n      - \(quote("!(actions.ngrok.oauth.identity.email.lowerAscii() in [\(list)])"))\n    actions:\n      - type: deny\n        config:\n          status_code: 403")
        }
        return "on_http_request:\n" + rules.joined(separator: "\n") + "\n"
    }

    /// YAML double-quoted scalar.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

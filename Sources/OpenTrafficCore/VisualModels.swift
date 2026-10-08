import Foundation

// MARK: - Connection path

/// One stop on the way from the local service to the public internet.
public struct ConnectionStage: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case localService
        case connector
        case edge
        case publicSite
    }

    public let kind: Kind
    public let state: HealthCheckState
    public let title: String
    public let detail: String?
    /// The health check that decided this stage's state, so callers can offer its fixes.
    public let sourceCheck: TunnelHealthCheck?

    public var id: Kind { kind }
}

public enum ConnectionPath {
    /// Folds the health checklist into four stages that read left to right like the traffic flow.
    public static func stages(
        checks: [TunnelHealthCheck],
        kind: TunnelKind,
        localLabel: String,
        publicLabel: String
    ) -> [ConnectionStage] {
        func check(_ kind: HealthCheckKind) -> TunnelHealthCheck? {
            checks.first { $0.kind == kind }
        }

        let local = check(.localOrigin)
        let connector = check(.connector)
        let localStage = ConnectionStage(
            kind: .localService,
            state: local?.state ?? .skipped,
            title: localLabel,
            detail: local?.detail,
            sourceCheck: local
        )
        let connectorStage = ConnectionStage(
            kind: .connector,
            state: connector?.state ?? .skipped,
            title: "This Mac",
            detail: connector?.detail,
            sourceCheck: connector
        )

        let edgeStage: ConnectionStage
        if kind.reportsEdgeStatus {
            let edge = check(.edge)
            edgeStage = ConnectionStage(
                kind: .edge,
                state: edge?.state ?? .skipped,
                title: kind.provider.edgeTitle,
                detail: edge?.detail,
                sourceCheck: edge
            )
        } else {
            // No account-side status; the edge is up exactly when the connector is.
            let state: HealthCheckState = switch connector?.state {
            case .ok: .ok
            case .working: .working
            default: .skipped
            }
            edgeStage = ConnectionStage(
                kind: .edge,
                state: state,
                title: kind.provider.edgeTitle,
                detail: state == .ok ? "Connected to the \(kind.publicHostPlaceholder) edge." : "Not connected.",
                sourceCheck: nil
            )
        }

        let dns = check(.dns)
        let site = check(.publicSite)
        let publicSource = dns?.state == .failed ? dns : site
        let publicStage = ConnectionStage(
            kind: .publicSite,
            state: publicSource?.state ?? .skipped,
            title: publicLabel,
            detail: publicSource?.detail,
            sourceCheck: publicSource
        )
        return [localStage, connectorStage, edgeStage, publicStage]
    }

    /// Traffic can flow across a link only when both of its ends are healthy.
    public static func isLinkFlowing(from: ConnectionStage, to: ConnectionStage) -> Bool {
        from.state == .ok && to.state == .ok
    }
}

// MARK: - Structured log lines

public struct LogField: Sendable, Equatable, Identifiable {
    public let key: String
    public let value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public enum StructuredLog {
    /// Keys already shown elsewhere in the row.
    static let consumedKeys: Set<String> = ["level", "lvl", "message", "msg", "time", "timestamp", "t"]
    /// Fields worth seeing first; everything else follows alphabetically.
    static let priorityKeys = ["error", "connIndex", "location", "protocol", "ip", "event", "url", "originService", "status", "component"]

    /// The extra key/value fields of a JSON log line, ready to show as tags. Empty for plain-text lines.
    public static func fields(fromRawLine rawLine: String?, limit: Int = 6) -> [LogField] {
        guard let rawLine,
              let data = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let keys = object.keys.filter { !consumedKeys.contains($0) }
        let ordered = priorityKeys.filter(keys.contains) + keys.filter { !priorityKeys.contains($0) }.sorted()
        return ordered.prefix(limit).compactMap { key in
            guard let value = describe(object[key]) else { return nil }
            return LogField(key: key, value: value)
        }
    }

    /// cloudflared prints ASCII tables with leading "|" and padding; tidy them for display.
    public static func displayMessage(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text
            .replacingOccurrences(of: #"\s{2,}"#, with: "  ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.nilIfBlank
        case let number as NSNumber: number.stringValue
        case nil, is NSNull: nil
        default:
            (try? JSONSerialization.data(withJSONObject: value as Any, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

// MARK: - Favicons

public enum FaviconLocator {
    /// The best icon URL declared by an HTML document, falling back to /favicon.ico.
    public static func iconURL(html: String, baseURL: URL) -> URL {
        let pattern = #"<link\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return fallback(baseURL)
        }
        let range = NSRange(html.startIndex..., in: html)
        var candidates: [(rank: Int, url: URL)] = []
        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let rank: Int
            if rel.contains("apple-touch-icon") {
                rank = 3
            } else if rel.split(separator: " ").contains("icon") {
                // SVG icons don't render reliably in NSImage; prefer bitmaps.
                rank = href.lowercased().hasSuffix(".svg") ? 1 : 2
            } else {
                continue
            }
            candidates.append((rank, url))
        }
        return candidates.max { $0.rank < $1.rank }?.url ?? fallback(baseURL)
    }

    static func fallback(_ baseURL: URL) -> URL {
        URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }
}

// MARK: - Menu bar icon

public enum MenuBarIconState: Sendable, Equatable {
    case idle
    case live
    case attention

    public static func resolve(activeTunnels: Int, needsAttention: Bool) -> MenuBarIconState {
        if needsAttention { return .attention }
        return activeTunnels > 0 ? .live : .idle
    }
}

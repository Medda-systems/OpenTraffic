import Foundation

public struct LocalOriginOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: String

    public init(id: String, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

public enum LocalOriginResolver {
    public struct OriginSections: Sendable, Equatable {
        public let saved: [LocalOriginOption]
        public let detected: [LocalOriginOption]

        public init(saved: [LocalOriginOption], detected: [LocalOriginOption]) {
            self.saved = saved
            self.detected = detected
        }

        public var flattened: [LocalOriginOption] { saved + detected }
        public var isEmpty: Bool { saved.isEmpty && detected.isEmpty }
    }

    public static func sections(
        definitions: [TunnelDefinition],
        discovered: [DiscoveredQuickTunnel],
        discoveredAliases: [String: String] = [:],
        detected: [LocalOriginOption] = []
    ) -> OriginSections {
        var seen = Set<String>()
        var saved: [LocalOriginOption] = []
        for definition in definitions {
            guard let normalized = normalizedHTTPURL(definition.localURL), seen.insert(normalized).inserted else { continue }
            saved.append(LocalOriginOption(id: "managed:\(definition.id.uuidString)", name: definition.name, url: definition.localURL))
        }
        for tunnel in discovered {
            guard let url = tunnel.localURL,
                  let normalized = normalizedHTTPURL(url),
                  seen.insert(normalized).inserted else { continue }
            let name = discoveredAliases[tunnel.preferenceKey]?.nilIfBlank
                ?? tunnel.publicURL.replacingOccurrences(of: "https://", with: "")
            saved.append(LocalOriginOption(id: "discovered:\(tunnel.preferenceKey)", name: name, url: url))
        }
        var fresh: [LocalOriginOption] = []
        for option in detected {
            guard let normalized = normalizedHTTPURL(option.url), seen.insert(normalized).inserted else { continue }
            fresh.append(option)
        }
        return OriginSections(saved: saved, detected: fresh)
    }

    public static func options(
        definitions: [TunnelDefinition],
        discovered: [DiscoveredQuickTunnel],
        discoveredAliases: [String: String] = [:],
        detected: [LocalOriginOption] = []
    ) -> [LocalOriginOption] {
        sections(definitions: definitions, discovered: discovered, discoveredAliases: discoveredAliases, detected: detected).flattened
    }

    public static func selectedSeed(
        selectedID: UUID?,
        definitions: [TunnelDefinition],
        discovered: [DiscoveredQuickTunnel],
        discoveredAliases: [String: String] = [:]
    ) -> LocalOriginOption? {
        guard let selectedID else { return nil }
        if let definition = definitions.first(where: { $0.id == selectedID }), normalizedHTTPURL(definition.localURL) != nil {
            return LocalOriginOption(id: "managed:\(definition.id.uuidString)", name: definition.name, url: definition.localURL)
        }
        if let tunnel = discovered.first(where: { $0.id == selectedID }),
           let url = tunnel.localURL,
           normalizedHTTPURL(url) != nil {
            let name = discoveredAliases[tunnel.preferenceKey]?.nilIfBlank
                ?? tunnel.publicURL.replacingOccurrences(of: "https://", with: "")
            return LocalOriginOption(id: "discovered:\(tunnel.preferenceKey)", name: name, url: url)
        }
        return nil
    }

    public static func pickerSeed(
        selected: LocalOriginOption?,
        options: [LocalOriginOption]
    ) -> LocalOriginOption? {
        guard let selected else { return nil }
        if options.contains(where: { $0.id == selected.id }) { return selected }
        guard let retained = options.first(where: {
            normalizedHTTPURL($0.url) == normalizedHTTPURL(selected.url)
        }) else { return selected }
        return LocalOriginOption(id: retained.id, name: selected.name, url: retained.url)
    }

    private static func normalizedHTTPURL(_ value: String) -> String? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url.standardized.absoluteString
    }
}

public enum LocalOriginReachability: Equatable, Sendable {
    case reachable(statusCode: Int)
    case invalid(message: String)
    case unreachable(message: String)
}

public struct LocalOriginReachabilityChecker: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func check(_ value: String) async -> LocalOriginReachability {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return .invalid(message: "Enter a valid HTTP or HTTPS local origin before creating the tunnel.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await transport.data(for: request)
            return .reachable(statusCode: response.statusCode)
        } catch {
            return .unreachable(
                message: "Nothing responded at \(value). Verify the local service and port, or explicitly continue if this origin is intentionally offline."
            )
        }
    }
}

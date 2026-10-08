import Foundation

/// The single user-facing status for a tunnel. Every surface (menu bar, sidebar,
/// detail header, accessibility) derives its status from this value so they agree.
public enum TunnelDisplayState: String, Sendable, Equatable, CaseIterable {
    case online
    case checking
    case starting
    case stopping
    case attention
    case stopped
    case external

    public var label: String {
        switch self {
        case .online: "Online"
        case .checking: "Checking"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .attention: "Needs attention"
        case .stopped: "Stopped"
        case .external: "Running elsewhere"
        }
    }

    public var isActive: Bool {
        switch self {
        case .online, .checking, .starting, .external: true
        case .attention, .stopping, .stopped: false
        }
    }

    public static func resolve(
        health: TunnelHealthState,
        connector: LocalTunnelState,
        hasError: Bool
    ) -> TunnelDisplayState {
        switch connector {
        case .starting: return .starting
        case .stopping: return .stopping
        case .failed: return .attention
        case .stopped: return hasError || health == .failed ? .attention : .stopped
        case .running:
            switch health {
            case .failed: return .attention
            case .healthy: return .online
            case .working, .unknown, .stopped: return .checking
            }
        }
    }
}

/// Response counts grouped by HTTP class (2xx, 3xx, 4xx, 5xx) in ascending order.
public struct ResponseClassCount: Sendable, Equatable, Identifiable {
    public let label: String
    public let count: Int64

    public var id: String { label }

    public init(label: String, count: Int64) {
        self.label = label
        self.count = count
    }

    public static func summarize(_ responseByCode: [String: Int64]) -> [ResponseClassCount] {
        var totals: [Int: Int64] = [:]
        for (code, count) in responseByCode {
            guard let value = Int(code), (100..<600).contains(value) else { continue }
            totals[value / 100, default: 0] += count
        }
        return totals.keys.sorted().map { ResponseClassCount(label: "\($0)xx", count: totals[$0] ?? 0) }
    }
}

/// A bounded series of cumulative request counters used for traffic sparklines.
public struct RequestHistory: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let date: Date
        public let total: Int64
    }

    public static let defaultCapacity = 60

    public private(set) var samples: [Sample] = []
    public let capacity: Int

    public init(capacity: Int = RequestHistory.defaultCapacity) {
        self.capacity = max(2, capacity)
    }

    public mutating func record(total: Int64, at date: Date = Date()) {
        if let last = samples.last, total < last.total {
            // The connector restarted; its counter reset, so the old series is meaningless.
            samples.removeAll()
        }
        samples.append(Sample(date: date, total: total))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Requests observed between consecutive samples.
    public var deltas: [(date: Date, count: Int64)] {
        zip(samples, samples.dropFirst()).map { previous, current in
            (current.date, max(0, current.total - previous.total))
        }
    }
}

/// Matches local services found on this Mac against the tunnels that already publish them.
public enum ShareSuggestions {
    /// The loopback port an HTTP(S) URL points at, or nil for non-loopback hosts.
    public static func loopbackPort(of value: String?) -> Int? {
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host) else { return nil }
        return url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// Processes whose listeners are tunnel infrastructure (connector metrics), not web apps.
    static let infrastructureProcesses: Set<String> = ["cloudflared", "ngrok", "tailscaled", "opentraffic"]

    /// Detected services worth offering: not tunnel infrastructure, and not already published by an active tunnel.
    public static func unshared(
        _ services: [DiscoveredLocalService],
        activeOrigins: [String?]
    ) -> [DiscoveredLocalService] {
        let published = Set(activeOrigins.compactMap(loopbackPort(of:)))
        return services.filter { !published.contains($0.port) && !isInfrastructure($0) }
    }

    public static func isInfrastructure(_ service: DiscoveredLocalService) -> Bool {
        infrastructureProcesses.contains(service.processName?.lowercased() ?? "")
    }

    /// An existing tunnel of the same kind for the port, so sharing reuses it instead of adding a duplicate.
    public static func existingTunnel(
        for service: DiscoveredLocalService,
        kind: TunnelKind = .quick,
        in definitions: [TunnelDefinition]
    ) -> TunnelDefinition? {
        definitions.first { $0.kind == kind && loopbackPort(of: $0.localURL) == service.port }
    }
}

import Foundation

/// A command from a `opentraffic://` URL (the CLI, Shortcuts' Open URL, Raycast, scripts, …).
public enum AutomationCommand: Equatable, Sendable {
    /// Share a local service: by port (`localhost:<port>`) or by full URL, through a kind of tunnel,
    /// optionally with live collaboration.
    case share(localURL: String, kind: TunnelKind, name: String?, collaboration: Bool = false)
    case start(name: String)
    case stop(name: String)
    case stopAll
    case copy(name: String)
    case show(name: String?)
    case startProject(String)
    case stopProject(String)

    /// Actions that put something on the internet need the user's confirmation unless they opted out,
    /// because any app or web page can open a `opentraffic://` link.
    public var exposesService: Bool {
        switch self {
        case .share, .start, .startProject: true
        case .stop, .stopAll, .copy, .show, .stopProject: false
        }
    }

    /// Control and invisible formatting characters (newlines, bidi overrides, zero-width spaces).
    private static let disallowedScalars = CharacterSet.controlCharacters
        .union(.illegalCharacters)
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x202A)!...Unicode.Scalar(0x202E)!))
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x2066)!...Unicode.Scalar(0x2069)!))

    /// The host and port a share link points at, for showing in the confirmation, and whether it's this Mac.
    public static func target(of localURL: String) -> (display: String, isLoopback: Bool)? {
        guard let components = URLComponents(string: localURL), let host = components.host?.lowercased() else { return nil }
        let port = components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
        let loopback = ["localhost", "::1", "[::1]", "0.0.0.0"].contains(host) || host.hasSuffix(".localhost") || isLoopbackIPv4(host)
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return ("\(shown):\(port)", loopback)
    }

    /// Four dotted decimal octets (0–255) starting with 127; not names like `127.evil.com`.
    static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part).flatMap { $0 <= 255 ? $0 : nil }
        }
        return octets.count == 4 && octets[0] == 127
    }

    public static func parse(_ url: URL) -> AutomationCommand? {
        guard url.scheme?.lowercased() == "opentraffic" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Values end up in a confirmation dialog, so anything that could disguise them is refused.
        func query(_ name: String) -> String? {
            guard let value = components?.queryItems?.first(where: { $0.name.lowercased() == name })?.value?.nilIfBlank,
                  value.unicodeScalars.allSatisfy({ !Self.disallowedScalars.contains($0) }),
                  value.count <= 512 else { return nil }
            return value
        }
        // opentraffic://share?… or opentraffic:share?… — the action is the host, or the path if there's no host.
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch action {
        case "share":
            let localURL: String
            if let value = query("url") {
                localURL = value
            } else if let port = query("port").flatMap(Int.init), (1...65_535).contains(port) {
                localURL = "http://localhost:\(port)"
            } else {
                return nil
            }
            guard let parsed = URLComponents(string: localURL),
                  let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  parsed.user == nil, parsed.password == nil,
                  let host = parsed.host, !host.isEmpty else { return nil }
            let kind: TunnelKind
            switch query("via")?.lowercased() ?? "quick" {
            case "quick", "cloudflare", "temporary": kind = .quick
            case "tailscale", "tailnet": kind = .tailscale
            case "ngrok": kind = .ngrok
            case "opentunnel": kind = .opentunnel
            default: return nil
            }
            let collaboration = ["1", "true", "yes", "on"].contains(query("collab")?.lowercased() ?? "")
            return .share(localURL: localURL, kind: kind, name: query("name"), collaboration: collaboration)
        case "start": return query("name").map { .start(name: $0) }
        case "stop":
            if query("all") != nil || components?.queryItems?.contains(where: { $0.name == "all" }) == true { return .stopAll }
            return query("name").map { .stop(name: $0) }
        case "copy": return query("name").map { .copy(name: $0) }
        case "show", "open": return .show(name: query("name"))
        case "project":
            guard let name = query("name") else { return nil }
            switch query("action")?.lowercased() {
            case "start": return .startProject(name)
            case "stop": return .stopProject(name)
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// When to restart a tunnel that stopped on its own: quickly at first, then backing off,
/// and giving up after a few failures in a short window so a broken setup doesn't loop.
public struct RestartPolicy: Sendable {
    public let delays: [TimeInterval]
    public let window: TimeInterval

    public init(delays: [TimeInterval] = [2, 10, 30], window: TimeInterval = 10 * 60) {
        self.delays = delays
        self.window = window
    }

    /// The delay before the next restart, or nil to give up.
    public func nextDelay(previousRestarts: [Date], now: Date = Date()) -> TimeInterval? {
        let recent = previousRestarts.filter { now.timeIntervalSince($0) < window }
        return recent.count < delays.count ? delays[recent.count] : nil
    }
}

/// Decides when a tunnel set to start with its local service should start.
/// It starts once each time the service comes up. After the user stops it — or after that one start
/// fails — it stays stopped until the service goes away and comes back, so a broken setup isn't
/// retried every few seconds. (Crashes of a tunnel that did run are handled by the restart policy.)
public struct AutoStartTracker: Sendable, Equatable {
    public private(set) var suppressed: Set<UUID> = []

    public init() {}

    public mutating func userStopped(_ id: UUID) {
        suppressed.insert(id)
    }

    /// Feed one observation; returns true when the tunnel should be started now.
    public mutating func observe(_ id: UUID, serviceReachable: Bool, tunnelActive: Bool) -> Bool {
        guard serviceReachable else {
            suppressed.remove(id)
            return false
        }
        guard !tunnelActive, !suppressed.contains(id) else { return false }
        suppressed.insert(id)
        return true
    }
}

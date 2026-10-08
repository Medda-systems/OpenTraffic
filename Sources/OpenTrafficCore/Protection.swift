import Foundation

/// Who can open a shared URL.
public enum ShareProtection: Codable, Hashable, Sendable {
    /// Anyone with the link.
    case none
    /// HTTP basic auth (ngrok). The password lives in the Keychain, never in the tunnels file.
    case password(username: String)
    /// Visitors sign in first: Google or GitHub through ngrok, or an emailed one-time code through
    /// Cloudflare Access. An empty list means any signed-in account (ngrok only).
    case login(LoginProvider, allowedEmails: [String])

    public var isProtected: Bool { self != .none }
}

public enum LoginProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case google
    case github
    /// Cloudflare Access with an emailed one-time PIN.
    case cloudflareEmail

    public var title: String {
        switch self {
        case .google: "Google"
        case .github: "GitHub"
        case .cloudflareEmail: "Email code (Cloudflare Access)"
        }
    }
}

public enum ProtectionOption: String, Sendable, CaseIterable, Identifiable {
    case none, password, google, github, cloudflareEmail
    public var id: String { rawValue }
}

extension TunnelKind {
    /// The protection each kind of share supports. Quick Tunnels, OpenTunnel, and Tailscale offer
    /// none here: Quick Tunnels and OpenTunnel can't be configured, and Tailscale's private shares are
    /// already limited to the tailnet.
    public var protectionOptions: [ProtectionOption] {
        switch self {
        case .quick, .tailscale, .opentunnel: []
        case .ngrok: [.none, .password, .google, .github]
        case .remote: [.none, .cloudflareEmail]
        }
    }
}

public enum EmailList {
    /// Parses "a@x.com, b@y.com" into validated, lowercased addresses; nil if any entry is invalid.
    /// Strict on purpose: addresses are embedded in ngrok policy expressions.
    public static func parse(_ text: String) -> [String]? {
        let entries = text
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let pattern = #"^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$"#
        guard entries.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) else { return nil }
        return Array(NSOrderedSet(array: entries)) as? [String] ?? entries
    }
}

/// Random credentials for password-protected shares.
public enum SharePassword {
    public static func generate(length: Int = 20) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<max(8, length)).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }
}

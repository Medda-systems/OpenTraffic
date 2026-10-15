import Foundation
import Security

/// Whether the request being handled came from OpenTraffic's own command-line tool or MCP bridge, over
/// the app's private socket. Those are part of OpenTraffic, so nothing asks before they publish.
public enum APITrust {
    @TaskLocal public static var isTrusted = false
}

/// Decides, from the caller's audit token (which macOS vouches for), whether a connection on the private
/// socket comes from this copy of OpenTraffic's own tools: signed by the same team as the app, with the
/// tools' identifiers. A build without a team (ad hoc, while developing) trusts the very binaries inside
/// its own bundle instead.
public struct TrustedCallerVerifier: Sendable {
    let requirement: String?
    let toolPaths: Set<String>

    public init(bundle: Bundle = .main) {
        let bundleID = bundle.bundleIdentifier ?? "se.medda.opentraffic"
        let tools = bundle.bundleURL.appending(path: "Contents/MacOS")
        toolPaths = Set(["opentraffic-cli", "opentraffic-mcp"].map { tools.appending(path: $0).resolvingSymlinksInPath().path })
        requirement = Self.ownTeamID().map {
            "anchor apple generic and certificate leaf[subject.OU] = \"\($0)\" and (identifier \"\(bundleID).cli\" or identifier \"\(bundleID).mcp\")"
        }
    }

    init(requirement: String?, toolPaths: Set<String>) {
        self.requirement = requirement
        self.toolPaths = toolPaths
    }

    /// The team that signed this app, if it was signed with a certificate from one.
    static func ownTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public func isTrusted(auditToken: audit_token_t) -> Bool {
        var token = auditToken
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return isTrusted(code)
    }

    func isTrusted(_ code: SecCode) -> Bool {
        if let requirement {
            var compiled: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
            return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
        }
        var staticCode: SecStaticCode?
        var url: CFURL?
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return false }
        return toolPaths.contains((url as URL).resolvingSymlinksInPath().path)
    }
}

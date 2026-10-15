import CryptoKit
import Foundation

/// A password in front of a share, enforced by OpenTraffic's own proxy: OpenTunnel can't do it (its
/// server only relays encrypted traffic) and Quick Tunnels can't be configured, but everything they
/// carry passes through the proxy on this Mac first. Visitors sign in on OpenTraffic's page and get a
/// cookie; tools can send the password as HTTP basic auth; an invite link signs people in directly.
/// The cookie and the invite are derived from the password, so a new password signs everyone out.
public struct ShareAccess: Sendable, Equatable {
    public static let cookieName = "__opentraffic_access"
    public static let inviteParameter = "ot_invite"
    public static let signInPath = "/__opentraffic/sign-in"
    /// How long signing in lasts.
    public static let cookieLifetime: TimeInterval = 30 * 24 * 60 * 60

    public let password: String
    /// Stable per share (its id), so cookies and invites of one share don't open another.
    public let shareKey: String
    public let shareName: String

    public init(password: String, shareKey: String, shareName: String) {
        self.password = password
        self.shareKey = shareKey
        self.shareName = shareName
    }

    /// What the access cookie holds.
    public var cookieValue: String { derive("opentraffic-access:\(shareKey)") }

    /// What an invite link carries instead of the password itself.
    public var inviteToken: String { derive("opentraffic-invite:\(shareKey)") }

    public func accepts(password candidate: String) -> Bool { Self.equal(candidate, password) }
    public func accepts(cookie candidate: String) -> Bool { Self.equal(candidate, cookieValue) }
    public func accepts(invite candidate: String) -> Bool { Self.equal(candidate, inviteToken) }

    /// `Authorization: Basic …` with this password (any username).
    public func accepts(authorization header: String) -> Bool {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let data = Data(base64Encoded: String(parts[1])), let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":") else { return false }
        return accepts(password: String(decoded[decoded.index(after: colon)...]))
    }

    /// The share's link with sign-in built in.
    public func inviteURL(publicURL: String) -> String {
        guard var components = URLComponents(string: publicURL) else { return publicURL }
        var items = (components.queryItems ?? []).filter { $0.name != Self.inviteParameter }
        items.append(URLQueryItem(name: Self.inviteParameter, value: inviteToken))
        components.queryItems = items
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? publicURL
    }

    public var setCookieHeader: String {
        "\(Self.cookieName)=\(cookieValue); Path=/; Max-Age=\(Int(Self.cookieLifetime)); HttpOnly; Secure; SameSite=Lax"
    }

    private func derive(_ purpose: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(purpose.utf8), using: SymmetricKey(data: Data(password.utf8)))
        return Data(code).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Compares without returning early, so timing says nothing about how much matched.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    // MARK: Paths

    /// A same-site path (with its query) to continue to after signing in; anything else becomes "/".
    public static func safeNext(_ value: String?) -> String {
        guard let value, value.hasPrefix("/"), !value.hasPrefix("//"), !value.contains("\\"), value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !value.hasPrefix(signInPath) else { return "/" }
        return value
    }

    /// `uri` without the invite parameter.
    public static func removingInvite(from uri: String) -> String {
        guard var components = URLComponents(string: uri) else { return "/" }
        let items = (components.queryItems ?? []).filter { $0.name != inviteParameter }
        components.queryItems = items.isEmpty ? nil : items
        return safeNext(components.string)
    }

    /// Fields of an `application/x-www-form-urlencoded` body.
    public static func formFields(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            if let key = parts.first, fields[key] == nil { fields[key] = parts.count > 1 ? parts[1] : "" }
        }
        return fields
    }

    // MARK: Pages

    /// Headers for OpenTraffic's own pages: nothing loads from elsewhere, nothing frames them.
    public static let pageHeaders: [(String, String)] = [
        ("content-type", "text/html; charset=utf-8"),
        ("cache-control", "no-store"),
        ("x-content-type-options", "nosniff"),
        ("referrer-policy", "no-referrer"),
        ("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"),
    ]

    /// OpenTraffic's sign-in page for the share (website/src/sign-in, built into `SignInTemplate`).
    /// `asksName`: the share has live collaboration, where people are shown by name.
    public static func signInPage(shareName: String, next: String, error: String? = nil, asksName: Bool = false) -> String {
        let password = error.map { SignInTemplate.passwordFieldInvalid.replacingOccurrences(of: "__OT_ERROR__", with: escape($0)) }
            ?? SignInTemplate.passwordField
        // Slots first, values last, so nothing a visitor sent can be taken for a slot or a placeholder.
        return SignInTemplate.page
            .replacingOccurrences(of: #"<template data-ot-slot="password"></template>"#, with: password)
            .replacingOccurrences(of: #"<template data-ot-slot="name"></template>"#, with: asksName ? SignInTemplate.nameField : "")
            .replacingOccurrences(of: "__OT_SHARE_NAME__", with: escape(shareName))
            .replacingOccurrences(of: "__OT_NEXT__", with: escape(next))
    }

    /// The page after signing in: remembers the name the visitor gave (as their name in the session) and
    /// continues to `next`.
    public static func signedInPage(next: String, name: String?) -> String {
        let target = escape(next)
        let remember = name.flatMap { CollabRoom.sanitizedName($0) }.map {
            let json = (try? JSONSerialization.data(withJSONObject: [$0], options: [])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            return "try { localStorage.setItem(\"__opentraffic_collab_name\", \(json.replacingOccurrences(of: "</", with: "<\\/"))[0]); } catch (e) {}"
        } ?? ""
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=\(target)"><title>Signed in</title></head>
        <body><script>\(remember) location.replace(\(jsonString(next)));</script><a href="\(target)">Continue</a></body></html>
        """
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[\"/\"]".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/") + "[0]"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Slows down password guessing: after a few wrong tries in a minute, more are refused for a while.
/// Keyed by the visitor's address when the tunnel says it (Cloudflare does), else per share.
public struct SignInLimiter: Sendable {
    public static let maximumFailures = 5
    public static let window: TimeInterval = 60

    private var failures: [String: [Date]] = [:]

    public init() {}

    public func allows(_ key: String, now: Date = Date()) -> Bool {
        (failures[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }.count < Self.maximumFailures
    }

    public mutating func failed(_ key: String, at date: Date = Date()) {
        var recent = (failures[key] ?? []).filter { date.timeIntervalSince($0) < Self.window }
        recent.append(date)
        failures[key] = recent
        if failures.count > 1000 { failures = failures.filter { !($0.value.last.map { date.timeIntervalSince($0) >= Self.window } ?? true) } }
    }
}

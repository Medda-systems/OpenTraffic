import Foundation

/// A coding agent working on a comment, as the hub shows it: the agent appears in the session with
/// its cursor on the comment's element, and the comment reads "working".
public struct CollabAgentWork: Equatable, Sendable {
    public let agent: String
    public let commentID: String
    public var progress: String?
    public let since: Date

    public init(agent: String, commentID: String, progress: String? = nil, since: Date) {
        self.agent = agent
        self.commentID = commentID
        self.progress = progress
        self.since = since
    }
}

/// An app's claim on a comment it's working on. Claims are leases: one that isn't renewed (by
/// claiming again, with or without progress) expires, so an agent that stopped never leaves a
/// comment stuck on "working".
public struct AgentClaim: Equatable, Sendable {
    public let shareID: UUID
    public let commentID: String
    public let agent: String
    public var progress: String?
    public let since: Date
    public var expires: Date

    public var work: CollabAgentWork {
        CollabAgentWork(agent: agent, commentID: commentID, progress: progress, since: since)
    }
}

/// Who is working on which comment, for every share. Not thread-safe; owned by the app.
public struct AgentClaimBook: Equatable, Sendable {
    public static let lease: TimeInterval = 15 * 60
    public static let maximumProgressLength = 120

    public enum ClaimError: Error, Equatable {
        /// Another app holds an unexpired claim.
        case claimed(by: String)
    }

    private struct Key: Hashable {
        let share: UUID
        let comment: String
    }

    private var claims: [Key: AgentClaim] = [:]

    public init() {}

    /// Claims a comment for `agent`, or renews its claim (updating the progress when given).
    @discardableResult
    public mutating func claim(share: UUID, comment: String, agent: String, progress: String? = nil, now: Date = Date()) throws(ClaimError) -> AgentClaim {
        let key = Key(share: share, comment: comment)
        let progress = progress.flatMap(Self.cleanProgress)
        if var existing = claims[key], existing.expires > now {
            guard existing.agent == agent else { throw .claimed(by: existing.agent) }
            existing.expires = now.addingTimeInterval(Self.lease)
            if let progress { existing.progress = progress }
            claims[key] = existing
            return existing
        }
        let claim = AgentClaim(shareID: share, commentID: comment, agent: agent, progress: progress, since: now, expires: now.addingTimeInterval(Self.lease))
        claims[key] = claim
        return claim
    }

    /// Ends a claim; with `agent`, only that app's. Returns the claim it ended.
    @discardableResult
    public mutating func release(share: UUID, comment: String, agent: String? = nil) -> AgentClaim? {
        let key = Key(share: share, comment: comment)
        guard let claim = claims[key], agent == nil || claim.agent == agent else { return nil }
        claims[key] = nil
        return claim
    }

    /// Ends every claim on a share (it was removed).
    public mutating func releaseAll(share: UUID) {
        claims = claims.filter { $0.key.share != share }
    }

    /// Removes and returns the claims that have run out.
    public mutating func expire(now: Date = Date()) -> [AgentClaim] {
        let expired = claims.values.filter { $0.expires <= now }
        for claim in expired { claims[Key(share: claim.shareID, comment: claim.commentID)] = nil }
        return expired.sorted { $0.since < $1.since }
    }

    public func claim(share: UUID, comment: String, now: Date = Date()) -> AgentClaim? {
        claims[Key(share: share, comment: comment)].flatMap { $0.expires > now ? $0 : nil }
    }

    /// A share's unexpired claims, oldest first.
    public func claims(share: UUID, now: Date = Date()) -> [AgentClaim] {
        claims.values.filter { $0.shareID == share && $0.expires > now }.sorted { $0.since < $1.since }
    }

    /// The earliest time a claim runs out, for scheduling the next `expire`.
    public var nextExpiry: Date? {
        claims.values.map(\.expires).min()
    }

    /// One line of at most 120 characters (line breaks become spaces), or nil when blank.
    static func cleanProgress(_ text: String) -> String? {
        let spaced = text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        return CollabRoom.shortText(spaced, limit: maximumProgressLength)
    }
}

/// The coding agents OpenTraffic knows by sight, recognised from the name they go by
/// (`OPENTRAFFIC_CLIENT`), so the session can show their mark instead of a generic one.
public enum AgentBrand: String, CaseIterable, Sendable {
    case claude, codex, cursor, opencode

    public init?(agentName: String) {
        let name = agentName.lowercased()
        // The most specific first: "opencode" mustn't read as "codex".
        if name.contains("opencode") { self = .opencode }
        else if name.contains("claude") { self = .claude }
        else if name.contains("codex") { self = .codex }
        else if name.contains("cursor") { self = .cursor }
        else { return nil }
    }

    /// The colour the agent's cursor and badges use, when the brand has one that works on any page
    /// (Cursor's and OpenCode's are black); nil uses `CollabRoom.agentColor`. Codex's is the deep end
    /// of its icon's gradient, which white reads on.
    public var color: String? {
        switch self {
        case .claude: "#D97757"
        case .codex: "#3941FF"
        case .cursor, .opencode: nil
        }
    }
}

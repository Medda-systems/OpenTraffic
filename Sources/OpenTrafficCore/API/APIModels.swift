import Foundation

// The contract between OpenTraffic's local API (REST, MCP, webhooks) and the app.
// See specs/collab-plan.md, "Local API, MCP and webhooks".

public struct APIPerson: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let isHost: Bool
    /// A coding agent working on a comment (absent for people).
    public let isAgent: Bool?
    /// "trusted", "commenter", or "viewer" (absent for the host and agents).
    public let role: String?
    /// Their browser, system, and window size, when their overlay said.
    public let device: CollabEnvironment?

    public init(name: String, path: String, isHost: Bool, isAgent: Bool? = nil, role: String? = nil, device: CollabEnvironment? = nil) {
        self.name = name
        self.path = path
        self.isHost = isHost
        self.isAgent = isAgent
        self.role = role
        self.device = device
    }
}

public struct APIShare: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// "cloudflare", "tailscale", "ngrok", or "opentunnel".
    public let provider: String
    /// "quick", "remote", "tailscale", "ngrok", or "opentunnel".
    public let kind: String
    /// "stopped", "starting", "running", "stopping", or "failed".
    public let state: String
    public let localURL: String
    public let publicURL: String?
    public let collaboration: Bool
    public let people: [APIPerson]
    public let openComments: Int
    public let comments: Int
    // What the share's detail view shows. Optional, so older clients and servers still decode.
    /// The fixed hostname: a custom domain, an ngrok domain, or nil for addresses the provider picks.
    public let hostname: String?
    /// Why the share last failed, while it's in the failed state.
    public let lastError: String?
    /// Who can open it: "none", "password", "google", "github", or "email".
    public let protection: String?
    public let project: String?
    /// Starts by itself whenever its local service is running.
    public let autoStart: Bool?
    /// Visitors' browser errors are collected (collaboration only).
    public let captureErrors: Bool?
    /// The local service sees its own address in the Host header instead of the public one.
    public let rewriteHostHeader: Bool?
    /// Tailscale only: reachable from the internet through Funnel, not just the tailnet.
    public let funnel: Bool?
    /// When the share stops by itself, if it's set to.
    public let stopsAt: Date?
    /// The connection path's latest checks, from the local service to the public URL.
    public let health: [APIHealthCheck]?
    /// Collaboration: works on a branch of its own while running (see `TunnelDefinition.workOnBranch`).
    public let branch: Bool?
    /// The branch it's working on right now, and the one it merges back into when it stops.
    public let branchName: String?
    public let baseBranch: String?

    public init(
        id: UUID, name: String, provider: String, kind: String, state: String, localURL: String, publicURL: String?,
        collaboration: Bool, people: [APIPerson], openComments: Int, comments: Int,
        hostname: String? = nil, lastError: String? = nil, protection: String? = nil, project: String? = nil,
        autoStart: Bool? = nil, captureErrors: Bool? = nil, rewriteHostHeader: Bool? = nil, funnel: Bool? = nil,
        stopsAt: Date? = nil, health: [APIHealthCheck]? = nil,
        branch: Bool? = nil, branchName: String? = nil, baseBranch: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.kind = kind
        self.state = state
        self.localURL = localURL
        self.publicURL = publicURL
        self.collaboration = collaboration
        self.people = people
        self.openComments = openComments
        self.comments = comments
        self.hostname = hostname
        self.lastError = lastError
        self.protection = protection
        self.project = project
        self.autoStart = autoStart
        self.captureErrors = captureErrors
        self.rewriteHostHeader = rewriteHostHeader
        self.funnel = funnel
        self.stopsAt = stopsAt
        self.health = health
        self.branch = branch
        self.branchName = branchName
        self.baseBranch = baseBranch
    }
}

/// One stop on a share's connection path.
public struct APIHealthCheck: Codable, Equatable, Sendable {
    /// "localOrigin", "connector", "edge", "dns", or "publicSite".
    public let kind: String
    public let title: String
    /// "ok", "working", "failed", or "skipped".
    public let state: String
    public let detail: String?

    public init(kind: String, title: String, state: String, detail: String?) {
        self.kind = kind
        self.title = title
        self.state = state
        self.detail = detail
    }
}

/// A web server OpenTraffic found running on this Mac (the menu bar's Ready to Share list).
public struct APILocalService: Codable, Equatable, Sendable {
    public let port: Int
    public let url: String
    /// The page title, when the server answered with one.
    public let title: String?
    public let process: String?
    public let statusCode: Int?
    /// Since when it has been answering without interruption.
    public let upSince: Date?
    /// The share that already publishes it, if one does.
    public let sharedAs: String?

    public init(port: Int, url: String, title: String?, process: String?, statusCode: Int?, upSince: Date?, sharedAs: String?) {
        self.port = port
        self.url = url
        self.title = title
        self.process = process
        self.statusCode = statusCode
        self.upSince = upSince
        self.sharedAs = sharedAs
    }
}

/// Shares grouped to start and stop together.
public struct APIProject: Codable, Equatable, Sendable {
    public let name: String
    public let shares: [String]
    public let running: Int

    public init(name: String, shares: [String], running: Int) {
        self.name = name
        self.shares = shares
        self.running = running
    }
}

/// A tool OpenTraffic shares through (cloudflared, opentunnel, ngrok, tailscale), and whether it's there.
public struct APITool: Codable, Equatable, Sendable {
    public let name: String
    public let provider: String
    public let installed: Bool
    public let path: String?
    public let version: String?
    /// Whether `POST /v1/tools/{name}/install` can install it (not Tailscale, an App Store app).
    public let installable: Bool

    public init(name: String, provider: String, installed: Bool, path: String?, version: String?, installable: Bool) {
        self.name = name
        self.provider = provider
        self.installed = installed
        self.path = path
        self.version = version
        self.installable = installable
    }
}

/// A domain in the connected Cloudflare account, for custom-domain shares.
public struct APIZone: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Whether a way of sharing can be used right now, and why not.
public struct APIProviderStatus: Codable, Equatable, Sendable {
    /// "quick", "domain", "opentunnel", "tailscale", or "ngrok".
    public let name: String
    public let ready: Bool
    public let detail: String?
    /// Ready, but likely to fail anyway (for example, the network blocks it). Optional for older clients.
    public let warning: String?

    public init(name: String, ready: Bool, detail: String?, warning: String? = nil) {
        self.name = name
        self.ready = ready
        self.detail = detail
        self.warning = warning
    }
}

public struct APIAppStatus: Codable, Equatable, Sendable {
    public let version: String
    public let shares: Int
    public let running: Int
    public let providers: [APIProviderStatus]
    /// Apps on this Mac can publish without OpenTraffic asking first.
    public let publishesWithoutAsking: Bool

    public init(version: String, shares: Int, running: Int, providers: [APIProviderStatus], publishesWithoutAsking: Bool) {
        self.version = version
        self.shares = shares
        self.running = running
        self.providers = providers
        self.publishesWithoutAsking = publishesWithoutAsking
    }
}

/// Changes to a share's settings; absent fields are left as they are.
public struct APIShareUpdate: Codable, Equatable, Sendable {
    public var name: String?
    /// A port or an http(s) URL for the local service.
    public var url: String?
    public var collaboration: Bool?
    public var captureErrors: Bool?
    public var autoStart: Bool?
    /// An empty string removes the share from its project.
    public var project: String?
    public var rewriteHostHeader: Bool?
    /// "never", "15m", "1h", or "4h": stop by itself after that long.
    public var autoStop: String?
    /// Work on a branch of its own while running (collaboration, in a git repository).
    public var branch: Bool?

    public init(name: String? = nil, url: String? = nil, collaboration: Bool? = nil, captureErrors: Bool? = nil, autoStart: Bool? = nil, project: String? = nil, rewriteHostHeader: Bool? = nil, autoStop: String? = nil, branch: Bool? = nil) {
        self.name = name
        self.url = url
        self.collaboration = collaboration
        self.captureErrors = captureErrors
        self.autoStart = autoStart
        self.project = project
        self.rewriteHostHeader = rewriteHostHeader
        self.autoStop = autoStop
        self.branch = branch
    }
}

/// Who can open a share. ngrok shares take a password or a Google or GitHub sign-in; custom domains
/// take email codes (Cloudflare Access).
public struct APIProtectionRequest: Codable, Equatable, Sendable {
    /// "none", "password", "google", "github", or "email".
    public var mode: String
    /// For "password" (default "guest").
    public var username: String?
    /// For sign-ins: who may sign in (empty: anyone with an account, except for "email").
    public var emails: [String]?

    public init(mode: String, username: String? = nil, emails: [String]? = nil) {
        self.mode = mode
        self.username = username
        self.emails = emails
    }
}

public struct APIProtection: Codable, Equatable, Sendable {
    public let mode: String
    public let username: String?
    /// The generated password, for "password".
    public let password: String?
    public let emails: [String]
    /// The share's address with the password built in, for shares whose password OpenTraffic checks
    /// (Quick Tunnels, OpenTunnel; any username works there, so `username` is nil). Nil until it has an address.
    public let link: String?

    public init(mode: String, username: String?, password: String?, emails: [String], link: String? = nil) {
        self.mode = mode
        self.username = username
        self.password = password
        self.emails = emails
        self.link = link
    }
}

public struct APIShareRef: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let publicURL: String?

    public init(id: UUID, name: String, publicURL: String?) {
        self.id = id
        self.name = name
        self.publicURL = publicURL
    }
}

public struct APIShareRequest: Codable, Equatable, Sendable {
    public var port: Int?
    public var url: String?
    /// "quick" (default), "opentunnel", "tailscale", "ngrok", or "domain" (a hostname in your Cloudflare account).
    public var provider: String?
    public var name: String?
    public var collaboration: Bool?
    /// "domain": the hostname to serve (required). "ngrok": a domain reserved in your ngrok account.
    public var hostname: String?
    /// "domain": take over a hostname that already has a DNS record (see the New Tunnel sheet).
    public var replaceDNS: Bool?
    /// "tailscale": public on the internet through Funnel, not just your tailnet.
    public var funnel: Bool?
    /// False saves the share without starting it.
    public var start: Bool?
    /// Work on a branch of its own while running (collaboration, in a git repository).
    public var branch: Bool?

    public init(port: Int? = nil, url: String? = nil, provider: String? = nil, name: String? = nil, collaboration: Bool? = nil, hostname: String? = nil, replaceDNS: Bool? = nil, funnel: Bool? = nil, start: Bool? = nil, branch: Bool? = nil) {
        self.port = port
        self.url = url
        self.provider = provider
        self.name = name
        self.collaboration = collaboration
        self.hostname = hostname
        self.replaceDNS = replaceDNS
        self.funnel = funnel
        self.start = start
        self.branch = branch
    }
}

public enum APICommentStatus: String, Codable, Sendable {
    case open, resolved, all
}

/// A comment as API clients see it: the hub's comment without session-only fields, plus its share.
public struct APIComment: Codable, Equatable, Sendable {
    public let shareId: UUID
    public let id: String
    public let author: String
    public let path: String
    public let title: String?
    public let label: String?
    public let anchor: String?
    public let text: String
    public let createdAt: Date
    public let resolved: Bool
    public let replies: [CollabReply]
    public let hasScreenshot: Bool
    public let environment: CollabEnvironment?
    public let errors: [CollabErrorItem]
    // Optional, so older clients and servers still decode.
    /// "open", "working" (an app claimed it), "resolved", or "confirmed" (the commenter agreed with the fix).
    public let status: String?
    /// The app working on it, while `status` is "working".
    public let claimedBy: String?
    /// What that app last said it's doing.
    public let progress: String?
    public let resolvedBy: String?
    public let resolvedAt: Date?
    /// A picture of the element after it was resolved (get it with `which: after`).
    public let hasAfterScreenshot: Bool?
    /// Where the element comes from: a selector, key styles, and on development servers that expose
    /// it, the component and source file. Start there rather than searching for the element.
    public let context: CollabElementContext?
    /// Exact changes the commenter suggested by editing the page (apply these as given).
    public let edits: [CollabSuggestedEdit]?
    /// For a comment on an area: its size in CSS pixels from the comment's position.
    public let area: CollabArea?

    public init(_ comment: CollabComment, shareID: UUID, claim: AgentClaim? = nil) {
        shareId = shareID
        id = comment.id
        author = comment.author
        path = comment.path
        title = comment.title
        label = comment.label
        anchor = comment.anchor
        text = comment.text
        createdAt = comment.createdAt
        resolved = comment.resolved
        replies = comment.replies
        hasScreenshot = comment.screenshot != nil
        environment = comment.environment
        errors = comment.errors
        let claim = comment.resolved ? nil : claim
        status = comment.resolved ? (comment.confirmed ? "confirmed" : "resolved") : (claim == nil ? "open" : "working")
        claimedBy = claim?.agent
        progress = claim?.progress
        resolvedBy = comment.resolved ? comment.resolvedBy : nil
        resolvedAt = comment.resolved ? comment.resolvedAt : nil
        hasAfterScreenshot = comment.afterScreenshot != nil
        context = comment.context
        edits = comment.edits.isEmpty ? nil : comment.edits
        area = comment.area
    }
}

/// The process on the other end of an API connection, as far as it can be told: the private socket
/// knows it from macOS; a TCP connection only by its port.
public struct APICaller: Sendable {
    public let pid: pid_t?
    public let tcpPort: Int?

    public init(pid: pid_t? = nil, tcpPort: Int? = nil) {
        self.pid = pid
        self.tcpPort = tcpPort
    }
}

/// An error a backend call reports, with the HTTP status the REST API answers with.
public struct OpenTrafficAPIError: Error, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public static func notFound(_ message: String) -> OpenTrafficAPIError { OpenTrafficAPIError(status: 404, code: "not_found", message: message) }
    public static func badRequest(_ message: String) -> OpenTrafficAPIError { OpenTrafficAPIError(status: 400, code: "bad_request", message: message) }
    public static func denied(_ message: String) -> OpenTrafficAPIError { OpenTrafficAPIError(status: 403, code: "denied", message: message) }
    public static func conflict(_ message: String) -> OpenTrafficAPIError { OpenTrafficAPIError(status: 409, code: "conflict", message: message) }
}

/// What the API server asks of the app. `share` arguments are a share's id or name (case-insensitive).
/// Implementations throw `OpenTrafficAPIError` for anything the caller should see.
public protocol OpenTrafficAPIBackend: Sendable {
    func listShares() async -> [APIShare]
    /// Publishes a local service. May ask the user first; throws `.denied` if they decline.
    func createShare(_ request: APIShareRequest, client: String) async throws -> APIShare
    func startShare(_ share: String, client: String) async throws -> APIShare
    func stopShare(_ share: String) async throws -> APIShare
    func comments(_ share: String, status: APICommentStatus) async throws -> [APIComment]
    func screenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String)
    /// The picture of the element after the comment was resolved.
    func afterScreenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String)
    /// Claims a comment for `client` (or renews its claim), so others leave it alone and the session sees
    /// it being worked on. Throws `.conflict` when another app holds it or it's resolved.
    func claimComment(_ share: String, commentID: String, progress: String?, client: String) async throws -> APIComment
    /// Gives up `client`'s claim without resolving the comment.
    func releaseComment(_ share: String, commentID: String, client: String) async throws -> APIComment
    /// The comment a caller is limited to, when it belongs to a run of the agent command OpenTraffic
    /// started (see `AgentRunScope`); nil for anyone else.
    func agentRunScope(for caller: APICaller) async -> AgentRunScope?
    func resolveComment(_ share: String, commentID: String, resolved: Bool) async throws -> APIComment
    /// Like `resolveComment(_:commentID:resolved:)`, naming the app that resolved it (shown to the commenter).
    func resolveComment(_ share: String, commentID: String, resolved: Bool, client: String) async throws -> APIComment
    func reply(_ share: String, commentID: String, text: String, client: String) async throws -> APIComment
    func errors(_ share: String) async throws -> [CollabErrorGroup]
    func logs(_ share: String, lines: Int) async throws -> [String]

    // What the app's windows can do, for the command-line tool. Default implementations answer 501.
    func status() async -> APIAppStatus?
    func share(_ share: String) async throws -> APIShare
    func updateShare(_ share: String, _ update: APIShareUpdate, client: String) async throws -> APIShare
    func restartShare(_ share: String, client: String) async throws -> APIShare
    func deleteShare(_ share: String) async throws
    func protection(_ share: String) async throws -> APIProtection
    func setProtection(_ share: String, _ request: APIProtectionRequest) async throws -> APIProtection
    func regeneratePassword(_ share: String) async throws -> APIProtection
    func deleteComment(_ share: String, commentID: String) async throws
    func localServices() async -> [APILocalService]
    func projects() async -> [APIProject]
    func startProject(_ name: String, client: String) async throws -> APIProject
    func stopProject(_ name: String) async throws -> APIProject
    func zones() async throws -> [APIZone]
    func tools() async -> [APITool]
    /// Downloads and installs a tool from its maker's official release.
    func installTool(_ name: String) async throws -> APITool
}

extension OpenTrafficAPIBackend {
    private var unsupported: OpenTrafficAPIError { OpenTrafficAPIError(status: 501, code: "not_supported", message: "This version of OpenTraffic doesn't support that.") }
    public func status() async -> APIAppStatus? { nil }
    public func resolveComment(_ share: String, commentID: String, resolved: Bool, client: String) async throws -> APIComment {
        try await resolveComment(share, commentID: commentID, resolved: resolved)
    }
    public func afterScreenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String) { throw unsupported }
    public func claimComment(_ share: String, commentID: String, progress: String?, client: String) async throws -> APIComment { throw unsupported }
    public func releaseComment(_ share: String, commentID: String, client: String) async throws -> APIComment { throw unsupported }
    public func agentRunScope(for caller: APICaller) async -> AgentRunScope? { nil }
    public func share(_ share: String) async throws -> APIShare {
        guard let found = await listShares().first(where: { $0.id.uuidString.caseInsensitiveCompare(share) == .orderedSame || $0.name.caseInsensitiveCompare(share) == .orderedSame }) else {
            throw OpenTrafficAPIError.notFound("No share named “\(share)”.")
        }
        return found
    }
    public func updateShare(_ share: String, _ update: APIShareUpdate, client: String) async throws -> APIShare { throw unsupported }
    public func restartShare(_ share: String, client: String) async throws -> APIShare { throw unsupported }
    public func deleteShare(_ share: String) async throws { throw unsupported }
    public func protection(_ share: String) async throws -> APIProtection { throw unsupported }
    public func setProtection(_ share: String, _ request: APIProtectionRequest) async throws -> APIProtection { throw unsupported }
    public func regeneratePassword(_ share: String) async throws -> APIProtection { throw unsupported }
    public func deleteComment(_ share: String, commentID: String) async throws { throw unsupported }
    public func localServices() async -> [APILocalService] { [] }
    public func projects() async -> [APIProject] { [] }
    public func startProject(_ name: String, client: String) async throws -> APIProject { throw unsupported }
    public func stopProject(_ name: String) async throws -> APIProject { throw unsupported }
    public func zones() async throws -> [APIZone] { throw unsupported }
    public func tools() async -> [APITool] { [] }
    public func installTool(_ name: String) async throws -> APITool { throw unsupported }
}

public struct APIEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case shareStarted = "share.started"
        case shareStopped = "share.stopped"
        case sessionJoined = "session.joined"
        case sessionLeft = "session.left"
        case commentCreated = "comment.created"
        case commentUpdated = "comment.updated"
        case commentDeleted = "comment.deleted"
        /// An app started working on a comment (`comment.claimedBy`).
        case commentClaimed = "comment.claimed"
        /// An app stopped working on a comment without resolving it, or its claim ran out.
        case commentReleased = "comment.released"
        case errorReported = "error.reported"
    }

    public let seq: Int
    public let id: String
    public let type: Kind
    public let at: Date
    public let share: APIShareRef
    public let comment: APIComment?
    /// For `comment.deleted`.
    public let commentId: String?
    public let peer: APIPerson?
    public let error: CollabErrorGroup?
}

/// Recent events for long polling, MCP's `wait_for_feedback`, and webhooks. Thread-safe.
public final class APIEventLog: @unchecked Sendable {
    public static let capacity = 1000

    private let lock = NSLock()
    private var events: [APIEvent] = []
    private var nextSeq = 1
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<UUID> = []
    private var subscribers: [UUID: @Sendable (APIEvent) -> Void] = [:]
    /// Apps waiting for feedback right now (MCP's `wait_for_feedback`), and when each share was last waited on.
    private var watchers: [UUID: (share: UUID?, client: String)] = [:]
    private var lastWatched: [UUID?: Date] = [:]

    public init() {}

    // MARK: Watchers

    /// How long after a wait ends its app still counts as watching: it's handling what it got and will wait again.
    public static let watchGrace: TimeInterval = 90

    /// Records that `client` is waiting for feedback on `share` (nil: every share) until `endWatching`.
    public func beginWatching(share: UUID?, client: String) -> UUID {
        let token = UUID()
        lock.withLock { watchers[token] = (share, client) }
        return token
    }

    public func endWatching(_ token: UUID, at date: Date = Date()) {
        lock.withLock {
            guard let watcher = watchers.removeValue(forKey: token) else { return }
            lastWatched[watcher.share] = date
        }
    }

    /// Whether an app is waiting for feedback on `share`, or was within `watchGrace`.
    public func isWatched(_ share: UUID, now: Date = Date()) -> Bool {
        lock.withLock {
            if watchers.values.contains(where: { $0.share == nil || $0.share == share }) { return true }
            let last = max(lastWatched[share] ?? .distantPast, lastWatched[nil] ?? .distantPast)
            return now.timeIntervalSince(last) < Self.watchGrace
        }
    }

    /// The apps waiting for feedback on `share` right now.
    public func watchingClients(_ share: UUID) -> [String] {
        lock.withLock { Array(Set(watchers.values.filter { $0.share == nil || $0.share == share }.map(\.client))).sorted() }
    }

    /// The sequence number the next event will get; pass it as `since` to wait for anything new.
    public var cursor: Int { lock.withLock { nextSeq } }

    @discardableResult
    public func append(_ type: APIEvent.Kind, share: APIShareRef, comment: APIComment? = nil, commentId: String? = nil, peer: APIPerson? = nil, error: CollabErrorGroup? = nil, at: Date = Date()) -> APIEvent {
        let (event, wake, notify) = lock.withLock { () -> (APIEvent, [CheckedContinuation<Void, Never>], [@Sendable (APIEvent) -> Void]) in
            let event = APIEvent(seq: nextSeq, id: UUID().uuidString.lowercased(), type: type, at: at, share: share, comment: comment, commentId: commentId, peer: peer, error: error)
            nextSeq += 1
            events.append(event)
            if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
            let wake = Array(waiters.values)
            waiters.removeAll()
            return (event, wake, Array(subscribers.values))
        }
        for continuation in wake { continuation.resume() }
        for handler in notify { handler(event) }
        return event
    }

    /// Events with `seq >= since`, oldest first, and the cursor to pass next time.
    public func events(since: Int) -> (events: [APIEvent], next: Int) {
        lock.withLock { (events.filter { $0.seq >= since }, nextSeq) }
    }

    /// Like `events(since:)`, but waits up to `timeout` seconds (at most a day) for at least one event.
    /// Returns early if the calling task is cancelled.
    public func wait(since: Int, timeout: TimeInterval) async -> (events: [APIEvent], next: Int) {
        let current = events(since: since)
        guard current.events.isEmpty, timeout.isFinite, timeout > 0 else { return current }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(timeout, 86_400)))
            guard !Task.isCancelled else { return }
            self?.releaseWaiter(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // A timeout or cancellation that came first is remembered in `released`.
                let resumeNow = lock.withLock { () -> Bool in
                    if released.remove(id) != nil || events.contains(where: { $0.seq >= since }) { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            releaseWaiter(id)
        }
        timer.cancel()
        lock.withLock { _ = released.remove(id) }
        return events(since: since)
    }

    /// Wakes one waiter, or marks it released if it hasn't started waiting yet.
    private func releaseWaiter(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let continuation = waiters.removeValue(forKey: id) { return continuation }
            released.insert(id)
            return nil
        }
        continuation?.resume()
    }

    /// Calls `handler` (on the appending thread) for every new event, until the token is passed to `unsubscribe`.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (APIEvent) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { subscribers[id] = handler }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: id) }
    }
}

import Foundation

// The contract between OpenTraffic's local API (REST, MCP, webhooks) and the app.
// See specs/collab-plan.md, "Local API, MCP and webhooks".

public struct APIPerson: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let isHost: Bool

    public init(name: String, path: String, isHost: Bool) {
        self.name = name
        self.path = path
        self.isHost = isHost
    }
}

public struct APIShare: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// "cloudflare", "tailscale", or "ngrok".
    public let provider: String
    /// "quick", "remote", "tailscale", or "ngrok".
    public let kind: String
    /// "stopped", "starting", "running", "stopping", or "failed".
    public let state: String
    public let localURL: String
    public let publicURL: String?
    public let collaboration: Bool
    public let people: [APIPerson]
    public let openComments: Int
    public let comments: Int

    public init(id: UUID, name: String, provider: String, kind: String, state: String, localURL: String, publicURL: String?, collaboration: Bool, people: [APIPerson], openComments: Int, comments: Int) {
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
    /// "quick" (default), "tailscale", or "ngrok".
    public var provider: String?
    public var name: String?
    public var collaboration: Bool?

    public init(port: Int? = nil, url: String? = nil, provider: String? = nil, name: String? = nil, collaboration: Bool? = nil) {
        self.port = port
        self.url = url
        self.provider = provider
        self.name = name
        self.collaboration = collaboration
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

    public init(_ comment: CollabComment, shareID: UUID) {
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
    func resolveComment(_ share: String, commentID: String, resolved: Bool) async throws -> APIComment
    func reply(_ share: String, commentID: String, text: String, client: String) async throws -> APIComment
    func errors(_ share: String) async throws -> [CollabErrorGroup]
    func logs(_ share: String, lines: Int) async throws -> [String]
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

    public init() {}

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

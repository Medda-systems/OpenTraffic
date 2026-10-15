import Foundation

/// Someone viewing a collaborative share, or a coding agent working on one of its comments.
public struct CollabPeer: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var color: String
    public var path: String
    public let isHost: Bool
    /// An app working through OpenTraffic's API, shown in the session while it holds a comment.
    public var isAgent = false
    /// Where an agent's cursor rests: the element of the comment it's working on.
    var spot: CollabSpot?

    var json: [String: Any] {
        var object: [String: Any] = ["id": id, "name": name, "color": color, "path": path, "isHost": isHost]
        if isAgent { object["isAgent"] = true }
        if let spot { object["at"] = spot.json }
        return object
    }
}

/// A position on a page, as cursors and comments give it.
struct CollabSpot: Equatable, Sendable {
    let anchor: String?
    let rx: Double?
    let ry: Double?
    let x: Double
    let y: Double

    init(_ comment: CollabComment) {
        anchor = comment.anchor
        rx = comment.rx
        ry = comment.ry
        x = comment.x
        y = comment.y
    }

    var json: [String: Any] {
        var object: [String: Any] = ["x": x, "y": y]
        if let anchor, let rx, let ry {
            object["anchor"] = anchor
            object["rx"] = rx
            object["ry"] = ry
        }
        return object
    }
}

/// The hub's state and rules, independent of the network: messages in, messages out.
/// See specs/collab-plan.md for the protocol. Not thread-safe; owned by one event loop.
public struct CollabRoom {
    public enum Target: Equatable, Sendable {
        case peer(String)
        /// Everyone who has said hello, except `except`; optionally only those on `path`.
        case others(except: String, path: String?)
        /// Everyone who has said hello on `path`, including the sender.
        case everyone(path: String)
    }

    public struct Outgoing: Equatable, Sendable {
        public let target: Target
        public let text: String
        /// Cursor and pointer updates: fine to drop for a peer that's falling behind.
        public var isEphemeral = false
    }

    public static let maximumPeers = 50
    public static let maximumFrameBytes = 4 * 1024
    public static let maximumMessagesPerSecond = 60
    public static let maximumComments = 500
    public static let maximumCommentLength = 1000
    public static let maximumRepliesPerComment = 50
    /// All comment and reply text of a share together, so a visitor can't make every `welcome` huge.
    public static let maximumFeedbackBytes = 1_000_000
    static let resolveInterval: TimeInterval = 0.5
    static let renameInterval: TimeInterval = 1
    static let commentInterval: TimeInterval = 2
    static let pointInterval: TimeInterval = 0.5
    /// How often someone may confirm a fix or send a picture of one.
    static let afterInterval: TimeInterval = 2
    /// Agents' cursors and badges.
    public static let agentColor = "#BF5AF2"
    public static let palette = [
        "#F38020", "#2F80ED", "#27AE60", "#9B51E0", "#EB5757",
        "#00A3A3", "#D97706", "#DB2777", "#4F46E5", "#65A30D",
    ]
    private static let adjectives = ["Amber", "Brisk", "Calm", "Daring", "Eager", "Fuzzy", "Gentle", "Happy", "Lucky", "Merry", "Nimble", "Quiet", "Sunny", "Swift", "Witty"]
    private static let animals = ["Badger", "Crane", "Dolphin", "Falcon", "Fox", "Gecko", "Heron", "Koala", "Lynx", "Otter", "Panda", "Puffin", "Robin", "Seal", "Wren"]

    /// Connected clients, including those that haven't said hello yet.
    private var connections: [String: Connection] = [:]
    private var joinOrder: [String] = []
    private var colorCursor = 0
    public private(set) var leading = false
    private var leadPath = "/"
    private var leadRatio = 0.0
    private let hostName: String
    /// Every comment on every page, oldest first.
    public private(set) var comments: [CollabComment]
    /// Comments coding agents are working on, by comment id (the app decides; see `setAgentWork`).
    private var agentWork: [String: CollabAgentWork] = [:]
    /// Each agent's place in the session, by agent name; its id stays the same while it's there.
    private var agentPeers: [String: CollabPeer] = [:]
    /// Comments resolved by someone other than their author that have no picture of the fix yet.
    /// The host's page takes one when it's on that page; the author's when they look at the fix.
    private var awaitingAfter: Set<String> = []

    private struct Connection {
        var peer: CollabPeer
        var client: String?
        var joined = false
        var windowStart = Date.distantPast
        var windowCount = 0
        var lastComment = Date.distantPast
        var lastPoint = Date.distantPast
        var lastReply = Date.distantPast
        var lastErrors = Date.distantPast
        var lastResolve = Date.distantPast
        var lastRename = Date.distantPast
        var lastAfter = Date.distantPast
        /// Authorizes this connection's screenshot uploads; sent only to it.
        let uploadToken = CollabRoom.makeToken()
    }

    /// Whether visitors' overlays should collect browser errors for the host.
    public var capturesErrors = false
    /// Errors reported since the owner last took them (see `takeReportedErrors`).
    private var reportedErrors: [CollabErrorItem] = []
    /// Screenshot ids uploaded through the proxy, by the peer that uploaded them.
    private var attachments: [String: String] = [:]

    public init(hostName: String? = nil, comments: [CollabComment] = [], now: Date = Date()) {
        self.hostName = Self.sanitizedName(hostName) ?? "Host"
        self.comments = comments
        // Fixes from the last day that nobody has pictured yet, from an earlier session.
        awaitingAfter = Set(comments.lazy.filter {
            $0.resolved && !$0.resolvedByAuthor && $0.resolvedBy != nil && $0.afterScreenshot == nil
                && now.timeIntervalSince($0.resolvedAt ?? .distantPast) < 86_400
        }.map(\.id))
    }

    public func hasRoom(isHost: Bool) -> Bool {
        let guests = connections.values.filter { !$0.peer.isHost }.count
        return isHost ? connections.count < Self.maximumPeers + 5 : guests < Self.maximumPeers - 1
    }

    public func isJoined(_ id: String) -> Bool {
        connections[id]?.joined == true
    }

    /// The connection a screenshot upload token belongs to, if it's in the session.
    public func connection(forUploadToken token: String) -> String? {
        connections.first { $0.value.joined && $0.value.uploadToken == token }?.key
    }

    /// Records an uploaded screenshot so a comment from the same peer may reference it.
    public mutating func registerAttachment(_ attachmentID: String, from peerID: String) {
        attachments[attachmentID] = peerID
    }

    /// Whether `peerID` belongs to someone in the session (uploads are only accepted from them).
    public func isConnected(_ peerID: String) -> Bool {
        connections[peerID]?.joined == true
    }

    /// Errors visitors reported since the last call.
    public mutating func takeReportedErrors() -> [CollabErrorItem] {
        defer { reportedErrors = [] }
        return reportedErrors
    }

    /// Everyone who has joined, in join order, then the agents at work.
    public var peers: [CollabPeer] {
        joinOrder.compactMap { id in connections[id].flatMap { $0.joined ? $0.peer : nil } }
            + agentPeers.values.sorted { $0.id < $1.id }
    }

    /// Registers a new connection; nil when the room is full. One place is always kept for the host.
    /// The owner closes connections that don't say hello within a few seconds (see `isJoined`).
    public mutating func connect(isHost: Bool, id: String = Self.makeID()) -> String? {
        guard hasRoom(isHost: isHost) else { return nil }
        let color = Self.palette[colorCursor % Self.palette.count]
        colorCursor += 1
        let name = isHost ? hostName : Self.generatedName()
        connections[id] = Connection(peer: CollabPeer(id: id, name: name, color: color, path: "/", isHost: isHost))
        return id
    }

    public mutating func disconnect(_ id: String) -> [Outgoing] {
        guard let connection = connections.removeValue(forKey: id) else { return [] }
        joinOrder.removeAll { $0 == id }
        guard connection.joined else { return [] }
        var output = broadcast(["type": "leave", "id": id], except: id)
        // Leading ends when no host is left to lead.
        if leading, connection.peer.isHost, !connections.values.contains(where: { $0.joined && $0.peer.isHost }) {
            leading = false
            output += broadcast(["type": "lead", "on": false], except: id)
        }
        return output
    }

    public mutating func receive(_ text: String, from id: String, now: Date = Date()) -> [Outgoing] {
        guard var connection = connections[id],
              text.utf8.count <= Self.maximumFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        if now.timeIntervalSince(connection.windowStart) >= 1 {
            connection.windowStart = now
            connection.windowCount = 0
        }
        connection.windowCount += 1
        connections[id] = connection
        guard connection.windowCount <= Self.maximumMessagesPerSecond else { return [] }

        if !connection.joined {
            guard type == "hello" else { return [] }
            return hello(object, id: id)
        }
        let peer = connection.peer
        switch type {
        case "rename":
            guard now.timeIntervalSince(connection.lastRename) >= Self.renameInterval,
                  let name = Self.sanitizedName(object["name"]) else { return [] }
            connections[id]?.lastRename = now
            return update(id) { $0.name = name }
        case "path":
            guard let path = Self.validPath(object["path"]) else { return [] }
            var output = update(id) { $0.path = path }
            if leading, peer.isHost {
                leadPath = path
                leadRatio = 0
                output += broadcast(leadMessage(), except: id)
            }
            if peer.isHost { output += captureRequests(for: id, path: path) }
            return output
        case "cursor":
            guard let message = Self.cursorMessage(object, id: id) else { return [] }
            return [Outgoing(target: .others(except: id, path: peer.path), text: Self.encode(message), isEphemeral: true)]
        case "cursor-hide":
            return [Outgoing(target: .others(except: id, path: peer.path), text: Self.encode(["type": "cursor-hide", "id": id]), isEphemeral: true)]
        case "scroll":
            guard leading, peer.isHost, let ratio = Self.unitNumber(object["ratio"]) else { return [] }
            leadRatio = ratio
            leadPath = peer.path
            return broadcast(leadMessage(), except: id)
        case "lead":
            guard peer.isHost, let on = object["on"] as? Bool else { return [] }
            leading = on
            leadPath = peer.path
            return broadcast(on ? leadMessage() : ["type": "lead", "on": false], except: id)
        case "comment":
            return addComment(object, from: id, now: now)
        case "reply":
            guard now.timeIntervalSince(connection.lastReply) >= 1,
                  let commentID = object["id"] as? String,
                  let text = Self.commentText(object["text"]) else { return [] }
            connections[id]?.lastReply = now
            return addReply(to: commentID, text: text, author: peer.name, color: peer.color, fromHost: peer.isHost, agent: nil, now: now).messages
        case "errors":
            guard capturesErrors, now.timeIntervalSince(connection.lastErrors) >= 4.5,
                  let items = object["items"] as? [Any] else { return [] }
            connections[id]?.lastErrors = now
            reportedErrors += items.prefix(10).compactMap { Self.errorItem($0) }
            return []
        case "resolve":
            guard now.timeIntervalSince(connection.lastResolve) >= Self.resolveInterval,
                  let commentID = object["id"] as? String, let resolved = object["resolved"] as? Bool,
                  let comment = comments.first(where: { $0.id == commentID }) else { return [] }
            connections[id]?.lastResolve = now
            return resolveComment(commentID, resolved: resolved, by: peer.name, byAuthor: comment.isAuthor(connection.client), now: now)
        case "confirm":
            // Only the commenter says the fix works.
            guard now.timeIntervalSince(connection.lastResolve) >= Self.resolveInterval,
                  let commentID = object["id"] as? String,
                  let index = comments.firstIndex(where: { $0.id == commentID }),
                  comments[index].resolved, !comments[index].confirmed,
                  comments[index].isAuthor(connection.client) else { return [] }
            connections[id]?.lastResolve = now
            comments[index].confirmed = true
            return commentMessages(comments[index])
        case "after":
            // A picture of the fix, from the host's page or the commenter's, uploaded by this connection.
            guard now.timeIntervalSince(connection.lastAfter) >= Self.afterInterval,
                  let commentID = object["id"] as? String, awaitingAfter.contains(commentID),
                  let attachment = object["screenshot"] as? String, attachments[attachment] == id,
                  let index = comments.firstIndex(where: { $0.id == commentID }),
                  comments[index].resolved, comments[index].afterScreenshot == nil,
                  peer.isHost || comments[index].isAuthor(connection.client) else { return [] }
            connections[id]?.lastAfter = now
            awaitingAfter.remove(commentID)
            comments[index].afterScreenshot = attachment
            return commentMessages(comments[index])
        case "delete":
            guard let commentID = object["id"] as? String,
                  let comment = comments.first(where: { $0.id == commentID }),
                  canDelete(comment, connection: connection) else { return [] }
            return deleteComment(commentID)
        case "point":
            guard now.timeIntervalSince(connection.lastPoint) >= Self.pointInterval,
                  var message = Self.cursorMessage(object, id: id) else { return [] }
            connections[id]?.lastPoint = now
            message["type"] = "point"
            message["name"] = peer.name
            message["color"] = peer.color
            return [Outgoing(target: .everyone(path: peer.path), text: Self.encode(message), isEphemeral: true)]
        default:
            return []
        }
    }

    // MARK: Comments

    private mutating func addComment(_ object: [String: Any], from id: String, now: Date) -> [Outgoing] {
        guard let connection = connections[id],
              now.timeIntervalSince(connection.lastComment) >= Self.commentInterval,
              let text = Self.commentText(object["text"]),
              let path = Self.validPath(object["path"]),
              let position = Self.cursorMessage(object, id: id) else { return [] }
        connections[id]?.lastComment = now
        let comment = CollabComment(
            id: Self.makeID(),
            author: connection.peer.name,
            color: connection.peer.color,
            path: path,
            text: text,
            x: position["x"] as? Double ?? 0,
            y: position["y"] as? Double ?? 0,
            anchor: position["anchor"] as? String,
            rx: position["rx"] as? Double,
            ry: position["ry"] as? Double,
            label: Self.shortText(object["label"], limit: 80),
            title: Self.shortText(object["title"], limit: 200),
            createdAt: now,
            fromHost: connection.peer.isHost,
            screenshot: (object["screenshot"] as? String).flatMap { attachments[$0] == id ? $0 : nil },
            environment: Self.environment(object["env"]),
            errors: capturesErrors ? ((object["errors"] as? [Any]) ?? []).prefix(10).compactMap { Self.errorItem($0) } : [],
            authorClient: connection.client
        )
        // Full: make room by dropping resolved comments, but never push out open ones; refuse instead.
        guard makeRoom(for: comment.text.utf8.count) else { return [] }
        comments.append(comment)
        return commentMessages(comment)
    }

    /// Adds a reply to a comment's thread (from someone in the session, the host in OpenTraffic, or an
    /// app using OpenTraffic's API). Returns the messages to send and the updated comment.
    public mutating func addReply(to commentID: String, text: String, author: String, color: String, fromHost: Bool, agent: String?, now: Date = Date()) -> (messages: [Outgoing], comment: CollabComment?) {
        guard let index = comments.firstIndex(where: { $0.id == commentID }),
              let text = Self.commentText(text),
              comments[index].replies.count < Self.maximumRepliesPerComment,
              feedbackBytes + text.utf8.count <= Self.maximumFeedbackBytes else { return ([], nil) }
        let reply = CollabReply(
            id: Self.makeID(),
            author: Self.sanitizedName(author) ?? "Someone",
            color: color,
            text: text,
            createdAt: now,
            fromHost: fromHost,
            agent: agent.flatMap { Self.sanitizedName($0) }
        )
        comments[index].replies.append(reply)
        return (commentMessages(comments[index]), comments[index])
    }

    /// The color replies from the host and from apps use.
    public var hostColor: String {
        peers.first(where: \.isHost)?.color ?? Self.palette[0]
    }

    /// Resolves or reopens a comment (from anyone in the session, or from OpenTraffic). `by` names who
    /// resolved it; `agent` marks an app using the API, `byAuthor` the commenter. When someone else
    /// resolved it, the host's page is asked for a picture of the fix.
    public mutating func resolveComment(_ commentID: String, resolved: Bool, by name: String? = nil, agent: Bool = false, byAuthor: Bool = false, now: Date = Date()) -> [Outgoing] {
        guard let index = comments.firstIndex(where: { $0.id == commentID }), comments[index].resolved != resolved else { return [] }
        comments[index].setResolved(resolved, by: name.flatMap { Self.sanitizedName($0) }, agent: agent, byAuthor: byAuthor, at: now)
        var output = commentMessages(comments[index])
        if resolved, !byAuthor {
            awaitingAfter.insert(commentID)
            let path = comments[index].path
            for id in joinedIDs where connections[id]?.peer.isHost == true && connections[id]?.peer.path == path {
                output.append(captureMessage(commentID, to: id))
            }
        } else {
            awaitingAfter.remove(commentID)
        }
        // Done or reopened, nobody is working on it any more; the app ends the claim too.
        if agentWork.removeValue(forKey: commentID) != nil { output += syncAgentPeers() }
        return output
    }

    /// Asks the host's page to take pictures of fixes on `path` it hasn't sent yet.
    private func captureRequests(for id: String, path: String) -> [Outgoing] {
        comments.filter { awaitingAfter.contains($0.id) && $0.path == path }.map { captureMessage($0.id, to: id) }
    }

    private func captureMessage(_ commentID: String, to id: String) -> Outgoing {
        Outgoing(target: .peer(id), text: Self.encode(["type": "capture", "id": commentID]))
    }

    // MARK: Agents

    /// Shows which comments coding agents are working on. Each agent is in the session while it holds a
    /// comment, its cursor on the newest one's element; those comments read "working" for everyone.
    public mutating func setAgentWork(_ work: [CollabAgentWork]) -> [Outgoing] {
        let known = Set(comments.lazy.filter { !$0.resolved }.map(\.id))
        var next: [String: CollabAgentWork] = [:]
        for item in work where known.contains(item.commentID) { next[item.commentID] = item }
        let changed = Set(next.keys).union(agentWork.keys).filter { next[$0] != agentWork[$0] }
        agentWork = next
        var output = comments.filter { changed.contains($0.id) }.flatMap(commentMessages)
        output += syncAgentPeers()
        return output
    }

    /// Brings the agents in the session in line with `agentWork`: joins, moves, and leaves.
    private mutating func syncAgentPeers() -> [Outgoing] {
        var newest: [String: CollabAgentWork] = [:]
        for work in agentWork.values where (newest[work.agent]?.since ?? .distantPast) <= work.since {
            newest[work.agent] = work
        }
        var output: [Outgoing] = []
        for (name, peer) in agentPeers where newest[name] == nil {
            agentPeers[name] = nil
            output += broadcastToJoined(["type": "leave", "id": peer.id])
        }
        for (name, work) in newest.sorted(by: { $0.value.since < $1.value.since }) {
            guard let comment = comments.first(where: { $0.id == work.commentID }) else { continue }
            let color = AgentBrand(agentName: name)?.color ?? Self.agentColor
            var peer = agentPeers[name] ?? CollabPeer(id: Self.makeID(), name: Self.sanitizedName(name) ?? "Agent", color: color, path: comment.path, isHost: false)
            let isNew = agentPeers[name] == nil
            let before = peer
            peer.isAgent = true
            peer.path = comment.path
            peer.spot = CollabSpot(comment)
            agentPeers[name] = peer
            if isNew {
                output += broadcastToJoined(["type": "join", "peer": peer.json])
            } else if peer != before {
                output += broadcastToJoined(["type": "update", "peer": peer.json])
            }
        }
        return output
    }

    private func broadcastToJoined(_ message: [String: Any]) -> [Outgoing] {
        let text = Self.encode(message)
        return joinedIDs.map { Outgoing(target: .peer($0), text: text) }
    }

    /// Deletes a comment. Permission is checked by the caller (the author, the host, or OpenTraffic).
    public mutating func deleteComment(_ commentID: String) -> [Outgoing] {
        guard comments.contains(where: { $0.id == commentID }) else { return [] }
        comments.removeAll { $0.id == commentID }
        awaitingAfter.remove(commentID)
        var output = broadcastToJoined(["type": "comment-delete", "id": commentID])
        if agentWork.removeValue(forKey: commentID) != nil { output += syncAgentPeers() }
        return output
    }

    /// Text of all comments and replies.
    private var feedbackBytes: Int {
        comments.reduce(0) { total, comment in
            total + comment.text.utf8.count + comment.replies.reduce(0) { $0 + $1.text.utf8.count }
        }
    }

    /// Whether a new comment of `bytes` fits, dropping the oldest resolved comments if needed.
    private mutating func makeRoom(for bytes: Int) -> Bool {
        while comments.count >= Self.maximumComments || feedbackBytes + bytes > Self.maximumFeedbackBytes {
            guard let index = comments.firstIndex(where: \.resolved) else { return false }
            awaitingAfter.remove(comments[index].id)
            comments.remove(at: index)
        }
        return true
    }

    /// One message per person: whether they may delete it differs, and only the host sees attached errors.
    private func commentMessages(_ comment: CollabComment) -> [Outgoing] {
        joinedIDs.compactMap { id in
            guard let connection = connections[id] else { return nil }
            let message: [String: Any] = ["type": "comment", "comment": json(comment, for: connection)]
            return Outgoing(target: .peer(id), text: Self.encode(message))
        }
    }

    private func json(_ comment: CollabComment, for connection: Connection) -> [String: Any] {
        comment.json(
            canDelete: canDelete(comment, connection: connection),
            includeErrors: connection.peer.isHost,
            mine: comment.isAuthor(connection.client),
            work: agentWork[comment.id]
        )
    }

    private func canDelete(_ comment: CollabComment, connection: Connection) -> Bool {
        connection.peer.isHost || (connection.client != nil && connection.client == comment.authorClient)
    }

    private var joinedIDs: [String] {
        joinOrder.filter { connections[$0]?.joined == true }
    }

    // MARK: Messages

    private mutating func hello(_ object: [String: Any], id: String) -> [Outgoing] {
        guard var connection = connections[id] else { return [] }
        if let name = Self.sanitizedName(object["name"]) { connection.peer.name = name }
        connection.peer.path = Self.validPath(object["path"]) ?? "/"
        connection.client = Self.validClient(object["client"])
        connection.joined = true
        connections[id] = connection
        joinOrder.append(id)
        let captures = connection.peer.isHost ? captureRequests(for: id, path: connection.peer.path) : []
        var welcome: [String: Any] = [
            "type": "welcome",
            "you": connection.peer.json,
            "peers": peers.filter { $0.id != id }.map(\.json),
            "leading": leading,
            "features": ["errors": capturesErrors],
            "comments": comments.map { json($0, for: connection) },
            "uploadToken": connection.uploadToken,
        ]
        if leading {
            welcome["path"] = leadPath
            welcome["ratio"] = leadRatio
        }
        return [Outgoing(target: .peer(id), text: Self.encode(welcome))]
            + broadcast(["type": "join", "peer": connection.peer.json], except: id)
            + captures
    }

    private mutating func update(_ id: String, _ change: (inout CollabPeer) -> Void) -> [Outgoing] {
        guard var connection = connections[id] else { return [] }
        let before = connection.peer
        change(&connection.peer)
        connections[id] = connection
        guard connection.peer != before else { return [] }
        return broadcast(["type": "update", "peer": connection.peer.json], except: id)
    }

    private func leadMessage() -> [String: Any] {
        ["type": "lead", "on": true, "path": leadPath, "ratio": leadRatio]
    }

    private func broadcast(_ message: [String: Any], except id: String) -> [Outgoing] {
        [Outgoing(target: .others(except: id, path: nil), text: Self.encode(message))]
    }

    /// Whether `target` includes the connection `id`.
    public func includes(_ target: Target, _ id: String) -> Bool {
        guard let connection = connections[id] else { return false }
        switch target {
        case .peer(let peer): return peer == id
        case .others(let except, let path):
            return id != except && connection.joined && (path == nil || connection.peer.path == path)
        case .everyone(let path):
            return connection.joined && connection.peer.path == path
        }
    }

    // MARK: Validation

    static func cursorMessage(_ object: [String: Any], id: String) -> [String: Any]? {
        guard let x = unitNumber(object["x"]),
              let y = object["y"] as? Double ?? (object["y"] as? Int).map(Double.init),
              y.isFinite, (0...1_000_000).contains(y) else { return nil }
        var message: [String: Any] = ["type": "cursor", "id": id, "x": x, "y": y]
        if let anchor = object["anchor"] as? String, !anchor.isEmpty, anchor.utf8.count <= 256,
           !anchor.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
           let rx = unitNumber(object["rx"]), let ry = unitNumber(object["ry"]) {
            message["anchor"] = anchor
            message["rx"] = rx
            message["ry"] = ry
        }
        return message
    }

    static func unitNumber(_ value: Any?) -> Double? {
        guard let number = value as? Double ?? (value as? Int).map(Double.init), number.isFinite else { return nil }
        return min(1, max(0, number))
    }

    /// A same-site path, without its query string or fragment (those can hold tokens): starts with one
    /// slash, no `//`, no backslashes (browsers treat `/\x` like `//x`), no dot segments (`/.//x`
    /// normalises to `//x`), no control characters.
    public static func validPath(_ value: Any?) -> String? {
        guard let raw = value as? String, raw.hasPrefix("/"), raw.utf8.count <= 512 else { return nil }
        let path = String(raw.prefix { $0 != "?" && $0 != "#" })
        guard !path.contains("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !segments.contains(where: { segment in
            let decoded = segment.lowercased().replacingOccurrences(of: "%2e", with: ".")
            return decoded == "." || decoded == ".."
        }) else { return nil }
        return path
    }

    /// Comment or reply text: 1–1000 characters after trimming, invisible characters removed.
    static func commentText(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let text = removingInvisibleCharacters(raw, keepNewlines: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumCommentLength else { return nil }
        return text
    }

    static func environment(_ value: Any?) -> CollabEnvironment? {
        guard let object = value as? [String: Any],
              let browser = shortText(object["browser"], limit: 60),
              let os = shortText(object["os"], limit: 60),
              let viewport = shortText(object["viewport"], limit: 20),
              viewport.range(of: #"^\d{1,5}x\d{1,5}$"#, options: .regularExpression) != nil else { return nil }
        let dpr = (object["dpr"] as? Double ?? (object["dpr"] as? Int).map(Double.init)).flatMap { $0.isFinite && $0 > 0 && $0 <= 10 ? $0 : nil } ?? 1
        return CollabEnvironment(browser: browser, os: os, viewport: viewport, dpr: dpr, language: shortText(object["language"], limit: 20) ?? "")
    }

    static func errorItem(_ value: Any?) -> CollabErrorItem? {
        guard let object = value as? [String: Any],
              let kind = (object["kind"] as? String).flatMap(CollabErrorItem.Kind.init(rawValue:)),
              let message = shortText(object["message"], limit: 300).map(withoutQueries),
              let path = validPath(object["path"]) else { return nil }
        let millis = object["at"] as? Double ?? (object["at"] as? Int).map(Double.init) ?? 0
        let at = millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : Date()
        let line = (object["line"] as? Int).flatMap { (0...10_000_000).contains($0) ? $0 : nil }
        return CollabErrorItem(kind: kind, message: message, source: shortText(object["source"], limit: 200).map(withoutQueries), line: line, path: path, at: min(at, Date()))
    }

    /// Text with query strings and fragments removed from any URLs or paths in it.
    static func withoutQueries(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=[^\s?#])[?#][^\s]*"#, with: "", options: .regularExpression)
    }

    static func validClient(_ value: Any?) -> String? {
        guard let client = value as? String, (8...64).contains(client.count),
              client.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return client
    }

    /// Single-line text from the page (element label, title), cleaned and cut to `limit`.
    static func shortText(_ value: Any?, limit: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let text = removingInvisibleCharacters(raw, keepNewlines: false)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    /// Text with everything a reader can't see removed, so what an agent reads is what the host sees:
    /// control and formatting characters (zero-width, direction overrides, the invisible "tag" letters
    /// used to smuggle instructions), private-use and unassigned code points, variation selectors that
    /// can carry hidden data (all but the emoji one), and blank filler letters. Look-alike forms, such
    /// as full-width letters, become ordinary ones. Visible text in any language, and emoji, stay.
    static func removingInvisibleCharacters(_ text: String, keepNewlines: Bool) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { isVisible($0, keepingNewlines: keepNewlines) }))
    }

    private static func isVisible(_ scalar: Unicode.Scalar, keepingNewlines: Bool) -> Bool {
        if scalar == "\n" { return keepingNewlines }
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator:
            return false
        default:
            break
        }
        let value = scalar.value
        if (0xFE00...0xFE0E).contains(value) || (0xE0100...0xE01EF).contains(value) { return false }
        // Letters that render as nothing (Hangul fillers, the braille blank).
        return ![0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x180E].contains(value)
    }

    public static func sanitizedName(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let cleaned = removingInvisibleCharacters(raw, keepNewlines: false).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(32))
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 128 random bits, URL-safe.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func makeID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func generatedName() -> String {
        "\(adjectives.randomElement()!) \(animals.randomElement()!)"
    }
}

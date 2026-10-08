import Foundation

/// Someone viewing a collaborative share.
public struct CollabPeer: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var color: String
    public var path: String
    public let isHost: Bool

    var json: [String: Any] {
        ["id": id, "name": name, "color": color, "path": path, "isHost": isHost]
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
        /// Authorizes this connection's screenshot uploads; sent only to it.
        let uploadToken = CollabRoom.makeToken()
    }

    /// Whether visitors' overlays should collect browser errors for the host.
    public var capturesErrors = false
    /// Errors reported since the owner last took them (see `takeReportedErrors`).
    private var reportedErrors: [CollabErrorItem] = []
    /// Screenshot ids uploaded through the proxy, by the peer that uploaded them.
    private var attachments: [String: String] = [:]

    public init(hostName: String? = nil, comments: [CollabComment] = []) {
        self.hostName = Self.sanitizedName(hostName) ?? "Host"
        self.comments = comments
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

    /// Everyone who has joined, in join order.
    public var peers: [CollabPeer] {
        joinOrder.compactMap { id in connections[id].flatMap { $0.joined ? $0.peer : nil } }
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
                  let commentID = object["id"] as? String, let resolved = object["resolved"] as? Bool else { return [] }
            connections[id]?.lastResolve = now
            return resolveComment(commentID, resolved: resolved)
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

    /// Resolves or reopens a comment (from anyone in the session, or from OpenTraffic).
    public mutating func resolveComment(_ commentID: String, resolved: Bool) -> [Outgoing] {
        guard let index = comments.firstIndex(where: { $0.id == commentID }), comments[index].resolved != resolved else { return [] }
        comments[index].resolved = resolved
        return commentMessages(comments[index])
    }

    /// Deletes a comment. Permission is checked by the caller (the author, the host, or OpenTraffic).
    public mutating func deleteComment(_ commentID: String) -> [Outgoing] {
        guard comments.contains(where: { $0.id == commentID }) else { return [] }
        comments.removeAll { $0.id == commentID }
        let text = Self.encode(["type": "comment-delete", "id": commentID])
        return joinedIDs.map { Outgoing(target: .peer($0), text: text) }
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
        comment.json(canDelete: canDelete(comment, connection: connection), includeErrors: connection.peer.isHost)
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

    static func removingInvisibleCharacters(_ text: String, keepNewlines: Bool) -> String {
        var invisible = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x202A)!...Unicode.Scalar(0x202E)!))
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x2066)!...Unicode.Scalar(0x2069)!))
        if keepNewlines { invisible.remove("\n") }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) }))
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

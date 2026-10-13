import Foundation

/// A note pinned to an element of a shared page. Persisted per share by OpenTraffic.
public struct CollabComment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let author: String
    public let color: String
    public let path: String
    public let text: String
    public let x: Double
    public let y: Double
    public let anchor: String?
    public let rx: Double?
    public let ry: Double?
    /// A short description of the pinned element ("Start free", "text field").
    public let label: String?
    /// The page's title when the comment was made.
    public let title: String?
    public let createdAt: Date
    public var resolved: Bool
    /// Written by the host (in OpenTraffic, no notification is needed for those).
    public let fromHost: Bool
    public var replies: [CollabReply]
    /// Attachment id of a picture of the pinned element.
    public let screenshot: String?
    /// The commenter's browser, system, and window size.
    public let environment: CollabEnvironment?
    /// Browser errors the commenter ran into shortly before (when the share collects them).
    public let errors: [CollabErrorItem]
    /// The commenter's overlay id, so they can delete it later. Never sent to other people.
    let authorClient: String?

    public init(
        id: String,
        author: String,
        color: String,
        path: String,
        text: String,
        x: Double,
        y: Double,
        anchor: String? = nil,
        rx: Double? = nil,
        ry: Double? = nil,
        label: String? = nil,
        title: String? = nil,
        createdAt: Date,
        resolved: Bool = false,
        fromHost: Bool = false,
        replies: [CollabReply] = [],
        screenshot: String? = nil,
        environment: CollabEnvironment? = nil,
        errors: [CollabErrorItem] = [],
        authorClient: String? = nil
    ) {
        self.id = id
        self.author = author
        self.color = color
        self.path = path
        self.text = text
        self.x = x
        self.y = y
        self.anchor = anchor
        self.rx = rx
        self.ry = ry
        self.label = label
        self.title = title
        self.createdAt = createdAt
        self.resolved = resolved
        self.fromHost = fromHost
        self.replies = replies
        self.screenshot = screenshot
        self.environment = environment
        self.errors = errors
        self.authorClient = authorClient
    }

    enum CodingKeys: String, CodingKey {
        case id, author, color, path, text, x, y, anchor, rx, ry, label, title, createdAt, resolved, fromHost
        case replies, screenshot, environment, errors, authorClient
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        author = try container.decode(String.self, forKey: .author)
        color = try container.decode(String.self, forKey: .color)
        path = try container.decode(String.self, forKey: .path)
        text = try container.decode(String.self, forKey: .text)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        anchor = try container.decodeIfPresent(String.self, forKey: .anchor)
        rx = try container.decodeIfPresent(Double.self, forKey: .rx)
        ry = try container.decodeIfPresent(Double.self, forKey: .ry)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        resolved = try container.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        fromHost = try container.decodeIfPresent(Bool.self, forKey: .fromHost) ?? false
        replies = try container.decodeIfPresent([CollabReply].self, forKey: .replies) ?? []
        screenshot = try container.decodeIfPresent(String.self, forKey: .screenshot)
        environment = try container.decodeIfPresent(CollabEnvironment.self, forKey: .environment)
        errors = try container.decodeIfPresent([CollabErrorItem].self, forKey: .errors) ?? []
        authorClient = try container.decodeIfPresent(String.self, forKey: .authorClient)
    }

    func json(canDelete: Bool, includeErrors: Bool = true) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "author": author, "color": color, "path": path, "text": text,
            "x": x, "y": y, "createdAt": Int64(createdAt.timeIntervalSince1970 * 1000),
            "resolved": resolved, "canDelete": canDelete,
        ]
        if let anchor, let rx, let ry {
            object["anchor"] = anchor
            object["rx"] = rx
            object["ry"] = ry
        }
        if let label { object["label"] = label }
        if let title { object["title"] = title }
        object["replies"] = replies.map(\.json)
        if let screenshot { object["screenshot"] = screenshot }
        if let environment { object["env"] = environment.json }
        if includeErrors, !errors.isEmpty { object["errors"] = errors.map(\.json) }
        return object
    }
}

/// An answer in a comment's thread, from someone in the session, the host, or an app using OpenTraffic's API.
public struct CollabReply: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let author: String
    public let color: String
    public let text: String
    public let createdAt: Date
    public let fromHost: Bool
    /// The app that wrote it through OpenTraffic's API (for example "Claude Code").
    public let agent: String?

    public init(id: String, author: String, color: String, text: String, createdAt: Date, fromHost: Bool = false, agent: String? = nil) {
        self.id = id
        self.author = author
        self.color = color
        self.text = text
        self.createdAt = createdAt
        self.fromHost = fromHost
        self.agent = agent
    }

    var json: [String: Any] {
        var object: [String: Any] = [
            "id": id, "author": author, "color": color, "text": text,
            "createdAt": Int64(createdAt.timeIntervalSince1970 * 1000), "fromHost": fromHost,
        ]
        if let agent { object["agent"] = agent }
        return object
    }
}

/// The commenter's browser, as the overlay reports it.
public struct CollabEnvironment: Codable, Equatable, Sendable {
    public let browser: String
    public let os: String
    public let viewport: String
    public let dpr: Double
    public let language: String

    public init(browser: String, os: String, viewport: String, dpr: Double, language: String) {
        self.browser = browser
        self.os = os
        self.viewport = viewport
        self.dpr = dpr
        self.language = language
    }

    var json: [String: Any] {
        ["browser": browser, "os": os, "viewport": viewport, "dpr": dpr, "language": language]
    }
}

/// One browser error a visitor ran into.
public struct CollabErrorItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case error, rejection, console, network
    }

    public let kind: Kind
    public let message: String
    public let source: String?
    public let line: Int?
    public let path: String
    public let at: Date

    public init(kind: Kind, message: String, source: String? = nil, line: Int? = nil, path: String, at: Date) {
        self.kind = kind
        self.message = message
        self.source = source
        self.line = line
        self.path = path
        self.at = at
    }

    var json: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "message": message, "path": path, "at": Int64(at.timeIntervalSince1970 * 1000)]
        if let source { object["source"] = source }
        if let line { object["line"] = line }
        return object
    }
}

/// The same error seen one or more times, possibly on several pages.
public struct CollabErrorGroup: Codable, Equatable, Sendable {
    public let message: String
    public let kind: CollabErrorItem.Kind
    public let source: String?
    public var count: Int
    public let firstAt: Date
    public var lastAt: Date
    public var paths: [String]

    public init(message: String, kind: CollabErrorItem.Kind, source: String?, count: Int, firstAt: Date, lastAt: Date, paths: [String]) {
        self.message = message
        self.kind = kind
        self.source = source
        self.count = count
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.paths = paths
    }

    /// The pages it happened on, then the script it came from unless that's one of them (an
    /// inline script's source is its page): each place once.
    public var location: String {
        let pages = paths.joined(separator: ", ")
        guard let source = source?.nilIfBlank, !paths.contains(source) else { return pages }
        return pages.isEmpty ? source : "\(pages) · \(source)"
    }

    /// Adds items to `groups` (same kind, message and source count as one), newest groups first, at most `limit`.
    /// Returns the groups that are new.
    @discardableResult
    public static func merge(_ items: [CollabErrorItem], into groups: inout [CollabErrorGroup], limit: Int = 100) -> [CollabErrorGroup] {
        var added: [CollabErrorGroup] = []
        for item in items {
            if let index = groups.firstIndex(where: { $0.kind == item.kind && $0.message == item.message && $0.source == item.source }) {
                groups[index].count += 1
                groups[index].lastAt = max(groups[index].lastAt, item.at)
                if !groups[index].paths.contains(item.path), groups[index].paths.count < 10 { groups[index].paths.append(item.path) }
            } else {
                let group = CollabErrorGroup(message: item.message, kind: item.kind, source: item.source, count: 1, firstAt: item.at, lastAt: item.at, paths: [item.path])
                groups.append(group)
                added.append(group)
            }
        }
        groups.sort { $0.lastAt > $1.lastAt }
        if groups.count > limit { groups.removeLast(groups.count - limit) }
        return added
    }
}

/// Comments as text people can paste elsewhere.
public enum FeedbackExport {
    /// A Markdown checklist grouped by page.
    public static func markdown(_ comments: [CollabComment], shareName: String, date: Date = Date()) -> String {
        "## Feedback on \(shareName) — \(dateString(date))\n\n" + checklist(comments)
    }

    /// A title and body for a new GitHub issue.
    public static func githubIssue(_ comments: [CollabComment], shareName: String, date: Date = Date()) -> (title: String, body: String) {
        let open = comments.filter { !$0.resolved }.count
        let title = "Feedback from \(shareName) session (\(dateString(date)))"
        let body = "\(open) open of \(comments.count) comments from an OpenTraffic live session.\n\n" + checklist(comments)
        return (title, body)
    }

    static func checklist(_ comments: [CollabComment]) -> String {
        let pages = Dictionary(grouping: comments, by: \.path)
        let order = comments.reduce(into: [String]()) { if !$0.contains($1.path) { $0.append($1.path) } }
        return order.map { path in
            let items = pages[path, default: []].sorted { $0.createdAt < $1.createdAt }
            let heading = items.compactMap(\.title).first.map { "### `\(path)` — \($0)" } ?? "### `\(path)`"
            let lines = items.map { comment -> String in
                let box = comment.resolved ? "[x]" : "[ ]"
                let target = comment.label.map { " on “\($0)”" } ?? ""
                let text = comment.text.replacingOccurrences(of: "\n", with: "\n  ")
                return "- \(box) **\(comment.author)**\(target): \(text)"
            }
            return ([heading, ""] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Comments of one share, kept between sessions in Application Support/OpenTraffic/feedback/.
public struct FeedbackPersistence: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTraffic", isDirectory: true)
            .appendingPathComponent("feedback", isDirectory: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func load(_ id: UUID) -> [CollabComment] {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return [] }
        return (try? JSONDecoder().decode([CollabComment].self, from: data)) ?? []
    }

    public func save(_ comments: [CollabComment], for id: UUID) throws {
        if comments.isEmpty {
            delete(id)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(comments).write(to: fileURL(id), options: .atomic)
    }

    /// Screenshots attached to the share's comments.
    public func attachmentsDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: attachmentsDirectory(id))
    }
}

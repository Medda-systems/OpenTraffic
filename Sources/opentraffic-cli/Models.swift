import Foundation

// What the command-line tool reads from OpenTraffic's local API. Only the fields it shows; the API
// sends more, and newer fields are optional so it also works with older versions of the app.

struct Share: Decodable {
    let id: String
    let name: String
    let provider: String
    let kind: String
    let state: String
    let localURL: String
    let publicURL: String?
    let collaboration: Bool
    let people: [Person]
    let openComments: Int
    let comments: Int
    let hostname: String?
    let lastError: String?
    let protection: String?
    let project: String?
    let autoStart: Bool?
    let captureErrors: Bool?
    let rewriteHostHeader: Bool?
    let funnel: Bool?
    let stopsAt: Date?
    let health: [HealthCheck]?
    let branch: Bool?
    let branchName: String?
    let baseBranch: String?
}

struct Person: Decodable {
    let name: String
    let path: String
    let isHost: Bool
}

struct HealthCheck: Decodable {
    let kind: String
    let title: String
    let state: String
    let detail: String?
}

struct Comment: Decodable {
    let id: String
    let author: String
    let path: String
    let label: String?
    let text: String
    let createdAt: Date
    let resolved: Bool
    let replies: [Reply]
    let hasScreenshot: Bool
    let environment: Environment?
    // Absent from older versions of OpenTraffic.
    let status: String?
    let claimedBy: String?
    let progress: String?
    let resolvedBy: String?
    let hasAfterScreenshot: Bool?

    struct Reply: Decodable {
        let author: String
        let text: String
        let createdAt: Date
        let agent: String?
    }

    struct Environment: Decodable {
        let browser: String
        let os: String
        let viewport: String
    }
}

struct ErrorGroup: Decodable {
    let message: String
    let kind: String
    let source: String?
    let count: Int
    let lastAt: Date
    let paths: [String]

    /// The pages it happened on, then the script it came from unless that's one of them (an
    /// inline script's source is its page): each place once.
    var location: String {
        let pages = paths.joined(separator: ", ")
        guard let source = source?.nonEmpty, !paths.contains(source) else { return pages }
        return pages.isEmpty ? source : "\(pages) · \(source)"
    }
}

struct LocalService: Decodable {
    let port: Int
    let url: String
    let title: String?
    let process: String?
    let statusCode: Int?
    let upSince: Date?
    let sharedAs: String?
}

struct Tool: Decodable {
    let name: String
    let installed: Bool
    let path: String?
    let version: String?
    let installable: Bool
}

struct ToolsBody: Decodable { let tools: [Tool] }

struct Project: Decodable {
    let name: String
    let shares: [String]
    let running: Int
}

struct Zone: Decodable {
    let id: String
    let name: String
}

struct AppStatus: Decodable {
    let version: String
    let shares: Int
    let running: Int
    let providers: [Provider]
    let publishesWithoutAsking: Bool

    struct Provider: Decodable {
        let name: String
        let ready: Bool
        let detail: String?
        /// Ready, but likely to fail anyway (newer versions of OpenTraffic).
        let warning: String?
    }
}

struct Protection: Decodable {
    let mode: String
    let username: String?
    let password: String?
    let emails: [String]
    /// The address with the password built in (temporary and OpenTunnel shares).
    let link: String?
}

struct Event: Decodable {
    let seq: Int
    let type: String
    let at: Date
    let share: ShareRef
    let comment: Comment?
    let peer: Person?
    let error: ErrorGroup?

    struct ShareRef: Decodable {
        let name: String
        let publicURL: String?
    }
}

struct SharesBody: Decodable { let shares: [Share] }
struct CommentsBody: Decodable { let comments: [Comment] }
struct ErrorsBody: Decodable { let errors: [ErrorGroup] }
struct LogsBody: Decodable { let lines: [String] }
struct ServicesBody: Decodable { let services: [LocalService] }
struct ProjectsBody: Decodable { let projects: [Project] }
struct ZonesBody: Decodable { let zones: [Zone] }
struct EventsBody: Decodable {
    let events: [Event]
    let next: Int
}

enum JSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }()

    static func encode(_ object: [String: Any?]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object.compactMapValues { $0 }, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// The API's JSON, indented for reading.
    static func pretty(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: pretty, as: UTF8.self)
    }
}

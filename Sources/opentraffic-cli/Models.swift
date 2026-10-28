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
    /// A Mac app share's app (newer versions of OpenTraffic).
    let macApp: SharedMacApp?
}

struct SharedMacApp: Decodable {
    let path: String
    let name: String
    /// "copy" or "empty".
    let data: String
    let state: String?
    let viewers: Int?
    let warning: String?
    let error: String?
    /// Who may control the app (newer versions of OpenTraffic).
    let control: MacAppControl?
    /// Rebuilding it from its sources (newer versions; nil when the share doesn't rebuild it).
    let build: MacAppBuild?
    /// An installed app or another developer's: never rebuilt (absent from older OpenTraffic).
    let installed: Bool?
}

/// Rebuilding a shared Mac app when its sources change.
struct MacAppBuild: Decodable {
    /// "idle", "building", or "failed".
    let state: String
    /// `failed`: why, with the compiler's first error.
    let message: String?
    /// The latest build's full output.
    let log: String?
    /// What builds it.
    let command: String?
}

/// Who may control a shared Mac app: the mode, and with ask to control, who has it and who asks.
struct MacAppControl: Decodable {
    /// "everyone", "watchOnly", or "askToControl".
    let mode: String
    let holder: ControlViewer?
    /// Oldest first.
    let requests: [ControlViewer]
}

/// A viewer asking for control of a shared Mac app, or the one who has it.
struct ControlViewer: Decodable {
    /// Its number on the share (what `control … allow` takes); nil for a holder whose page is away.
    let viewer: Int?
    let name: String?
    let since: Date
    /// The holder: whether its page is connected.
    let connected: Bool?
}

/// A Mac app being built on this Mac, as `GET /v1/services` lists it.
struct MacAppEntry: Decodable {
    let kind: String
    let name: String
    let bundle: String
    let projectDirectory: String?
    let running: Bool
    let builtAt: Date?
    let sharedAs: String?
    /// "iPhone 17 Simulator" for an app in a booted simulator.
    let device: String?
    /// An installed app or another developer's that is running (older OpenTraffic: absent).
    let installed: Bool?
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
    let context: Context?
    let edits: [Edit]?
    let area: Area?

    struct Context: Decodable {
        let selector: String?
        let component: String?
        let source: String?
    }

    struct Edit: Decodable {
        let kind: String
        let property: String?
        let old: String
        let new: String
    }

    struct Area: Decodable {
        let width: Double
        let height: Double
    }

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
    /// `control.requested`: who asks.
    let viewer: ControlViewer?
    /// `build.*`: how the build went.
    let build: MacAppBuild?

    struct ShareRef: Decodable {
        let name: String
        let publicURL: String?
    }
}

struct SharesBody: Decodable { let shares: [Share] }
struct CommentsBody: Decodable { let comments: [Comment] }
struct ErrorsBody: Decodable { let errors: [ErrorGroup] }
struct LogsBody: Decodable { let lines: [String] }
struct ServicesBody: Decodable {
    let services: [LocalService]
    /// Absent from older versions of OpenTraffic.
    let apps: [MacAppEntry]?
}
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

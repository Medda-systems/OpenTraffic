import Foundation

/// An HTTP response from the local API, before it's written to a connection.
struct APIResponse: Sendable {
    var status: Int
    var headers: [(name: String, value: String)]
    var body: Data

    init(status: Int, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ value: some Encodable, status: Int = 200) -> APIResponse {
        APIResponse(status: status, headers: [("content-type", "application/json")], body: APIJSON.encode(value))
    }

    static func error(_ error: OpenTrafficAPIError) -> APIResponse {
        json(ErrorBody(error: .init(code: error.code, message: error.message)), status: error.status)
    }

    private struct ErrorBody: Encodable {
        struct Detail: Encodable {
            let code: String
            let message: String
        }
        let error: Detail
    }
}

extension OpenTrafficAPIError {
    static func methodNotAllowed(_ method: String) -> OpenTrafficAPIError {
        OpenTrafficAPIError(status: 405, code: "method_not_allowed", message: "\(method) isn't supported here")
    }

    static let routeNotFound = OpenTrafficAPIError.notFound("No such endpoint")
    static let internalError = OpenTrafficAPIError(status: 500, code: "internal", message: "Something went wrong in OpenTraffic")
}

/// The REST routes of specs/collab-plan.md, "Local API, MCP and webhooks". Requests reach it already authenticated.
struct APIRouter: Sendable {
    static let maximumWait: TimeInterval = 60
    static let maximumLogLines = 2000
    static let maximumReplyLength = 1000

    let backend: any OpenTrafficAPIBackend
    let events: APIEventLog
    let mcp: MCPServer

    init(backend: any OpenTrafficAPIBackend, events: APIEventLog) {
        self.backend = backend
        self.events = events
        mcp = MCPServer(backend: backend, events: events)
    }

    /// `scope`: the caller is a run of the agent command, limited to one comment.
    func respond(method: String, uri: String, body: Data, client: String, scope: AgentRunScope? = nil) async -> APIResponse {
        do {
            return try await route(method: method, uri: uri, body: body, client: client, scope: scope)
        } catch let error as OpenTrafficAPIError {
            return .error(error)
        } catch {
            return .error(.internalError)
        }
    }

    private func route(method: String, uri: String, body: Data, client: String, scope: AgentRunScope?) async throws -> APIResponse {
        let path = String(uri.prefix { $0 != "?" && $0 != "#" })
        let query = URLComponents(string: uri)?.queryItems ?? []
        func parameter(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard let segments = Self.segments(of: path) else { throw OpenTrafficAPIError.badRequest("Malformed path") }
        func allow(_ allowed: String) throws {
            guard method == allowed else { throw OpenTrafficAPIError.methodNotAllowed(method) }
        }

        if segments == ["mcp"] {
            try allow("POST")
            return await mcp.respond(to: body, client: client, scope: scope)
        }
        if let scope { try await check(scope, method: method, segments: segments) }
        if segments == ["v1", "events"] {
            try allow("GET")
            let since = try parameter("since").map { try Self.integer($0, name: "since") } ?? 0
            let wait = try parameter("wait").map { try Self.integer($0, name: "wait") } ?? 0
            let result = await events.wait(since: since, timeout: min(max(TimeInterval(wait), 0), Self.maximumWait))
            return .json(EventsBody(events: result.events, next: result.next))
        }
        if segments == ["v1", "status"] {
            try allow("GET")
            guard let status = await backend.status() else { throw OpenTrafficAPIError(status: 501, code: "not_supported", message: "This version of OpenTraffic doesn't report its status.") }
            return .json(status)
        }
        if segments == ["v1", "services"] {
            try allow("GET")
            return .json(ServicesBody(services: await backend.localServices()))
        }
        if segments == ["v1", "zones"] {
            try allow("GET")
            return .json(ZonesBody(zones: try await backend.zones()))
        }
        if segments == ["v1", "projects"] {
            try allow("GET")
            return .json(ProjectsBody(projects: await backend.projects()))
        }
        if segments.count == 4, segments[0] == "v1", segments[1] == "projects" {
            try allow("POST")
            switch segments[3] {
            case "start": return .json(try await backend.startProject(segments[2], client: client))
            case "stop": return .json(try await backend.stopProject(segments[2]))
            default: throw OpenTrafficAPIError.routeNotFound
            }
        }
        if segments == ["v1", "tools"] {
            try allow("GET")
            return .json(ToolsBody(tools: await backend.tools()))
        }
        if segments.count == 4, segments[0] == "v1", segments[1] == "tools", segments[3] == "install" {
            try allow("POST")
            return .json(try await backend.installTool(segments[2]))
        }
        if segments == ["v1", "shares"] {
            if method == "GET" { return .json(SharesBody(shares: await backend.listShares())) }
            try allow("POST")
            let request = try Self.decode(APIShareRequest.self, from: body)
            try Self.validate(request)
            return .json(try await backend.createShare(request, client: client))
        }
        guard segments.count >= 3, segments[0] == "v1", segments[1] == "shares" else { throw OpenTrafficAPIError.routeNotFound }
        let share = segments[2]
        let rest = Array(segments.dropFirst(3))

        switch rest {
        case []:
            switch method {
            case "GET": return .json(try await backend.share(share))
            case "PATCH": return .json(try await backend.updateShare(share, try Self.decode(APIShareUpdate.self, from: body), client: client))
            case "DELETE":
                try await backend.deleteShare(share)
                return .json(DeletedBody(deleted: true))
            default: throw OpenTrafficAPIError.methodNotAllowed(method)
            }
        case ["restart"]:
            try allow("POST")
            return .json(try await backend.restartShare(share, client: client))
        case ["protection"]:
            switch method {
            case "GET": return .json(try await backend.protection(share))
            case "PUT": return .json(try await backend.setProtection(share, try Self.decode(APIProtectionRequest.self, from: body)))
            default: throw OpenTrafficAPIError.methodNotAllowed(method)
            }
        case ["password"]:
            try allow("POST")
            return .json(try await backend.regeneratePassword(share))
        case ["start"]:
            try allow("POST")
            return .json(try await backend.startShare(share, client: client))
        case ["stop"]:
            try allow("POST")
            return .json(try await backend.stopShare(share))
        case ["comments"]:
            try allow("GET")
            let status = try parameter("status").map { value in
                guard let status = APICommentStatus(rawValue: value) else {
                    throw OpenTrafficAPIError.badRequest("status must be open, resolved, or all")
                }
                return status
            } ?? .open
            let comments = try await backend.comments(share, status: status)
            return .json(CommentsBody(comments: scope.map { scope in comments.filter { $0.id == scope.commentID } } ?? comments))
        case ["errors"]:
            try allow("GET")
            return .json(ErrorsBody(errors: try await backend.errors(share)))
        case ["logs"]:
            try allow("GET")
            let lines = try parameter("lines").map { try Self.integer($0, name: "lines") } ?? 200
            return .json(LogsBody(lines: try await backend.logs(share, lines: min(max(lines, 1), Self.maximumLogLines))))
        default:
            break
        }

        guard rest.count >= 2, rest[0] == "comments" else { throw OpenTrafficAPIError.routeNotFound }
        let comment = rest[1]
        switch Array(rest.dropFirst(2)) {
        case []:
            switch method {
            case "PATCH":
                let update = try Self.decode(ResolveBody.self, from: body)
                return .json(try await backend.resolveComment(share, commentID: comment, resolved: update.resolved, client: client))
            case "DELETE":
                try await backend.deleteComment(share, commentID: comment)
                return .json(DeletedBody(deleted: true))
            default:
                throw OpenTrafficAPIError.methodNotAllowed(method)
            }
        case ["replies"]:
            try allow("POST")
            let reply = try Self.decode(ReplyBody.self, from: body)
            let text = try Self.validReply(reply.text)
            return .json(try await backend.reply(share, commentID: comment, text: text, client: client))
        case ["claim"]:
            switch method {
            case "POST":
                let claim = try Self.decode(ClaimBody.self, from: body)
                return .json(try await backend.claimComment(share, commentID: comment, progress: claim.progress, client: client))
            case "DELETE":
                return .json(try await backend.releaseComment(share, commentID: comment, client: client))
            default:
                throw OpenTrafficAPIError.methodNotAllowed(method)
            }
        case ["screenshot"]:
            try allow("GET")
            let after: Bool
            switch parameter("which") ?? "before" {
            case "before": after = false
            case "after": after = true
            default: throw OpenTrafficAPIError.badRequest("which must be before or after")
            }
            let image = after
                ? try await backend.afterScreenshot(share, commentID: comment)
                : try await backend.screenshot(share, commentID: comment)
            return APIResponse(status: 200, headers: [("content-type", image.contentType)], body: image.data)
        default:
            throw OpenTrafficAPIError.routeNotFound
        }
    }

    /// A run of the agent command may only read its share's comments (just its own comes back), and read,
    /// claim, reply to, and resolve its own comment.
    private func check(_ scope: AgentRunScope, method: String, segments: [String]) async throws {
        guard segments.count >= 4, segments[0] == "v1", segments[1] == "shares", segments[3] == "comments",
              (try? await backend.share(segments[2]))?.id == scope.shareID else { throw AgentRunScope.refused() }
        let rest = Array(segments.dropFirst(4))
        if rest.isEmpty, method == "GET" { return }
        guard rest.first == scope.commentID else { throw AgentRunScope.refused() }
        let allowed: [(String, [String])] = [
            ("PATCH", []), ("POST", ["replies"]), ("POST", ["claim"]), ("DELETE", ["claim"]), ("GET", ["screenshot"]),
        ]
        guard allowed.contains(where: { $0.0 == method && $0.1 == Array(rest.dropFirst()) }) else { throw AgentRunScope.refused() }
    }

    // MARK: Bodies

    private struct SharesBody: Encodable { let shares: [APIShare] }
    private struct CommentsBody: Encodable { let comments: [APIComment] }
    private struct ErrorsBody: Encodable { let errors: [CollabErrorGroup] }
    private struct LogsBody: Encodable { let lines: [String] }
    private struct EventsBody: Encodable {
        let events: [APIEvent]
        let next: Int
    }
    private struct ResolveBody: Decodable { let resolved: Bool }
    private struct ServicesBody: Encodable { let services: [APILocalService] }
    private struct ZonesBody: Encodable { let zones: [APIZone] }
    private struct ProjectsBody: Encodable { let projects: [APIProject] }
    private struct ToolsBody: Encodable { let tools: [APITool] }
    private struct DeletedBody: Encodable { let deleted: Bool }
    private struct ReplyBody: Decodable { let text: String }
    private struct ClaimBody: Decodable { let progress: String? }

    // MARK: Helpers

    /// Path segments, percent-decoded one by one so an encoded "/" stays inside its segment.
    static func segments(of path: String) -> [String]? {
        var segments: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = raw.removingPercentEncoding else { return nil }
            segments.append(segment)
        }
        return segments
    }

    static func integer(_ value: String, name: String) throws -> Int {
        guard let number = Int(value) else { throw OpenTrafficAPIError.badRequest("\(name) must be a whole number") }
        return number
    }

    static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try APIJSON.decoder().decode(type, from: body.isEmpty ? Data("{}".utf8) : body)
        } catch DecodingError.keyNotFound(let key, _) {
            throw OpenTrafficAPIError.badRequest("Missing \(key.stringValue)")
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw OpenTrafficAPIError.badRequest(field.isEmpty ? "Expected a JSON object" : "\(field) has the wrong type")
        } catch {
            throw OpenTrafficAPIError.badRequest("The body isn't valid JSON")
        }
    }

    static func validate(_ request: APIShareRequest) throws {
        guard request.port != nil || request.url != nil else { throw OpenTrafficAPIError.badRequest("Give a port or a url") }
        if let port = request.port, !(1...65535).contains(port) { throw OpenTrafficAPIError.badRequest("port must be between 1 and 65535") }
        // The names and aliases the app's share handler maps, in any case.
        if let provider = request.provider,
           !["quick", "cloudflare", "temporary", "tailscale", "tailnet", "ngrok", "opentunnel", "domain"].contains(provider.lowercased()) {
            throw OpenTrafficAPIError.badRequest("provider must be quick, opentunnel, tailscale, ngrok, or domain")
        }
        if request.provider?.lowercased() == "domain", request.hostname?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            throw OpenTrafficAPIError.badRequest("A domain share needs a hostname")
        }
    }

    static func validReply(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenTrafficAPIError.badRequest("text is empty") }
        guard text.count <= maximumReplyLength else {
            throw OpenTrafficAPIError.badRequest("text is longer than \(maximumReplyLength) characters")
        }
        return text
    }
}

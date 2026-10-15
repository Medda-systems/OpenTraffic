import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import OpenTrafficCore

// A fake app behind the local API, and helpers to talk to the server over HTTP.

final class FakeAPIBackend: OpenTrafficAPIBackend, @unchecked Sendable {
    static let orbitID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let screenshot = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private let lock = NSLock()
    private var shares: [APIShare]
    private var comments: [CollabComment]
    private var recordedClients: [String] = []
    private var recordedTrust: [Bool] = []
    private var declineShares = false

    init() {
        shares = [APIShare(
            id: Self.orbitID, name: "Orbit", provider: "cloudflare", kind: "quick", state: "running",
            localURL: "http://127.0.0.1:5173", publicURL: "https://orbit.trycloudflare.com", collaboration: true,
            people: [APIPerson(name: "Ada", path: "/", isHost: false)], openComments: 1, comments: 2
        )]
        let date = Date(timeIntervalSince1970: 1_760_000_000.25)
        comments = [
            CollabComment(id: "c1", author: "Ada", color: "#f00", path: "/pricing", text: "Button is cut off", x: 0.5, y: 0.2,
                          label: "Start free", title: "Pricing", createdAt: date, screenshot: "shot1",
                          environment: CollabEnvironment(browser: "Safari 19", os: "macOS", viewport: "1280x800", dpr: 2, language: "en")),
            CollabComment(id: "c2", author: "Ada", color: "#f00", path: "/", text: "Typo", x: 0.1, y: 0.1, createdAt: date, resolved: true),
        ]
    }

    var shareRef: APIShareRef { APIShareRef(id: Self.orbitID, name: "Orbit", publicURL: "https://orbit.trycloudflare.com") }

    func comment(_ id: String) -> APIComment? {
        lock.withLock { comments.first { $0.id == id }.map { APIComment($0, shareID: Self.orbitID) } }
    }

    private func find(_ ref: String) throws -> APIShare {
        let share = lock.withLock { shares.first { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame || $0.name.caseInsensitiveCompare(ref) == .orderedSame } }
        guard let share else { throw OpenTrafficAPIError.notFound("No share named \(ref)") }
        return share
    }

    /// Client names passed to calls that take one, in order.
    var clients: [String] { lock.withLock { recordedClients } }

    /// Whether each of those calls ran as trusted (OpenTraffic's own tools, over the private socket).
    var trust: [Bool] { lock.withLock { recordedTrust } }

    func declineNewShares() {
        lock.withLock { declineShares = true }
    }

    private func record(_ client: String) {
        let trusted = APITrust.isTrusted
        lock.withLock {
            recordedClients.append(client)
            recordedTrust.append(trusted)
        }
    }

    func listShares() async -> [APIShare] { lock.withLock { shares } }

    func createShare(_ request: APIShareRequest, client: String) async throws -> APIShare {
        record(client)
        if lock.withLock({ declineShares }) { throw OpenTrafficAPIError.denied("The user declined") }
        let share = APIShare(
            id: UUID(), name: request.name ?? "localhost:\(request.port ?? 0)", provider: request.provider == "ngrok" ? "ngrok" : "cloudflare",
            kind: request.provider ?? "quick", state: "running", localURL: request.url ?? "http://127.0.0.1:\(request.port ?? 0)",
            publicURL: "https://new.trycloudflare.com", collaboration: request.collaboration ?? false, people: [], openComments: 0, comments: 0
        )
        lock.withLock { shares.append(share) }
        return share
    }

    func startShare(_ share: String, client: String) async throws -> APIShare {
        record(client)
        return try find(share)
    }

    func stopShare(_ share: String) async throws -> APIShare {
        let found = try find(share)
        return APIShare(id: found.id, name: found.name, provider: found.provider, kind: found.kind, state: "stopped", localURL: found.localURL,
                        publicURL: nil, collaboration: found.collaboration, people: [], openComments: found.openComments, comments: found.comments)
    }

    func comments(_ share: String, status: APICommentStatus) async throws -> [APIComment] {
        let id = try find(share).id
        return lock.withLock {
            comments.filter { status == .all || $0.resolved == (status == .resolved) }.map { APIComment($0, shareID: id) }
        }
    }

    func screenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String) {
        _ = try find(share)
        guard let comment = comment(commentID) else { throw OpenTrafficAPIError.notFound("No comment \(commentID)") }
        guard comment.hasScreenshot else { throw OpenTrafficAPIError.notFound("That comment has no screenshot") }
        return (Self.screenshot, "image/png")
    }

    func resolveComment(_ share: String, commentID: String, resolved: Bool) async throws -> APIComment {
        let id = try find(share).id
        return try lock.withLock {
            guard let index = comments.firstIndex(where: { $0.id == commentID }) else { throw OpenTrafficAPIError.notFound("No comment \(commentID)") }
            comments[index].resolved = resolved
            return APIComment(comments[index], shareID: id)
        }
    }

    func reply(_ share: String, commentID: String, text: String, client: String) async throws -> APIComment {
        let id = try find(share).id
        record(client)
        return try lock.withLock {
            guard let index = comments.firstIndex(where: { $0.id == commentID }) else { throw OpenTrafficAPIError.notFound("No comment \(commentID)") }
            comments[index].replies.append(CollabReply(id: "r\(comments[index].replies.count + 1)", author: client, color: "#888", text: text,
                                                       createdAt: Date(), fromHost: true, agent: client))
            return APIComment(comments[index], shareID: id)
        }
    }

    func errors(_ share: String) async throws -> [CollabErrorGroup] {
        _ = try find(share)
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        return [CollabErrorGroup(message: "TypeError: x is undefined", kind: .error, source: "app.js", count: 3, firstAt: at, lastAt: at, paths: ["/"])]
    }

    func logs(_ share: String, lines: Int) async throws -> [String] {
        _ = try find(share)
        return Array((1...500).map { "line \($0)" }.suffix(lines))
    }

    // What the app's windows can do.
    private var protectionMode = "none"

    func status() async -> APIAppStatus? {
        APIAppStatus(version: "9.9.9", shares: lock.withLock { shares.count }, running: 1,
                     providers: [APIProviderStatus(name: "quick", ready: true, detail: nil, warning: QuickTunnelNetwork.filtered(to: nil).warning), APIProviderStatus(name: "ngrok", ready: false, detail: "ngrok isn't installed.")],
                     publishesWithoutAsking: false)
    }

    func updateShare(_ share: String, _ update: APIShareUpdate, client: String) async throws -> APIShare {
        let found = try find(share)
        let renamed = APIShare(id: found.id, name: update.name ?? found.name, provider: found.provider, kind: found.kind, state: found.state,
                               localURL: update.url ?? found.localURL, publicURL: found.publicURL, collaboration: update.collaboration ?? found.collaboration,
                               people: found.people, openComments: found.openComments, comments: found.comments, project: update.project?.isEmpty == true ? nil : update.project)
        lock.withLock { shares = shares.map { $0.id == found.id ? renamed : $0 } }
        return renamed
    }

    func restartShare(_ share: String, client: String) async throws -> APIShare {
        record(client)
        return try find(share)
    }

    func deleteShare(_ share: String) async throws {
        let found = try find(share)
        lock.withLock { shares.removeAll { $0.id == found.id } }
    }

    func protection(_ share: String) async throws -> APIProtection {
        _ = try find(share)
        let mode = lock.withLock { protectionMode }
        return APIProtection(mode: mode, username: mode == "password" ? "guest" : nil, password: mode == "password" ? "s3cret" : nil, emails: [])
    }

    func setProtection(_ share: String, _ request: APIProtectionRequest) async throws -> APIProtection {
        guard ["none", "password"].contains(request.mode) else { throw OpenTrafficAPIError.badRequest("This share can be protected with: password.") }
        lock.withLock { protectionMode = request.mode }
        return try await protection(share)
    }

    func regeneratePassword(_ share: String) async throws -> APIProtection {
        _ = try find(share)
        return APIProtection(mode: "password", username: "guest", password: "n3w", emails: [])
    }

    func deleteComment(_ share: String, commentID: String) async throws {
        _ = try find(share)
        try lock.withLock {
            guard comments.contains(where: { $0.id == commentID }) else { throw OpenTrafficAPIError.notFound("No comment \(commentID)") }
            comments.removeAll { $0.id == commentID }
        }
    }

    func localServices() async -> [APILocalService] {
        [APILocalService(port: 5173, url: "http://localhost:5173", title: "Orbit", process: "node", statusCode: 200, upSince: Date(timeIntervalSince1970: 1_760_000_000), sharedAs: "Orbit")]
    }

    func projects() async -> [APIProject] {
        [APIProject(name: "Demo", shares: ["Orbit"], running: 1)]
    }

    func startProject(_ name: String, client: String) async throws -> APIProject {
        record(client)
        guard name.caseInsensitiveCompare("Demo") == .orderedSame else { throw OpenTrafficAPIError.notFound("No project named “\(name)”.") }
        return APIProject(name: "Demo", shares: ["Orbit"], running: 1)
    }

    func stopProject(_ name: String) async throws -> APIProject {
        APIProject(name: "Demo", shares: ["Orbit"], running: 0)
    }

    func zones() async throws -> [APIZone] {
        [APIZone(id: "z1", name: "example.com")]
    }
}

/// A running API server with a fake backend.
struct APIHarness {
    static let token = "test-token-0123456789abcdefghijklmnopqrstuvwxyz"

    let server: LocalAPIServer
    let backend: FakeAPIBackend
    let events: APIEventLog
    let port: Int
    let session: URLSession

    static func start() async throws -> APIHarness {
        let backend = FakeAPIBackend()
        let events = APIEventLog()
        let server = LocalAPIServer(port: 0, token: token, backend: backend, events: events)
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return APIHarness(server: server, backend: backend, events: events, port: port, session: URLSession(configuration: configuration))
    }

    func stop() async {
        await server.stop()
    }

    func request(_ method: String, _ path: String, json: String? = nil, token: String? = APIHarness.token, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    /// A JSON object response.
    func object(_ method: String, _ path: String, json: String? = nil) async throws -> [String: Any] {
        let (data, _) = try await request(method, path, json: json)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func mcp(_ message: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try await request("POST", "/mcp", json: message, headers: headers)
    }

    /// The `result` of a JSON-RPC call.
    func mcpResult(_ method: String, params: String = "{}", id: Int = 1) async throws -> [String: Any] {
        let (data, response) = try await mcp(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
        #expect(response.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? Int == id)
        return try #require(object["result"] as? [String: Any])
    }

    func callTool(_ name: String, _ arguments: String = "{}") async throws -> [String: Any] {
        try await mcpResult("tools/call", params: #"{"name":"\#(name)","arguments":\#(arguments)}"#)
    }
}

/// Sends raw bytes and returns everything the server answers until it closes the connection.
func rawHTTP(port: Int, _ request: String) async throws -> String {
    let collector = ResponseCollector()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
        }
        .connect(host: "127.0.0.1", port: port)
        .get()
    try await channel.writeAndFlush(ByteBuffer(string: request))
    try await channel.closeFuture.get()
    return collector.text
}

private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        lock.withLock { bytes += buffer.readableBytesView }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Polls `condition` until it holds or `seconds` pass.
func eventually(_ seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

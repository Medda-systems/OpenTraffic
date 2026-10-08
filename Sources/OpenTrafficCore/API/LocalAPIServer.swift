import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os

/// OpenTraffic's local API: REST under `/v1`, MCP at `/mcp`, on 127.0.0.1 only.
///
/// Every request needs the bearer token, a `Host` naming this server on the loopback address, and no
/// `Origin` header, so web pages (including DNS-rebinding ones) can't use it. Handlers run as tasks,
/// so a long poll holds only its own connection. See specs/collab-plan.md, "Local API, MCP and webhooks".
public final class LocalAPIServer: Sendable {
    public static let defaultPort = 47777
    public static let maximumBodyBytes = 64 * 1024
    static let defaultClientName = "API client"

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private struct State {
        var token: String
        var port: Int?
        var server: Channel?
        var connections: [ObjectIdentifier: Channel] = [:]
    }

    private let requestedPort: Int
    private let state: OSAllocatedUnfairLock<State>
    let router: APIRouter

    public init(port: Int, token: String, backend: any OpenTrafficAPIBackend, events: APIEventLog) {
        requestedPort = port
        state = OSAllocatedUnfairLock(initialState: State(token: token))
        router = APIRouter(backend: backend, events: events)
    }

    /// The port it listens on, once started.
    public var port: Int? { state.withLock { $0.port } }

    /// Replaces the token; requests already being handled finish normally.
    public func setToken(_ token: String) {
        state.withLock { $0.token = token }
    }

    /// Starts listening and returns the port (pass 0 to the initializer for any free port).
    public func start() async throws -> Int {
        if let port { return port }
        let bootstrap = ServerBootstrap(group: Self.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(APIConnectionHandler(server: self))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: requestedPort).get()
        let port = channel.localAddress?.port ?? requestedPort
        state.withLock {
            $0.server = channel
            $0.port = port
        }
        return port
    }

    /// Stops listening and closes open connections, including long polls.
    public func stop() async {
        let channels = state.withLock { state -> [Channel] in
            let all = [state.server].compactMap { $0 } + Array(state.connections.values)
            state.server = nil
            state.port = nil
            state.connections = [:]
            return all
        }
        for channel in channels { try? await channel.close() }
    }

    // MARK: Connections

    fileprivate func opened(_ channel: Channel) {
        state.withLock { $0.connections[ObjectIdentifier(channel)] = channel }
    }

    fileprivate func closed(_ channel: Channel) {
        _ = state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    /// Why a request may not be answered, if it may not.
    fileprivate func rejection(of head: HTTPRequestHead) -> APIResponse? {
        let (token, port) = state.withLock { ($0.token, $0.port) }
        if head.headers.contains(name: "origin") {
            return .error(OpenTrafficAPIError(status: 403, code: "forbidden", message: "Requests from web pages aren't accepted"))
        }
        let hosts = head.headers[canonicalForm: "host"].map { $0.lowercased() }
        guard let port, hosts.count == 1, hosts[0] == "127.0.0.1:\(port)" || hosts[0] == "localhost:\(port)" else {
            return .error(OpenTrafficAPIError(status: 403, code: "forbidden", message: "Host must be 127.0.0.1 or localhost with this port"))
        }
        let authorization = head.headers[canonicalForm: "authorization"]
        guard authorization.count == 1, Self.matchesToken(String(authorization[0]), token: token) else {
            var response = APIResponse.error(OpenTrafficAPIError(status: 401, code: "unauthorized", message: "Missing or wrong API token"))
            response.headers.append(("www-authenticate", "Bearer"))
            return response
        }
        return nil
    }

    /// Compares `Bearer <token>` in time that doesn't depend on where the values differ.
    static func matchesToken(_ authorization: String, token: String) -> Bool {
        let prefix = "bearer "
        guard !token.isEmpty, authorization.count > prefix.count, authorization.prefix(prefix.count).lowercased() == prefix else { return false }
        let given = Array(authorization.utf8.dropFirst(prefix.utf8.count))
        let expected = Array(token.utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for index in 0..<expected.count {
            difference |= expected[index] ^ (index < given.count ? given[index] : 0)
        }
        return difference == 0
    }

    /// `X-OpenTraffic-Client`, printable and at most 40 characters.
    static func clientName(_ header: String?) -> String {
        guard let header else { return defaultClientName }
        let printable = header.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: false
            default: true
            }
        }
        let name = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? defaultClientName : String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - HTTP

/// One client connection. Requests arrive one at a time (the pipelining handler holds the next one
/// back until the response is written); each is answered by a task that hops back to the loop.
private final class APIConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: LocalAPIServer
    private var context: ChannelHandlerContext?
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    /// The request was already answered (body too large) and the rest of it is ignored.
    private var discarding = false
    private var task: Task<Void, Never>?

    init(server: LocalAPIServer) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        server.opened(context.channel)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.closed(context.channel)
        task?.cancel()
        task = nil
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
            discarding = false
            if let length = head.headers.first(name: "content-length").flatMap(Int.init), length > LocalAPIServer.maximumBodyBytes {
                rejectTooLarge(head: head)
            }
        case .body(var buffer):
            guard !discarding, let head else { return }
            if body.readableBytes + buffer.readableBytes > LocalAPIServer.maximumBodyBytes {
                rejectTooLarge(head: head)
            } else {
                body.writeBuffer(&buffer)
            }
        case .end:
            guard let head, !discarding else { return }
            self.head = nil
            if let rejection = server.rejection(of: head) {
                write(rejection, for: head)
                return
            }
            let router = server.router
            let request = (method: head.method.rawValue, uri: head.uri, body: Data(body.readableBytesView))
            let client = LocalAPIServer.clientName(head.headers.first(name: "x-opentraffic-client"))
            let loop = context.eventLoop
            let handler = NIOLoopBound(self, eventLoop: loop)
            task = Task {
                let response = await router.respond(method: request.method, uri: request.uri, body: request.body, client: client)
                loop.execute {
                    handler.value.task = nil
                    handler.value.write(response, for: head)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func rejectTooLarge(head: HTTPRequestHead) {
        discarding = true
        let error = OpenTrafficAPIError(status: 413, code: "too_large", message: "The body is larger than 64 KB")
        write(.error(error), for: head, close: true)
    }

    private func write(_ response: APIResponse, for request: HTTPRequestHead, close: Bool = false) {
        guard let context, context.channel.isActive else { return }
        let keepAlive = request.isKeepAlive && !close
        var headers = HTTPHeaders()
        for header in response.headers { headers.add(name: header.name, value: header.value) }
        headers.replaceOrAdd(name: "content-length", value: String(response.body.count))
        headers.replaceOrAdd(name: "cache-control", value: "no-store")
        if !keepAlive {
            headers.replaceOrAdd(name: "connection", value: "close")
        } else if request.version.minor == 0 {
            headers.replaceOrAdd(name: "connection", value: "keep-alive")
        }
        let status = HTTPResponseStatus(statusCode: response.status)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: request.version, status: status, headers: headers))), promise: nil)
        if !response.body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: response.body)))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }
}

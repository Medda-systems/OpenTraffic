import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
@testable import OpenTrafficCore

// An end-to-end check of the collaboration proxy against a real local HTTP server.

private final class UpstreamHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var head: HTTPRequestHead?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end: respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        guard let head else { return }
        var headers = HTTPHeaders()
        var chunks: [String]
        switch head.uri {
        case "/":
            headers.add(name: "content-type", value: "text/html; charset=utf-8")
            chunks = ["<html><head><title>t</title></head><body>hello</body></html>"]
            headers.add(name: "content-length", value: String(chunks[0].utf8.count))
        case "/streamed":
            headers.add(name: "content-type", value: "text/html")
            chunks = ["<html><head><title>t</title></he", "ad><body>streamed", "</body></html>"]
        case "/api":
            headers.add(name: "content-type", value: "application/json")
            chunks = [#"{"ok":true}"#]
        case "/gzip":
            headers.add(name: "content-type", value: "text/html")
            headers.add(name: "content-encoding", value: "x-test")
            chunks = ["<html><head></head></html>"]
        case "/headers":
            headers.add(name: "content-type", value: "application/json")
            let echo: [String: String] = [
                "host": head.headers.first(name: "host") ?? "",
                "accept-encoding": head.headers.first(name: "accept-encoding") ?? "",
                "cookie": head.headers.first(name: "cookie") ?? "",
            ]
            chunks = [String(decoding: try! JSONSerialization.data(withJSONObject: echo), as: UTF8.self)]
        case "/redirect":
            headers.add(name: "location", value: "http://localhost:\(context.channel.localAddress?.port ?? 0)/after?x=1")
            headers.add(name: "set-cookie", value: "sid=1; Path=/; Domain=localhost; HttpOnly")
            chunks = [""]
        case "/strict":
            headers.add(name: "content-type", value: "text/html")
            headers.add(name: "content-security-policy", value: "script-src 'nonce-app' 'strict-dynamic'; connect-src 'self' ws://localhost:7880")
            chunks = ["<html><head><script nonce=app src=/a.js></script></head><body></body></html>"]
        default:
            chunks = ["missing"]
        }
        let status: HTTPResponseStatus = chunks == ["missing"] ? .notFound : .ok
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
        for chunk in chunks {
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: chunk)))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

/// Stands in for a dev server's hot-reload socket.
private final class EchoSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: frame.unmaskedData)), promise: nil)
    }
}

private func startUpstream() async throws -> Channel {
    try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in channel.eventLoop.makeSucceededFuture(head.uri == "/hmr" ? HTTPHeaders() : nil) },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            let sync = channel.pipeline.syncOperations
                            if let context = try? sync.context(name: "upstream") { _ = sync.removeHandler(context: context) }
                            try sync.addHandler(EchoSocketHandler())
                        }
                    }
                )
                try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
                try channel.pipeline.syncOperations.addHandler(UpstreamHandler(), name: "upstream")
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

private struct Harness {
    let upstream: Channel
    let proxy: CollabProxy
    let port: Int
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    static func start() async throws -> Harness {
        let upstream = try await startUpstream()
        let proxy = CollabProxy(configuration: .init(
            upstreamHost: "127.0.0.1",
            upstreamPort: upstream.localAddress!.port!,
            overlayScript: Data("console.log('overlay')".utf8)
        ))
        let port = try await proxy.start()
        return Harness(upstream: upstream, proxy: proxy, port: port)
    }

    func stop() async {
        await proxy.stop()
        try? await upstream.close()
    }

    func get(_ path: String, headers: [String: String] = [:]) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (String(decoding: data, as: UTF8.self), response as! HTTPURLResponse)
    }

    func socket(_ path: String, origin: String? = nil) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)\(path)")!)
        request.setValue(origin ?? "http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }
}

private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
    guard case .string(let text) = try await task.receive() else { return [:] }
    return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

@Test func proxyInjectsTheOverlayIntoHTMLAndKeepsFramingRight() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }

    let (page, response) = try await harness.get("/")
    #expect(page == "<html><head>\(CollabProxy.bridgeTag(nonce: nil))<title>t</title>\(CollabProxy.scriptTag)</head><body>hello</body></html>")
    #expect(response.value(forHTTPHeaderField: "Content-Length") == String(page.utf8.count))

    let (streamed, _) = try await harness.get("/streamed")
    #expect(streamed == "<html><head>\(CollabProxy.bridgeTag(nonce: nil))<title>t</title>\(CollabProxy.scriptTag)</head><body>streamed</body></html>")

    let (json, _) = try await harness.get("/api")
    #expect(json == #"{"ok":true}"#)
    let (compressed, _) = try await harness.get("/gzip")
    #expect(!compressed.contains("collab.js"))
    let (_, missing) = try await harness.get("/nope")
    #expect(missing.statusCode == 404)
}

@Test func proxyCleansUpstreamHeadersForTheLocalServer() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let (body, _) = try await harness.get("/headers", headers: ["Cookie": "a=1; __opentraffic_host=secret; b=2"])
    let echo = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
    // The host's browser addresses the proxy; the dev server sees its own address.
    #expect(echo["host"] == "127.0.0.1:\(harness.upstream.localAddress!.port!)")
    #expect(echo["accept-encoding"] == "")
    #expect(echo["cookie"] == "a=1; b=2")
}

@Test func proxyServesTheOverlayAndTheHostLink() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let (script, scriptResponse) = try await harness.get(CollabProxy.scriptPath)
    #expect(script == "console.log('overlay')")
    #expect(scriptResponse.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/javascript") == true)

    let (_, joined) = try await harness.get("\(CollabProxy.hostPath)?token=\(harness.proxy.hostToken)")
    #expect(joined.statusCode == 302)
    #expect(joined.value(forHTTPHeaderField: "Set-Cookie")?.contains("HttpOnly") == true)
    let (_, refused) = try await harness.get("\(CollabProxy.hostPath)?token=guess")
    #expect(refused.statusCode == 403)
}

@Test func hubConnectsPagesFromTheShareAndRejectsOtherOrigins() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }

    let first = harness.socket(CollabProxy.socketPath)
    try await first.send(.string(#"{"type":"hello","name":"Ada","path":"/"}"#))
    let welcome = try await receiveJSON(first)
    #expect(welcome["type"] as? String == "welcome")

    let second = harness.socket(CollabProxy.socketPath)
    try await second.send(.string(#"{"type":"hello","name":"Grace","path":"/"}"#))
    _ = try await receiveJSON(second)
    let join = try await receiveJSON(first)
    #expect((join["peer"] as? [String: Any])?["name"] as? String == "Grace")

    let stranger = harness.socket(CollabProxy.socketPath, origin: "https://evil.example")
    await #expect(throws: (any Error).self) { try await stranger.receive() }
    first.cancel(with: .goingAway, reason: nil)
    second.cancel(with: .goingAway, reason: nil)
}

@Test func aFullSessionTurnsNewPeopleAwayWithoutHarm() async throws {
    // Regression: closing a socket the room had no space for used to stop the app.
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    var sockets: [URLSessionWebSocketTask] = []
    for index in 0..<CollabProxy.socketsPerAddress {
        let socket = harness.socket(CollabProxy.socketPath)
        try await socket.send(.string(#"{"type":"hello","name":"P\#(index)","path":"/"}"#))
        _ = try await receiveJSON(socket)
        sockets.append(socket)
    }
    let extra = harness.socket(CollabProxy.socketPath)
    await #expect(throws: (any Error).self) { try await extra.receive() }
    let (_, response) = try await harness.get("/")
    #expect(response.statusCode == 200)
    try await sockets[0].send(.string(#"{"type":"path","path":"/next"}"#))
    for socket in sockets { socket.cancel(with: .goingAway, reason: nil) }
}

@Test func silentHubConnectionsAreClosed() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let silent = harness.socket(CollabProxy.socketPath)
    let started = Date()
    await #expect(throws: (any Error).self) { while true { _ = try await silent.receive() } }
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test func otherWebSocketsAreRelayedToTheLocalServer() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let hotReload = harness.socket("/hmr")
    try await hotReload.send(.string("rebuild"))
    guard case .string(let echoed) = try await hotReload.receive() else {
        Issue.record("expected a text frame")
        return
    }
    #expect(echoed == "rebuild")
    hotReload.cancel(with: .goingAway, reason: nil)
}

@Test func proxyAnswersWithAFriendlyPageWhenTheLocalServerIsDown() async throws {
    let proxy = CollabProxy(configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: 1, overlayScript: Data()))
    let port = try await proxy.start()
    defer { Task { await proxy.stop() } }
    let (data, response) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 502)
    #expect(String(decoding: data, as: UTF8.self).contains("isn't responding"))
}

// MARK: Reused connections

/// Collects whatever a raw TCP connection receives.
private final class ByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var received = ""

    var text: String { lock.withLock { received } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let chunk = buffer.readString(length: buffer.readableBytes) ?? ""
        lock.withLock { received += chunk }
    }
}

@Test func hubAcceptsAWebSocketOnAConnectionThatAlreadyServedAPage() async throws {
    // cloudflared keeps connections to the origin alive and reuses them, so the hub's upgrade
    // often isn't the first request on its connection.
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let collector = ByteCollector()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
        }
        .connect(host: "127.0.0.1", port: harness.port)
        .get()
    defer { channel.close(promise: nil) }
    let host = "127.0.0.1:\(harness.port)"
    try await channel.writeAndFlush(ByteBuffer(string: "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(collector.text.contains("200 OK"))
    try await channel.writeAndFlush(ByteBuffer(string: """
        GET \(CollabProxy.socketPath) HTTP/1.1\r
        Host: \(host)\r
        Origin: http://\(host)\r
        Connection: Upgrade\r
        Upgrade: websocket\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r

        """))
    try await Task.sleep(for: .milliseconds(300))
    #expect(collector.text.contains("101 Switching Protocols"))
    #expect(collector.text.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
}

private final class CommentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [[CollabComment]] = []
    func record(_ comments: [CollabComment]) { lock.withLock { updates.append(comments) } }
    var last: [CollabComment]? { lock.withLock { updates.last } }
}

@Test func savedCommentsReachTheSessionAndChangesFromOpenTrafficGoLive() async throws {
    let upstream = try await startUpstream()
    let saved = CollabComment(id: "c1", author: "Alice", color: "#2F80ED", path: "/", text: "Bigger please", x: 0.5, y: 100, createdAt: Date(timeIntervalSince1970: 1_000))
    let proxy = CollabProxy(
        configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: upstream.localAddress!.port!, overlayScript: Data(), hostName: "Sam"),
        comments: [saved]
    )
    let log = CommentLog()
    proxy.setCommentsHandler { log.record($0) }
    let port = try await proxy.start()
    defer { Task { await proxy.stop(); try? await upstream.close() } }

    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)\(CollabProxy.socketPath)")!)
    request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
    let socket = URLSession(configuration: .ephemeral).webSocketTask(with: request)
    socket.resume()
    try await socket.send(.string(#"{"type":"hello","path":"/","client":"client-test-123456"}"#))
    let welcome = try await receiveJSON(socket)
    let comments = try #require(welcome["comments"] as? [[String: Any]])
    #expect(comments.first?["text"] as? String == "Bigger please")
    #expect(comments.first?["canDelete"] as? Bool == false)

    await proxy.resolveComment("c1", resolved: true)
    let update = try await receiveJSON(socket)
    #expect(update["type"] as? String == "comment")
    #expect((update["comment"] as? [String: Any])?["resolved"] as? Bool == true)
    #expect(log.last?.first?.resolved == true)

    try await Task.sleep(for: .seconds(2.1)) // a fresh comment is allowed
    try await socket.send(.string(#"{"type":"comment","text":"New one","path":"/","x":0.1,"y":5}"#))
    let added = try await receiveJSON(socket)
    #expect((added["comment"] as? [String: Any])?["canDelete"] as? Bool == true)
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.last?.count == 2)
    socket.cancel(with: .goingAway, reason: nil)
}


// MARK: Phase 3 — bridge, rewriting, uploads

private final class Candidates: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [Int] = []
    func add(_ port: Int) { lock.withLock { ports.append(port) } }
    var all: [Int] { lock.withLock { ports } }
}

@Test func bridgedPortsAreForwardedOnlyOnceAllowed() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let service = try await startUpstream()
    defer { service.close(promise: nil) }
    let servicePort = service.localAddress!.port!
    let candidates = Candidates()
    harness.proxy.setBridgeCandidatesHandler { candidates.add($0) }

    let (denied, deniedResponse) = try await harness.get("/__opentraffic/port/\(servicePort)/api")
    #expect(deniedResponse.statusCode == 403)
    #expect(denied.contains("localhost:\(servicePort)"))
    #expect(candidates.all == [servicePort])

    harness.proxy.setBridgedPorts([servicePort])
    let (body, response) = try await harness.get("/__opentraffic/port/\(servicePort)/headers")
    #expect(response.statusCode == 200)
    let echo = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
    #expect(echo["host"] == "localhost:\(servicePort)")
    // Back to the app on the same connection.
    let (page, _) = try await harness.get("/")
    #expect(page.contains("<title>t</title>"))

    let (script, _) = try await harness.get(CollabProxy.bridgePath)
    #expect(script.hasPrefix(#"window.__opentrafficBridge = {"appPort":\#(harness.upstream.localAddress!.port!),"ports":[\#(servicePort)]};"#))
}

@Test func pagesGetTheBridgeFirstAndTheOverlayLast() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let (page, response) = try await harness.get("/")
    #expect(page.hasPrefix("<html><head>\(CollabProxy.bridgeTag(nonce: nil))<title>t</title>\(CollabProxy.scriptTag)</head>"))
    #expect(response.value(forHTTPHeaderField: "Content-Length") == String(page.utf8.count))
}

@Test func strictPoliciesGetANonceOnOpenTrafficsTags() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let candidates = Candidates()
    harness.proxy.setBridgeCandidatesHandler { candidates.add($0) }
    let (page, response) = try await harness.get("/strict")
    let policy = try #require(response.value(forHTTPHeaderField: "Content-Security-Policy"))
    let nonce = try #require(policy.range(of: #"'nonce-([A-Za-z0-9_-]{22})'"#, options: .regularExpression).map { String(policy[$0].dropFirst(7).dropLast()) })
    #expect(page.contains(#"<script src="/__opentraffic/bridge.js" data-opentraffic nonce="\#(nonce)">"#))
    #expect(page.contains(#"defer data-opentraffic nonce="\#(nonce)">"#))
    #expect(candidates.all == [7880])
}

@Test func redirectsAndCookiesForLocalhostAreRewritten() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let (_, response) = try await harness.get("/redirect")
    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Location") == "/after?x=1")
    #expect(response.value(forHTTPHeaderField: "Set-Cookie") == "sid=1; Path=/; HttpOnly")
}

@Test func onlyPeopleInTheSessionCanUploadScreenshots() async throws {
    let upstream = try await startUpstream()
    let directory = FileManager.default.temporaryDirectory.appending(path: "tb-attachments-\(UUID().uuidString)")
    let proxy = CollabProxy(configuration: .init(upstreamHost: "127.0.0.1", upstreamPort: upstream.localAddress!.port!, overlayScript: Data(), attachmentsDirectory: directory))
    let port = try await proxy.start()
    defer { Task { await proxy.stop(); try? await upstream.close(); try? FileManager.default.removeItem(at: directory) } }
    let session = URLSession(configuration: .ephemeral)

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 992)
    func upload(token: String?, body: Data = png) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__opentraffic/upload")!)
        request.httpMethod = "POST"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue(token, forHTTPHeaderField: "X-OpenTraffic-Upload-Token") }
        let (data, response) = try await session.upload(for: request, from: body)
        return (data, (response as! HTTPURLResponse).statusCode)
    }
    #expect(try await upload(token: nil).1 == 403)
    #expect(try await upload(token: "stranger").1 == 403)

    var socketRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)\(CollabProxy.socketPath)")!)
    socketRequest.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
    let socket = session.webSocketTask(with: socketRequest)
    socket.resume()
    try await socket.send(.string(#"{"type":"hello","path":"/"}"#))
    let welcome = try await receiveJSON(socket)
    let token = try #require(welcome["uploadToken"] as? String)
    let peerID = try #require((welcome["you"] as? [String: Any])?["id"] as? String)
    #expect(try await upload(token: peerID).1 == 403) // the public peer id isn't enough
    #expect(try await upload(token: token, body: Data(repeating: 7, count: 1000)).1 == 415)

    let (data, status) = try await upload(token: token)
    #expect(status == 201)
    let id = try #require((try JSONSerialization.jsonObject(with: data) as? [String: String])?["id"])
    let (image, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/__opentraffic/attachments/\(id)")!)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "image/png")
    #expect(image.count == 1000)
    let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/__opentraffic/attachments/AAAAAAAAAAAAAAAAAAAAAA")!)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    socket.cancel(with: .goingAway, reason: nil)
}

@Test func aRefusedUpgradeIsAnsweredAndTheConnectionClosed() async throws {
    // The tunnel connector reuses connections. If a local server refuses an upgrade (say, a
    // WebSocket without a token), the refusal is passed on and the connection closed, so no later
    // request can end up on it.
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let collector = ByteCollector()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
        }
        .connect(host: "127.0.0.1", port: harness.port)
        .get()
    defer { channel.close(promise: nil) }
    let host = "127.0.0.1:\(harness.port)"
    try await channel.writeAndFlush(ByteBuffer(string: """
        GET /no-socket-here HTTP/1.1\r
        Host: \(host)\r
        Connection: Upgrade\r
        Upgrade: websocket\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r

        """))
    try await Task.sleep(for: .milliseconds(300))
    #expect(collector.text.contains("404 Not Found"))
    #expect(collector.text.lowercased().contains("connection: close"))
    #expect(!channel.isActive)
    let (page, _) = try await harness.get("/")
    #expect(page.contains("<title>t</title>"))
}


@Test func upgradesOpenTrafficAnswersItselfAlsoCloseTheConnection() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let collector = ByteCollector()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
        }
        .connect(host: "127.0.0.1", port: harness.port)
        .get()
    defer { channel.close(promise: nil) }
    let host = "127.0.0.1:\(harness.port)"
    // A bridged port that isn't allowed: refused by OpenTraffic itself.
    try await channel.writeAndFlush(ByteBuffer(string: "GET /__opentraffic/port/9/x HTTP/1.1\r\nHost: \(host)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(collector.text.contains("403 Forbidden"))
    #expect(collector.text.lowercased().contains("connection: close"))
    #expect(!channel.isActive)
}

@Test func forwardOnlyProxiesSendTheLocalHostAndLeavePagesAlone() async throws {
    // OpenTunnel passes visitors' requests on with the public hostname; dev servers that reject it
    // get their own address from the proxy, with no overlay added.
    let upstream = try await startUpstream()
    let upstreamPort = upstream.localAddress!.port!
    let proxy = CollabProxy(configuration: .init(
        upstreamHost: "localhost",
        upstreamPort: upstreamPort,
        overlayScript: Data(),
        injectsOverlay: false,
        rewritesHostHeader: true,
        limitsConnectionsPerAddress: false
    ))
    let port = try await proxy.start()
    defer { Task { await proxy.stop(); try? await upstream.close() } }

    func request(_ path: String) async throws -> String {
        let collector = ByteCollector()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        defer { channel.close(promise: nil) }
        try await channel.writeAndFlush(ByteBuffer(string: "GET \(path) HTTP/1.1\r\nHost: web.abc.opentunnel.xyz\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"))
        try await Task.sleep(for: .milliseconds(300))
        return collector.text
    }
    let headers = try await request("/headers")
    #expect(headers.contains(#""host":"localhost:\#(upstreamPort)""#))
    #expect(headers.contains(#""accept-encoding":"gzip""#))
    let page = try await request("/")
    #expect(page.contains("<body>hello</body>"))
    #expect(!page.contains("collab.js"))
    #expect(!page.contains("bridge.js"))
}

@Test func stoppingTheProxyClosesConnectionsKeptAlive() async throws {
    // A stopped share mustn't keep serving visitors over connections the tunnel kept open.
    let harness = try await Harness.start()
    let collector = ByteCollector()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
        }
        .connect(host: "127.0.0.1", port: harness.port)
        .get()
    try await channel.writeAndFlush(ByteBuffer(string: "GET /api HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\n\r\n"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(collector.text.contains("200 OK"))
    #expect(channel.isActive)
    await harness.stop()
    try await Task.sleep(for: .milliseconds(300))
    #expect(!channel.isActive)
}

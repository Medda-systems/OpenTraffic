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
                "authorization": head.headers.first(name: "authorization") ?? "",
            ]
            chunks = [String(decoding: try! JSONSerialization.data(withJSONObject: echo), as: UTF8.self)]
        case "/redirect":
            headers.add(name: "location", value: "http://localhost:\(context.channel.localAddress?.port ?? 0)/after?x=1")
            headers.add(name: "set-cookie", value: "sid=1; Path=/; Domain=localhost; HttpOnly")
            chunks = [""]
        case MirrorProtocol.viewerScriptPath:
            // A Mac app's mirror server, answering for its own files.
            headers.add(name: "content-type", value: "application/javascript")
            headers.add(name: "x-seen-host", value: head.headers.first(name: "host") ?? "")
            chunks = ["viewer()"]
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
                    shouldUpgrade: { channel, head in channel.eventLoop.makeSucceededFuture(head.uri == "/hmr" || head.uri == MirrorProtocol.webSocketPath ? HTTPHeaders() : nil) },
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

    static func start(mirrorsMacApp: Bool = false) async throws -> Harness {
        let upstream = try await startUpstream()
        let proxy = CollabProxy(configuration: .init(
            upstreamHost: "127.0.0.1",
            upstreamPort: upstream.localAddress!.port!,
            overlayScript: Data("console.log('overlay')".utf8),
            // As a Mac app share sets it up: the mirror server only ever sees its own address.
            rewritesHostHeader: mirrorsMacApp,
            mirrorsMacApp: mirrorsMacApp
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
    // A fix landed: the page is told to catch up.
    #expect(try await receiveJSON(socket)["type"] as? String == "refresh")

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

// MARK: Password

private extension Harness {
    /// A request that leaves cookies to the test.
    func send(_ path: String, method: String = "GET", headers: [String: String] = [:], body: String? = nil) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await session.data(for: request)
        return (String(decoding: data, as: UTF8.self), response as! HTTPURLResponse)
    }
}

private let page = ["Accept": "text/html", "Sec-Fetch-Mode": "navigate"]

@Test func aPasswordKeepsVisitorsOutUntilTheySignIn() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let access = ShareAccess(password: "correct horse", shareKey: "share-1", shareName: "Shop <dev>")
    harness.proxy.setAccess(access)

    let (signIn, refused) = try await harness.send("/streamed?x=1", headers: page)
    #expect(refused.statusCode == 401)
    #expect(signIn.contains("Shop &lt;dev&gt;"))
    #expect(signIn.contains(#"value="/streamed?x=1""#))
    #expect(!signIn.contains("streamed</body>"))
    #expect(refused.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)

    // Scripts and tools get a plain 401 that offers basic auth; so do OpenTraffic's own routes.
    let (_, api) = try await harness.send("/api")
    #expect(api.statusCode == 401)
    #expect(api.value(forHTTPHeaderField: "WWW-Authenticate")?.hasPrefix("Basic") == true)
    let (_, script) = try await harness.send(CollabProxy.scriptPath)
    #expect(script.statusCode == 401)

    let (_, wrong) = try await harness.send(ShareAccess.signInPath, method: "POST", body: "password=nope&next=%2Fapi")
    #expect(wrong.statusCode == 401)

    let (done, signedIn) = try await harness.send(ShareAccess.signInPath, method: "POST", body: "password=correct+horse&name=Ada&next=%2Fapi")
    #expect(signedIn.statusCode == 200)
    let cookie = try #require(signedIn.value(forHTTPHeaderField: "Set-Cookie"))
    #expect(cookie.hasPrefix("\(ShareAccess.cookieName)=\(access.cookieValue);"))
    #expect(cookie.contains("HttpOnly") && cookie.contains("Secure") && cookie.contains("SameSite=Lax"))
    #expect(done.contains(#"location.replace(["\/api"][0])"#) || done.contains(#"location.replace(["/api"][0])"#))
    #expect(done.contains("Ada"))
    #expect(signIn.contains(#"name="name""#))

    // Signed in, the site works, and the app never sees OpenTraffic's cookie.
    let (json, ok) = try await harness.send("/api", headers: ["Cookie": "\(ShareAccess.cookieName)=\(access.cookieValue)"])
    #expect(ok.statusCode == 200 && json == #"{"ok":true}"#)
    let (echoed, _) = try await harness.send("/headers", headers: ["Cookie": "a=1; \(ShareAccess.cookieName)=\(access.cookieValue)"])
    #expect(echoed.contains(#""cookie":"a=1""#))

    // A new password signs everyone out.
    harness.proxy.setAccess(ShareAccess(password: "another one", shareKey: "share-1", shareName: "Shop"))
    let (_, stale) = try await harness.send("/api", headers: ["Cookie": "\(ShareAccess.cookieName)=\(access.cookieValue)"])
    #expect(stale.statusCode == 401)

    harness.proxy.setAccess(nil)
    let (_, open) = try await harness.send("/api")
    #expect(open.statusCode == 200)
}

@Test func toolsCanSendThePasswordAndTheAppDoesntSeeIt() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    harness.proxy.setAccess(ShareAccess(password: "p4ss", shareKey: "k", shareName: "S"))
    let basic = "Basic " + Data("anyone:p4ss".utf8).base64EncodedString()
    let (echoed, ok) = try await harness.send("/headers", headers: ["Authorization": basic])
    #expect(ok.statusCode == 200)
    #expect(echoed.contains(#""authorization":"""#))
    let (_, wrong) = try await harness.send("/headers", headers: ["Authorization": "Basic " + Data("anyone:nope".utf8).base64EncodedString()])
    #expect(wrong.statusCode == 401)
    // The app's own authorization passes through untouched.
    harness.proxy.setAccess(nil)
    let (own, _) = try await harness.send("/headers", headers: ["Authorization": "Bearer app"])
    #expect(own.contains("Bearer app"))
}

@Test func anInviteLinkSignsInAndDropsTheToken() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    let access = ShareAccess(password: "p4ss", shareKey: "k", shareName: "S")
    harness.proxy.setAccess(access)
    let link = try #require(URL(string: access.inviteURL(publicURL: "https://shop.example/streamed?x=1")))
    #expect(link.query?.contains("ot_invite=") == true)
    #expect(!link.absoluteString.contains("p4ss"))

    let (_, invited) = try await harness.send("/streamed?x=1&\(ShareAccess.inviteParameter)=\(access.inviteToken)", headers: page)
    #expect(invited.statusCode == 303)
    #expect(invited.value(forHTTPHeaderField: "Location") == "/streamed?x=1")
    #expect(invited.value(forHTTPHeaderField: "Set-Cookie")?.contains(access.cookieValue) == true)

    let (_, forged) = try await harness.send("/?\(ShareAccess.inviteParameter)=guess", headers: page)
    #expect(forged.statusCode == 401)
}

@Test func theHostLinkStillWorksAndTheHostHeaderProvesNothing() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    harness.proxy.setAccess(ShareAccess(password: "p4ss", shareKey: "k", shareName: "S"))
    // A visitor naming the proxy's own address is still a visitor.
    let (_, spoofed) = try await harness.send("/api", headers: ["Host": "127.0.0.1:\(harness.port)"])
    #expect(spoofed.statusCode == 401)

    let (_, joined) = try await harness.send("\(CollabProxy.hostPath)?token=\(harness.proxy.hostToken)")
    #expect(joined.statusCode == 302)
    let hostCookie = "\(CollabProxy.hostCookiePrefix)_\(harness.port)=\(harness.proxy.hostToken)"
    let (_, host) = try await harness.send("/api", headers: ["Cookie": hostCookie])
    #expect(host.statusCode == 200)
}

@Test func guessingThePasswordIsSlowedDown() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    harness.proxy.setAccess(ShareAccess(password: "p4ss", shareKey: "k", shareName: "S"))
    for _ in 0..<SignInLimiter.maximumFailures {
        let (_, wrong) = try await harness.send(ShareAccess.signInPath, method: "POST", headers: ["CF-Connecting-IP": "203.0.113.9"], body: "password=x")
        #expect(wrong.statusCode == 401)
    }
    let (_, limited) = try await harness.send(ShareAccess.signInPath, method: "POST", headers: ["CF-Connecting-IP": "203.0.113.9"], body: "password=p4ss")
    #expect(limited.statusCode == 429)
    // Someone else isn't held up by it.
    let (_, other) = try await harness.send(ShareAccess.signInPath, method: "POST", headers: ["CF-Connecting-IP": "198.51.100.4"], body: "password=p4ss")
    #expect(other.statusCode == 200)
}

@Test func theHubAndUpgradesNeedThePasswordToo() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    harness.proxy.setAccess(ShareAccess(password: "p4ss", shareKey: "k", shareName: "S"))
    let task = harness.socket(CollabProxy.socketPath)
    await #expect(throws: (any Error).self) { _ = try await task.receive() }
    #expect((task.response as? HTTPURLResponse)?.statusCode == 401)
}

// MARK: A shared Mac app

@Test func aMacAppsMirrorRoutesPassThroughToItsServer() async throws {
    let harness = try await Harness.start(mirrorsMacApp: true)
    defer { Task { await harness.stop() } }
    let upstreamPort = harness.upstream.localAddress!.port!

    // The viewer page is a page like any other: the bridge first, the overlay last.
    let (page, _) = try await harness.get("/")
    #expect(page == "<html><head>\(CollabProxy.bridgeTag(nonce: nil))<title>t</title>\(CollabProxy.scriptTag)</head><body>hello</body></html>")

    // Its files under /__opentraffic/macapp/ come from the mirror server, which sees its own address.
    let (script, response) = try await harness.send(MirrorProtocol.viewerScriptPath, headers: ["Host": "orbit.example.dev"])
    #expect(response.statusCode == 200)
    #expect(script == "viewer()")
    #expect(response.value(forHTTPHeaderField: "x-seen-host") == "127.0.0.1:\(upstreamPort)")
    let (_, unknown) = try await harness.get(MirrorProtocol.snapshotPath)
    #expect(unknown.statusCode == 404)
    // OpenTraffic's own routes are still its own.
    let (overlay, _) = try await harness.get(CollabProxy.scriptPath)
    #expect(overlay == "console.log('overlay')")

    // The app's WebSocket is relayed to the mirror server.
    let socket = harness.socket(MirrorProtocol.webSocketPath)
    try await socket.send(.string(#"{"t":"act"}"#))
    guard case .string(let echoed) = try await socket.receive() else {
        Issue.record("expected a text frame")
        return
    }
    #expect(echoed == #"{"t":"act"}"#)
    socket.cancel(with: .goingAway, reason: nil)

    // Pages from other sites can't drive the app.
    let stranger = harness.socket(MirrorProtocol.webSocketPath, origin: "https://evil.example")
    await #expect(throws: (any Error).self) { _ = try await stranger.receive() }
    #expect((stranger.response as? HTTPURLResponse)?.statusCode == 403)

    // The share's public pages can, once the public address is known.
    harness.proxy.setPublicHost("orbit.example.dev")
    let visitor = harness.socket(MirrorProtocol.webSocketPath, origin: "https://orbit.example.dev")
    try await visitor.send(.string("ping"))
    guard case .string(let pong) = try await visitor.receive() else {
        Issue.record("expected a text frame")
        return
    }
    #expect(pong == "ping")
    visitor.cancel(with: .goingAway, reason: nil)
}

@Test func withoutAMacAppTheMirrorPathsStayOpenTrafficsOwn() async throws {
    let harness = try await Harness.start()
    defer { Task { await harness.stop() } }
    // The local server would answer 200; the proxy keeps /__opentraffic/ to itself.
    let (_, response) = try await harness.get(MirrorProtocol.viewerScriptPath)
    #expect(response.statusCode == 404)
    let socket = harness.socket(MirrorProtocol.webSocketPath)
    await #expect(throws: (any Error).self) { _ = try await socket.receive() }
}

@Test func aMacAppsMirrorNeedsThePasswordToo() async throws {
    let harness = try await Harness.start(mirrorsMacApp: true)
    defer { Task { await harness.stop() } }
    let access = ShareAccess(password: "p4ss", shareKey: "k", shareName: "Orbit")
    harness.proxy.setAccess(access)
    let (_, refused) = try await harness.send(MirrorProtocol.viewerScriptPath)
    #expect(refused.statusCode == 401)
    let socket = harness.socket(MirrorProtocol.webSocketPath)
    await #expect(throws: (any Error).self) { _ = try await socket.receive() }
    #expect((socket.response as? HTTPURLResponse)?.statusCode == 401)
    let (script, signedIn) = try await harness.send(MirrorProtocol.viewerScriptPath, headers: ["Cookie": "\(ShareAccess.cookieName)=\(access.cookieValue)"])
    #expect(signedIn.statusCode == 200)
    #expect(script == "viewer()")
}

// MARK: A shared Mac app for real (the Orbit fixture)

/// What OpenTraffic sets up for a Mac app share, minus the tunnel: the isolated copy's mirror server
/// behind a proxy configured as the app configures it, opened as a visitor from the public address.
@MainActor
@Suite("A Mac app share through the proxy on the Orbit fixture", .serialized,
       .enabled(if: AccessibilityTree.isTrusted, "needs Accessibility permission"),
       .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"),
       .macAppFixtureTurn, .timeLimit(.minutes(10)))
struct MacAppShareProxyFixtureTests {
    @Test func visitorsGetTheViewerWithTheOverlayAndDriveTheAppThroughTheProxy() async throws {
        try OrbitFixture.buildIfNeeded()
        let sessions = OrbitFixture.repository.appendingPathComponent(".build/macapp-share-tests", isDirectory: true)
        await MacAppSession.removeLeftovers(in: sessions)
        let app = MacApp(name: "Orbit", bundle: OrbitFixture.app, bundleIdentifier: OrbitFixture.bundleIdentifier,
                         projectDirectory: OrbitFixture.folder, isRunning: false)
        let page = Data(#"<!doctype html><html><head><title>Orbit</title></head><body><main id="desktop"></main></body></html>"#.utf8)
        let session = MacAppSession(options: .init(
            app: app, data: .empty, assets: .init(page: page, script: Data("/* viewer */".utf8), style: Data()),
            sessionDirectory: sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ))
        let port = try await session.start()
        let proxy = CollabProxy(configuration: .init(
            upstreamHost: "127.0.0.1", upstreamPort: port, overlayScript: Data("overlay".utf8),
            rewritesHostHeader: true, mirrorsMacApp: true
        ))
        do {
            let proxyPort = try await proxy.start()
            // The tunnel is up: its address is the share's public origin.
            proxy.setPublicHost("orbit.example.dev")
            session.server?.setAllowedOrigins(["https://orbit.example.dev"])
            let urls = URLSession(configuration: .ephemeral)
            func visitor(_ path: String) -> URLRequest {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)\(path)")!)
                request.setValue("orbit.example.dev", forHTTPHeaderField: "Host")
                request.setValue("https", forHTTPHeaderField: "X-Forwarded-Proto")
                return request
            }

            // The viewer page with the overlay; the viewer's own files from the mirror server.
            let (html, _) = try await urls.data(for: visitor("/"))
            let text = String(decoding: html, as: UTF8.self)
            #expect(text.contains(CollabProxy.scriptTag) && text.contains(#"<main id="desktop">"#))
            let (script, scriptResponse) = try await urls.data(for: visitor(MirrorProtocol.viewerScriptPath))
            #expect((scriptResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: script, as: UTF8.self) == "/* viewer */")

            // The app's WebSocket, from the public page: hello with Orbit's window, then its tree.
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(proxyPort)\(MirrorProtocol.webSocketPath)")!)
            request.setValue("orbit.example.dev", forHTTPHeaderField: "Host")
            request.setValue("https://orbit.example.dev", forHTTPHeaderField: "Origin")
            let socket = urls.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let hello = try await nextMessage(socket, type: "hello")
            #expect((hello["app"] as? [String: Any])?["name"] as? String == "Orbit")
            let boot = try #require(hello["boot"] as? String)
            #expect((hello["windows"] as? [Any])?.isEmpty == false)
            _ = try await nextMessage(socket, type: "tree")
            #expect(session.viewerCount == 1)

            // Reset Data, as the card's button does: same port, the visitor stays connected and gets a new launch.
            try await session.resetData()
            let again = try await nextMessage(socket, type: "hello")
            #expect(again["boot"] as? String != boot)
            #expect(session.port == port)

            // Another site's page can't drive the app.
            var foreign = request
            foreign.setValue("https://evil.example", forHTTPHeaderField: "Origin")
            let evil = urls.webSocketTask(with: foreign)
            evil.resume()
            await #expect(throws: (any Error).self) { _ = try await evil.receive() }
        } catch {
            await proxy.stop()
            await session.stop()
            await removeLateOrbitPreferences()
            throw error
        }
        await proxy.stop()
        await session.stop()
        await removeLateOrbitPreferences()
        #expect(!FileManager.default.fileExists(atPath: session.sessionDirectory.path))
    }

    /// The next text message of this type (`{"t":"hello"}`), skipping the others and binary tiles.
    private func nextMessage(_ socket: URLSessionWebSocketTask, type: String) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            guard case .string(let text) = try await socket.receive(),
                  let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if message["t"] as? String == type { return message }
        }
        throw FixtureError("no \(type) message within 30 seconds")
    }

    /// cfprefsd writes the copy's emptied preferences back a few seconds after the session deletes
    /// them; delete that write too (the session's own follow-up runs later than a test process lives).
    private func removeLateOrbitPreferences() async {
        let file = ElectronSandbox.realHomeDirectory + "/Library/Preferences/se.medda.orbit.opentraffic.plist"
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: file) {
                try? FileManager.default.removeItem(atPath: file)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

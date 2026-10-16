import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import OpenTrafficCore

// Webhook deliveries against a local receiver.

/// Records each request and answers with the next scripted status (the last one repeats).
private final class Receiver: @unchecked Sendable {
    struct Delivery {
        let path: String
        let headers: HTTPHeaders
        let body: Data
    }

    private let lock = NSLock()
    private var statuses: [Int]
    private var received: [Delivery] = []
    private var channel: Channel?

    init(statuses: [Int]) {
        self.statuses = statuses
    }

    var deliveries: [Delivery] { lock.withLock { received } }

    fileprivate func receive(_ delivery: Delivery) -> Int {
        lock.withLock {
            received.append(delivery)
            return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        }
    }

    func start() async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(ReceiverHandler(receiver: self))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        lock.withLock { self.channel = channel }
        return channel.localAddress!.port!
    }

    func stop() async {
        try? await lock.withLock { channel }?.close()
    }
}

private final class ReceiverHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let receiver: Receiver
    private var head: HTTPRequestHead?
    private var body = Data()

    init(receiver: Receiver) {
        self.receiver = receiver
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(let buffer):
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { return }
            // Only webhook deliveries count. Anything else listing local servers (a running
            // OpenTraffic finds new ports and probes them with GET) is answered and ignored.
            guard head.method == .POST, head.headers.first(name: "user-agent") == "OpenTraffic" else {
                var headers = HTTPHeaders()
                headers.add(name: "content-length", value: "0")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .notFound, headers: headers))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
            let status = receiver.receive(.init(path: head.uri, headers: head.headers, body: body))
            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: "0")
            if (300..<400).contains(status) { headers.add(name: "location", value: "/redirected") }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: HTTPResponseStatus(statusCode: status), headers: headers))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private let fastRetries: [Duration] = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
private let share = APIShareRef(id: UUID(), name: "Orbit", publicURL: "https://orbit.trycloudflare.com")

@Test func webhookSignatureIsHexHMACSHA256OfTimestampAndBody() {
    // HMAC-SHA256("secret", "1700000000.hello")
    #expect(WebhookDispatcher.signature(for: Data("hello".utf8), timestamp: 1_700_000_000, secret: "secret")
        == "sha256=47b1df0ab12338b2685470b0d2b37033add7c3b2bc8172f313e77413f1bb78c8")
}

@Test func webhooksDeliverSignedEventsToMatchingEndpoints() async throws {
    let receiver = Receiver(statuses: [200])
    let port = try await receiver.start()
    defer { Task { await receiver.stop() } }
    let events = APIEventLog()
    let dispatcher = WebhookDispatcher(events: events, retryDelays: fastRetries)
    defer { dispatcher.stop() }
    let all = WebhookEndpoint(url: "http://127.0.0.1:\(port)/all", secret: "s3cret")
    let comments = WebhookEndpoint(url: "http://127.0.0.1:\(port)/comments", events: ["comment.created"], secret: "other")
    let disabled = WebhookEndpoint(url: "http://127.0.0.1:\(port)/off", secret: "x", enabled: false)
    let notHTTP = WebhookEndpoint(url: "file:///etc/passwd", secret: "x")
    dispatcher.setEndpoints([all, comments, disabled, notHTTP])

    let started = events.append(.shareStarted, share: share)
    let created = events.append(.commentCreated, share: share, commentId: "c1")
    #expect(await eventually { receiver.deliveries.count >= 3 })
    try await Task.sleep(for: .milliseconds(200))
    let deliveries = receiver.deliveries
    #expect(deliveries.count == 3)

    for delivery in deliveries {
        let headers = delivery.headers
        let secret = delivery.path == "/comments" ? "other" : "s3cret"
        // Verify the way a receiver would: HMAC "<timestamp>.<raw body>" with the endpoint's secret.
        let timestamp = try #require(headers.first(name: "x-opentraffic-timestamp"))
        #expect(abs((Int(timestamp) ?? 0) - Int(Date().timeIntervalSince1970)) < 60)
        let expected = HMAC<SHA256>.authenticationCode(for: Data("\(timestamp).".utf8) + delivery.body, using: SymmetricKey(data: Data(secret.utf8)))
        #expect(headers.first(name: "x-opentraffic-signature") == "sha256=" + expected.map { String(format: "%02x", $0) }.joined())
        #expect(headers.first(name: "content-type") == "application/json")
        #expect(headers.first(name: "user-agent") == "OpenTraffic")
        let event = try APIJSON.decoder().decode(APIEvent.self, from: delivery.body)
        #expect(headers.first(name: "x-opentraffic-event") == event.type.rawValue)
        #expect(headers.first(name: "x-opentraffic-delivery") == event.id)
        #expect([started.id, created.id].contains(event.id))
    }
    #expect(deliveries.filter { $0.path == "/all" }.count == 2)
    #expect(deliveries.filter { $0.path == "/comments" }.map { $0.headers.first(name: "x-opentraffic-event") } == ["comment.created"])
    #expect(dispatcher.lastDeliveries[all.id]?.succeeded == true)
    #expect(dispatcher.lastDeliveries[comments.id]?.statusCode == 200)
    #expect(dispatcher.lastDeliveries[disabled.id] == nil)
}

@Test func webhooksRetryFailedDeliveries() async throws {
    let receiver = Receiver(statuses: [500, 503, 200])
    let port = try await receiver.start()
    defer { Task { await receiver.stop() } }
    let events = APIEventLog()
    let dispatcher = WebhookDispatcher(events: events, retryDelays: fastRetries)
    defer { dispatcher.stop() }
    let endpoint = WebhookEndpoint(url: "http://127.0.0.1:\(port)/hook", secret: "s")
    dispatcher.setEndpoints([endpoint])

    let event = events.append(.commentCreated, share: share)
    #expect(await eventually { dispatcher.lastDeliveries[endpoint.id]?.succeeded == true })
    let deliveries = receiver.deliveries
    #expect(deliveries.count == 3)
    #expect(Set(deliveries.compactMap { $0.headers.first(name: "x-opentraffic-delivery") }) == [event.id])
    #expect(dispatcher.lastDeliveries[endpoint.id]?.attempt == 3)
}

@Test func webhooksGiveUpAfterThreeRetries() async throws {
    let receiver = Receiver(statuses: [500])
    let port = try await receiver.start()
    defer { Task { await receiver.stop() } }
    let events = APIEventLog()
    let dispatcher = WebhookDispatcher(events: events, retryDelays: fastRetries)
    defer { dispatcher.stop() }
    let failing = WebhookEndpoint(url: "http://127.0.0.1:\(port)/hook", secret: "s")
    // Nothing listens on port 1: a transport error, also retried.
    let unreachable = WebhookEndpoint(url: "http://127.0.0.1:1/hook", secret: "s")
    dispatcher.setEndpoints([failing, unreachable])

    events.append(.shareStopped, share: share)
    #expect(await eventually { dispatcher.lastDeliveries[failing.id]?.attempt == 4 && dispatcher.lastDeliveries[unreachable.id]?.attempt == 4 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(receiver.deliveries.count == 4)
    #expect(dispatcher.lastDeliveries[failing.id]?.error == "HTTP 500")
    #expect(dispatcher.lastDeliveries[failing.id]?.statusCode == 500)
    #expect(dispatcher.lastDeliveries[unreachable.id]?.statusCode == nil)
    #expect(dispatcher.lastDeliveries[unreachable.id]?.succeeded == false)
}

@Test func webhooksDontFollowRedirects() async throws {
    let receiver = Receiver(statuses: [302])
    let port = try await receiver.start()
    defer { Task { await receiver.stop() } }
    let events = APIEventLog()
    let dispatcher = WebhookDispatcher(events: events, retryDelays: fastRetries)
    defer { dispatcher.stop() }
    let endpoint = WebhookEndpoint(url: "http://127.0.0.1:\(port)/hook", secret: "s")
    dispatcher.setEndpoints([endpoint])

    events.append(.shareStarted, share: share)
    #expect(await eventually { dispatcher.lastDeliveries[endpoint.id]?.attempt == 4 })
    try await Task.sleep(for: .milliseconds(200))
    // Every attempt went to the configured URL; none followed the Location header.
    #expect(receiver.deliveries.map(\.path) == Array(repeating: "/hook", count: 4))
    #expect(dispatcher.lastDeliveries[endpoint.id]?.statusCode == 302)
    #expect(dispatcher.lastDeliveries[endpoint.id]?.succeeded == false)
}

@Test func stoppedWebhookDispatcherSendsNothing() async throws {
    let receiver = Receiver(statuses: [200])
    let port = try await receiver.start()
    defer { Task { await receiver.stop() } }
    let events = APIEventLog()
    let dispatcher = WebhookDispatcher(events: events, retryDelays: fastRetries)
    dispatcher.setEndpoints([WebhookEndpoint(url: "http://127.0.0.1:\(port)/hook", secret: "s")])
    dispatcher.stop()
    events.append(.shareStarted, share: share)
    try await Task.sleep(for: .milliseconds(300))
    #expect(receiver.deliveries.isEmpty)
}

@Test func webhookEndpointsAcceptOnlyHTTPURLs() {
    #expect(WebhookEndpoint(url: "https://example.com/hook", secret: "").isValidURL)
    #expect(WebhookEndpoint(url: "http://127.0.0.1:8080", secret: "").isValidURL)
    #expect(!WebhookEndpoint(url: "ftp://example.com", secret: "").isValidURL)
    #expect(!WebhookEndpoint(url: "https://", secret: "").isValidURL)
    #expect(!WebhookEndpoint(url: "not a url", secret: "").isValidURL)
}

// MARK: Token

@Test func apiTokenIsCreatedPrivateAndKept() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "opentraffic-token-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "nested/api-token")

    let token = try APIToken.loadOrCreate(at: url)
    #expect(token.count == 43)
    #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try APIToken.loadOrCreate(at: url) == token)

    let fresh = try APIToken.regenerate(at: url)
    #expect(fresh != token)
    #expect(try APIToken.loadOrCreate(at: url) == fresh)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(leftovers == ["api-token"])

    // A file someone made readable to others is tightened again.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(try APIToken.loadOrCreate(at: url) == fresh)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    #expect(APIToken.defaultURL.path.hasSuffix("Library/Application Support/OpenTraffic/api-token"))
}

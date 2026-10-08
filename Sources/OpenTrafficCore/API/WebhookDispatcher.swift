import CryptoKit
import Foundation
import os

/// A URL that receives OpenTraffic's events (Settings → Integrations).
public struct WebhookEndpoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var url: String
    /// Event types to send (`comment.created`…); empty means all.
    public var events: [String]
    /// Signs each delivery: `X-OpenTraffic-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<body>">`.
    public var secret: String
    public var enabled: Bool

    public init(id: UUID = UUID(), url: String, events: [String] = [], secret: String, enabled: Bool = true) {
        self.id = id
        self.url = url
        self.events = events
        self.secret = secret
        self.enabled = enabled
    }

    /// Only http and https URLs receive events.
    public var isValidURL: Bool {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        return scheme == "http" || scheme == "https"
    }

    func wants(_ type: APIEvent.Kind) -> Bool {
        events.isEmpty || events.contains(type.rawValue)
    }
}

/// The latest delivery attempt to one endpoint, for the settings screen.
public struct WebhookDeliveryStatus: Equatable, Sendable {
    public let at: Date
    public let event: String
    public let deliveryID: String
    /// 1 for the first try, up to 4 after three retries.
    public let attempt: Int
    /// The HTTP status, when the endpoint answered.
    public let statusCode: Int?
    /// What went wrong, when the attempt failed.
    public let error: String?

    public var succeeded: Bool { error == nil }
}

/// POSTs every event from an `APIEventLog` to the endpoints that want it, signed with their secret.
/// Redirects aren't followed. Failed deliveries (transport errors or non-2xx, 3xx included) are retried
/// after 1, 5 and 25 seconds; deliveries run concurrently and never block the thread that appends events.
public final class WebhookDispatcher: Sendable {
    public static let defaultRetryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(25)]
    public static let attemptTimeout: TimeInterval = 10

    private struct State {
        var endpoints: [WebhookEndpoint] = []
        var deliveries: [UUID: Task<Void, Never>] = [:]
        var lastDeliveries: [UUID: WebhookDeliveryStatus] = [:]
        var statusHandler: (@Sendable (UUID, WebhookDeliveryStatus) -> Void)?
        var subscription: UUID?
    }

    private let events: APIEventLog
    private let session: URLSession
    private let retryDelays: [Duration]
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(events: APIEventLog, session: URLSession = WebhookDispatcher.makeSession(), retryDelays: [Duration] = WebhookDispatcher.defaultRetryDelays) {
        self.events = events
        self.session = session
        self.retryDelays = retryDelays
        let subscription = events.subscribe { [weak self] event in self?.dispatch(event) }
        state.withLock { $0.subscription = subscription }
    }

    deinit {
        stop()
    }

    /// No cookies, cache or credentials; at most 10 s per attempt.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = attemptTimeout
        configuration.timeoutIntervalForResource = attemptTimeout
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    public func setEndpoints(_ endpoints: [WebhookEndpoint]) {
        state.withLock { state in
            state.endpoints = endpoints
            let ids = Set(endpoints.map(\.id))
            state.lastDeliveries = state.lastDeliveries.filter { ids.contains($0.key) }
        }
    }

    /// The latest attempt per endpoint id.
    public var lastDeliveries: [UUID: WebhookDeliveryStatus] {
        state.withLock { $0.lastDeliveries }
    }

    /// Called (on any thread) after every delivery attempt.
    public func setStatusHandler(_ handler: (@Sendable (UUID, WebhookDeliveryStatus) -> Void)?) {
        state.withLock { $0.statusHandler = handler }
    }

    /// Stops listening for events and cancels deliveries in progress.
    public func stop() {
        let (subscription, deliveries) = state.withLock { state in
            defer {
                state.subscription = nil
                state.deliveries = [:]
            }
            return (state.subscription, Array(state.deliveries.values))
        }
        if let subscription { events.unsubscribe(subscription) }
        for delivery in deliveries { delivery.cancel() }
    }

    /// `sha256=<hex HMAC-SHA256 of "<timestamp>.<body>" keyed with secret>`, the `X-OpenTraffic-Signature` value.
    /// `timestamp` is the `X-OpenTraffic-Timestamp` value (unix seconds), so receivers can reject replays.
    public static func signature(for body: Data, timestamp: Int, secret: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(timestamp).".utf8) + body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + code.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Delivery

    private func dispatch(_ event: APIEvent) {
        let targets = state.withLock { state -> [WebhookEndpoint] in
            guard state.subscription != nil else { return [] }
            return state.endpoints.filter { $0.enabled && $0.isValidURL && $0.wants(event.type) }
        }
        guard !targets.isEmpty else { return }
        let body = APIJSON.encode(event)
        for endpoint in targets {
            let key = UUID()
            // Created under the lock, so the task can't remove itself before it's registered.
            state.withLock { state in
                guard state.subscription != nil else { return }
                state.deliveries[key] = Task { [weak self] in
                    await self?.deliver(event, body: body, to: endpoint)
                    _ = self?.state.withLock { $0.deliveries.removeValue(forKey: key) }
                }
            }
        }
    }

    private func deliver(_ event: APIEvent, body: Data, to endpoint: WebhookEndpoint) async {
        guard let url = URL(string: endpoint.url) else { return }
        var request = URLRequest(url: url, timeoutInterval: Self.attemptTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OpenTraffic", forHTTPHeaderField: "User-Agent")
        request.setValue(event.type.rawValue, forHTTPHeaderField: "X-OpenTraffic-Event")
        request.setValue(event.id, forHTTPHeaderField: "X-OpenTraffic-Delivery")

        for attempt in 1...(retryDelays.count + 1) {
            if attempt > 1 {
                do { try await Task.sleep(for: retryDelays[attempt - 2]) } catch { return }
                // Removed or turned off while waiting.
                guard state.withLock({ $0.endpoints.contains { $0.id == endpoint.id && $0.enabled } }) else { return }
            }
            // Signed per attempt, so a retry carries a fresh timestamp.
            let timestamp = Int(Date().timeIntervalSince1970)
            request.setValue(String(timestamp), forHTTPHeaderField: "X-OpenTraffic-Timestamp")
            request.setValue(Self.signature(for: body, timestamp: timestamp, secret: endpoint.secret), forHTTPHeaderField: "X-OpenTraffic-Signature")
            var statusCode: Int?
            var failure: String?
            do {
                let (_, response) = try await session.data(for: request, delegate: NoRedirects.shared)
                statusCode = (response as? HTTPURLResponse)?.statusCode
                if let statusCode, (300..<400).contains(statusCode) {
                    failure = "HTTP \(statusCode) (redirects aren't followed)"
                } else if let statusCode, !(200..<300).contains(statusCode) {
                    failure = "HTTP \(statusCode)"
                }
            } catch {
                if Task.isCancelled { return }
                failure = error.localizedDescription
            }
            record(WebhookDeliveryStatus(at: Date(), event: event.type.rawValue, deliveryID: event.id, attempt: attempt, statusCode: statusCode, error: failure), for: endpoint.id)
            if failure == nil { return }
        }
    }

    private func record(_ status: WebhookDeliveryStatus, for endpoint: UUID) {
        let handler = state.withLock { state -> (@Sendable (UUID, WebhookDeliveryStatus) -> Void)? in
            guard state.endpoints.contains(where: { $0.id == endpoint }) else { return nil }
            state.lastDeliveries[endpoint] = status
            return state.statusHandler
        }
        handler?(endpoint, status)
    }
}

/// Refuses every redirect, so a delivery (and its signature) only ever goes to the configured URL;
/// the 3xx response itself is returned instead.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

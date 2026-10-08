import Foundation
import Network

/// A small TCP relay from `127.0.0.1:<ephemeral>` to another host and port.
///
/// Tailscale Serve only proxies to `127.0.0.1`, so servers that listen only on `::1` (common for
/// Vite/Node) or live on another machine need a loopback hop. Bytes are copied unchanged in both
/// directions, so HTTP, HTTPS, and WebSocket upgrades (hot reload) all pass through.
///
/// All mutable state is confined to `queue`.
public final class LoopbackForwarder: @unchecked Sendable {
    public let targetHost: String
    public let targetPort: UInt16

    private let queue = DispatchQueue(label: "OpenTraffic.LoopbackForwarder")
    private var listener: NWListener?
    private var pairs: [ObjectIdentifier: Pair] = [:]
    private static let connectTimeout: TimeInterval = 10

    public init(targetHost: String, targetPort: UInt16) {
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// Starts listening on 127.0.0.1 and returns the port the system assigned.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] inbound in
                self?.accept(inbound)
            }
            queue.sync { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for pair in self.pairs.values { pair.cancel() }
            self.pairs.removeAll()
        }
    }

    /// Whether something accepts TCP connections at host:port within the timeout.
    public static func canConnect(host: String, port: UInt16, timeout: TimeInterval = 1.5) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let once = ResumeOnce()
        let queue = DispatchQueue(label: "OpenTraffic.LoopbackForwarder.probe")
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .waiting, .cancelled:
                    if once.claim() { connection.cancel(); continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { connection.cancel(); continuation.resume(returning: false) }
            }
        }
    }

    // MARK: Relaying (on `queue`)

    private func accept(_ inbound: NWConnection) {
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(targetHost), port: port, using: .tcp)
        let pair = Pair(inbound: inbound, outbound: outbound)
        let key = ObjectIdentifier(pair)
        pairs[key] = pair
        pair.onFinished = { [weak self] in self?.pairs[key] = nil }
        inbound.stateUpdateHandler = { [weak pair] state in
            switch state {
            case .failed, .cancelled: pair?.cancel()
            default: break
            }
        }
        // A refused upstream (dev server down) leaves the connection in .waiting, retrying forever;
        // treat that as a failure so the client gets a closed connection instead of a hang.
        outbound.stateUpdateHandler = { [weak pair] state in
            switch state {
            case .ready: pair?.outboundReady = true
            case .waiting, .failed, .cancelled: pair?.cancel()
            default: break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak pair] in
            if let pair, !pair.outboundReady { pair.cancel() }
        }
        pipe(from: inbound, to: outbound, pair: pair)
        pipe(from: outbound, to: inbound, pair: pair)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection, pair: Pair) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if sendError != nil {
                        pair.cancel()
                    } else if isComplete {
                        pair.finishDirection(to: destination)
                    } else {
                        self?.pipe(from: source, to: destination, pair: pair)
                    }
                })
            } else if isComplete {
                pair.finishDirection(to: destination)
            } else if error != nil {
                pair.cancel()
            } else {
                self?.pipe(from: source, to: destination, pair: pair)
            }
        }
    }

    /// One client connection and its upstream connection. Mutated only on the forwarder's queue.
    private final class Pair: @unchecked Sendable {
        let inbound: NWConnection
        let outbound: NWConnection
        var onFinished: (() -> Void)?
        var outboundReady = false
        private var finishedDirections = 0
        private var isCancelled = false

        init(inbound: NWConnection, outbound: NWConnection) {
            self.inbound = inbound
            self.outbound = outbound
        }

        /// The sending side reached end of stream: pass the half-close on, and tear down once both sides are done.
        func finishDirection(to destination: NWConnection) {
            destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            finishedDirections += 1
            if finishedDirections >= 2 { cancel() }
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            inbound.cancel()
            outbound.cancel()
            onFinished?()
            onFinished = nil
        }
    }
}

/// Guards a continuation against being resumed twice from racing callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

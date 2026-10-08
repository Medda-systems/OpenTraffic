import Foundation
import Network
import Testing
@testable import OpenTrafficCore

// Shapes captured from Tailscale 1.90.6 on a real Mac (hostnames replaced).
private let runningStatus = #"""
{"BackendState":"Running","CertDomains":["macbook.tail1234.ts.net"],
 "Self":{"DNSName":"macbook.tail1234.ts.net.","CapMap":{"https":null,"https://tailscale.com/cap/ssh":null}}}
"""#
private let funnelStatus = #"""
{"BackendState":"Running","Self":{"DNSName":"macbook.tail1234.ts.net.","CapMap":{"https":null,"funnel":null,"https://tailscale.com/cap/funnel-ports?ports=443,8443,10000":null}}}
"""#
private let serveStatus = #"""
{"TCP":{"8443":{"HTTPS":true},"443":{"HTTPS":true}},
 "Web":{"macbook.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:48123"}}},
        "macbook.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},
 "AllowFunnel":{"macbook.tail1234.ts.net:443":true}}
"""#

@Test func parsesRunningStatusWithoutFunnel() throws {
    let status = try #require(TailscaleStatus.parse(Data(runningStatus.utf8)))
    #expect(status.isRunning)
    #expect(status.dnsName == "macbook.tail1234.ts.net")
    #expect(status.httpsEnabled)
    #expect(!status.funnelEnabled)
}

@Test func detectsFunnelCapability() throws {
    let status = try #require(TailscaleStatus.parse(Data(funnelStatus.utf8)))
    #expect(status.funnelEnabled)
    let stopped = try #require(TailscaleStatus.parse(Data(#"{"BackendState":"Stopped","Self":{}}"#.utf8)))
    #expect(!stopped.isRunning)
    #expect(!stopped.httpsEnabled)
    #expect(stopped.dnsName == nil)
}

@Test func parsesServeConfigPortsProxiesAndFunnel() throws {
    let config = try #require(TailscaleServeConfig.parse(Data(serveStatus.utf8)))
    #expect(config.portsInUse == [443, 8443])
    #expect(config.entry(port: 8443) == .init(port: 8443, proxy: "http://127.0.0.1:48123", isFunnel: false))
    #expect(config.entry(port: 443)?.isFunnel == true)
    #expect(TailscaleServeConfig.parse(Data("{}".utf8))?.entries.isEmpty == true)
}

@Test func choosesPreferredThenFirstFreeAllowedPort() {
    #expect(TailscaleShare.choosePort(isPublic: false, preferred: nil, inUse: []) == 443)
    #expect(TailscaleShare.choosePort(isPublic: false, preferred: 9443, inUse: [443]) == 9443)
    #expect(TailscaleShare.choosePort(isPublic: false, preferred: 9443, inUse: [9443, 443]) == 8443)
    #expect(TailscaleShare.choosePort(isPublic: true, preferred: 9443, inUse: [443]) == 8443)
    #expect(TailscaleShare.choosePort(isPublic: true, preferred: nil, inUse: [443, 8443, 10000]) == nil)
}

@Test func buildsShareAndStopCommandsAndURLs() {
    #expect(TailscaleShare.shareArguments(port: 8443, target: "http://127.0.0.1:3000", isPublic: false)
        == ["serve", "--bg", "--yes", "--https=8443", "http://127.0.0.1:3000"])
    #expect(TailscaleShare.shareArguments(port: 443, target: "http://127.0.0.1:3000", isPublic: true).first == "funnel")
    #expect(TailscaleShare.stopArguments(port: 8443, isPublic: false) == ["serve", "--https=8443", "off"])
    #expect(TailscaleShare.url(dnsName: "mac.ts.net", port: 443) == "https://mac.ts.net")
    #expect(TailscaleShare.url(dnsName: "mac.ts.net", port: 8443) == "https://mac.ts.net:8443")
    #expect(TailscaleShare.target(scheme: "https", port: 5000) == "https+insecure://127.0.0.1:5000")
    #expect(TailscaleShare.needsForwarder(host: "::1"))
    #expect(TailscaleShare.needsForwarder(host: "192.168.1.20"))
    #expect(!TailscaleShare.needsForwarder(host: "LOCALHOST"))
}

@Test func recordsOnlyRemoveSharesStillPointingWhereOpenTrafficLeftThem() throws {
    let config = try #require(TailscaleServeConfig.parse(Data(serveStatus.utf8)))
    let ours = TailscaleShareRecord(tunnelID: UUID(), port: 8443, isPublic: false, target: "http://127.0.0.1:48123")
    let replaced = TailscaleShareRecord(tunnelID: UUID(), port: 443, isPublic: true, target: "http://127.0.0.1:9999")
    #expect(ours.stillOwned(in: config))
    #expect(!replaced.stillOwned(in: config))
}

@Test func shareRecordsRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ts-records-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let persistence = TailscaleShareRecordPersistence(fileURL: url)
    #expect(persistence.load().isEmpty)
    let record = TailscaleShareRecord(tunnelID: UUID(), port: 443, isPublic: false, target: "http://127.0.0.1:3000")
    try persistence.save([record])
    #expect(persistence.load() == [record])
}

// MARK: - Loopback forwarder

/// A one-shot echo server on IPv6 loopback, like a dev server that only listens on ::1.
private final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "EchoServer")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let box = Box()
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, box.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                if case .failed(let error) = state, box.claim() { continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                @Sendable func echo() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, _ in
                        if let data, !data.isEmpty {
                            connection.send(content: data, completion: .contentProcessed { _ in if !done { echo() } })
                        }
                        if done { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
                    }
                }
                echo()
            }
            listener.start(queue: queue)
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}

private func roundTrip(_ message: String, port: UInt16) async throws -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "EchoClient")
    connection.start(queue: queue)
    defer { connection.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
        let box = EchoServer.Box()
        connection.send(content: Data(message.utf8), completion: .contentProcessed { error in
            if let error, box.claim() { continuation.resume(throwing: error) }
        })
        connection.receive(minimumIncompleteLength: message.utf8.count, maximumLength: 4096) { data, _, _, error in
            guard box.claim() else { return }
            if let error { continuation.resume(throwing: error) } else {
                continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
            }
        }
        queue.asyncAfter(deadline: .now() + 5) {
            if box.claim() { continuation.resume(throwing: CancellationError()) }
        }
    }
}

@Test func forwarderRelaysLoopbackTrafficToAnIPv6OnlyServer() async throws {
    let server = try EchoServer()
    let serverPort = try await server.start()
    defer { server.listener.cancel() }

    #expect(await LoopbackForwarder.canConnect(host: "::1", port: serverPort))
    #expect(!(await LoopbackForwarder.canConnect(host: "127.0.0.1", port: serverPort)))

    let forwarder = LoopbackForwarder(targetHost: "::1", targetPort: serverPort)
    let port = try await forwarder.start()
    defer { forwarder.stop() }
    #expect(port > 0)
    #expect(try await roundTrip("hello through the tailnet", port: port) == "hello through the tailnet")
    #expect(try await roundTrip("second connection", port: port) == "second connection")
}

@Test func forwarderClosesClientConnectionsWhenTheServerIsDown() async throws {
    // Grab a port nothing listens on.
    let probe = try EchoServer()
    let deadPort = try await probe.start()
    probe.listener.cancel()
    try await Task.sleep(for: .milliseconds(100))

    let forwarder = LoopbackForwarder(targetHost: "::1", targetPort: deadPort)
    let port = try await forwarder.start()
    defer { forwarder.stop() }
    let started = Date()
    // The relay must close the client side promptly instead of holding it while upstream retries.
    let reply = try? await roundTrip("anyone there?", port: port)
    #expect(reply == nil || reply == "")
    #expect(Date().timeIntervalSince(started) < 4)
}

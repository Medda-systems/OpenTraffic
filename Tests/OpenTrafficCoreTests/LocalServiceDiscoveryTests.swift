import Foundation
import os
import Testing
@testable import OpenTrafficCore

private struct StubTransport: HTTPTransport {
    var bodies: [Int: (Int, String)]
    var failures: Set<Int> = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let port = request.url?.port ?? -1
        if failures.contains(port) { throw URLError(.cannotConnectToHost) }
        let (status, body) = bodies[port] ?? (404, "Not Found")
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func parsesLsofListenerRecords() {
    let output = """
    p63125
    cnode
    f10
    n127.0.0.1:5174 (LISTEN)
    p123
    crapportd
    n*:49168
    p124
    n[::1]:8080
    """
    let sockets = LocalListenerParser.parseLsof(output)
    #expect(sockets.count == 3)
    #expect(sockets[0] == ListeningSocket(pid: 63125, processName: "node", host: "127.0.0.1", port: 5174))
    #expect(sockets[1] == ListeningSocket(pid: 123, processName: "rapportd", host: "*", port: 49168))
    #expect(sockets[2] == ListeningSocket(pid: 124, processName: nil, host: "[::1]", port: 8080))
}

@Test func ignoresMalformedLsofLines() {
    let sockets = LocalListenerParser.parseLsof("p1\ncapp\nnnot-a-port\ngarbage\nn10.0.0.1:notaport\n")
    #expect(sockets.isEmpty)
}

@Test func scannerKeepsOnlyReachableHTTPServices() async {
    let sockets = [
        ListeningSocket(pid: 1, processName: "node", host: "127.0.0.1", port: 5174),
        ListeningSocket(pid: 2, processName: "rapportd", host: "*", port: 49168),
        ListeningSocket(pid: 3, processName: "postgres", host: "127.0.0.1", port: 5432),
        ListeningSocket(pid: 4, processName: "nginx", host: "192.168.1.10", port: 80),
        ListeningSocket(pid: 5, processName: "myapp", host: "0.0.0.0", port: 3000),
    ]
    let scanner = LocalServiceScanner(
        transport: StubTransport(
            bodies: [
                5174: (200, "<html><head><title>Orbit  |  Dashboard</title></head></html>"),
                3000: (404, "Not Found"),
            ],
            failures: [5432]
        ),
        listeners: { sockets },
        startTimes: { _ in [:] }
    )
    let services = await scanner.scan()
    #expect(services.map(\.port) == [3000, 5174])
    let vite = services.first(where: { $0.port == 5174 })
    #expect(vite?.title == "Orbit | Dashboard")
    #expect(vite?.url == "http://localhost:5174")
    #expect(vite?.displayName == "Orbit | Dashboard")
    #expect(services.first(where: { $0.port == 3000 })?.displayName == "myapp :3000")
}

@Test func scannerMergesDuplicatePortsPreferringProcessNames() async {
    let sockets = [
        ListeningSocket(pid: nil, processName: nil, host: "0.0.0.0", port: 8080),
        ListeningSocket(pid: 9, processName: "Python", host: "127.0.0.1", port: 8080),
    ]
    let scanner = LocalServiceScanner(
        transport: StubTransport(bodies: [8080: (200, "<title>Docs</title>")]),
        listeners: { sockets },
        startTimes: { _ in [:] }
    )
    let services = await scanner.scan()
    #expect(services.count == 1)
    #expect(services.first?.processName == "Python")
    #expect(services.first?.displayName == "Docs")
}

/// Counts probes per port; ports in `notHTTP` answer with something that isn't HTTP.
private final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    let notHTTP: Set<Int>

    init(notHTTP: Set<Int>) {
        self.notHTTP = notHTTP
    }

    func probes(_ port: Int) -> Int { lock.withLock { counts[port] ?? 0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let port = request.url?.port ?? -1
        lock.withLock { counts[port, default: 0] += 1 }
        if notHTTP.contains(port) { throw URLError(.badServerResponse) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func scannerSkipsWellKnownNonHTTPServers() async {
    let sockets = [
        ListeningSocket(pid: 1, processName: "Postgres", host: "127.0.0.1", port: 15432),
        ListeningSocket(pid: 2, processName: "redis-server", host: "127.0.0.1", port: 16379),
        ListeningSocket(pid: 3, processName: "beam.smp", host: "127.0.0.1", port: 15672),
        ListeningSocket(pid: 4, processName: "docker", host: "127.0.0.1", port: 3306),
        ListeningSocket(pid: 5, processName: nil, host: "0.0.0.0", port: 22),
        ListeningSocket(pid: 6, processName: "node", host: "127.0.0.1", port: 5173),
    ]
    let transport = CountingTransport(notHTTP: [])
    let scanner = LocalServiceScanner(transport: transport, listeners: { sockets }, startTimes: { _ in [:] }, probeMemo: LocalServiceProbeMemo())
    #expect(await scanner.scan().map(\.port) == [5173])
    for socket in sockets where socket.port != 5173 {
        #expect(transport.probes(socket.port) == 0, "\(socket.port)")
    }
}

@Test func scannerDoesntReprobeNonHTTPListenersWhileTheSameProcessOwnsThePort() async {
    let current = OSAllocatedUnfairLock(initialState: [
        ListeningSocket(pid: 7, processName: "custom-db", host: "127.0.0.1", port: 9000),
        ListeningSocket(pid: 8, processName: "node", host: "127.0.0.1", port: 5173),
    ])
    let transport = CountingTransport(notHTTP: [9000])
    let scanner = LocalServiceScanner(transport: transport, listeners: { current.withLock { $0 } }, startTimes: { _ in [:] }, probeMemo: LocalServiceProbeMemo())
    #expect(await scanner.scan().map(\.port) == [5173])
    #expect(await scanner.scan().map(\.port) == [5173])
    #expect(transport.probes(9000) == 1)
    #expect(transport.probes(5173) == 2)
    // Another process took the port: probed again.
    current.withLock { $0[0] = ListeningSocket(pid: 9, processName: "custom-db", host: "127.0.0.1", port: 9000) }
    _ = await scanner.scan()
    #expect(transport.probes(9000) == 2)
}

@Test func displayNameFallsBackToFriendlyProcessNames() {
    #expect(DiscoveredLocalService(port: 1, processName: "node").displayName == "Node.js :1")
    #expect(DiscoveredLocalService(port: 2, processName: nil).displayName == "Service :2")
    #expect(DiscoveredLocalService(port: 3, processName: "custom-server").displayName == "custom-server :3")
}

@Test func titleExtractionHandlesMissingTitles() {
    #expect(LocalServiceTitle.extract(from: Data("plain text".utf8)) == nil)
    #expect(LocalServiceTitle.extract(from: Data("<TITLE>  Spaced  </TITLE>".utf8)) == "Spaced")
}

@Test func parsesPsStartTimes() {
    let output = "     1 Thu Oct  1 16:15:52 2026    \n 63125 Fri Oct  2 10:24:54 2026    \n"
    let starts = ProcessStartTimeParser.parsePs(output)
    #expect(starts.count == 2)
    #expect(starts[1]?.description.contains("2026-10-01") == true)
    #expect(starts[63125]?.description.contains("2026-10-02") == true)
    #expect(ProcessStartTimeParser.parsePs("not a line\n").isEmpty)
}

@Test func scannerSortsNewestFirstWithUnknownLast() async {
    let old = Date(timeIntervalSince1970: 1_000_000)
    let new = Date(timeIntervalSince1970: 2_000_000)
    let sockets = [
        ListeningSocket(pid: 1, processName: "old", host: "127.0.0.1", port: 3000),
        ListeningSocket(pid: 2, processName: "new", host: "127.0.0.1", port: 5174),
        ListeningSocket(pid: 3, processName: "mystery", host: "127.0.0.1", port: 8080),
    ]
    let starts: [Int32: Date] = [1: old, 2: new]
    let scanner = LocalServiceScanner(
        transport: StubTransport(bodies: [3000: (200, "a"), 5174: (200, "b"), 8080: (200, "c")]),
        listeners: { sockets },
        startTimes: { pids in starts.filter { pids.contains($0.key) } }
    )
    let services = await scanner.scan()
    #expect(services.map(\.port) == [5174, 3000, 8080])
    #expect(services.first?.startedAt == new)
}

// MARK: Uptime

@Test func uptimeStartsAtProcessStartAndSurvivesOneMissedScan() {
    var tracker = LocalServiceUptimeTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    let vite = DiscoveredLocalService(port: 5173, processName: "node", startedAt: start, pid: 42)
    var now = Date(timeIntervalSince1970: 2_000)
    // Running before OpenTraffic looked: its process start time counts.
    #expect(tracker.update(with: [vite], now: now).first?.upSince == start)
    // One missed scan (busy rebuilding): still listed, uptime kept.
    now += 4
    #expect(tracker.update(with: [], now: now).first?.upSince == start)
    now += 4
    #expect(tracker.update(with: [vite], now: now).first?.upSince == start)
}

@Test func uptimeResetsAfterDowntimeOrARestart() {
    var tracker = LocalServiceUptimeTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    let vite = DiscoveredLocalService(port: 5173, startedAt: start, pid: 42)
    var now = Date(timeIntervalSince1970: 2_000)
    _ = tracker.update(with: [vite], now: now)
    // Two missed scans: down, and off the list.
    now += 4; _ = tracker.update(with: [], now: now)
    now += 4
    #expect(tracker.update(with: [], now: now).isEmpty)
    // Back (same process recovered): uptime starts no earlier than the last scan that saw it down.
    let downSeenAt = now
    now += 4
    #expect(tracker.update(with: [vite], now: now).first?.upSince == downSeenAt)
    // Replaced by a new process between scans: the new process's start time.
    let restarted = DiscoveredLocalService(port: 5173, startedAt: now + 2, pid: 43)
    now += 4
    #expect(tracker.update(with: [restarted], now: now).first?.upSince == restarted.startedAt)
}

@Test func mostRecentlyUpComesFirst() {
    var tracker = LocalServiceUptimeTracker()
    let old = DiscoveredLocalService(port: 3000, startedAt: Date(timeIntervalSince1970: 100), pid: 1)
    let new = DiscoveredLocalService(port: 5173, startedAt: Date(timeIntervalSince1970: 900), pid: 2)
    #expect(tracker.update(with: [old, new], now: Date(timeIntervalSince1970: 1_000)).map(\.port) == [5173, 3000])
}

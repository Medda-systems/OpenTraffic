import Foundation
import Testing
@testable import OpenTrafficCore

// opentraffic-mcp end to end: the built binary relaying stdio to a test API server.

/// `opentraffic-mcp` next to the test bundle (swift test builds every product), or in .build/debug.
private func bridgeBinary() throws -> URL {
    let products = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [products, package.appending(path: ".build/debug")].compactMap { $0?.appending(path: "opentraffic-mcp") }
    return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Build opentraffic-mcp first")
}

/// A running bridge process and the lines it writes.
private final class Bridge: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let lines: AsyncStream<String>

    init(port: Int, tokenFile: URL) throws {
        process.executableURL = try bridgeBinary()
        process.environment = [
            "OPENTRAFFIC_API_PORT": String(port),
            // Not the app's real private socket: this test talks to its own server over HTTP.
            "OPENTRAFFIC_SOCKET": "/tmp/ot-test-no-such.sock",
            "OPENTRAFFIC_API_TOKEN_FILE": tokenFile.path,
            "OPENTRAFFIC_CLIENT": "Bridge Test",
        ]
        process.standardInput = input
        process.standardOutput = output
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        lines = stream
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                for line in buffer.append(data) { continuation.yield(line) }
            }
        }
        try process.run()
    }

    func send(_ message: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
    }

    func closeInput() throws {
        try input.fileHandleForWriting.close()
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending = Data(pending[pending.index(after: newline)...])
            }
            return lines
        }
    }
}

private func message(_ line: String?) throws -> [String: Any] {
    let line = try #require(line, "The bridge stopped writing")
    return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

@Test func bridgeRelaysStdioToTheAPIConcurrently() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let tokenFile = FileManager.default.temporaryDirectory.appending(path: "opentraffic-bridge-\(UUID().uuidString)")
    try Data(APIHarness.token.utf8).write(to: tokenFile)
    defer { try? FileManager.default.removeItem(at: tokenFile) }

    let bridge = try Bridge(port: api.port, tokenFile: tokenFile)
    // Never hang the test run: a killed bridge ends the output stream.
    let watchdog = Task {
        try await Task.sleep(for: .seconds(30))
        bridge.process.terminate()
    }
    defer { watchdog.cancel() }
    var lines = bridge.lines.makeAsyncIterator()

    try bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
    let initialized = try message(await lines.next())
    #expect(initialized["id"] as? Int == 1)
    #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    try bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

    try bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reply_to_comment","arguments":{"share":"Orbit","comment_id":"c1","text":"On it"}}}"#)
    let replied = try message(await lines.next())
    #expect(replied["id"] as? Int == 2)
    // The pretty JSON text block survives as one line.
    #expect(((replied["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String != nil)
    #expect(api.backend.clients == ["Bridge Test"])

    // A long wait doesn't hold up a ping sent after it.
    try bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait_for_feedback","arguments":{"timeout_seconds":20}}}"#)
    try await Task.sleep(for: .milliseconds(300))
    try bridge.send(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
    #expect(try message(await lines.next())["id"] as? Int == 4)
    api.events.append(.commentCreated, share: api.backend.shareRef, comment: api.backend.comment("c1"))
    let waited = try message(await lines.next())
    #expect(waited["id"] as? Int == 3)
    let events = ((waited["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["events"] as? [[String: Any]]
    #expect(events?.first?["type"] as? String == "comment.created")

    // At end of input, requests in flight still get their answer before the bridge exits.
    try bridge.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"wait_for_feedback","arguments":{"timeout_seconds":0.5}}}"#)
    try bridge.closeInput()
    #expect(try message(await lines.next())["id"] as? Int == 5)
    #expect(await lines.next() == nil)
    #expect(await eventually { !bridge.process.isRunning })
    #expect(bridge.process.terminationStatus == 0)
}

@Test func bridgeExplainsHowToTurnTheAPIOn() async throws {
    let tokenFile = FileManager.default.temporaryDirectory.appending(path: "opentraffic-bridge-\(UUID().uuidString)")
    try Data("token".utf8).write(to: tokenFile)
    defer { try? FileManager.default.removeItem(at: tokenFile) }

    for file in [tokenFile, tokenFile.appendingPathExtension("missing")] {
        // Nothing listens on port 1.
        let bridge = try Bridge(port: 1, tokenFile: file)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            bridge.process.terminate()
        }
        defer { watchdog.cancel() }
        var lines = bridge.lines.makeAsyncIterator()
        try bridge.send(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
        try bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try bridge.closeInput()
        let reply = try message(await lines.next())
        #expect(reply["id"] as? String == "a")
        let error = try #require(reply["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("Allow apps on this Mac") == true)
        #expect(await lines.next() == nil)
        #expect(await eventually { !bridge.process.isRunning })
    }
}

import Foundation
import OpenTrafficSocket

// opentraffic-mcp — OpenTraffic's MCP server for clients that launch servers over stdio.
//
// Relays newline-delimited JSON-RPC from stdin to OpenTraffic (POST /mcp) and writes each reply to stdout
// as one line. Requests run concurrently, so a long wait_for_feedback doesn't hold up anything else.
// It talks over OpenTraffic's private socket, where the app checks that this is its own signed bridge:
// no setup, token, or confirmations, and it starts OpenTraffic in the background if it isn't running.
// An older OpenTraffic without the socket is reached through its HTTP API. Environment:
//   OPENTRAFFIC_API_PORT        the API's port (default 47777)
//   OPENTRAFFIC_CLIENT          the name OpenTraffic shows for this app (default "MCP client")
//   OPENTRAFFIC_API_TOKEN_FILE  the token file (default ~/Library/Application Support/OpenTraffic/api-token)

/// Writes whole lines to stdout, one at a time.
final class Output: @unchecked Sendable {
    private let lock = NSLock()

    func write(line data: Data) {
        lock.withLock {
            do {
                try FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
            } catch {
                // The client went away.
                exit(0)
            }
        }
    }
}

/// Starts this copy of OpenTraffic in the background (menu bar only, no window), once.
enum AppLauncher {
    nonisolated(unsafe) private static var launched = false
    private static let lock = NSLock()

    /// Whether it launched OpenTraffic now (so it's worth waiting for it to answer).
    static func launchIfNeeded() -> Bool {
        lock.withLock {
            guard !launched else { return false }
            launched = true
            // …/OpenTraffic.app/Contents/MacOS/opentraffic-mcp
            let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            // Only the bridge inside an app starts that app (not a development build, or a test).
            guard app.pathExtension == "app" else { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-j", "-a", app.path, "--args", "--background"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
}

struct Bridge: Sendable {
    static let enableHint = "In OpenTraffic, turn on Settings → Integrations → “Allow apps on this Mac”."

    let endpoint: URL
    let port: Int
    let client: String
    let tokenFile: URL
    let session: URLSession
    let output: Output

    init(environment: [String: String]) {
        port = environment["OPENTRAFFIC_API_PORT"].flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? $0 : nil } ?? 47777
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") ?? URL(fileURLWithPath: "/")
        let name = environment["OPENTRAFFIC_CLIENT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = name.isEmpty ? "MCP client" : name
        if let path = environment["OPENTRAFFIC_API_TOKEN_FILE"], !path.isEmpty {
            tokenFile = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
            tokenFile = support.appending(path: "OpenTraffic/api-token")
        }
        let configuration = URLSessionConfiguration.ephemeral
        // wait_for_feedback may hold a request for up to 300 s.
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = 660
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        output = Output()
    }

    /// Sends one message to OpenTraffic and writes its reply, if any.
    func relay(_ line: String) async {
        let message = Data(line.utf8)
        let client = self.client
        func overSocket() async throws -> AppSocket.Response {
            try await Task.detached { try AppSocket.send("POST", "/mcp", body: message, client: client) }.value
        }
        var answer = try? await overSocket()
        if answer == nil, AppLauncher.launchIfNeeded() {
            for _ in 0..<80 where answer == nil {
                try? await Task.sleep(for: .milliseconds(250))
                answer = try? await overSocket()
            }
        }
        if let answer {
            if Self.isJSONRPC(answer.body) {
                output.write(line: Self.singleLine(answer.body))
            } else if !(200..<300).contains(answer.status) {
                fail(message, "OpenTraffic answered HTTP \(answer.status): \(Self.errorMessage(in: answer.body) ?? "no details").")
            }
            return
        }
        await relayOverHTTP(message)
    }

    /// An older OpenTraffic, without the private socket: its HTTP API, with the token.
    private func relayOverHTTP(_ message: Data) async {
        guard let token = readToken() else {
            fail(message, "OpenTraffic's API token wasn't found at \(tokenFile.path). \(Self.enableHint)")
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(client, forHTTPHeaderField: "X-OpenTraffic-Client")

        let body: Data
        let status: Int
        do {
            let (data, response) = try await session.data(for: request)
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            fail(message, "OpenTraffic isn't reachable on 127.0.0.1:\(port). Make sure it's running. \(Self.enableHint)")
            return
        }
        if Self.isJSONRPC(body) {
            output.write(line: Self.singleLine(body))
        } else if status == 401 {
            fail(message, "OpenTraffic didn't accept the API token in \(tokenFile.path). It's read again on every request, so no restart is needed; check that the file holds OpenTraffic's current token.")
        } else if !(200..<300).contains(status) {
            fail(message, "OpenTraffic answered HTTP \(status): \(Self.errorMessage(in: body) ?? "no details").")
        }
        // 202: a notification or response, nothing to write.
    }

    private func readToken() -> String? {
        guard let data = try? Data(contentsOf: tokenFile),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Answers the requests in `message` (those with an id) with a JSON-RPC error.
    private func fail(_ message: Data, _ text: String) {
        let parsed = try? JSONSerialization.jsonObject(with: message)
        func error(id: Any) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]]
        }
        func requestID(_ item: Any) -> Any? {
            guard let object = item as? [String: Any], object["method"] != nil else { return nil }
            return object["id"]
        }
        let reply: Any?
        switch parsed {
        case let batch as [Any]:
            let errors = batch.compactMap(requestID).map(error)
            reply = errors.isEmpty ? nil : errors
        case nil:
            reply = error(id: NSNull())
        case let item?:
            reply = requestID(item).map(error)
        }
        if let reply, let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
            output.write(line: data)
        }
    }

    static func isJSONRPC(_ body: Data) -> Bool {
        switch try? JSONSerialization.jsonObject(with: body) {
        case let object as [String: Any]: object["jsonrpc"] != nil
        case is [Any]: true
        default: false
        }
    }

    /// The body as one line; JSON never needs a raw newline outside strings.
    static func singleLine(_ body: Data) -> Data {
        guard body.contains(0x0A) || body.contains(0x0D) else { return body }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return Data(body.filter { $0 != 0x0A && $0 != 0x0D })
        }
        return data
    }

    /// `message` from the REST API's `{error: {code, message}}`.
    static func errorMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

signal(SIGPIPE, SIG_IGN)
let bridge = Bridge(environment: ProcessInfo.processInfo.environment)
let inFlight = DispatchGroup()
while let line = readLine(strippingNewline: true) {
    let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { continue }
    inFlight.enter()
    Task.detached { [bridge] in
        await bridge.relay(message)
        inFlight.leave()
    }
}
inFlight.wait()
exit(0)

import Foundation
import OpenTrafficSocket

/// A failure the command-line tool reports, with its exit status.
enum CLIError: Error {
    /// The command was used wrong (exit 2).
    case usage(String)
    /// OpenTraffic said no, or something failed (exit 1).
    case failed(String)
    /// OpenTraffic isn't reachable or isn't set up (exit 3).
    case unavailable(String)

    var status: Int32 {
        switch self {
        case .usage: 2
        case .failed: 1
        case .unavailable: 3
        }
    }

    var message: String {
        switch self {
        case .usage(let text), .failed(let text), .unavailable(let text): text
        }
    }
}

/// Where OpenTraffic and its local API are.
struct AppLocation {
    /// The app bundle this tool came in, when it runs from one (through a symlink or not).
    let appURL: URL?
    let bundleID: String
    let port: Int
    let tokenFile: URL

    static let defaultPort = 47777

    init(environment: [String: String] = ProcessInfo.processInfo.environment, executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) {
        // …/OpenTraffic.app/Contents/MacOS/opentraffic-cli
        let resolved = executable.resolvingSymlinksInPath()
        let bundle = resolved.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let infoBundleID = bundle.pathExtension == "app" ? Bundle(url: bundle)?.bundleIdentifier : nil
        appURL = infoBundleID == nil ? nil : bundle
        bundleID = environment["OPENTRAFFIC_BUNDLE_ID"]?.nonEmpty ?? infoBundleID ?? "se.medda.opentraffic"
        let savedPort = (Self.preference("apiPort", of: bundleID) as? Int) ?? 0
        port = environment["OPENTRAFFIC_API_PORT"].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
            ?? ((1...65535).contains(savedPort) ? savedPort : Self.defaultPort)
        if let path = environment["OPENTRAFFIC_API_TOKEN_FILE"]?.nonEmpty {
            tokenFile = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
            tokenFile = support.appending(path: "OpenTraffic/api-token")
        }
    }

    /// Settings → Integrations → "Allow apps on this Mac to use OpenTraffic".
    var apiEnabled: Bool {
        Self.preference("apiEnabled", of: bundleID) as? Bool ?? false
    }

    /// The app's own setting. (Inside the app bundle this tool shares its identifier, which
    /// `UserDefaults(suiteName:)` refuses; Core Foundation reads any app's preferences.)
    static func preference(_ key: String, of bundleID: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, bundleID as CFString)
    }

    var token: String? {
        guard let data = try? Data(contentsOf: tokenFile) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}

/// Talks to OpenTraffic, starting it in the background (no window) when it isn't running. It uses the
/// app's private socket, where OpenTraffic checks that this is its own signed tool: no setup, token, or
/// confirmations. An older OpenTraffic without the socket is reached through its HTTP API instead.
final class Client: Sendable {
    let location: AppLocation
    private let session: URLSession
    let socketPath = AppSocket.path()

    init(location: AppLocation) {
        self.location = location
        let configuration = URLSessionConfiguration.ephemeral
        // Publishing can wait for the user to answer OpenTraffic's confirmation.
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = 660
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    struct Response {
        let status: Int
        let body: Data
    }

    /// One request; API errors become `CLIError.failed` with OpenTraffic's message.
    @discardableResult
    func request(_ method: String, _ path: String, body: Data? = nil, accept: Set<Int> = []) async throws -> Response {
        try await ensureReachable()
        let response = try await send(method, path, body: body)
        guard (200..<300).contains(response.status) || accept.contains(response.status) else {
            throw CLIError.failed(Self.errorMessage(in: response.body) ?? "OpenTraffic answered HTTP \(response.status).")
        }
        return response
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> (T, Data) {
        let response = try await request("GET", path)
        return (try decode(type, from: response.body), response.body)
    }

    func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any?]? = nil, as type: T.Type) async throws -> (T, Data) {
        let response = try await request(method, path, body: body.map(JSON.encode))
        return (try decode(type, from: response.body), response.body)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSON.decoder.decode(type, from: data)
        } catch {
            throw CLIError.failed("OpenTraffic sent something this version of the opentraffic command doesn't understand. Update OpenTraffic and try again.")
        }
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Response {
        let socket = socketPath
        do {
            let answer = try await Task.detached {
                try AppSocket.send(method, path, body: body, client: "opentraffic command", socketPath: socket)
            }.value
            return Response(status: answer.status, body: answer.body)
        } catch AppSocket.Failure.broken(let message) {
            throw CLIError.unavailable(message)
        } catch {
            // No socket: an older OpenTraffic, reached through its HTTP API.
            return try await sendOverHTTP(method, path, body: body)
        }
    }

    private func sendOverHTTP(_ method: String, _ path: String, body: Data?) async throws -> Response {
        guard let token = location.token else {
            throw CLIError.unavailable("OpenTraffic isn't answering. Open it (and update it, if it's older than 1.0.8), then try again.")
        }
        guard let url = URL(string: "http://127.0.0.1:\(location.port)\(path)") else { throw CLIError.usage("Invalid request path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("opentraffic command", forHTTPHeaderField: "X-OpenTraffic-Client")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                throw CLIError.unavailable("OpenTraffic didn't accept the API token in \(location.tokenFile.path). If you made a new token in Settings → Integrations, run the command again.")
            }
            return Response(status: status, body: data)
        } catch let error as CLIError {
            throw error
        } catch {
            throw Unreachable()
        }
    }

    private struct Unreachable: Error {}

    // MARK: Reaching the app

    func answers() async -> Bool {
        do {
            _ = try await send("GET", "/v1/shares", body: nil)
            return true
        } catch {
            return false
        }
    }

    /// Makes sure OpenTraffic answers, starting it in the background (no window) if it isn't running.
    func ensureReachable() async throws {
        if await answers() { return }
        if !isAppRunning { try launchInBackground() }
        for _ in 0..<80 {
            if await answers() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CLIError.unavailable(location.appURL == nil
            ? "OpenTraffic isn't answering. Is it installed in Applications? Get it at https://opentraffic.dev"
            : "OpenTraffic isn't answering. Quit it and run the command again, or update OpenTraffic.")
    }

    var isAppRunning: Bool {
        let output = Shell.run("/bin/ps", ["-axo", "command="]) ?? ""
        let executable = location.appURL.map { $0.appending(path: "Contents/MacOS/OpenTraffic").path }
        return output.split(separator: "\n").contains { line in
            if let executable { return line.hasPrefix(executable) }
            return line.contains(".app/Contents/MacOS/OpenTraffic") && !line.contains("opentraffic-")
        }
    }

    /// Starts OpenTraffic in the menu bar without opening its window or taking focus.
    func launchInBackground() throws {
        var arguments = ["-g", "-j"]
        if let app = location.appURL { arguments += ["-a", app.path] } else { arguments += ["-b", location.bundleID] }
        arguments += ["--args", "--background"]
        guard Shell.run("/usr/bin/open", arguments) != nil else {
            throw CLIError.unavailable("Couldn't start OpenTraffic. Is it installed in Applications?")
        }
    }

    /// Hands a link to this copy of OpenTraffic (not whichever copy macOS would pick).
    func openLink(_ link: String) throws {
        guard Shell.run("/usr/bin/open", ["-g", "-b", location.bundleID, link]) != nil else {
            throw CLIError.failed("Couldn't reach OpenTraffic.")
        }
    }

    /// `message` from the API's `{error: {code, message}}`, naming this command's options where the
    /// API names its request fields.
    static func errorMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any], let message = error["message"] as? String else { return nil }
        switch error["code"] as? String {
        case "dns_record_exists":
            return message.replacingOccurrences(of: "Send replaceDNS: true to replace it", with: "Add --replace-dns to replace it")
        default:
            return message
        }
    }

    /// Nothing to turn on any more: just makes sure OpenTraffic is running and answers.
    func setUp() async throws -> Bool {
        try await ensureReachable()
        return true
    }
}

enum Shell {
    /// Runs a program and returns what it printed, or nil if it failed.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        do {
            try process.run()
        } catch {
            return nil
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// For a path segment in an API URL.
    var pathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? self
    }
}

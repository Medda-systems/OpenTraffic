import Foundation

// Mac apps you are building, as the local API shows and shares them (see MacAppDiscovery and
// MacAppSession): listed by `GET /v1/services`, shared with `POST /v1/shares {"macApp": ...}`.

/// A Mac app OpenTraffic found on this Mac (the menu bar's Mac Apps list).
public struct APIMacApp: Codable, Equatable, Sendable {
    /// "macapp".
    public let kind: String
    public let name: String
    /// The .app's path: pass it (or the name) as `macApp` to share it.
    public let bundle: String
    public let bundleIdentifier: String?
    /// The folder of the project it's built from, when known: where comments get fixed.
    public let projectDirectory: String?
    /// A debug build that is running now (otherwise a recent build).
    public let running: Bool
    public let builtAt: Date?
    /// The share that publishes it right now, if one does.
    public let sharedAs: String?
    /// For an app in a booted Simulator, the device ("iPhone 17 Simulator"); nil for a Mac app.
    public let device: String?

    public init(_ app: MacApp, sharedAs: String?) {
        kind = "macapp"
        name = app.name
        bundle = app.bundle.path
        bundleIdentifier = app.bundleIdentifier
        projectDirectory = app.projectDirectory?.path
        running = app.isRunning
        builtAt = app.builtAt
        self.sharedAs = sharedAs
        device = app.simulator?.label
    }
}

/// The Mac app a share publishes, and how its isolated copy is doing.
public struct APIShareMacApp: Codable, Equatable, Sendable {
    /// The .app's path.
    public let path: String
    public let name: String
    /// "copy" (a copy of the app's data) or "empty".
    public let data: String
    /// While the share runs: "starting", "running", "restarting", "crashed", "failed", or "stopped".
    public let state: String?
    /// Browsers showing the app right now.
    public let viewers: Int?
    /// The latest thing worth a look (dropped entitlements, an action the app refused).
    public let warning: String?
    /// Why it crashed or failed.
    public let error: String?

    public init(path: String, name: String, data: String, state: String? = nil, viewers: Int? = nil, warning: String? = nil, error: String? = nil) {
        self.path = path
        self.name = name
        self.data = data
        self.state = state
        self.viewers = viewers
        self.warning = warning
        self.error = error
    }

    /// The API's name for a session state, and the message that comes with it.
    public static func describe(_ state: MacAppSession.State) -> (state: String, error: String?) {
        switch state {
        case .idle, .starting: ("starting", nil)
        case .running: ("running", nil)
        case .restarting: ("restarting", nil)
        case .crashed(let message): ("crashed", message)
        case .failed(let message): ("failed", message)
        case .stopped: ("stopped", nil)
        }
    }
}

/// What `macApp` names: an .app by its path, or a Mac app OpenTraffic lists, by name.
public enum APIMacAppReference: Equatable, Sendable {
    case path(String)
    case name(String)

    public init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPath = text.hasPrefix("/") || text.hasPrefix("~") || text.contains("/") || text.lowercased().hasSuffix(".app")
        self = isPath ? .path(text) : .name(text)
    }

    public enum Match: Equatable, Sendable {
        case found(MacApp)
        case none
        /// Several apps have the name (different projects): give the path instead.
        case ambiguous([MacApp])
    }

    /// The app called `name` (its display name or its bundle's file name, in any case). Of several,
    /// the one that is running wins when only one is.
    public static func match(_ name: String, in apps: [MacApp]) -> Match {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let matches = apps.filter { app in
            let file = app.bundle.deletingPathExtension().lastPathComponent
            guard app.name.caseInsensitiveCompare(name) == .orderedSame || file.caseInsensitiveCompare(name) == .orderedSame else { return false }
            return seen.insert(app.id).inserted
        }
        if matches.count == 1 { return .found(matches[0]) }
        let running = matches.filter(\.isRunning)
        if running.count == 1 { return .found(running[0]) }
        return matches.isEmpty ? .none : .ambiguous(matches)
    }
}

extension OpenTrafficAPIError {
    /// Sharing a Mac app needs Accessibility and Screen Recording for OpenTraffic.
    public static func missingMacAppPermissions(_ missing: [MacAppSession.Permission]) -> OpenTrafficAPIError {
        let names = missing.map(\.title)
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.joined()
        return OpenTrafficAPIError(
            status: 409,
            code: "missing_permissions",
            message: "OpenTraffic needs \(list) to share Mac apps. Turn \(names.count > 1 ? "them" : "it") on for OpenTraffic in System Settings → Privacy & Security (OpenTraffic's menu bar shows how), then share again."
        )
    }
}

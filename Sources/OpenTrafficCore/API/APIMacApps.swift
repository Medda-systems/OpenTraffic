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
    /// An installed app or another developer's (TextEdit, an App Store app) that is running, not one
    /// you're building: shared as a copy like yours, never rebuilt.
    public let installed: Bool

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
        installed = app.isInstalled
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
    /// Who may control the app: the mode, who has control and who asks for it.
    public let control: APIMacAppControl?
    /// Rebuilding it when its sources change: whether a build runs or the latest one failed (and why).
    /// Nil when the share doesn't rebuild the app (no project found, a Simulator app, not running).
    public let build: APIMacAppBuild?
    /// An installed app or another developer's (TextEdit, an App Store app): it is never rebuilt.
    public let installed: Bool?

    public init(path: String, name: String, data: String, state: String? = nil, viewers: Int? = nil, warning: String? = nil, error: String? = nil,
                control: APIMacAppControl? = nil, build: APIMacAppBuild? = nil, installed: Bool? = nil) {
        self.path = path
        self.name = name
        self.data = data
        self.state = state
        self.viewers = viewers
        self.warning = warning
        self.error = error
        self.control = control
        self.build = build
        self.installed = installed
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

/// Rebuilding a shared Mac app from its sources (`APIShareMacApp.build`, and the `build.*` events).
public struct APIMacAppBuild: Codable, Equatable, Sendable {
    /// "idle" (no build runs; the latest, if any, succeeded), "building", or "failed" (viewers see the
    /// version from before the change until a build succeeds).
    public let state: String
    /// `failed`: why, with the compiler's first error (`The build failed (swift build): Orders.swift:12:5: error: …`).
    public let message: String?
    /// The latest build's full output, once one ran.
    public let log: String?
    /// What builds it (`swift build … && sh package.sh`, `xcodebuild -scheme Orbit … build`).
    public let command: String?

    public init(state: String, message: String? = nil, log: String? = nil, command: String? = nil) {
        self.state = state
        self.message = message
        self.log = log
        self.command = command
    }

    public init(_ state: MacAppSession.BuildState, log: URL?, command: String?) {
        switch state {
        case .idle: self.init(state: "idle", log: log?.path, command: command)
        case .building: self.init(state: "building", log: log?.path, command: command)
        case .failed(let message): self.init(state: "failed", message: message, log: log?.path, command: command)
        }
    }

    /// The event a change from `old` to `new` makes: a build started, failed, or succeeded (`building`
    /// to `idle` while the app still runs; a share stopping mid-build is no success).
    public static func event(from old: MacAppSession.BuildState, to new: MacAppSession.BuildState, running: Bool) -> APIEvent.Kind? {
        switch (old, new) {
        case (_, .building) where old != .building: .buildStarted
        case (_, .failed): .buildFailed
        case (.building, .idle) where running: .buildSucceeded
        default: nil
        }
    }
}

/// Who may control a shared Mac app (`APIShareMacApp.control`): the host's choice on the card and,
/// with ask to control, who has control and who asks for it.
public struct APIMacAppControl: Codable, Equatable, Sendable {
    /// "everyone", "watchOnly", or "askToControl".
    public let mode: String
    /// `askToControl`: the viewer the host gave control; nil while only the host controls the app.
    public let holder: APIControlViewer?
    /// `askToControl`: viewers asking for control, oldest first.
    public let requests: [APIControlViewer]

    public init(mode: String, holder: APIControlViewer? = nil, requests: [APIControlViewer] = []) {
        self.mode = mode
        self.holder = holder
        self.requests = requests
    }

    public init(_ state: MirrorServer.ControlState) {
        self.init(
            mode: state.mode.rawValue,
            holder: state.holder.map { APIControlViewer(viewer: $0.viewer, name: $0.name, since: $0.since, connected: $0.connected) },
            requests: state.requests.map { APIControlViewer(viewer: $0.viewer, name: $0.name, since: $0.since) }
        )
    }

    /// What the host does with ask to control: `allow` a viewer who asks (they get control; whoever had
    /// it loses it), `deny` a request (their page says so; they may ask again), or `take-back` control.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case allow
        case deny
        case takeBack = "take-back"

        /// `take-back`, also written `take_back` or `takeBack`.
        public init?(api: String) {
            switch api.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "allow": self = .allow
            case "deny": self = .deny
            case "take-back", "takeback": self = .takeBack
            default: return nil
            }
        }
    }

    /// The viewer an action applies to: for `allow` and `deny`, the request `viewer` names (its
    /// number, or its name in any case) or, without one, the oldest; nil for `take-back`. Throws what
    /// the caller should see when the share doesn't ask, nobody asks, or the viewer isn't asking.
    public static func target(of action: Action, viewer: String?, in state: MirrorServer.ControlState, share: String) throws -> Int? {
        let trimmed = viewer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewer = trimmed.isEmpty ? nil : trimmed
        guard state.mode == .askToControl else {
            let now = state.mode == .watchOnly ? "viewers only watch" : "every viewer controls the app"
            throw OpenTrafficAPIError.conflict("“\(share)” doesn't ask to control: \(now). Set it to ask to control first (macAppControl askToControl, or `opentraffic set \"\(share)\" --control ask`).")
        }
        if action == .takeBack {
            guard viewer == nil else { throw OpenTrafficAPIError.badRequest("take-back takes no viewer: only one viewer has control at a time.") }
            guard state.holder != nil else { throw OpenTrafficAPIError.conflict("Nobody has control of “\(share)” but you.") }
            return nil
        }
        guard !state.requests.isEmpty else { throw OpenTrafficAPIError.conflict("Nobody is asking to control “\(share)”.") }
        guard let viewer else { return state.requests[0].viewer }
        let waiting = state.requests.map { "\($0.name ?? "A viewer") (\($0.viewer))" }.joined(separator: ", ")
        if let number = Int(viewer.hasPrefix("#") ? String(viewer.dropFirst()) : viewer) {
            guard let request = state.requests.first(where: { $0.viewer == number }) else {
                throw OpenTrafficAPIError.notFound("Viewer \(number) isn't asking to control “\(share)”. Asking: \(waiting).")
            }
            return request.viewer
        }
        let named = state.requests.filter { ($0.name ?? "").caseInsensitiveCompare(viewer) == .orderedSame }
        guard !named.isEmpty else { throw OpenTrafficAPIError.notFound("Nobody called “\(viewer)” is asking to control “\(share)”. Asking: \(waiting).") }
        guard named.count == 1 else {
            throw OpenTrafficAPIError.conflict("\(named.count) viewers called “\(viewer)” ask to control “\(share)”: give the number (\(named.map { String($0.viewer) }.joined(separator: " or "))).")
        }
        return named[0].viewer
    }
}

/// A viewer in `APIMacAppControl`: one who asks for control, or the one who has it.
public struct APIControlViewer: Codable, Equatable, Sendable {
    /// The viewer's number on the share (what `allow` and `deny` take); nil for a holder whose page is away.
    public let viewer: Int?
    /// The name their page gave, nil when none.
    public let name: String?
    /// When they asked, or got control.
    public let since: Date
    /// The holder only: whether their page is connected (away, they get control back when they return).
    public let connected: Bool?

    public init(viewer: Int?, name: String?, since: Date, connected: Bool? = nil) {
        self.viewer = viewer
        self.name = name
        self.since = since
        self.connected = connected
    }
}

/// `POST /v1/shares/{ref}/control`: `{"action":"allow"|"deny"|"take-back","viewer":"Ada"|3}`.
public struct APIMacAppControlChange: Decodable, Equatable, Sendable {
    public let action: String
    /// A viewer's number or name; a number may come as a JSON number.
    public let viewer: String?

    public init(action: String, viewer: String? = nil) {
        self.action = action
        self.viewer = viewer
    }

    private enum CodingKeys: String, CodingKey { case action, viewer }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        if let number = try? c.decodeIfPresent(Int.self, forKey: .viewer) {
            viewer = String(number)
        } else {
            viewer = try c.decodeIfPresent(String.self, forKey: .viewer)
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
    /// With `wizardOpened`, OpenTraffic has opened its permissions window, which walks through them.
    public static func missingMacAppPermissions(_ missing: [MacAppSession.Permission], wizardOpened: Bool = false) -> OpenTrafficAPIError {
        let names = missing.map(\.title)
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.joined()
        let how = wizardOpened
            ? "OpenTraffic opened a window that walks you through it"
            : "`opentraffic permissions` opens a window that walks you through it"
        return OpenTrafficAPIError(
            status: 409,
            code: "missing_permissions",
            message: "OpenTraffic needs \(list) to share Mac apps. Turn \(names.count > 1 ? "them" : "it") on for OpenTraffic in System Settings → Privacy & Security (\(how)), then share again."
        )
    }
}

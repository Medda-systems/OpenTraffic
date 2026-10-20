import AppKit
import Foundation
import OpenTrafficCore

/// What a shared Mac app is doing, for its Live Collaboration card.
struct MacAppShareStatus: Equatable {
    var state: MacAppSession.State = .idle
    /// Browsers showing the app right now.
    var viewers = 0
    /// The latest thing worth a look: dropped entitlements, another off-screen display, an action
    /// the app refused.
    var warning: String?
}

/// A Mac app share waiting for the permissions it needs; it starts once they're on.
struct PendingMacAppShare: Equatable {
    var app: MacApp
    var kind: TunnelKind
    var data: MacAppSession.DataSource
}

/// Sharing a native Mac app being developed: an isolated copy runs hidden on this Mac (see
/// MacAppSession) and its window is mirrored to viewers' browsers, with the collaboration overlay.
extension AppStore {
    /// The viewer page, script and styles (bundled next to bridge.js), or nil when they're missing.
    static let macAppViewer: (page: Data, script: Data, style: Data)? = {
        func load(_ ext: String) -> Data? {
            Bundle.main.url(forResource: "macapp-viewer", withExtension: ext).flatMap { try? Data(contentsOf: $0) }
        }
        guard let page = load("html"), let script = load("js"), let style = load("css") else { return nil }
        return (page, script, style)
    }()

    // MARK: Discovery

    /// Finds the Mac apps being built on this Mac: running debug builds and recent Xcode builds.
    func scanMacApps() async {
        var apps = await Task.detached(priority: .utility) { await MacAppDiscovery.scan() }.value
        // Captures for the website list only the apps they name (OPENTRAFFIC_DEMO_MAC_APPS=Orbit),
        // never the projects on this Mac.
        if DemoCapture.demoPorts != nil {
            let names = Set((ProcessInfo.processInfo.environment["OPENTRAFFIC_DEMO_MAC_APPS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            apps = apps.filter { names.contains($0.name) }
        }
        if apps != detectedMacApps { detectedMacApps = apps }
    }

    /// Detected Mac apps that aren't shared right now.
    var shareableMacApps: [MacApp] {
        let shared = Set(definitions.filter { isActive($0.id) || runtime(for: $0.id).state == .stopping }.compactMap(\.macApp))
        return detectedMacApps.filter { !shared.contains($0.id) }
    }

    // MARK: Permissions

    /// Checks (without asking) whether OpenTraffic may read and capture other apps' windows. A share
    /// waiting for them starts once both are on.
    func refreshMacAppPermissions() {
        var missing: [MacAppSession.Permission] = []
        if !AccessibilityTree.isTrusted { missing.append(.accessibility) }
        if !WindowCapture.isPermitted { missing.append(.screenRecording) }
        if missing != missingMacAppPermissions { missingMacAppPermissions = missing }
        guard missing.isEmpty else { return }
        macAppPermissionPolling?.cancel()
        macAppPermissionPolling = nil
        if let pending = pendingMacAppShare {
            pendingMacAppShare = nil
            share(pending.app, kind: pending.kind, data: pending.data)
        }
    }

    /// Asks macOS for a permission (its prompt the first time, which also lists OpenTraffic in
    /// System Settings), opens the pane where it's turned on, and watches for the switch for a while.
    func requestMacAppPermission(_ permission: MacAppSession.Permission) {
        switch permission {
        case .accessibility: AccessibilityTree.requestTrust()
        case .screenRecording: WindowCapture.requestPermission()
        }
        NSWorkspace.shared.open(permission.settingsURL)
        macAppPermissionPolling?.cancel()
        macAppPermissionPolling = Task { [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshMacAppPermissions()
                if self.missingMacAppPermissions.isEmpty { return }
            }
        }
    }

    func cancelPendingMacAppShare() {
        pendingMacAppShare = nil
        macAppPermissionPolling?.cancel()
        macAppPermissionPolling = nil
    }

    // MARK: Sharing

    /// One-step sharing of a Mac app, like a web server: reuse its saved share or create one. Without
    /// Accessibility and Screen Recording it waits for them (the menu bar shows how to turn them on).
    func share(_ app: MacApp, kind: TunnelKind = .quick, data: MacAppSession.DataSource = .copy) {
        let kind: TunnelKind = kind == .opentunnel ? .opentunnel : .quick
        guard Self.macAppViewer != nil, Self.collaborationScript != nil else {
            notice = AppNotice(.error, "OpenTraffic's Mac app support is missing from the app. Reinstall OpenTraffic.")
            return
        }
        refreshMacAppPermissions()
        guard missingMacAppPermissions.isEmpty else {
            pendingMacAppShare = PendingMacAppShare(app: app, kind: kind, data: data)
            return
        }
        pendingMacAppShare = nil
        // The address is the mirror server's, decided when the session starts.
        let localURL = "http://127.0.0.1/"
        if let index = definitions.firstIndex(where: { $0.macApp == app.id && $0.kind == kind }) {
            definitions[index].localURL = localURL
            definitions[index].macAppData = data
            definitions[index].collaboration = true
            if definitions[index].agentDirectory == nil { definitions[index].agentDirectory = app.projectDirectory?.path }
            saveDefinitions()
            startSharing(definitions[index])
            return
        }
        do {
            var definition = switch kind {
            case .opentunnel: try addOpenTunnel(name: app.name, localURL: localURL, collaboration: true)
            default: try addQuick(name: app.name, localURL: localURL, collaboration: true)
            }
            guard let index = definitions.firstIndex(where: { $0.id == definition.id }) else { return }
            definitions[index].macApp = app.id
            definitions[index].macAppData = data
            definitions[index].collaboration = true
            // Comments get fixed in the project the app is built from.
            definitions[index].agentDirectory = definitions[index].agentDirectory ?? app.projectDirectory?.path
            definition = definitions[index]
            saveDefinitions()
            startSharing(definition)
        } catch {
            notice = AppNotice(.error, error.localizedDescription)
        }
    }

    /// Starts the isolated copy of the share's app and returns its mirror server's port on 127.0.0.1.
    func startMacAppSession(for definition: TunnelDefinition) async throws -> Int {
        guard let path = definition.macApp else { throw OpenTrafficError.invalidLocalURL }
        let id = definition.id
        stopMacAppSession(id)
        // Copies of one app share a bundle identifier and preferences: let earlier ones quit first.
        await macAppLeftovers?.value
        for stop in Array(macAppStops.values) { await stop.value }
        guard let viewer = Self.macAppViewer else {
            throw OpenTrafficError.process("OpenTraffic's Mac app viewer is missing from the app. Reinstall OpenTraffic.")
        }
        if let other = macAppSessions.first(where: { $0.key != id && $0.value.options.app.id == path }) {
            let name = definitions.first { $0.id == other.key }?.name ?? "another share"
            throw OpenTrafficError.process("\(other.value.name) is already shared by “\(name)”. Stop that share first.")
        }
        let app: MacApp
        if let found = detectedMacApps.first(where: { $0.id == path }) {
            app = found
        } else {
            app = try await Task.detached { try MacAppDiscovery.resolve(path: path) }.value
        }
        refreshMacAppPermissions()
        if let missing = missingMacAppPermissions.first { throw MacAppSessionError.permission(missing) }
        let data = definition.macAppData ?? .copy
        let session = MacAppSession(options: .init(
            app: app,
            data: data,
            assets: .init(page: viewer.page, script: viewer.script, style: viewer.style, icon: Self.iconPNG(for: app))
        ))
        macAppSessions[id] = session
        macAppStatus[id] = MacAppShareStatus(state: .starting)
        macAppReaders[id] = [
            Task { [weak self] in
                for await line in session.log {
                    guard let self, self.macAppSessions[id] === session else { return }
                    self.appendMacAppLog(line.text, for: id, fromApp: line.source == .app)
                }
            },
            Task { [weak self] in
                for await event in session.events {
                    guard let self, self.macAppSessions[id] === session else { return }
                    self.macAppEvent(event, for: id)
                }
            },
        ]
        appendMacAppLog("Starting an isolated copy of \(app.name) with \(data == .empty ? "empty data" : "a copy of its data").", for: id)
        do {
            let port = try await session.start()
            if let host = runtime(for: id).publicURL.flatMap(Self.publicOrigin) { session.server?.setAllowedOrigins([host]) }
            return port
        } catch {
            if macAppSessions[id] === session { stopMacAppSession(id) }
            if Self.isPermissionError(error) { refreshMacAppPermissions() }
            appendMacAppLog(error.localizedDescription, for: id, error: true)
            throw error
        }
    }

    /// Quits the share's copy and deletes it (in the background; OpenTraffic waits for it before quitting).
    func stopMacAppSession(_ id: UUID) {
        macAppReaders.removeValue(forKey: id)?.forEach { $0.cancel() }
        macAppStatus[id] = nil
        guard let session = macAppSessions.removeValue(forKey: id) else { return }
        if let pid = session.pid { macAppStoppingPIDs[id] = pid }
        let previous = macAppStops[id]
        let stop = Task { @MainActor in
            await previous?.value
            await session.stop()
        }
        macAppStops[id] = stop
        Task { [weak self] in
            await stop.value
            if self?.macAppStops[id] == stop {
                self?.macAppStops[id] = nil
                self?.macAppStoppingPIDs[id] = nil
            }
        }
    }

    /// Waits until every shared Mac app's copy has quit: otherwise macOS moves its windows onto
    /// the screen once OpenTraffic's off-screen display goes away. A copy whose session is still
    /// stopping after `timeout` is quit right away; the next launch deletes its folder.
    func waitForMacAppSessionsToStop(timeout: Duration = .seconds(10)) async {
        for id in Array(macAppSessions.keys) { stopMacAppSession(id) }
        let deadline = ContinuousClock.now + timeout
        while !macAppStops.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let sessions = MacAppSession.sessionsDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for pid in macAppStoppingPIDs.values {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(sessions) == true else { continue }
            app.forceTerminate()
        }
    }

    /// Starts the share's app again on the same address; a rebuilt app is copied again first.
    /// The task ends once it's back, with why it failed if it did; nil when the share has no app running.
    @discardableResult
    func restartMacApp(_ id: UUID) -> Task<String?, Never>? {
        guard let session = macAppSessions[id] else { return nil }
        appendMacAppLog("Restarting \(session.name).", for: id)
        return Task { [weak self] in
            do { try await session.restart() } catch {
                self?.macAppActionFailed(error, for: id)
                return error.localizedDescription
            }
            return nil
        }
    }

    /// Starts the share's app over from the data it started with (see `restartMacApp`).
    @discardableResult
    func resetMacAppData(_ id: UUID) -> Task<String?, Never>? {
        guard let session = macAppSessions[id] else { return nil }
        appendMacAppLog("Resetting \(session.name)'s data.", for: id)
        return Task { [weak self] in
            do { try await session.resetData() } catch {
                self?.macAppActionFailed(error, for: id)
                return error.localizedDescription
            }
            return nil
        }
    }

    /// The public address is known: pages from it may open the app's WebSocket.
    func macAppReceived(publicURL: String, for id: UUID) {
        guard let session = macAppSessions[id], let origin = Self.publicOrigin(publicURL) else { return }
        session.server?.setAllowedOrigins([origin])
    }

    static func isPermissionError(_ error: any Error) -> Bool {
        if case .permission? = error as? MacAppSessionError { return true }
        return false
    }

    /// `https://orbit.example.dev` for any URL there.
    static func publicOrigin(_ url: String) -> String? {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    // MARK: While it runs

    private func macAppEvent(_ event: MacAppSession.Event, for id: UUID) {
        switch event {
        case .state(let state):
            macAppStatus[id, default: MacAppShareStatus()].state = state
            switch state {
            case .crashed(let message):
                notice = AppNotice(.error, "\(message) It runs again by itself once; use Restart App on the share's card if it doesn't.")
            case .failed(let message) where runtime(for: id).state == .running:
                // A restart that failed; a failed first start is the share's own error.
                notice = AppNotice(.error, "\(shareName(id)): \(message)")
            default:
                break
            }
        case .viewers(let count):
            macAppStatus[id, default: MacAppShareStatus()].viewers = count
        case .warning(let text):
            macAppStatus[id, default: MacAppShareStatus()].warning = text
        case .message:
            break
        }
    }

    private func macAppActionFailed(_ error: any Error, for id: UUID) {
        if Self.isPermissionError(error) { refreshMacAppPermissions() }
        appendMacAppLog(error.localizedDescription, for: id, error: true)
        notice = AppNotice(.error, "\(shareName(id)): \(error.localizedDescription)")
    }

    private func shareName(_ id: UUID) -> String {
        definitions.first { $0.id == id }?.name ?? "The app"
    }

    /// The app's output (stream "app") and what the session did, in the share's log.
    private func appendMacAppLog(_ line: String, for id: UUID, fromApp: Bool = false, error: Bool = false) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if logs[id] == nil { logs[id] = BoundedLogBuffer() }
        logs[id]?.append(contentsOf: [TunnelLogEntry(level: error ? "error" : "info", message: text, stream: fromApp ? "app" : "session")])
    }

    // MARK: Icons

    /// The app's icon as Finder shows it (asset-catalog icons included).
    static func icon(for app: MacApp) -> NSImage {
        if let file = app.iconFile, let image = NSImage(contentsOf: file) { return image }
        return NSWorkspace.shared.icon(forFile: app.bundle.path)
    }

    /// The icon for the viewer's desktop bar: 128 × 128 PNG.
    static func iconPNG(for app: MacApp) -> Data? {
        let side = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon(for: app).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

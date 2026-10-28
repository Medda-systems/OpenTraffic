import AppKit
import Foundation
import OpenTrafficCore
import UniformTypeIdentifiers

/// What a shared Mac app is doing, for its Live Collaboration card.
struct MacAppShareStatus: Equatable {
    var state: MacAppSession.State = .idle
    /// Browsers showing the app right now.
    var viewers = 0
    /// The latest thing worth a look: dropped entitlements, another off-screen display, an action
    /// the app refused.
    var warning: String?
    /// Who may control the app: the mode, who has control, who asks for it.
    var control: MirrorServer.ControlState?
    /// The appearance the copy runs with.
    var appearance: MirrorProtocol.Appearance?
    /// Building the app after its sources changed (idle when none runs).
    var build: MacAppSession.BuildState = .idle
}

/// A Mac app share waiting for the permissions it needs; it starts once they're on.
struct PendingMacAppShare: Equatable {
    var app: MacApp
    var kind: TunnelKind
    var data: MacAppSession.DataSource
    var name: String? = nil
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

    /// Finds the Mac apps being built on this Mac (running debug builds and recent Xcode builds), your
    /// apps in booted simulators, and the apps you chose or shared before that discovery doesn't list.
    /// Running ones come first, Mac apps before simulator apps, apps you chose last.
    func scanMacApps() async {
        let paths = Self.rememberedMacAppPaths
        async let macApps = Task.detached(priority: .utility) { await MacAppDiscovery.scan() }.value
        async let simulatorApps = Task.detached(priority: .utility) { SimulatorDiscovery.scan() }.value
        async let rememberedApps = Task.detached(priority: .utility) { MacAppDiscovery.remembered(paths) }.value
        let found = await macApps + simulatorApps
        let foundIDs = Set(found.map(\.id))
        let remembered = await rememberedApps.filter { !foundIDs.contains($0.id) }
        let all = found + remembered
        var apps = all.filter(\.isRunning) + all.filter { !$0.isRunning }
        // Captures for the website list only the apps they name (OPENTRAFFIC_DEMO_MAC_APPS=Orbit),
        // never the projects on this Mac.
        if DemoCapture.demoPorts != nil {
            let names = Set((ProcessInfo.processInfo.environment["OPENTRAFFIC_DEMO_MAC_APPS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            apps = apps.filter { names.contains($0.name) }
        }
        if apps != detectedMacApps { detectedMacApps = apps }
        let rememberedIDs = Set(remembered.map(\.id))
        if rememberedIDs != rememberedMacAppIDs { rememberedMacAppIDs = rememberedIDs }
    }

    // MARK: Apps you chose

    /// The .app paths chosen with Choose App… or shared, newest first: listed under Mac Apps until
    /// they're removed, even when they don't run (discovery alone only lists those that run, or recent
    /// Xcode builds).
    private static let rememberedMacAppsKey = "rememberedMacApps"
    private static let rememberedMacAppsLimit = 12

    static var rememberedMacAppPaths: [String] {
        UserDefaults.standard.stringArray(forKey: rememberedMacAppsKey) ?? []
    }

    /// Keeps a Mac app under Mac Apps from now on (simulator apps aren't kept: their copy moves).
    func rememberMacApp(_ app: MacApp) {
        guard app.simulator == nil else { return }
        let path = app.bundle.path
        let paths = [path] + Self.rememberedMacAppPaths.filter { $0 != path }
        UserDefaults.standard.set(Array(paths.prefix(Self.rememberedMacAppsLimit)), forKey: Self.rememberedMacAppsKey)
        guard !detectedMacApps.contains(where: { $0.id == app.id }) else { return }
        detectedMacApps.append(app)
        rememberedMacAppIDs.insert(app.id)
    }

    /// Remove from List: the app isn't kept under Mac Apps anymore (its saved shares stay).
    func forgetMacApp(_ app: MacApp) {
        UserDefaults.standard.set(Self.rememberedMacAppPaths.filter { $0 != app.bundle.path }, forKey: Self.rememberedMacAppsKey)
        guard rememberedMacAppIDs.remove(app.id) != nil else { return }
        detectedMacApps.removeAll { $0.id == app.id }
    }

    /// The folder Choose App… opened last (else /Applications).
    private static let chooseMacAppFolderKey = "chooseMacAppFolder"

    /// Choose App… under Mac Apps (and Share a Mac App… in the main window): an open panel for any .app,
    /// with the Share ▾ choices under its file list. The pick is checked as `opentraffic share <path>` checks
    /// it (`MacAppDiscovery.resolve`); a refusal says why, with Choose Another App…. An app that may be
    /// shared is remembered under Mac Apps and shared as a listed one is (the permissions window first
    /// when a permission is off).
    func chooseMacAppToShare() {
        let choice = MacAppChoiceAccessory(
            kind: effectiveDefaultShareKind == .opentunnel ? .opentunnel : .quick,
            canShare: cloudflaredPath != nil,
            canShareWithOpenTunnel: openTunnelBlocker == nil
        )
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = Vocabulary.share
        panel.message = "Choose a Mac app: one you built or an installed one. Viewers use a separate copy of it, with a copy of its data."
        let folder = UserDefaults.standard.string(forKey: Self.chooseMacAppFolderKey).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        panel.directoryURL = URL(fileURLWithPath: folder ?? "/Applications", isDirectory: true)
        panel.accessoryView = choice
        panel.isAccessoryViewDisclosed = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.chooseMacAppFolderKey)
        let kind = choice.kind
        let data = choice.data
        Task {
            let path = url.path
            let result = await Task.detached { Result { try MacAppDiscovery.resolve(path: path) } }.value
            switch result {
            case .success(let app):
                if let shared = definitions.first(where: { $0.macApp == app.id && (isActive($0.id) || runtime(for: $0.id).state == .stopping) }) {
                    notice = AppNotice(.info, "\(app.name) is already shared as “\(shared.name)”.")
                    return
                }
                rememberMacApp(app)
                share(app, kind: kind, data: data)
            case .failure(let error):
                NSApp.activate(ignoringOtherApps: true)
                let alert = Self.macAppRefusalAlert(app: url.deletingPathExtension().lastPathComponent, reason: error.localizedDescription)
                if alert.runModal() == .alertFirstButtonReturn { chooseMacAppToShare() }
            }
        }
    }

    /// A pick Choose App… can't share: why, with Choose Another App… (the default) and Cancel.
    static func macAppRefusalAlert(app: String, reason: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "OpenTraffic can't share “\(app)”"
        alert.informativeText = reason
        alert.addButton(withTitle: "Choose Another App…")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    // MARK: Installed apps

    static let installedMacAppNoteKey = "hasSeenInstalledMacAppNote"

    /// The note the first share of an installed app (or another developer's) shows on its card, until
    /// Got It: viewers use a copy of the app with a copy of its data, and the host's own stays as it is.
    static func installedMacAppNote(app: String, data: MacAppSession.DataSource) -> String {
        let copy = data == .empty ? "a copy of \(app) that starts with no data" : "a copy of \(app) with a copy of its data"
        return "Viewers use \(copy), running hidden on this Mac: what they change stays in the copy, and your own \(app) and its data stay as they are. Some apps can't do everything as a copy: iCloud, keychain items and App Groups stay with your own app."
    }

    /// Got It on the installed-app note: it doesn't show again.
    func dismissInstalledMacAppNote() {
        UserDefaults.standard.set(true, forKey: Self.installedMacAppNoteKey)
        hasSeenInstalledMacAppNote = true
    }

    /// Whether a share publishes an installed app or another developer's, not one being built.
    func sharesInstalledMacApp(_ id: UUID) -> Bool {
        if let session = macAppSessions[id] { return session.options.app.isInstalled }
        guard let path = definitions.first(where: { $0.id == id })?.macApp else { return false }
        return detectedMacApps.first { $0.id == path }?.isInstalled ?? false
    }

    /// Detected Mac apps that aren't shared right now.
    var shareableMacApps: [MacApp] {
        let shared = Set(definitions.filter { isActive($0.id) || runtime(for: $0.id).state == .stopping }.compactMap(\.macApp))
        return detectedMacApps.filter { !shared.contains($0.id) }
    }

    /// Whether simulator apps can be shared: MacAppSession runs them in the Simulator and mirrors the
    /// device's window (see SimulatorSession).
    static let sharesSimulatorApps = true

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
            share(pending.app, kind: pending.kind, data: pending.data, name: pending.name)
        }
    }

    /// Asks macOS for a permission (with `ask`: its prompt the first time, which also lists
    /// OpenTraffic in System Settings), opens the pane where it's turned on, and watches for the
    /// switch for a while.
    func requestMacAppPermission(_ permission: MacAppSession.Permission, ask: Bool = true) {
        if ask {
            switch permission {
            case .accessibility: AccessibilityTree.requestTrust()
            case .screenRecording: WindowCapture.requestPermission()
            }
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

    /// Opens the window that walks through the permissions (PermissionsWizardView).
    func showPermissionsWizard() {
        refreshMacAppPermissions()
        PermissionsWindowController.shared.show(store: self)
    }

    /// The share waiting for permissions, kept across Quit & Reopen (Screen Recording applies when
    /// the app starts): the app's id, the tunnel kind and its data.
    private static let pendingShareKey = "pendingMacAppShareAfterRelaunch"

    /// Quits and reopens OpenTraffic for Screen Recording to apply; a share waiting for it starts
    /// once the app is back (and the wizard opens again if something is still off).
    func relaunchForPermissions() {
        var saved: [String: String] = ["wizard": "1"]
        if let pending = pendingMacAppShare {
            saved["app"] = pending.app.id
            saved["kind"] = pending.kind.rawValue
            saved["data"] = pending.data.rawValue
        }
        UserDefaults.standard.set(saved, forKey: Self.pendingShareKey)
        AppRelauncher.relaunch()
    }

    /// At launch, after Quit & Reopen: starts the share that was waiting (it starts once both
    /// permissions are on), or opens the wizard again while one is still off.
    func resumeAfterPermissionsRelaunch() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.pendingShareKey) as? [String: String] else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingShareKey)
        refreshMacAppPermissions()
        guard let id = saved["app"] else {
            if !missingMacAppPermissions.isEmpty || saved["wizard"] != nil { showPermissionsWizard() }
            return
        }
        let kind = saved["kind"].flatMap(TunnelKind.init(rawValue:)) ?? .quick
        let data = saved["data"].flatMap(MacAppSession.DataSource.init(rawValue:)) ?? .copy
        Task {
            let app: MacApp? = SimulatorDiscovery.parseAppID(id) != nil
                ? try? await Task.detached { try SimulatorDiscovery.resolve(id: id) }.value
                : try? await Task.detached { try MacAppDiscovery.resolve(path: id) }.value
            guard let app else {
                if !missingMacAppPermissions.isEmpty { showPermissionsWizard() }
                return
            }
            share(app, kind: kind, data: data)
            if !missingMacAppPermissions.isEmpty || saved["wizard"] != nil { showPermissionsWizard() }
        }
    }

    // MARK: Sharing

    /// One-step sharing of a Mac app, like a web server: reuse its saved share or create one. Without
    /// Accessibility and Screen Recording it waits for them and opens the window that walks through them.
    /// `name` names a new share (default: the app's); a share of the app that exists keeps its own.
    func share(_ app: MacApp, kind: TunnelKind = .quick, data: MacAppSession.DataSource = .copy, name: String? = nil) {
        let kind: TunnelKind = kind == .opentunnel ? .opentunnel : .quick
        if let device = app.simulator, !Self.sharesSimulatorApps {
            notice = AppNotice(.warning, "Sharing \(app.name) from the \(device.label) isn't available yet.")
            return
        }
        guard Self.macAppViewer != nil, Self.collaborationScript != nil else {
            notice = AppNotice(.error, "OpenTraffic's Mac app support is missing from the app. Reinstall OpenTraffic.")
            return
        }
        refreshMacAppPermissions()
        guard missingMacAppPermissions.isEmpty else {
            pendingMacAppShare = PendingMacAppShare(app: app, kind: kind, data: data, name: name)
            showPermissionsWizard()
            return
        }
        pendingMacAppShare = nil
        // Shared once, listed under Mac Apps from now on, running or not.
        rememberMacApp(app)
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
            case .opentunnel: try addOpenTunnel(name: name ?? app.name, localURL: localURL, collaboration: true)
            default: try addQuick(name: name ?? app.name, localURL: localURL, collaboration: true)
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
        } else if SimulatorDiscovery.parseAppID(path) != nil {
            app = try await Task.detached { try SimulatorDiscovery.resolve(id: path) }.value
        } else {
            app = try await Task.detached { try MacAppDiscovery.resolve(path: path) }.value
        }
        if let device = app.simulator, !Self.sharesSimulatorApps {
            throw OpenTrafficError.process("Sharing \(app.name) from the \(device.label) isn't available yet.")
        }
        refreshMacAppPermissions()
        if let missing = missingMacAppPermissions.first { throw MacAppSessionError.permission(missing) }
        let data = definition.macAppData ?? .copy
        let session = MacAppSession(options: .init(
            app: app,
            data: data,
            assets: .init(page: viewer.page, script: viewer.script, style: viewer.style, icon: Self.iconPNG(for: app)),
            viewerOptions: definition.macAppOptions ?? MacAppViewerOptions()
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
        if let device = app.simulator {
            appendMacAppLog(data == .empty ? "Starting \(app.name) in an empty \(device.name) of OpenTraffic's own."
                                           : "Starting \(app.name) in the \(device.label) with its real data.", for: id)
        } else {
            appendMacAppLog("Starting an isolated copy of \(app.name) with \(data == .empty ? "empty data" : "a copy of its data")\(app.isInstalled ? "; your own \(app.name) and its data stay as they are" : "").", for: id)
        }
        do {
            let port = try await session.start()
            if macAppSessions[id] === session { macAppStatus[id, default: MacAppShareStatus()].appearance = session.appearance }
            if let host = runtime(for: id).publicURL.flatMap(Self.publicOrigin) { session.server?.setAllowedOrigins([host]) }
            watchMacAppSources(session, app: app, agentDirectory: definition.agentDirectory, for: id)
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
            // A copy runs without its bundle identifier (its sandbox launcher), and its NSRunningApplication
            // may still say pid -1: it's the copy when its bundle or executable is in a session folder.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  [app.bundleURL, app.executableURL].contains(where: { $0?.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(sessions) == true })
            else { continue }
            kill(pid, SIGKILL)
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

    // MARK: Rebuilding

    /// Like `watchElectronCode`: when the app's project sources change, the session builds the app
    /// (xcodebuild or swift build), starts the new build on the same address and puts viewers back
    /// where they were. The project is the one discovery found the app's build in, else the share's
    /// agent folder.
    private func watchMacAppSources(_ session: MacAppSession, app: MacApp, agentDirectory: String?, for id: UUID) {
        guard app.simulator == nil, !app.isInstalled else { return } // an installed app isn't built here
        let folders = [app.projectDirectory, agentDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }].compactMap { $0 }
        guard let project = folders.first(where: { MacAppBuild.detect(project: $0, bundle: app.bundle) != nil }) else {
            appendMacAppLog("\(app.name) isn't rebuilt when its sources change: OpenTraffic found no Xcode project or Swift package it's built from.", for: id)
            return
        }
        Task { [weak self] in
            do {
                let plan = try await MacAppBuild.plan(for: app, project: project)
                guard let self, self.macAppSessions[id] === session else { return }
                session.watchSources(plan)
            } catch {
                guard let self, self.macAppSessions[id] === session else { return }
                self.appendMacAppLog("\(app.name) isn't rebuilt when its sources change: \(error)", for: id)
            }
        }
    }

    /// Build Again on the card: builds the app from its sources now (changed or not) and starts the new
    /// build when it succeeds.
    func buildMacAppAgain(_ id: UUID) {
        guard let session = macAppSessions[id], session.buildPlan != nil else { return }
        appendMacAppLog("Building \(session.name) again.", for: id)
        session.rebuild(because: "You asked for a new build.")
    }

    /// Show Log on the card: the latest build's full output, in the app that opens logs (Console).
    func showMacAppBuildLog(_ id: UUID) {
        guard let log = macAppSessions[id]?.buildLog, FileManager.default.fileExists(atPath: log.path) else { return }
        NSWorkspace.shared.open(log)
    }

    /// Whether the share's Live Collaboration card is in front of the host: OpenTraffic is active
    /// with the share's Overview showing.
    func isMacAppCardVisible(_ id: UUID) -> Bool {
        NSApp.isActive && selectedID == id && detailTab == .overview
            && NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    /// An agent finished a comment on the share: build and restart now if it changed the sources
    /// (the watcher usually has already).
    func rebuildMacAppIfChanged(_ id: UUID) {
        macAppSessions[id]?.sourcesMayHaveChanged()
    }

    // MARK: Viewer options

    /// The host's viewer options for a Mac app share (saved with it; a running share follows at once,
    /// with a restart of the app when its appearance changes).
    func setMacAppOptions(_ options: MacAppViewerOptions, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }), (definitions[index].macAppOptions ?? MacAppViewerOptions()) != options else { return }
        definitions[index].macAppOptions = options
        saveDefinitions()
        macAppSessions[id]?.setViewerOptions(options)
    }

    /// Ask to control: gives control to a viewer who asked.
    func allowMacAppControl(viewer: Int, for id: UUID) {
        macAppSessions[id]?.server?.allowControl(viewer: viewer)
    }

    /// Ask to control: turns a viewer's request down.
    func denyMacAppControl(viewer: Int, for id: UUID) {
        macAppSessions[id]?.server?.denyControl(viewer: viewer)
    }

    /// Ask to control: takes control back from the viewer who has it.
    func revokeMacAppControl(for id: UUID) {
        macAppSessions[id]?.server?.revokeControl()
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
        case .control(let control):
            let before = Set(macAppStatus[id]?.control?.requests.map(\.viewer) ?? [])
            macAppStatus[id, default: MacAppShareStatus()].control = control
            // Someone new asks: the card shows Allow; a notification brings the host to it, and
            // `opentraffic watch`, webhooks and the event API hear of it.
            let new = control.requests.filter { !before.contains($0.viewer) }
            if let share = apiShareRef(id) {
                for request in new {
                    apiEvents.append(.controlRequested, share: share, viewer: APIControlViewer(viewer: request.viewer, name: request.name, since: request.since))
                }
            }
            if let request = new.last {
                let who = request.name ?? "A viewer"
                TunnelNotifications.post(title: "\(who) asks to control \(shareName(id))",
                                         body: "Allow it on the share's Live Collaboration card.",
                                         identifier: "macapp-control-\(id.uuidString)", tunnelID: id)
            }
        case .appearance(let appearance):
            macAppStatus[id, default: MacAppShareStatus()].appearance = appearance
        case .build(let build):
            let before = macAppStatus[id]?.build ?? .idle
            macAppStatus[id, default: MacAppShareStatus()].build = build
            // `opentraffic watch`, webhooks and the event API hear of it; a failure brings the host to
            // the card unless it's in front of them.
            let running = switch macAppStatus[id]?.state { case .running?, .restarting?, .crashed?, .failed?: isActive(id); default: false }
            if let kind = APIMacAppBuild.event(from: before, to: build, running: running), let share = apiShareRef(id) {
                apiEvents.append(kind, share: share, build: apiMacAppBuild(id))
            }
            if case .failed(let message) = build, !isMacAppCardVisible(id) {
                TunnelNotifications.post(title: "\(macAppSessions[id]?.name ?? shareName(id)) didn't build",
                                         body: "Viewers of \(shareName(id)) see the previous version. \(message)",
                                         identifier: "macapp-build-\(id.uuidString)", tunnelID: id)
            }
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

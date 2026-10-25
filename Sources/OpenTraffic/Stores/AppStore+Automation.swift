import AppKit
import Foundation
import OpenTrafficCore

extension AppStore {
    // MARK: Keep-alive

    /// Restarts a tunnel whose connector exited on its own, backing off and giving up after repeated failures.
    func scheduleRestartAfterCrash(_ id: UUID, policy: RestartPolicy = RestartPolicy()) {
        guard restartCrashedTunnels,
              let definition = definitions.first(where: { $0.id == id }),
              definition.kind.provider != .tailscale,
              !pendingRestarts.contains(id) else { return }
        let error = runtime(for: id).lastError ?? ""
        if definition.kind.provider == .ngrok, !NgrokAgent.isRetryable(error) { return }
        let history = restartHistory[id] ?? []
        guard let delay = policy.nextDelay(previousRestarts: history) else {
            notice = AppNotice(.error, "“\(definition.name)” keeps stopping, so OpenTraffic stopped restarting it. Check its logs.")
            return
        }
        pendingRestarts.insert(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.pendingRestarts.remove(id) != nil,
                  let current = self.definitions.first(where: { $0.id == id }),
                  [.stopped, .failed].contains(self.runtime(for: id).state) else { return }
            self.restartHistory[id, default: []].append(Date())
            self.notice = AppNotice(.info, "Restarting “\(current.name)” after it stopped unexpectedly.")
            self.start(current)
        }
    }

    // MARK: Auto-start

    /// Starts tunnels marked "start when the local service is running" once their service answers.
    func startTunnelsWhoseServicesAreRunning() async {
        for definition in definitions where definition.autoStart {
            guard let url = URL(string: definition.localURL), let host = url.host else { continue }
            let port = UInt16(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
            let reachable = await LoopbackForwarder.canConnect(host: host, port: port, timeout: 0.8)
            let active = [.running, .starting, .stopping].contains(runtime(for: definition.id).state)
            if autoStartTracker.observe(definition.id, serviceReachable: reachable, tunnelActive: active),
               let current = definitions.first(where: { $0.id == definition.id }) {
                notice = AppNotice(.info, "Started “\(current.name)” because \(TunnelRowPresentation.localEndpoint(current.localURL) ?? "its service") is running.")
                startSharing(current)
            }
        }
    }

    // MARK: Projects

    var projectNames: [String] {
        Array(Set(definitions.compactMap(\.project))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func tunnels(inProject name: String) -> [TunnelDefinition] {
        definitions.filter { $0.project?.caseInsensitiveCompare(name) == .orderedSame }
    }

    func startProject(_ name: String) {
        for definition in tunnels(inProject: name) where !isActive(definition.id) {
            startSharing(definition)
        }
    }

    func stopProject(_ name: String) {
        for definition in tunnels(inProject: name) where isActive(definition.id) {
            stop(definition.id)
        }
    }

    func setProject(_ name: String?, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].project = name?.nilIfBlank
        saveDefinitions()
    }

    func setAutoStart(_ enabled: Bool, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].autoStart = enabled
        saveDefinitions()
    }

    // MARK: opentraffic:// links

    func handleAutomationURL(_ url: URL) {
        guard let command = AutomationCommand.parse(url) else {
            notice = AppNotice(.warning, "OpenTraffic didn't understand the link \(url.absoluteString).")
            return
        }
        if command.exposesService, !allowUnconfirmedAutomation, !confirm(command) { return }
        perform(command)
    }

    private func definition(named name: String) -> TunnelDefinition? {
        definitions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func perform(_ command: AutomationCommand) {
        switch command {
        case .share(let localURL, let kind, let name, let collaboration):
            shareLocalURL(localURL, kind: kind, name: name, collaboration: collaboration)
        case .start(let name):
            guard let definition = definition(named: name) else { return reportMissing(name) }
            startSharing(definition)
        case .stop(let name):
            guard let definition = definition(named: name) else { return reportMissing(name) }
            stop(definition.id)
        case .stopAll:
            for definition in definitions where isActive(definition.id) { stop(definition.id) }
        case .copy(let name):
            guard let definition = definition(named: name) else { return reportMissing(name) }
            copyPublicURL(definition.id)
        case .show(let name):
            if let name, let definition = definition(named: name) { selectedID = definition.id }
            MainWindowController.shared.show {}
        case .startProject(let name):
            startProject(name)
        case .stopProject(let name):
            stopProject(name)
        case .permissions:
            showPermissionsWizard()
        case .enableAPI:
            enableAPIIfConfirmed()
        }
    }

    /// The command-line tool's setup: turning on the local API lets apps on this Mac control OpenTraffic,
    /// so it always asks, whatever the automation setting says.
    private func enableAPIIfConfirmed() {
        guard !apiEnabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Let the opentraffic command and other apps on this Mac use OpenTraffic?"
        alert.informativeText = "They can list, start, and stop shares and read feedback through OpenTraffic's local API. Publishing still asks first unless you allow it in Settings → Integrations. You can turn this off there too."
        let allow = alert.addButton(withTitle: "Allow")
        let cancel = alert.addButton(withTitle: "Cancel")
        allow.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apiEnabled = true
    }

    /// Shares a local URL with an existing tunnel of that kind for the same address, or a new one.
    /// Collaboration only applies to kinds that support it. Returns the restart when a running share
    /// has to restart to turn collaboration on.
    @discardableResult
    func shareLocalURL(_ localURL: String, kind: TunnelKind, name: String?, collaboration: Bool = false) -> Task<Void, Never>? {
        let collaboration = collaboration && kind.supportsCollaboration
        if let existing = definitions.first(where: { $0.kind == kind && $0.localURL == localURL }) {
            if collaboration, !existing.collaboration, isActive(existing.id) {
                return Task { await setCollaboration(true, for: existing.id) }
            }
            if collaboration, !existing.collaboration, let index = definitions.firstIndex(where: { $0.id == existing.id }) {
                definitions[index].collaboration = true
                saveDefinitions()
            }
            startSharing(definitions.first { $0.id == existing.id } ?? existing)
            return nil
        }
        let title = name ?? TunnelRowPresentation.localEndpoint(localURL).map { "localhost\($0)" } ?? "Local site"
        do {
            let definition = switch kind {
            case .tailscale: try addTailscale(name: title, localURL: localURL, isPublic: false)
            case .ngrok: try addNgrok(name: title, localURL: localURL, domain: nil)
            case .opentunnel: try addOpenTunnel(name: title, localURL: localURL, collaboration: collaboration)
            default: try addQuick(name: title, localURL: localURL, collaboration: collaboration)
            }
            startSharing(definition)
        } catch {
            notice = AppNotice(.error, error.localizedDescription)
        }
        return nil
    }

    private func reportMissing(_ name: String) {
        notice = AppNotice(.warning, "No tunnel named “\(name)”.")
    }

    /// Asks before a link puts something on the internet. Cancel is the default button, so a stray
    /// Return doesn't approve it, and the address shown is the parsed host and port rather than raw text.
    private func confirm(_ command: AutomationCommand) -> Bool {
        var warning = ""
        let description: String
        switch command {
        case .share(let localURL, let kind, _, let collaboration):
            let target = AutomationCommand.target(of: localURL)
            description = "share \(target?.display ?? localURL) \(kind == .tailscale ? "on your tailnet" : "publicly") with \(kind.provider.title)\(collaboration && kind.supportsCollaboration ? " and live collaboration" : "")"
            if target?.isLoopback == false {
                warning = "\n\nThis address is not on this Mac — it's another device on your network, which would become reachable from outside it."
            }
        case .start(let name):
            description = "start “\(name)”"
        case .startProject(let name):
            description = "start every tunnel in the project “\(name)”"
        default:
            description = "run a command"
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow a link to \(description)?"
        alert.informativeText = "An opentraffic:// link asked OpenTraffic to do this. Links can come from any app or web page, so only allow it if you started it — for example from the opentraffic command or a Shortcut. You can turn off this question in Settings → General." + warning
        let allow = alert.addButton(withTitle: "Allow")
        let cancel = alert.addButton(withTitle: "Cancel")
        allow.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}

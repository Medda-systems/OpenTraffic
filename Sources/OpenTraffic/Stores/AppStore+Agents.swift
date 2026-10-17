import AppKit
import Foundation
import OpenTrafficCore
import OpenTrafficSocket

/// The agent command's run for one comment.
struct AgentRun: Equatable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case stopped
    }

    let id = UUID()
    let commentID: String
    let client: String
    let directory: String
    let startedAt: Date
    var state = State.running
    /// It claimed, replied to, released, or resolved its comment through OpenTraffic. A run that ends
    /// without doing any of that never got to OpenTraffic's tools, whatever its exit status says.
    var reachedOpenTraffic = false
    /// The last lines it printed.
    var output: [String] = []
    /// The last line hasn't ended yet.
    var endsMidLine = false
}

/// Coding agents and comments. OpenTraffic never runs a model itself: agents (whatever starts them)
/// claim, reply to, and resolve comments through the API, and the session sees them at work. When no
/// agent is watching a share, OpenTraffic can start one with the command set in Settings.
extension AppStore {
    static let agentOutputLines = 300

    // MARK: Claims

    /// Shows the share's claims in its session.
    func claimsChanged(for id: UUID) {
        guard let proxy = collabProxies[id] else { return }
        let work = agentClaims.claims(share: id).map(\.work)
        Task { await proxy.setAgentWork(work) }
    }

    /// Ends claims nobody renewed (their app stopped without saying so), and forgets callers from agent
    /// runs that have exited.
    func expireAgentClaims() {
        agentRunCallers = agentRunCallers.filter { kill($0.key, 0) == 0 }
        let expired = agentClaims.expire()
        for share in Set(expired.map(\.shareID)) { claimsChanged(for: share) }
        for claim in expired {
            guard let share = apiShareRef(claim.shareID),
                  let comment = comments(for: claim.shareID).first(where: { $0.id == claim.commentID }) else { continue }
            apiEvents.append(.commentReleased, share: share, comment: APIComment(comment, shareID: claim.shareID))
        }
    }

    // MARK: Safety

    /// The comment a caller is held to, when it's part of a run of the agent command (see `AgentRunScope`):
    /// the run's own processes, and anything they started, wherever it calls from. A process this app
    /// started that isn't in any run's tree was let go by one (its parent exited, so it went to launchd),
    /// perhaps to get out of its scope: it may do nothing at all.
    func agentRunScope(for caller: APICaller) async -> AgentRunScope? {
        let runs: [(pid_t, AgentRunScope)] = agentProcesses.compactMap { id, process in
            guard let run = agentRuns[id], run.state == .running, process.isRunning else { return nil }
            return (process.processIdentifier, AgentRunScope(shareID: id, commentID: run.commentID))
        }
        let remembered = agentRunCallers
        // Without runs, only a caller on the socket is checked: finding a TCP caller's process takes lsof.
        guard !runs.isEmpty || !remembered.isEmpty || caller.pid != nil else { return nil }
        let scope = await Task.detached { () -> (pid_t, AgentRunScope)? in
            let lookUp = !runs.isEmpty || !remembered.isEmpty
            guard let pid = caller.pid ?? (lookUp ? caller.tcpPort.flatMap(ProcessAncestry.ownerOfLocalTCPPort) : nil) else { return nil }
            if let scope = remembered[pid] { return (pid, scope) }
            for (root, scope) in runs where ProcessAncestry.descends(pid, from: [root]) { return (pid, scope) }
            if ProcessAncestry.startedByApp(pid) { return (pid, .nothing) }
            return nil
        }.value
        guard let (pid, found) = scope else { return nil }
        agentRunCallers[pid] = found
        // A process left over from a run that's over may do nothing at all.
        return runs.contains { $0.1 == found } ? found : .nothing
    }

    /// Text an app wants visitors to see (a reply, its progress), with anything that looks like a secret
    /// hidden: values from the project's .env files, and key-, token-, and password-shaped text. The host
    /// is told when something was hidden.
    func redactedForVisitors(_ text: String, client: String, in definition: TunnelDefinition) -> String {
        var folders: [URL] = []
        if let folder = definition.agentDirectory ?? detectedProjectDirectory(for: definition)?.path { folders.append(URL(fileURLWithPath: folder)) }
        if let root = definition.branchSession?.root { folders.append(URL(fileURLWithPath: root)) }
        let redactor = ReplyRedactor(values: ReplyRedactor.environmentValues(in: folders))
        let result = redactor.redact(text)
        if result.redacted {
            notice = AppNotice(.info, "OpenTraffic hid what looked like a password or key in \(client)'s message on “\(definition.name)” before visitors could see it.")
        }
        return result.text
    }

    // MARK: Running the agent command

    var agentCommandIsSet: Bool {
        agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil
    }

    /// The name agents started by OpenTraffic go by in the session.
    var agentClientName: String {
        AgentPreset.matching(agentCommand)?.clientName ?? "Agent"
    }

    func isQueuedForAgent(_ commentID: String, in id: UUID) -> Bool {
        agentQueues[id]?.contains(commentID) == true || (agentRuns[id]?.state == .running && agentRuns[id]?.commentID == commentID)
    }

    /// The host asked for it: runs the agent command for the comment (after any run already going).
    func sendToAgent(_ commentID: String, for id: UUID) {
        guard agentCommandIsSet else {
            notice = AppNotice(.error, "Set the agent command in Settings → Integrations first.")
            return
        }
        enqueueAgentRun(commentID, for: id)
    }

    /// A new comment: if no app takes it within a few seconds, runs the agent command for it.
    func scheduleAutomaticAgentRun(_ commentID: String, for id: UUID) {
        guard agentCommandIsSet else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AgentDispatchPolicy.grace))
            guard let self, self.agentRunsAutomatically else { return }
            // Our own run is busy with this share: the comment waits its turn.
            if self.agentRuns[id]?.state == .running {
                self.enqueueAgentRun(commentID, for: id)
                return
            }
            guard let comment = self.comments(for: id).first(where: { $0.id == commentID }),
                  AgentDispatchPolicy.shouldRun(
                      comment,
                      claimed: self.agentClaims.claim(share: id, comment: commentID) != nil,
                      watched: self.apiEvents.isWatched(id),
                      otherClaims: !self.agentClaims.claims(share: id).isEmpty
                  ) else { return }
            // Comments that read like orders, and more than the budget allows, wait for the host's Send to ….
            let name = self.definitions.first { $0.id == id }?.name ?? "a share"
            // Only people the host trusts start the agent by themselves.
            if !comment.fromHost, self.definitions.first(where: { $0.id == id })?.collabRole(forClient: comment.authorClient) != .trusted {
                self.notice = AppNotice(.info, "\(comment.author)'s comment on “\(name)” is waiting for you: only people you trust start \(self.agentClientName) by themselves. Trust them in Live Collaboration, or use Send to \(self.agentClientName).")
                return
            }
            let host = self.definitions.first { $0.id == id }.flatMap { self.publicURL(for: $0) }.flatMap { URL(string: $0)?.host }
            if AgentDispatchPolicy.looksSuspicious(comment, siteHost: host) {
                self.notice = AppNotice(.info, "\(comment.author)'s comment on “\(name)” is waiting for you: it reads more like instructions than feedback, so \(self.agentClientName) didn't start by itself.")
                return
            }
            let visitor = comment.authorClient ?? comment.author
            guard self.agentRunBudget.allows(share: id, visitor: visitor) else {
                self.notice = AppNotice(.info, "\(comment.author)'s comment on “\(name)” is waiting for you: \(self.agentClientName) already ran by itself as often as it may this hour.")
                return
            }
            self.agentRunBudget.record(share: id, visitor: visitor)
            self.enqueueAgentRun(commentID, for: id)
        }
    }

    private func enqueueAgentRun(_ commentID: String, for id: UUID) {
        guard !isQueuedForAgent(commentID, in: id) else { return }
        agentQueues[id, default: []].append(commentID)
        if agentRuns[id]?.state != .running { startNextAgentRun(for: id) }
    }

    /// Starts the run for the next comment still open and unclaimed, if any.
    private func startNextAgentRun(for id: UUID) {
        guard !isTerminating, agentRuns[id]?.state != .running,
              let definition = definitions.first(where: { $0.id == id }) else { return }
        while var queue = agentQueues[id], !queue.isEmpty {
            let commentID = queue.removeFirst()
            agentQueues[id] = queue.isEmpty ? nil : queue
            guard let comment = comments(for: id).first(where: { $0.id == commentID }), !comment.resolved,
                  agentClaims.claim(share: id, comment: commentID) == nil else { continue }
            guard let directory = agentDirectory(for: definition) else {
                agentQueues[id] = nil
                notice = AppNotice(.error, "Choose the project folder for “\(definition.name)” in its Feedback tab, so the agent knows where to work.")
                return
            }
            launchAgent(AgentRunRequest(shareID: id, shareName: definition.name, commentID: commentID, client: agentClientName, socket: AppSocket.path()), in: directory)
            return
        }
    }

    private func launchAgent(_ request: AgentRunRequest, in directory: URL) {
        let id = request.shareID
        let command = agentCommand
        let run = AgentRun(commentID: request.commentID, client: request.client, directory: directory.path, startedAt: Date())
        agentRuns[id] = run
        Task { [weak self] in
            guard let self else { return }
            let path = await self.userShellPath()
            // Stopped (or the share removed) while looking up PATH.
            guard self.agentRuns[id]?.id == run.id, self.agentRuns[id]?.state == .running else { return }
            let process = AgentProcess(command: command, directory: directory, environment: request.environment, path: self.agentPath(path))
            do {
                try process.start(
                    output: { [weak self] text in
                        Task { @MainActor in self?.agentPrinted(text, for: id, run: run.id) }
                    },
                    exit: { [weak self] status, signalled in
                        Task { @MainActor in self?.agentExited(status: status, signalled: signalled, for: id, run: run.id) }
                    }
                )
            } catch {
                self.agentRuns[id]?.state = .failed("Couldn't start the agent command: \(error.localizedDescription)")
                self.startNextAgentRun(for: id)
                return
            }
            self.agentProcesses[id] = process
            try? await Task.sleep(for: .seconds(AgentDispatchPolicy.timeout))
            if self.agentRuns[id]?.id == run.id, self.agentRuns[id]?.state == .running {
                self.agentPrinted("\nOpenTraffic stopped the agent after \(Int(AgentDispatchPolicy.timeout / 60)) minutes.\n", for: id, run: run.id)
                self.stopAgentRun(for: id, keepingQueue: true)
            }
        }
    }

    private func agentPrinted(_ text: String, for id: UUID, run runID: UUID) {
        guard var run = agentRuns[id], run.id == runID, !text.isEmpty else { return }
        var parts = text.components(separatedBy: "\n")
        // Continue the line the previous chunk ended in the middle of.
        if run.endsMidLine, !run.output.isEmpty {
            run.output[run.output.count - 1] = String((run.output[run.output.count - 1] + parts.removeFirst()).prefix(2000))
        }
        run.endsMidLine = !text.hasSuffix("\n")
        if !run.endsMidLine { parts.removeLast() }
        run.output = Array((run.output + parts.map { String($0.prefix(2000)) }).suffix(Self.agentOutputLines))
        agentRuns[id] = run
    }

    private func agentExited(status: Int32, signalled: Bool, for id: UUID, run runID: UUID) {
        guard var run = agentRuns[id], run.id == runID else { return }
        agentProcesses[id] = nil
        let commentID = run.commentID
        if run.state == .running {
            if status != 0 {
                run.state = .failed(signalled ? "The agent stopped." : "The agent command exited with status \(status).")
            } else if !run.reachedOpenTraffic {
                run.state = .failed("\(run.client) ended without touching the comment: it couldn't reach OpenTraffic. See its output.")
            } else {
                run.state = .finished
            }
        }
        agentRuns[id] = run
        // It stopped without finishing: the comment is free for someone else.
        if agentClaims.claim(share: id, comment: commentID)?.agent == run.client,
           agentClaims.release(share: id, comment: commentID) != nil {
            claimsChanged(for: id)
            if let share = apiShareRef(id), let comment = comments(for: id).first(where: { $0.id == commentID }) {
                apiEvents.append(.commentReleased, share: share, comment: APIComment(comment, shareID: id))
            }
        }
        if case .failed(let reason) = run.state, notifyCollaboration, let share = definitions.first(where: { $0.id == id }) {
            TunnelNotifications.post(
                title: "\(run.client) couldn't finish a comment on \(share.name)",
                body: reason,
                identifier: "agent-run-\(id.uuidString)",
                tunnelID: id
            )
        }
        startNextAgentRun(for: id)
    }

    /// An app worked on `commentID` through OpenTraffic: if it's the comment the share's run is for, that run
    /// got to OpenTraffic's tools. Whoever called counts, since a custom command may go by any name.
    func noteAgentReachedOpenTraffic(_ commentID: String, in id: UUID) {
        guard agentRuns[id]?.state == .running, agentRuns[id]?.commentID == commentID else { return }
        agentRuns[id]?.reachedOpenTraffic = true
    }

    /// Stops the share's run, if one is going, and forgets the comments waiting for it unless `keepingQueue`.
    func stopAgentRun(for id: UUID, keepingQueue: Bool = false) {
        if !keepingQueue { agentQueues[id] = nil }
        if agentRuns[id]?.state == .running { agentRuns[id]?.state = .stopped }
        agentProcesses.removeValue(forKey: id)?.stop()
    }

    func stopAllAgentRuns() {
        for id in Array(agentProcesses.keys) + Array(agentRuns.keys) { stopAgentRun(for: id) }
    }

    /// `path` with this copy of OpenTraffic's `opentraffic` command first, whether or not the user put one in
    /// their PATH (Settings → General) and whichever copy that is: the agent's way to the comment.
    private func agentPath(_ path: String) -> String {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.isExecutableFile(atPath: resources.appending(path: "opentraffic").path) else { return path }
        return resources.path + ":" + path
    }

    /// The user's PATH from their shell, so `claude` and the like are found; looked up once.
    private func userShellPath() async -> String {
        if agentShellPath == nil {
            agentShellPath = Task.detached(priority: .userInitiated) { LoginShell.pathOrFallback() }
        }
        return await agentShellPath?.value ?? LoginShell.pathOrFallback()
    }

    // MARK: Project folder

    /// Where the agent works on this share's comments: the folder chosen for it, else the folder its local
    /// server runs from (remembered once found).
    func agentDirectory(for definition: TunnelDefinition) -> URL? {
        if let path = definition.agentDirectory {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        guard let directory = detectedProjectDirectory(for: definition) else { return nil }
        setAgentDirectory(directory.path, for: definition.id)
        return directory
    }

    /// The folder the share's local server runs from, if OpenTraffic can tell.
    func detectedProjectDirectory(for definition: TunnelDefinition) -> URL? {
        guard let port = URL(string: definition.localURL)?.port,
              let pid = detectedLocalServices.first(where: { $0.port == port })?.pid else { return nil }
        return ProcessDirectory.of(pid)
    }

    func setAgentDirectory(_ path: String?, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }), definitions[index].agentDirectory != path?.nilIfBlank else { return }
        definitions[index].agentDirectory = path?.nilIfBlank
        saveDefinitions()
    }

    /// Lets the user pick the share's project folder.
    func chooseAgentDirectory(for id: UUID) {
        guard let definition = definitions.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The project the agent works in for comments on “\(definition.name)”."
        if let current = definition.agentDirectory ?? detectedProjectDirectory(for: definition)?.path {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setAgentDirectory(url.path, for: id)
    }
}

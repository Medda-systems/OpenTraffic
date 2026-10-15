import AppKit
import Foundation
import OpenTrafficCore

/// Whether a share's project can work on a branch.
enum BranchReadiness: Equatable {
    case ready
    /// OpenTraffic can't tell where the project is yet; decided when the share starts.
    case folderUnknown
    case gitMissing
    case noRepository(URL)
}

/// "Work on a branch": while a collaborative share runs, its project is on a branch of its own. Each
/// fix for a comment is committed there, and stopping the share merges the branch back when that's
/// clean. See specs/collab-plan.md, 3.6.
extension AppStore {
    /// The share's repository object, one per repository so its git calls never overlap.
    private func repository(at root: String) -> GitRepository {
        if let existing = gitRepositories[root] { return existing }
        let repository = GitRepository(root: URL(fileURLWithPath: root, isDirectory: true))
        gitRepositories[root] = repository
        return repository
    }

    private func setBranchSession(_ session: GitBranchSession?, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }), definitions[index].branchSession != session else { return }
        definitions[index].branchSession = session
        saveDefinitions()
    }

    func branchReadiness(for definition: TunnelDefinition) async -> BranchReadiness {
        guard let folder = agentDirectory(for: definition) else { return .folderUnknown }
        return await Task.detached { () -> BranchReadiness in
            // Checked first: running Apple's git without its tools opens macOS's install dialog.
            guard GitRepository.isGitInstalled else { return .gitMissing }
            return GitRepository.containing(folder) == nil ? .noRepository(folder) : .ready
        }.value
    }

    /// The switch in the share's card: turning it on checks the project first, offering to set up git
    /// where there's none (or to install it).
    func requestWorkOnBranch(_ enabled: Bool, for id: UUID) async {
        guard enabled, let definition = definitions.first(where: { $0.id == id }) else {
            await setWorkOnBranch(false, for: id)
            return
        }
        switch await branchReadiness(for: definition) {
        case .ready, .folderUnknown:
            await setWorkOnBranch(true, for: id)
        case .gitMissing:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "git isn't installed"
            alert.informativeText = "Working on a branch needs git, which comes with Apple's Command Line Tools. Installing them takes a few minutes; then turn this on again."
            alert.addButton(withTitle: "Install Command Line Tools")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task.detached { GitRepository.installCommandLineTools() }
            }
        case .noRepository(let folder):
            let path = (folder.path as NSString).abbreviatingWithTildeInPath
            NSApp.activate(ignoringOtherApps: true)
            guard Self.gitSetupAlert(shareName: definition.name, path: path).runModal() == .alertFirstButtonReturn else {
                notice = AppNotice(.info, "“\(definition.name)” works without a branch.")
                return
            }
            let result = await Task.detached { Result { try GitRepository.initialize(folder) } }.value
            switch result {
            case .success:
                notice = AppNotice(.success, "Set up git in \(path).")
                await setWorkOnBranch(true, for: id)
            case .failure(let error):
                notice = AppNotice(.error, "Couldn't set up git in \(path): \(error.localizedDescription)")
            }
        }
    }

    /// Offers to set up git for a share's project: Set Up Git, or Continue Without.
    static func gitSetupAlert(shareName: String, path: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(shareName)” isn't in a git repository"
        alert.informativeText = """
        OpenTraffic can set one up in \(path), so fixes are committed on a branch and merged back when the share stops.

        It adds a .gitignore if there isn't one, then commits the project as it is now, leaving out dependencies, build output, .env files, and files over 10 MB. Nothing leaves this Mac.
        """
        alert.addButton(withTitle: "Set Up Git")
        alert.addButton(withTitle: "Continue Without")
        return alert
    }

    /// The API's (and so the command line's) answer when the project can't work on a branch: no dialog
    /// there, so it says what to do instead.
    func apiRequireBranchReady(_ definition: TunnelDefinition) async throws {
        switch await branchReadiness(for: definition) {
        case .ready, .folderUnknown:
            return
        case .gitMissing:
            throw OpenTrafficAPIError.conflict("git isn't installed on this Mac. Install Apple's Command Line Tools (xcode-select --install), then try again.")
        case .noRepository(let folder):
            let path = (folder.path as NSString).abbreviatingWithTildeInPath
            throw OpenTrafficAPIError.conflict("“\(definition.name)”'s project, \(path), isn't in a git repository. Run git init there, or turn on Work on a branch in OpenTraffic, which offers to set it up.")
        }
    }

    /// Turns "Work on a branch" on or off; a running collaborative share starts or ends its branch now.
    func setWorkOnBranch(_ enabled: Bool, for id: UUID) async {
        guard let index = definitions.firstIndex(where: { $0.id == id }), definitions[index].workOnBranch != enabled else { return }
        definitions[index].workOnBranch = enabled
        saveDefinitions()
        if enabled {
            if isCollaborating(id) { await beginBranchSession(for: id) }
        } else {
            await endBranchSession(for: id)
        }
    }

    /// Puts the share's project on a branch of its own (or carries on with the one it was on). Called
    /// when its collaboration starts.
    func beginBranchSession(for id: UUID) async {
        guard let definition = definitions.first(where: { $0.id == id }), definition.workOnBranch, definition.collaboration else { return }
        if let session = definition.branchSession {
            let repository = repository(at: session.root)
            let carryOn = await Task.detached { repository.isOn(session) ? try? repository.currentSnapshot() : nil }.value
            if let baseline = carryOn {
                gitBaselines[id] = baseline
                return
            }
            // Someone switched branches since: that session is over.
            setBranchSession(nil, for: id)
        }
        guard let directory = agentDirectory(for: definition) else {
            notice = AppNotice(.info, "OpenTraffic couldn't tell where “\(definition.name)”'s project is, so it isn't on a branch. Choose the folder in its Feedback tab.")
            return
        }
        let name = definition.name
        let started = await Task.detached { () -> Result<(GitRepository, GitBranchSession, GitSnapshot), Error> in
            guard GitRepository.isGitInstalled else { return .failure(GitSessionError.gitMissing) }
            guard let found = GitRepository.containing(directory) else { return .failure(GitSessionError.notARepository) }
            return Result { let (session, baseline) = try found.startSession(name: name); return (found, session, baseline) }
        }.value
        // Stopped, or turned off, meanwhile.
        guard isCollaborating(id), definitions.first(where: { $0.id == id })?.workOnBranch == true else {
            if case .success(let (found, session, _)) = started { _ = try? await Task.detached { try found.endSession(session) }.value }
            return
        }
        switch started {
        case .success(let (found, session, baseline)):
            gitRepositories[session.root] = gitRepositories[session.root] ?? found
            gitBaselines[id] = baseline
            setBranchSession(session, for: id)
            notice = AppNotice(.info, "“\(name)” is working on \(session.branch). Stopping it merges that into \(session.original).")
        case .failure(GitSessionError.notARepository):
            turnOffWorkOnBranch(for: id, because: "its project isn't in a git repository")
        case .failure(GitSessionError.gitMissing):
            turnOffWorkOnBranch(for: id, because: "git isn't installed")
        case .failure(let error):
            notice = AppNotice(.error, "“\(name)” isn't on a branch: \(error.localizedDescription)")
        }
    }

    /// It won't work next time either: turned off, rather than saying so on every start.
    private func turnOffWorkOnBranch(for id: UUID, because reason: String) {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].workOnBranch = false
        saveDefinitions()
        notice = AppNotice(.info, "“\(definitions[index].name)” isn't working on a branch: \(reason). Turn Work on a branch on again to set it up.")
    }

    /// Ends the share's branch: merges it back when that's clean, or keeps it and says why.
    func endBranchSession(for id: UUID) async {
        guard let session = definitions.first(where: { $0.id == id })?.branchSession else { return }
        let repository = repository(at: session.root)
        let result = await Task.detached { Result { try repository.endSession(session) } }.value
        let stillOn = await Task.detached { repository.isOn(session) }.value
        branchSessionEnded(session, result: result, stillOn: stillOn, for: id)
    }

    /// `endBranchSession` without waiting for anything else, for quitting and removing a share.
    func endBranchSessionNow(for id: UUID) {
        guard let session = definitions.first(where: { $0.id == id })?.branchSession else { return }
        let repository = repository(at: session.root)
        branchSessionEnded(session, result: Result { try repository.endSession(session) }, stillOn: repository.isOn(session), for: id)
    }

    private func branchSessionEnded(_ session: GitBranchSession, result: Result<GitSessionEnd, Error>, stillOn: Bool, for id: UUID) {
        gitBaselines[id] = nil
        claimSnapshots[id] = nil
        // A branch that's still checked out is carried on with next time; otherwise the session is over.
        if !stillOn { setBranchSession(nil, for: id) }
        let name = definitions.first(where: { $0.id == id })?.name ?? "The share"
        let message: String
        switch result {
        case .success(.merged(let commits)):
            message = commits == 0
                ? "Back on \(session.original); nothing was committed on \(session.branch)."
                : "Merged \(commits) fix\(commits == 1 ? "" : "es") from \(session.branch) into \(session.original)."
            notice = AppNotice(.success, message)
        case .success(.kept(let reason)):
            message = reason
            notice = AppNotice(.info, message)
        case .failure(let error):
            message = "Couldn't merge \(session.branch): \(error.localizedDescription)"
            notice = AppNotice(.error, message)
        }
        if notifyCollaboration {
            TunnelNotifications.post(title: "\(name): \(session.branch)", body: message, identifier: "branch-\(id.uuidString)", tunnelID: id)
        }
    }

    /// Notes what's changed when an app claims a comment, so its fix commits only what changed after.
    func noteClaimForBranch(_ commentID: String, for id: UUID) {
        guard let session = definitions.first(where: { $0.id == id })?.branchSession else { return }
        let repository = repository(at: session.root)
        Task {
            guard let snapshot = await Task.detached(operation: { try? repository.currentSnapshot() }).value else { return }
            claimSnapshots[id, default: [:]][commentID] = snapshot
        }
    }

    /// A comment was resolved: commits what changed for it on the share's branch. Changes count from
    /// the claim, or else from the last commit (or the start); comments a visitor resolved without an
    /// app or the host having worked on them aren't committed.
    func commitFixIfNeeded(_ comment: CollabComment, for id: UUID) {
        guard let definition = definitions.first(where: { $0.id == id }), let session = definition.branchSession else { return }
        let claimed = claimSnapshots[id]?.removeValue(forKey: comment.id)
        let byHost = comment.resolvedBy == (collaborationHostName.nilIfBlank ?? "Host")
        guard claimed != nil || comment.resolvedByAgent || byHost, let since = claimed ?? gitBaselines[id] else { return }
        let text = comment.text.components(separatedBy: .newlines).joined(separator: " ")
        let subject = "Fix: " + (text.count > 64 ? text.prefix(63) + "…" : text)
        let element = comment.label.map { " (“\($0)”)" } ?? ""
        let body = """
        \(comment.author)'s comment on \(comment.path)\(element), resolved by \(comment.resolvedBy ?? "the host") in OpenTraffic.
        Share “\(definition.name)”, comment \(comment.id).
        """
        let repository = repository(at: session.root)
        Task {
            let result = await Task.detached {
                Result { (try repository.commitChanges(since: since, in: session, subject: subject, body: body), try repository.currentSnapshot()) }
            }.value
            switch result {
            case .success(let (_, after)):
                gitBaselines[id] = after
            case .failure(let error):
                notice = AppNotice(.error, "Couldn't commit the fix for \(comment.author)'s comment on \(session.branch): \(error.localizedDescription)")
            }
        }
    }
}

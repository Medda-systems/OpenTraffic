import AppKit
import Foundation
import OpenTrafficCore

/// Live collaboration: a share runs through OpenTraffic's proxy, which adds the presence overlay to
/// pages and hosts the hub everyone's browser connects to. See specs/collab-plan.md.
extension AppStore {
    static let collaborationScript: Data? = Bundle.main.url(forResource: "collab", withExtension: "js")
        .flatMap { try? Data(contentsOf: $0) }
    static let bridgeScript: Data = Bundle.main.url(forResource: "bridge", withExtension: "js")
        .flatMap { try? Data(contentsOf: $0) } ?? Data()

    /// Why collaboration can't be used for this tunnel, or nil when it can.
    func collaborationBlocker(for definition: TunnelDefinition) -> String? {
        guard definition.kind.supportsCollaboration else {
            return "Live collaboration works with temporary (Quick Tunnel) and OpenTunnel shares for now."
        }
        guard URL(string: definition.localURL)?.scheme?.lowercased() == "http" else {
            return "Live collaboration needs an http:// local address for now."
        }
        guard Self.collaborationScript != nil else {
            return "OpenTraffic's collaboration overlay is missing from the app. Reinstall OpenTraffic."
        }
        return nil
    }

    func usesCollaboration(_ definition: TunnelDefinition) -> Bool {
        definition.collaboration && collaborationBlocker(for: definition) == nil
    }

    func isCollaborating(_ id: UUID) -> Bool {
        collabProxies[id]?.configuration.injectsOverlay == true
    }

    func peers(for id: UUID) -> [CollabPeer] {
        collabPeers[id] ?? []
    }

    /// Turns collaboration on or off. A running Quick Tunnel restarts to apply it, which gives it a
    /// new address; callers confirm that first.
    func setCollaboration(_ enabled: Bool, for id: UUID) async {
        guard let index = definitions.firstIndex(where: { $0.id == id }), definitions[index].collaboration != enabled else { return }
        definitions[index].collaboration = enabled
        saveDefinitions()
        if !enabled { await endBranchSession(for: id) }
        if isActive(id) { await restart(id) }
    }

    /// Starts (creating if needed) a temporary share of `localURL` with collaboration on, and shows it.
    func shareWithCollaboration(localURL: String, name: String) {
        shareLocalURL(localURL, kind: .quick, name: name, collaboration: true)
        if let share = definitions.first(where: { $0.kind == .quick && $0.localURL == localURL }) {
            selectedID = share.id
        }
    }

    /// Opens the share in the browser as its host, who can lead everyone else.
    func openAsCollaborationHost(_ id: UUID) {
        guard let url = collabProxies[id]?.hostJoinURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Lifecycle

    /// Quick Tunnels go through OpenTraffic's proxy for live collaboration or a password.
    func quickNeedsProxy(_ definition: TunnelDefinition) -> Bool {
        if usesCollaboration(definition) { return true }
        if case .password = definition.protection { return true }
        return false
    }

    /// Starts a Quick Tunnel whose connector forwards to a fresh proxy (collaboration, a password, or both).
    func startQuickWithProxy(_ definition: TunnelDefinition, generation: UInt64, executable: URL) async {
        let collaboration = usesCollaboration(definition)
        do {
            guard let proxyURL = try await startShareProxy(for: definition, generation: generation, collaboration: collaboration) else { return }
            startQuickConnector(definition, localURL: proxyURL, generation: generation, executable: executable)
            // The connector didn't launch: nothing will reach the proxy.
            if runtime(for: definition.id).state == .failed { stopCollaboration(definition.id) }
        } catch {
            let what = collaboration ? "live collaboration" : "this share"
            setFailure("OpenTraffic couldn't start \(what): \(error.localizedDescription)", for: definition.id, generation: generation)
        }
    }

    /// Starts OpenTraffic's proxy in front of the share's local server and returns its local URL, or
    /// nil when a newer start or a stop has taken over. With `collaboration` it adds the overlay and
    /// hosts the session; without it, it only forwards, sending the local Host header when the share
    /// asks for that (used by tunnels that can't rewrite it themselves).
    func startShareProxy(for definition: TunnelDefinition, generation: UInt64, collaboration: Bool) async throws -> String? {
        guard let url = URL(string: definition.localURL), let host = url.host else {
            throw OpenTrafficError.invalidLocalURL
        }
        guard !collaboration || Self.collaborationScript != nil else { throw OpenTrafficError.invalidLocalURL }
        let access = try shareAccess(for: definition)
        stopCollaboration(definition.id)
        let id = definition.id
        let proxy = CollabProxy(
            configuration: .init(
                upstreamHost: host,
                upstreamPort: url.port ?? 80,
                overlayScript: Self.collaborationScript ?? Data(),
                hostName: collaborationHostName.nilIfBlank,
                bridgeScript: Self.bridgeScript,
                attachmentsDirectory: collaboration ? feedbackPersistence.attachmentsDirectory(id) : nil,
                injectsOverlay: collaboration,
                rewritesHostHeader: definition.kind != .quick && definition.rewriteHostHeader,
                // Only Cloudflare says who each visitor is.
                limitsConnectionsPerAddress: definition.kind.provider == .cloudflare
            ),
            comments: collaboration ? comments(for: id) : []
        )
        proxy.setAccess(access)
        if collaboration {
            proxy.setBridgedPorts(Set(definition.bridgedPorts))
            await proxy.setCapturesErrors(definition.captureErrors)
            proxy.setBridgeCandidatesHandler { [weak self, weak proxy] port in
                Task { @MainActor in
                    guard let self, let proxy, self.collabProxies[id] === proxy else { return }
                    self.collabBridgeCandidates[id, default: []].insert(port)
                }
            }
            proxy.setErrorsHandler { [weak self, weak proxy] items in
                Task { @MainActor in
                    guard let self, let proxy, self.collabProxies[id] === proxy else { return }
                    self.errorsReported(items, for: id)
                }
            }
            proxy.setPeersHandler { [weak self, weak proxy] peers in
                Task { @MainActor in
                    guard let self, let proxy, self.collabProxies[id] === proxy else { return }
                    self.peersChanged(peers, for: id)
                }
            }
            proxy.setCommentsHandler { [weak self, weak proxy] comments in
                Task { @MainActor in
                    guard let self, let proxy, self.collabProxies[id] === proxy else { return }
                    self.commentsChanged(comments, for: id)
                }
            }
            await proxy.setAgentWork(agentClaims.claims(share: id).map(\.work))
        }
        _ = try await proxy.start()
        guard runtime(for: id).generation == generation, let proxyURL = proxy.localURL else {
            await proxy.stop()
            return nil
        }
        collabProxies[id] = proxy
        updateReservedPorts()
        if collaboration { Task { await beginBranchSession(for: id) } }
        return proxyURL
    }

    // MARK: People and comments

    /// Every page load is a new connection, so someone browsing leaves and joins again a moment
    /// later. Departures wait a few seconds; a return by then counts as neither.
    private func peersChanged(_ peers: [CollabPeer], for id: UUID) {
        let previous = collabPeers[id] ?? []
        let before = Set(previous.map(\.id))
        let now = Set(peers.map(\.id))
        collabPeers[id] = peers.isEmpty ? nil : peers
        var joined: [CollabPeer] = []
        for peer in peers where !before.contains(peer.id) {
            let returning = recentDepartures[id]?.removeValue(forKey: peer.name) != nil
            // Already here in another tab, or the new page connected before the old one closed.
            let present = previous.contains { $0.name == peer.name }
            if !returning, !present { joined.append(peer) }
        }
        let left = previous.filter { !now.contains($0.id) }
        for peer in left {
            recentDepartures[id, default: [:]][peer.name] = peer
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.departureSettled(peer, for: id)
            }
        }
        if let share = apiShareRef(id) {
            for peer in joined { apiEvents.append(.sessionJoined, share: share, peer: APIPerson(peer)) }
        }
        let joinedNames = joined.filter { !$0.isHost && !$0.isAgent }.map(\.name)
        if !joinedNames.isEmpty { notifyJoined(joinedNames, for: id) }
    }

    private func departureSettled(_ peer: CollabPeer, for id: UUID) {
        guard recentDepartures[id]?[peer.name]?.id == peer.id else { return } // came back, or left again since
        recentDepartures[id]?[peer.name] = nil
        guard !peers(for: id).contains(where: { $0.name == peer.name }) else { return }
        if let share = apiShareRef(id) { apiEvents.append(.sessionLeft, share: share, peer: APIPerson(peer)) }
    }

    private func errorsReported(_ items: [CollabErrorItem], for id: UUID) {
        var groups = collabErrors[id] ?? []
        let added = CollabErrorGroup.merge(items, into: &groups)
        collabErrors[id] = groups
        if let share = apiShareRef(id) {
            for group in added { apiEvents.append(.errorReported, share: share, error: group) }
        }
    }

    // MARK: Localhost bridge and error collection

    /// Lets the shared page reach another local service through the tunnel. Applies immediately.
    func allowBridgedPort(_ port: Int, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }), !definitions[index].bridgedPorts.contains(port) else { return }
        definitions[index].bridgedPorts.append(port)
        definitions[index].bridgedPorts.sort()
        saveDefinitions()
        collabBridgeCandidates[id]?.remove(port)
        collabProxies[id]?.setBridgedPorts(Set(definitions[index].bridgedPorts))
    }

    func removeBridgedPort(_ port: Int, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].bridgedPorts.removeAll { $0 == port }
        saveDefinitions()
        collabProxies[id]?.setBridgedPorts(Set(definitions[index].bridgedPorts))
    }

    func dismissBridgeCandidate(_ port: Int, for id: UUID) {
        collabBridgeCandidates[id]?.remove(port)
    }

    /// Turns browser-error collection on or off; pages opened from now on follow it.
    func setCaptureErrors(_ enabled: Bool, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }), definitions[index].captureErrors != enabled else { return }
        definitions[index].captureErrors = enabled
        saveDefinitions()
        if let proxy = collabProxies[id] { Task { await proxy.setCapturesErrors(enabled) } }
    }

    func clearErrors(for id: UUID) {
        collabErrors[id] = nil
    }

    /// A reply from the host (or, with `agent`, from an app using the API). Live when the share runs.
    @discardableResult
    func replyToComment(_ commentID: String, text: String, for id: UUID, agent: String? = nil) async -> CollabComment? {
        let author = collaborationHostName.nilIfBlank ?? "Host"
        if let proxy = collabProxies[id] {
            return await proxy.addReply(to: commentID, text: text, author: agent ?? author, agent: agent)
        }
        var comments = comments(for: id)
        guard let index = comments.firstIndex(where: { $0.id == commentID }),
              let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank, text.count <= CollabRoom.maximumCommentLength else { return nil }
        comments[index].replies.append(CollabReply(
            id: CollabRoom.makeID(),
            author: agent ?? author,
            color: CollabRoom.palette[0],
            text: text,
            createdAt: Date(),
            fromHost: true,
            agent: agent
        ))
        commentsChanged(comments, for: id)
        return comments[index]
    }

    /// The picture attached to a comment, or with `after`, the picture of it once resolved; if any.
    func screenshotURL(for comment: CollabComment, in id: UUID, after: Bool = false) -> URL? {
        guard let attachment = after ? comment.afterScreenshot : comment.screenshot, CollabProxyAttachment.isValid(attachment) else { return nil }
        let directory = feedbackPersistence.attachmentsDirectory(id)
        return ["webp", "jpg", "png"].lazy
            .map { directory.appending(path: "\(attachment).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: API events

    func apiShareRef(_ id: UUID) -> APIShareRef? {
        guard let definition = definitions.first(where: { $0.id == id }) else { return nil }
        return APIShareRef(id: id, name: definition.name, publicURL: publicURL(for: definition))
    }

    /// Joins are grouped: at most one notification per share every 15 seconds.
    private func notifyJoined(_ names: [String], for id: UUID) {
        guard notifyCollaboration else { return }
        pendingJoinNames[id, default: []] += names
        let wait = 15 - Date().timeIntervalSince(lastJoinNotification[id] ?? .distantPast)
        guard pendingJoinNames[id]?.count == names.count else { return } // a post is already scheduled
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.postJoinNotification(for: id)
        }
    }

    private func postJoinNotification(for id: UUID) {
        guard let names = pendingJoinNames.removeValue(forKey: id), let first = names.first,
              let share = definitions.first(where: { $0.id == id }) else { return }
        lastJoinNotification[id] = Date()
        let who = switch names.count {
        case 1: first
        case 2: "\(first) and \(names[1])"
        default: "\(first) and \(names.count - 1) others"
        }
        TunnelNotifications.post(
            title: "\(who) joined \(share.name)",
            body: "\(peers(for: id).count) people are in the session now.",
            identifier: "collab-join-\(id.uuidString)",
            tunnelID: id
        )
    }

    func commentsChanged(_ comments: [CollabComment], for id: UUID) {
        let previous = self.comments(for: id)
        let known = Set(previous.map(\.id))
        setComments(comments, for: id)
        let byID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let share = apiShareRef(id) {
            for comment in comments {
                let claim = agentClaims.claim(share: id, comment: comment.id)
                if let old = byID[comment.id] {
                    if old != comment { apiEvents.append(.commentUpdated, share: share, comment: APIComment(comment, shareID: id, claim: claim)) }
                } else {
                    apiEvents.append(.commentCreated, share: share, comment: APIComment(comment, shareID: id, claim: claim))
                }
            }
            let current = Set(comments.map(\.id))
            for comment in previous where !current.contains(comment.id) {
                apiEvents.append(.commentDeleted, share: share, commentId: comment.id)
            }
        }
        // Resolved or deleted from the page while an app was on it: nothing left to work on.
        let open = Set(comments.lazy.filter { !$0.resolved }.map(\.id))
        for claim in agentClaims.claims(share: id) where !open.contains(claim.commentID) {
            agentClaims.release(share: id, comment: claim.commentID)
            claimsChanged(for: id)
        }
        for comment in comments {
            guard let old = byID[comment.id] else { continue }
            if comment.resolved, !old.resolved { commitFixIfNeeded(comment, for: id) }
            if comment.confirmed, !old.confirmed {
                notifyFixFeedback(comment, confirmed: true, for: id)
            } else if old.resolved, !comment.resolved {
                // Reopened from the page, not by the host or an app.
                if quietReopens.remove(comment.id) == nil, !old.resolvedByAuthor, old.resolvedBy != nil {
                    notifyFixFeedback(old, confirmed: false, for: id)
                }
            }
        }
        let new = comments.filter { !known.contains($0.id) && !$0.fromHost }
        if !new.isEmpty { notifyCommented(new, for: id) }
        if agentRunsAutomatically {
            for comment in new { scheduleAutomaticAgentRun(comment.id, for: id) }
        }
    }

    /// The commenter agreed with a fix, or reopened it.
    private func notifyFixFeedback(_ comment: CollabComment, confirmed: Bool, for id: UUID) {
        guard notifyCollaboration, let share = definitions.first(where: { $0.id == id }) else { return }
        let fixer = comment.resolvedBy.map { " by \($0)" } ?? ""
        TunnelNotifications.post(
            title: confirmed ? "\(comment.author) confirmed the fix on \(share.name)" : "A fix\(fixer) was reopened on \(share.name)",
            body: "\(comment.path): \(comment.text)",
            identifier: "collab-fix-\(comment.id)",
            tunnelID: id
        )
    }

    /// Comments are grouped like joins: at most one notification per share every 10 seconds.
    private func notifyCommented(_ comments: [CollabComment], for id: UUID) {
        guard notifyCollaboration else { return }
        let scheduled = pendingCommentNotices[id] != nil
        pendingCommentNotices[id, default: []] += comments
        guard !scheduled else { return }
        let wait = 10 - Date().timeIntervalSince(lastCommentNotification[id] ?? .distantPast)
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.postCommentNotification(for: id)
        }
    }

    private func postCommentNotification(for id: UUID) {
        guard let comments = pendingCommentNotices.removeValue(forKey: id), let first = comments.first,
              let share = definitions.first(where: { $0.id == id }) else { return }
        lastCommentNotification[id] = Date()
        let authors = Array(NSOrderedSet(array: comments.map(\.author))) as? [String] ?? [first.author]
        TunnelNotifications.post(
            title: comments.count == 1 ? "\(first.author) commented on \(share.name)"
                : "\(comments.count) new comments on \(share.name)",
            body: comments.count == 1 ? "\(first.path): \(first.text)" : "From \(authors.prefix(3).joined(separator: ", "))\(authors.count > 3 ? " and others" : "")",
            identifier: "collab-comment-\(comments.count == 1 ? first.id : id.uuidString)",
            tunnelID: id
        )
    }

    func comments(for id: UUID) -> [CollabComment] {
        if let comments = collabComments[id] { return comments }
        return feedbackPersistence.load(id)
    }

    /// Loads saved comments into memory so views can observe them.
    func loadComments(for id: UUID) {
        if collabComments[id] == nil { collabComments[id] = feedbackPersistence.load(id) }
    }

    /// Writes to disk a second later, so a burst of changes is one write.
    private func setComments(_ comments: [CollabComment], for id: UUID) {
        collabComments[id] = comments
        unsavedComments.insert(id)
        guard commentSaveTask == nil else { return }
        commentSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.saveCommentsNow()
        }
    }

    /// Writes pending comment changes now (also when quitting).
    func saveCommentsNow() {
        commentSaveTask?.cancel()
        commentSaveTask = nil
        let ids = unsavedComments
        unsavedComments = []
        for id in ids {
            do { try feedbackPersistence.save(collabComments[id] ?? [], for: id) }
            catch { notice = AppNotice(.error, "Couldn't save comments: \(error.localizedDescription)") }
        }
    }

    /// Resolves or reopens a comment; live for everyone when the share is running. `by` is the app that
    /// resolved it (with `agent`), or nil for the host.
    func resolveComment(_ commentID: String, resolved: Bool, for id: UUID, by name: String? = nil, agent: Bool = false) async {
        let name = name ?? (collaborationHostName.nilIfBlank ?? "Host")
        if resolved, agentClaims.release(share: id, comment: commentID) != nil { claimsChanged(for: id) }
        if !resolved, comments(for: id).contains(where: { $0.id == commentID && $0.resolved }) { quietReopens.insert(commentID) }
        if let proxy = collabProxies[id] {
            await proxy.resolveComment(commentID, resolved: resolved, by: name, agent: agent)
        } else {
            var comments = comments(for: id)
            guard let index = comments.firstIndex(where: { $0.id == commentID }), comments[index].resolved != resolved else { return }
            comments[index].setResolved(resolved, by: name, agent: agent)
            commentsChanged(comments, for: id)
        }
    }

    func deleteComment(_ commentID: String, for id: UUID) async {
        if let proxy = collabProxies[id] {
            await proxy.deleteComment(commentID)
        } else {
            commentsChanged(comments(for: id).filter { $0.id != commentID }, for: id)
        }
    }

    func clearResolvedComments(for id: UUID) async {
        for comment in comments(for: id) where comment.resolved {
            await deleteComment(comment.id, for: id)
        }
    }

    func copyFeedback(for id: UUID, asIssue: Bool) {
        guard let share = definitions.first(where: { $0.id == id }) else { return }
        let comments = comments(for: id)
        if asIssue {
            let issue = FeedbackExport.githubIssue(comments, shareName: share.name)
            Pasteboard.copy("\(issue.title)\n\n\(issue.body)")
            notice = AppNotice(.success, "Copied. Paste into a new GitHub issue — the first line is the title.")
        } else {
            Pasteboard.copy(FeedbackExport.markdown(comments, shareName: share.name))
            notice = AppNotice(.success, "Copied \(comments.count) comments as Markdown.")
        }
    }

    func stopCollaboration(_ id: UUID) {
        let peers = collabPeers.removeValue(forKey: id) ?? []
        let departed = recentDepartures.removeValue(forKey: id).map { Array($0.values) } ?? []
        if let share = apiShareRef(id) {
            for peer in peers + departed { apiEvents.append(.sessionLeft, share: share, peer: APIPerson(peer)) }
        }
        guard let proxy = collabProxies.removeValue(forKey: id) else { return }
        Task { await proxy.stop() }
        updateReservedPorts()
    }

    /// Pages can't reach OpenTraffic's own ports through any share's localhost bridge.
    func updateReservedPorts() {
        var reserved = Set(collabProxies.values.compactMap(\.port))
        if case .running(let port) = apiStatus { reserved.insert(port) }
        reserved.insert(apiPort)
        for proxy in collabProxies.values { proxy.setReservedPorts(reserved) }
    }

    func stopAllCollaboration() {
        for id in Array(collabProxies.keys) { stopCollaboration(id) }
    }

    /// The public hostname lets pages served through the tunnel open the hub's WebSocket.
    func collaborationReceived(publicURL: String, for id: UUID) {
        collabProxies[id]?.setPublicHost(URL(string: publicURL)?.host)
    }

    /// The connector reports the proxy as its origin; show the dev server instead.
    func originBehindCollaboration(_ origin: String, for definition: TunnelDefinition) -> String {
        guard let proxyPort = collabProxies[definition.id]?.port,
              let url = URL(string: origin), url.port == proxyPort,
              ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "") else { return origin }
        return definition.localURL
    }
}

extension APIPerson {
    init(_ peer: CollabPeer) {
        self.init(name: peer.name, path: peer.path, isHost: peer.isHost, isAgent: peer.isAgent ? true : nil)
    }
}

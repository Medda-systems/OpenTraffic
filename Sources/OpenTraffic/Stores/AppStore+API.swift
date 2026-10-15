import AppKit
import Foundation
import OpenTrafficCore
import OpenTrafficSocket

/// Answers OpenTraffic's local API (REST, MCP) from the app's state. Calls hop to the main actor.
final class AppAPIBackend: OpenTrafficAPIBackend {
    let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    func listShares() async -> [APIShare] {
        await store.apiShares()
    }

    func createShare(_ request: APIShareRequest, client: String) async throws -> APIShare {
        try await store.apiCreateShare(request, client: client)
    }

    func startShare(_ share: String, client: String) async throws -> APIShare {
        try await store.apiStartShare(share, client: client)
    }

    func stopShare(_ share: String) async throws -> APIShare {
        try await store.apiStopShare(share)
    }

    func comments(_ share: String, status: APICommentStatus) async throws -> [APIComment] {
        try await store.apiComments(share, status: status)
    }

    func screenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String) {
        try await store.apiScreenshot(share, commentID: commentID)
    }

    func resolveComment(_ share: String, commentID: String, resolved: Bool) async throws -> APIComment {
        try await store.apiResolve(share, commentID: commentID, resolved: resolved)
    }

    func reply(_ share: String, commentID: String, text: String, client: String) async throws -> APIComment {
        try await store.apiReply(share, commentID: commentID, text: text, client: client)
    }

    func errors(_ share: String) async throws -> [CollabErrorGroup] {
        try await store.apiErrors(share)
    }

    func logs(_ share: String, lines: Int) async throws -> [String] {
        try await store.apiLogs(share, lines: lines)
    }

    func status() async -> APIAppStatus? {
        await store.apiAppStatus()
    }

    func share(_ share: String) async throws -> APIShare {
        try await MainActor.run { try store.apiShare(store.apiDefinition(share)) }
    }

    func updateShare(_ share: String, _ update: APIShareUpdate, client: String) async throws -> APIShare {
        try await store.apiUpdateShare(share, update, client: client)
    }

    func restartShare(_ share: String, client: String) async throws -> APIShare {
        try await store.apiRestartShare(share, client: client)
    }

    func deleteShare(_ share: String) async throws {
        try await store.apiDeleteShare(share)
    }

    func protection(_ share: String) async throws -> APIProtection {
        try await store.apiProtection(share)
    }

    func setProtection(_ share: String, _ request: APIProtectionRequest) async throws -> APIProtection {
        try await store.apiSetProtection(share, request)
    }

    func regeneratePassword(_ share: String) async throws -> APIProtection {
        try await store.apiRegeneratePassword(share)
    }

    func deleteComment(_ share: String, commentID: String) async throws {
        try await store.apiDeleteComment(share, commentID: commentID)
    }

    func localServices() async -> [APILocalService] {
        await store.apiLocalServices()
    }

    func projects() async -> [APIProject] {
        await store.apiProjects()
    }

    func startProject(_ name: String, client: String) async throws -> APIProject {
        try await store.apiStartProject(name, client: client)
    }

    func stopProject(_ name: String) async throws -> APIProject {
        try await store.apiStopProject(name)
    }

    func zones() async throws -> [APIZone] {
        try await store.apiZones()
    }

    func tools() async -> [APITool] {
        await store.apiTools()
    }

    func installTool(_ name: String) async throws -> APITool {
        try await store.apiInstallTool(name)
    }
}

enum APIStatus: Equatable {
    case off
    case running(port: Int)
    case failed(String)
}

extension AppStore {
    // MARK: Server

    /// Opens the private socket the `opentraffic` command and the MCP bridge talk to OpenTraffic over.
    /// It's always on (unlike the HTTP API for other apps): they're part of OpenTraffic, so they need no
    /// setup, token, or confirmations.
    func startTrustedChannel() {
        guard trustedChannel == nil else { return }
        let channel = LocalAPIServer(trustedSocketPath: AppSocket.path(), backend: AppAPIBackend(store: self), events: apiEvents)
        trustedChannel = channel
        Task {
            do {
                _ = try await channel.start()
            } catch {
                trustedChannel = nil
                notice = AppNotice(.error, "The opentraffic command can't reach OpenTraffic: \(error.localizedDescription)")
            }
        }
    }

    /// Starts, restarts, or stops the local API to match Settings.
    /// Applies API settings after any earlier apply has finished, so quick changes can't race.
    func scheduleAPISettings() {
        let previous = apiSettingsTask
        apiSettingsTask = Task {
            await previous?.value
            await applyAPISettings()
        }
    }

    func applyAPISettings() async {
        if let server = apiServer, !apiEnabled || server.port != apiPort {
            apiServer = nil
            await server.stop()
        }
        guard apiEnabled, !isTerminating else {
            apiStatus = .off
            return
        }
        guard apiServer == nil else { return }
        do {
            let token = try APIToken.loadOrCreate()
            let server = LocalAPIServer(port: apiPort, token: token, backend: AppAPIBackend(store: self), events: apiEvents)
            let port = try await server.start()
            // Settings may have changed while starting.
            guard apiEnabled, apiPort == port, !isTerminating else {
                await server.stop()
                return await applyAPISettings()
            }
            apiServer = server
            apiStatus = .running(port: port)
            updateReservedPorts()
        } catch {
            apiStatus = .failed("Couldn't start on port \(apiPort): \(error.localizedDescription)")
        }
    }

    var apiToken: String? {
        try? APIToken.loadOrCreate()
    }

    /// Replaces the token; apps using the old one must be set up again.
    func regenerateAPIToken() {
        do {
            let token = try APIToken.regenerate()
            apiServer?.setToken(token)
            notice = AppNotice(.success, "New API token created. Apps using the old one need the new one.")
        } catch {
            notice = AppNotice(.error, "Couldn't create a new token: \(error.localizedDescription)")
        }
    }

    /// The MCP bridge inside this copy of OpenTraffic.
    var mcpBridgePath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/opentraffic-mcp").path
    }

    enum MCPSetup: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case cursor = "Cursor"
        case opencode = "opencode"

        var id: String { rawValue }
    }

    func mcpSetupText(_ client: MCPSetup) -> String {
        let path = mcpBridgePath
        let port = apiPort == LocalAPIServer.defaultPort ? "" : ", \"OPENTRAFFIC_API_PORT\": \"\(apiPort)\""
        switch client {
        case .claudeCode:
            let portFlag = apiPort == LocalAPIServer.defaultPort ? "" : " --env OPENTRAFFIC_API_PORT=\(apiPort)"
            return "claude mcp add --scope user opentraffic --env OPENTRAFFIC_CLIENT=\"Claude Code\"\(portFlag) -- \"\(path)\""
        case .codex:
            let codexPort = apiPort == LocalAPIServer.defaultPort ? "" : ", OPENTRAFFIC_API_PORT = \"\(apiPort)\""
            return """
            [mcp_servers.opentraffic]
            command = "\(path)"
            env = { OPENTRAFFIC_CLIENT = "Codex"\(codexPort) }
            tool_timeout_sec = 330
            """
        case .cursor:
            return """
            {
              "mcpServers": {
                "opentraffic": {
                  "command": "\(path)",
                  "env": { "OPENTRAFFIC_CLIENT": "Cursor"\(port) }
                }
              }
            }
            """
        case .opencode:
            return """
            {
              "mcp": {
                "opentraffic": {
                  "type": "local",
                  "command": ["\(path)"],
                  "environment": { "OPENTRAFFIC_CLIENT": "opencode"\(port) },
                  "enabled": true
                }
              }
            }
            """
        }
    }

    // MARK: Shares

    func apiShares() -> [APIShare] {
        definitions.map(apiShare)
    }

    func apiShare(_ definition: TunnelDefinition) -> APIShare {
        let comments = comments(for: definition.id)
        return APIShare(
            id: definition.id,
            name: definition.name,
            provider: definition.kind.provider.rawValue,
            kind: definition.kind.rawValue,
            state: runtime(for: definition.id).state.rawValue,
            localURL: definition.localURL,
            publicURL: publicURL(for: definition),
            collaboration: definition.collaboration,
            people: peers(for: definition.id).map(APIPerson.init),
            openComments: comments.filter { !$0.resolved }.count,
            comments: comments.count,
            hostname: definition.hostname?.nilIfBlank,
            lastError: runtime(for: definition.id).state == .failed ? runtime(for: definition.id).lastError : nil,
            protection: Self.apiProtectionMode(definition.protection),
            project: definition.project,
            autoStart: definition.autoStart,
            captureErrors: definition.kind.supportsCollaboration ? definition.captureErrors : nil,
            rewriteHostHeader: definition.rewriteHostHeader,
            funnel: definition.kind == .tailscale ? definition.tailscalePublic : nil,
            stopsAt: autoStopDeadlines[definition.id],
            health: health(for: definition.id)?.checks.map {
                APIHealthCheck(kind: $0.kind.rawValue, title: $0.kind.title(for: definition.kind.provider), state: "\($0.state)", detail: $0.detail)
            }
        )
    }

    /// A share by id or (case-insensitive) name.
    func apiDefinition(_ reference: String) throws -> TunnelDefinition {
        if let id = UUID(uuidString: reference), let definition = definitions.first(where: { $0.id == id }) { return definition }
        if let definition = definitions.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) { return definition }
        throw OpenTrafficAPIError.notFound("No share named “\(reference)”.")
    }

    func apiStartShare(_ reference: String, client: String) async throws -> APIShare {
        let definition = try apiDefinition(reference)
        if !isActive(definition.id) {
            try await apiCheckTailscaleReady(definition)
            try confirmAPIPublishing("start “\(definition.name)”", client: client)
            startSharing(definition)
        }
        return try await apiWaitUntilLive(definition.id)
    }

    /// Answers once the share has stopped (Tailscale and OpenTunnel take a moment), so whatever the
    /// caller does next sees it stopped. Waits up to 10 seconds.
    func apiStopShare(_ reference: String) async throws -> APIShare {
        let definition = try apiDefinition(reference)
        stop(definition.id)
        for _ in 0..<50 where runtime(for: definition.id).state == .stopping {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return apiShare(definitions.first { $0.id == definition.id } ?? definition)
    }

    /// Waits up to 30 seconds for a public URL (or a failure).
    /// "Live" should mean the link works: waits (up to 15 s) for the public-site check to pass, or to find a
    /// real problem, so the command doesn't print a URL that answers with the provider's error page.
    func apiWaitUntilReachable(_ id: UUID) async {
        await refreshHealth(for: id)
        for _ in 0..<60 {
            let site = tunnelHealth[id]?.checks.first(where: { $0.kind == .publicSite })?.state
            if site == .ok || site == .failed || site == .skipped || runtime(for: id).state != .running { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func apiWaitUntilLive(_ id: UUID) async throws -> APIShare {
        for _ in 0..<120 {
            guard let definition = definitions.first(where: { $0.id == id }) else { throw OpenTrafficAPIError.notFound("The share was removed.") }
            if runtime(for: id).state == .failed {
                // A Quick Tunnel's failure may still be being explained (see explainQuickTunnelFailure).
                await failureDiagnoses[id]?.value
                throw OpenTrafficAPIError(status: 502, code: "start_failed", message: runtime(for: id).lastError ?? "The share failed to start.")
            }
            let runtime = runtime(for: id)
            if runtime.state == .running, publicURL(for: definition) != nil {
                await apiWaitUntilReachable(id)
                return apiShare(definition)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let definition = definitions.first(where: { $0.id == id }) else { throw OpenTrafficAPIError.notFound("The share was removed.") }
        return apiShare(definition)
    }

    /// Publishing asks first, like opentraffic:// links, unless apps are allowed to publish without asking.
    /// `offMac`: the address is another device on the network, which always asks.
    func confirmAPIPublishing(_ description: String, client: String, offMac: Bool = false) throws {
        // OpenTraffic's own command-line tool and MCP bridge are part of it: they don't ask.
        guard !APITrust.isTrusted else { return }
        guard !apiAllowsPublishingWithoutAsking || offMac else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow \(client) to \(description)?"
        alert.informativeText = offMac
            ? "An app on this Mac asked OpenTraffic to do this through its local API. This address is not on this Mac — it's another device on your network, which would become reachable from outside it."
            : "An app on this Mac asked OpenTraffic to do this through its local API. You can let apps publish without asking in Settings → Integrations."
        let allow = alert.addButton(withTitle: "Allow")
        let cancel = alert.addButton(withTitle: "Cancel")
        allow.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw OpenTrafficAPIError.denied("The user declined in OpenTraffic.")
        }
    }

    func apiComments(_ reference: String, status: APICommentStatus) throws -> [APIComment] {
        let definition = try apiDefinition(reference)
        loadComments(for: definition.id)
        return comments(for: definition.id)
            .filter { status == .all || (status == .open) != $0.resolved }
            .map { APIComment($0, shareID: definition.id) }
    }

    private func apiComment(_ definition: TunnelDefinition, _ commentID: String) throws -> CollabComment {
        guard let comment = comments(for: definition.id).first(where: { $0.id == commentID }) else {
            throw OpenTrafficAPIError.notFound("No comment \(commentID) on “\(definition.name)”.")
        }
        return comment
    }

    func apiScreenshot(_ reference: String, commentID: String) throws -> (data: Data, contentType: String) {
        let definition = try apiDefinition(reference)
        let comment = try apiComment(definition, commentID)
        guard let url = screenshotURL(for: comment, in: definition.id), let data = try? Data(contentsOf: url) else {
            throw OpenTrafficAPIError.notFound("This comment has no screenshot.")
        }
        let type = switch url.pathExtension {
        case "webp": "image/webp"
        case "png": "image/png"
        default: "image/jpeg"
        }
        return (data, type)
    }

    func apiResolve(_ reference: String, commentID: String, resolved: Bool) async throws -> APIComment {
        let definition = try apiDefinition(reference)
        _ = try apiComment(definition, commentID)
        await resolveComment(commentID, resolved: resolved, for: definition.id)
        return APIComment(try apiComment(definition, commentID), shareID: definition.id)
    }

    func apiReply(_ reference: String, commentID: String, text: String, client: String) async throws -> APIComment {
        let definition = try apiDefinition(reference)
        _ = try apiComment(definition, commentID)
        guard let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank, text.count <= CollabRoom.maximumCommentLength else {
            throw OpenTrafficAPIError.badRequest("text must be 1–\(CollabRoom.maximumCommentLength) characters.")
        }
        guard let updated = await replyToComment(commentID, text: text, for: definition.id, agent: client) else {
            throw OpenTrafficAPIError.conflict("The reply couldn't be added.")
        }
        return APIComment(updated, shareID: definition.id)
    }

    func apiErrors(_ reference: String) throws -> [CollabErrorGroup] {
        let definition = try apiDefinition(reference)
        return collabErrors[definition.id] ?? []
    }

    func apiLogs(_ reference: String, lines: Int) throws -> [String] {
        let definition = try apiDefinition(reference)
        let formatter = ISO8601DateFormatter()
        return logEntries(for: definition.id).suffix(max(1, min(lines, 2000))).map {
            "\(formatter.string(from: $0.timestamp)) [\($0.level)] \($0.rawLine ?? $0.message)"
        }
    }
}

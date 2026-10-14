import Foundation
import OpenTrafficCore

/// OpenTunnel shares are routes on one tunnel that OpenTunnel's own background service keeps
/// connected. OpenTraffic adds and removes routes in its own profile with the CLI, remembers exactly
/// which ones it added, and stops the service when none are left.
extension AppStore {
    var openTunnelPath: URL? {
        _ = toolsRevision
        return ExecutableLocator.resolve(.opentunnel)
    }

    /// Why OpenTunnel sharing can't be used right now, or nil when it's ready.
    var openTunnelBlocker: String? {
        openTunnelPath == nil ? "OpenTunnel isn't installed." : nil
    }

    func refreshOpenTunnel() async {
        let status = await Task.detached { OpenTunnelStatus.query() }.value
        if status != openTunnelStatus { openTunnelStatus = status }
        let hostname = OpenTunnel.hostname()
        if hostname != openTunnelHostname { openTunnelHostname = hostname }
        await retryLeftoverOpenTunnelRoutes()
    }

    /// The URL a stopped OpenTunnel share will have again: its route keeps the same name.
    func lastKnownOpenTunnelURL(for definition: TunnelDefinition) -> String? {
        guard definition.kind == .opentunnel, let route = definition.openTunnelRoute, let hostname = openTunnelHostname else { return nil }
        return OpenTunnel.url(route: route, hostname: hostname)
    }

    @discardableResult
    func addOpenTunnel(name: String, localURL: String, collaboration: Bool = false) throws -> TunnelDefinition {
        try validateLocalURL(localURL)
        guard OpenTunnel.target(for: localURL) != nil else {
            throw OpenTrafficError.api("OpenTunnel shares need an http:// local address.")
        }
        let definition = TunnelDefinition(
            name: name.nilIfBlank ?? "Local site",
            kind: .opentunnel,
            localURL: localURL,
            collaboration: collaboration,
            openTunnelRoute: OpenTunnel.routeName(for: name.nilIfBlank ?? "Local site", taken: takenOpenTunnelRoutes())
        )
        definitions.append(definition)
        runtimes[definition.id] = TunnelRuntime()
        logs[definition.id] = BoundedLogBuffer()
        selectedID = definition.id
        saveDefinitions()
        return definition
    }

    /// Route names in use: by saved shares, and in the profile's config (routes added by hand).
    private func takenOpenTunnelRoutes(except id: UUID? = nil) -> Set<String> {
        Set(definitions.filter { $0.id != id }.compactMap(\.openTunnelRoute))
            .union(OpenTunnel.configuredRoutes().keys)
    }

    // MARK: Start

    func startOpenTunnel(_ definition: TunnelDefinition, generation: UInt64, executable: URL) async {
        let cli = CommandLineTool(executable: executable, name: "OpenTunnel")
        let id = definition.id
        do {
            guard var target = OpenTunnel.target(for: definition.localURL) else {
                throw OpenTrafficError.api("OpenTunnel shares need an http:// local address.")
            }
            // Keep the share's route (and so its URL) unless another share has it, or someone added
            // a route with that name by hand.
            var route = definition.openTunnelRoute ?? ""
            let usedByOthers = Set(definitions.filter { $0.id != id }.compactMap(\.openTunnelRoute))
            let configured = OpenTunnel.configuredRoutes()
            let ours = Set(openTunnelRecords.filter { $0.tunnelID == id }.map(\.route))
            if !OpenTunnel.isValidRoute(route) || usedByOthers.contains(route) || (configured[route] != nil && !ours.contains(route)) {
                route = OpenTunnel.routeName(for: definition.name, taken: usedByOthers.union(configured.keys))
            }
            if let index = definitions.firstIndex(where: { $0.id == id }), definitions[index].openTunnelRoute != route {
                definitions[index].openTunnelRoute = route
                saveDefinitions()
            }
            // OpenTunnel passes the visitor's bytes straight to the local server, so live collaboration
            // and the Host header fix both need OpenTraffic's proxy in between.
            let collaboration = usesCollaboration(definition)
            if collaboration || definition.rewriteHostHeader {
                guard let proxyURL = try await startShareProxy(for: definition, generation: generation, collaboration: collaboration),
                      let proxyTarget = OpenTunnel.target(for: proxyURL) else { return }
                target = proxyTarget
            }
            guard isCurrent(id, generation) else { return stopCollaboration(id) }
            if OpenTunnel.hostname() == nil, var runtime = runtimes[id] {
                runtime.startupNote = "Creating OpenTraffic's OpenTunnel address. The first time takes a minute or two while its certificate is issued."
                runtimes[id] = runtime
            }
            let record = OpenTunnelRouteRecord(tunnelID: id, route: route, target: target)
            openTunnelRecords.removeAll { $0.tunnelID == id }
            openTunnelRecords.append(record)
            saveOpenTunnelRecords()
            let output = try await cli.run(["--profile", OpenTunnel.profile, "route", "add", route, target], timeout: 600)
            guard isCurrent(id, generation) else {
                // Stopped while the route was being added: undo just this one.
                await removeOpenTunnelRecord(record)
                return
            }
            let hostname = OpenTunnel.hostname()
            openTunnelHostname = hostname
            guard let url = OpenTunnel.publicURL(inOutput: String(decoding: output, as: UTF8.self))
                ?? hostname.map({ OpenTunnel.url(route: route, hostname: $0) }) else {
                throw OpenTrafficError.process("OpenTunnel added the route but didn't say its address.")
            }
            if var runtime = runtimes[id] {
                runtime.state = .running
                runtime.startupNote = nil
                runtimes[id] = runtime
            }
            receive(publicURL: url, for: id, generation: generation)
            await refreshOpenTunnel()
            await refreshHealth(for: id)
        } catch {
            stopCollaboration(id)
            if let record = openTunnelRecords.first(where: { $0.tunnelID == id }) { await removeOpenTunnelRecord(record) }
            setFailure(error.localizedDescription, for: id, generation: generation)
            await refreshHealth(for: id)
        }
    }

    // MARK: Stop and clean up

    func removeOpenTunnelRoute(for id: UUID) async {
        for record in openTunnelRecords where record.tunnelID == id {
            await removeOpenTunnelRecord(record)
        }
    }

    func removeAllOpenTunnelRoutes() async {
        for record in openTunnelRecords {
            await removeOpenTunnelRecord(record)
        }
    }

    /// Leftovers from a run that ended without cleaning up: at launch nothing is shared yet.
    func reconcileOpenTunnelRoutes() async {
        guard !openTunnelRecords.isEmpty, openTunnelPath != nil else { return }
        await removeAllOpenTunnelRoutes()
    }

    /// Routes whose removal failed earlier are kept on record and retried here.
    private func retryLeftoverOpenTunnelRoutes() async {
        let leftovers = openTunnelRecords.filter { record in
            [.stopped, .failed].contains(runtime(for: record.tunnelID).state) || !definitions.contains { $0.id == record.tunnelID }
        }
        for record in leftovers { await removeOpenTunnelRecord(record) }
    }

    /// Removes one route OpenTraffic added, only if it still points where OpenTraffic left it, then
    /// stops OpenTunnel's service for the profile when no routes are left.
    private func removeOpenTunnelRecord(_ record: OpenTunnelRouteRecord) async {
        guard openTunnelRemovalsInFlight.insert(record).inserted else { return }
        defer { openTunnelRemovalsInFlight.remove(record) }
        guard let executable = openTunnelPath else { return }
        let cli = CommandLineTool(executable: executable, name: "OpenTunnel")
        if OpenTunnel.configuredRoutes()[record.route] == record.target {
            do {
                try await cli.run(["--profile", OpenTunnel.profile, "route", "remove", record.route], timeout: 15)
            } catch {
                notice = AppNotice(.warning, "Couldn't remove the OpenTunnel route \(record.route) yet: \(error.localizedDescription). OpenTraffic will try again.")
                return
            }
        }
        openTunnelRecords.removeAll { $0 == record }
        saveOpenTunnelRecords()
        if OpenTunnel.configuredRoutes().isEmpty, openTunnelStatus != nil || OpenTunnelStatus.query() != nil {
            _ = try? await cli.run(["--profile", OpenTunnel.profile, "down"], timeout: 15)
            openTunnelStatus = nil
        }
    }

    private func saveOpenTunnelRecords() {
        do { try openTunnelRecordPersistence.save(openTunnelRecords) }
        catch { notice = AppNotice(.error, "Could not save OpenTunnel route records: \(error.localizedDescription)") }
    }

    // MARK: Health

    func openTunnelEdgeCheck(for definition: TunnelDefinition) -> TunnelHealthCheck {
        guard runtime(for: definition.id).state == .running else {
            return TunnelHealthCheck(kind: .edge, state: .skipped, detail: "Start the share to connect to OpenTunnel.")
        }
        guard let status = openTunnelStatus else {
            return TunnelHealthCheck(kind: .edge, state: .failed, detail: "OpenTunnel's service isn't running. Stop and start the share again.")
        }
        if let route = definition.openTunnelRoute, status.phase == .running, !status.routes.isEmpty, status.routes[route] == nil {
            return TunnelHealthCheck(kind: .edge, state: .failed, detail: "The route \(route) was removed outside OpenTraffic. Stop and start the share again.")
        }
        switch status.phase {
        case .running where status.isConnected:
            return TunnelHealthCheck(kind: .edge, state: .ok, detail: "Connected. Traffic is encrypted until it reaches this Mac.")
        case .provisioning:
            return TunnelHealthCheck(kind: .edge, state: .working, detail: "Waiting for OpenTunnel to issue the certificate…")
        case .stopped:
            return TunnelHealthCheck(kind: .edge, state: .failed, detail: status.lastError.map { "OpenTunnel stopped: \($0)" } ?? "OpenTunnel's tunnel stopped after an error.")
        default:
            let state = status.state?.replacingOccurrences(of: "-", with: " ") ?? "connecting"
            return TunnelHealthCheck(kind: .edge, state: .working, detail: "OpenTunnel is \(state)…" + (status.lastError.map { " Last error: \($0)" } ?? ""))
        }
    }

    func openTunnelRunningDetail(for definition: TunnelDefinition) -> String {
        let proxy = collabProxies[definition.id] != nil && !isCollaborating(definition.id) ? " through OpenTraffic's proxy (Host header fix)" : ""
        let connections = openTunnelStatus?.connections ?? 0
        return "Route \(definition.openTunnelRoute ?? "?")\(proxy). \(connections == 1 ? "1 open connection" : "\(connections) open connections") on the tunnel."
    }
}

import Foundation
import OpenTrafficCore

/// Tailscale shares live in the Tailscale daemon rather than in a child process, so OpenTraffic
/// applies them with the CLI, remembers exactly what it applied, and removes only that.
extension AppStore {
    var tailscalePath: URL? {
        ExecutableLocator.resolve(.tailscale, customPath: customTailscalePath)
    }

    func executablePath(for provider: TunnelProvider) -> URL? {
        switch provider {
        case .cloudflare: cloudflaredPath
        case .tailscale: tailscalePath
        case .ngrok: ExecutableLocator.resolve(.ngrok)
        case .opentunnel: openTunnelPath
        }
    }

    func missingExecutableMessage(for provider: TunnelProvider) -> String {
        switch provider {
        case .cloudflare: OpenTrafficError.cloudflaredMissing.localizedDescription
        case .tailscale: "Tailscale isn't installed. Install the Tailscale app from tailscale.com/download, or choose its CLI in Settings."
        case .ngrok: "ngrok isn't installed. Install it with Homebrew (`brew install ngrok`)."
        case .opentunnel: "OpenTunnel isn't installed. Install it with Homebrew (`\(OpenTunnel.installCommand)`) or from opentunnel.xyz."
        }
    }

    /// Shares on this Mac that OpenTraffic didn't create, for display only.
    var otherTailscaleShares: [TailscaleServeConfig.Entry] {
        let ours = Set(tailscaleRecords.map(\.port))
        return (tailscaleServeConfig?.entries ?? []).filter { !ours.contains($0.port) }
    }

    func refreshTailscale() async {
        guard let executable = tailscalePath else {
            tailscaleStatus = nil
            tailscaleServeConfig = nil
            return
        }
        let cli = TailscaleCLI(executable: executable)
        let status = await cli.status()
        if status != tailscaleStatus { tailscaleStatus = status }
        let config = status?.isRunning == true ? await cli.serveConfig() : nil
        if config != tailscaleServeConfig { tailscaleServeConfig = config }
        await retryLeftoverTailscaleShares()
    }

    /// Shares whose removal failed earlier (Tailscale was down, the CLI timed out) are kept on record
    /// and retried here, so a public Funnel share isn't left behind for good.
    private func retryLeftoverTailscaleShares() async {
        guard tailscaleServeConfig != nil else { return }
        let leftovers = tailscaleRecords.filter { record in
            [.stopped, .failed].contains(runtime(for: record.tunnelID).state) || !definitions.contains { $0.id == record.tunnelID }
        }
        for record in leftovers { await removeTailscaleRecord(record) }
    }

    /// The URL a stopped Tailscale share will have again, so it can be shown and copied ahead of time.
    func lastKnownTailscaleURL(for definition: TunnelDefinition) -> String? {
        guard definition.kind == .tailscale,
              let port = definition.tailscalePort,
              let dnsName = tailscaleStatus?.dnsName else { return nil }
        return TailscaleShare.url(dnsName: dnsName, port: port)
    }

    // MARK: Start

    func startTailscale(_ definition: TunnelDefinition, generation: UInt64, executable: URL) async {
        let cli = TailscaleCLI(executable: executable)
        var relay: LoopbackForwarder?
        do {
            await refreshTailscale()
            guard let status = tailscaleStatus, status.isRunning, let dnsName = status.dnsName else {
                throw OpenTrafficError.api("Tailscale isn't connected. Open Tailscale and sign in, then start again.")
            }
            guard status.httpsEnabled else {
                throw OpenTrafficError.api("HTTPS certificates are off for your tailnet. Turn on HTTPS on the DNS page of the Tailscale admin console, then start again.")
            }
            if definition.tailscalePublic, !status.funnelEnabled {
                throw OpenTrafficError.api("Funnel isn't enabled for this Mac. Allow Funnel in your tailnet's access controls, or share privately instead.")
            }
            let inUse = (tailscaleServeConfig?.portsInUse ?? [])
                .union(tailscaleRecords.map(\.port))
                .union(tailscaleReservedPorts.filter { $0.key != definition.id }.values)
            guard let port = TailscaleShare.choosePort(
                isPublic: definition.tailscalePublic,
                preferred: definition.tailscalePort,
                inUse: inUse
            ) else {
                throw OpenTrafficError.api(definition.tailscalePublic
                    ? "All three Funnel ports (443, 8443, 10000) are already in use on this Mac."
                    : "No free HTTPS port is left for another Tailscale share.")
            }
            tailscaleReservedPorts[definition.id] = port
            defer { if tailscaleReservedPorts[definition.id] == port { tailscaleReservedPorts[definition.id] = nil } }
            // The relay and record stay local to this generation until it's confirmed current, so a
            // stale start never tears down what a newer start set up.
            let (target, forwarder) = try await prepareTailscaleTarget(for: definition)
            relay = forwarder
            guard isCurrent(definition.id, generation) else {
                forwarder?.stop()
                return
            }
            try await cli.run(TailscaleShare.shareArguments(port: port, target: target, isPublic: definition.tailscalePublic))
            let record = TailscaleShareRecord(tunnelID: definition.id, port: port, isPublic: definition.tailscalePublic, target: target)
            tailscaleRecords.append(record)
            saveTailscaleRecords()
            guard isCurrent(definition.id, generation) else {
                // Stopped while the share was being applied: undo just this one right away.
                forwarder?.stop()
                await removeTailscaleRecord(record)
                return
            }
            if let forwarder {
                tailscaleForwarders.removeValue(forKey: definition.id)?.stop()
                tailscaleForwarders[definition.id] = forwarder
            }
            if let index = definitions.firstIndex(where: { $0.id == definition.id }), definitions[index].tailscalePort != port {
                definitions[index].tailscalePort = port
                saveDefinitions()
            }
            if var runtime = runtimes[definition.id] {
                runtime.state = .running
                runtimes[definition.id] = runtime
            }
            receive(publicURL: TailscaleShare.url(dnsName: dnsName, port: port), for: definition.id, generation: generation)
            await refreshTailscale()
            await refreshHealth(for: definition.id)
        } catch {
            relay?.stop()
            setFailure(error.localizedDescription, for: definition.id, generation: generation)
            await refreshHealth(for: definition.id)
        }
    }

    /// Tailscale proxies only to 127.0.0.1. Servers there are used directly; IPv6-only servers and
    /// other machines get OpenTraffic's loopback relay in between.
    private func prepareTailscaleTarget(for definition: TunnelDefinition) async throws -> (target: String, relay: LoopbackForwarder?) {
        guard let url = URL(string: definition.localURL), let host = url.host else {
            throw OpenTrafficError.invalidLocalURL
        }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let path = url.path.isEmpty || url.path == "/" ? "" : url.path
        let relayHost: String
        if TailscaleShare.needsForwarder(host: host) {
            relayHost = host
        } else if await LoopbackForwarder.canConnect(host: "127.0.0.1", port: UInt16(port)) {
            return (TailscaleShare.target(scheme: url.scheme, port: port) + path, nil)
        } else if host.lowercased() == "localhost" {
            // Common for Vite/Node: listening on ::1 only. "localhost" lets the relay try both families.
            relayHost = "localhost"
        } else {
            // 127.0.0.1 itself isn't answering yet; share it directly and let health checks report it.
            return (TailscaleShare.target(scheme: url.scheme, port: port) + path, nil)
        }
        let forwarder = LoopbackForwarder(targetHost: relayHost, targetPort: UInt16(port))
        let relayPort = try await forwarder.start()
        return (TailscaleShare.target(scheme: url.scheme, port: Int(relayPort)) + path, forwarder)
    }

    func isCurrent(_ id: UUID, _ generation: UInt64) -> Bool {
        runtimes[id]?.generation == generation && definitions.contains { $0.id == id }
    }

    // MARK: Stop and clean up

    func removeTailscaleShare(for id: UUID) async {
        tailscaleForwarders.removeValue(forKey: id)?.stop()
        for record in tailscaleRecords where record.tunnelID == id {
            await removeTailscaleRecord(record)
        }
    }

    func removeAllTailscaleShares() async {
        for forwarder in tailscaleForwarders.values { forwarder.stop() }
        tailscaleForwarders.removeAll()
        for record in tailscaleRecords {
            await removeTailscaleRecord(record)
        }
    }

    /// Leftovers from a run that ended without cleaning up. At launch nothing is running, so every
    /// recorded share that still points where OpenTraffic left it is removed.
    func reconcileTailscaleShares() async {
        guard !tailscaleRecords.isEmpty, tailscalePath != nil else { return }
        await removeAllTailscaleShares()
    }

    /// Removes one share OpenTraffic applied. The record is dropped only once the share is gone (or
    /// someone else has since taken the port); otherwise it's kept and retried on the next refresh.
    private func removeTailscaleRecord(_ record: TailscaleShareRecord) async {
        guard tailscaleRemovalsInFlight.insert(record).inserted else { return }
        defer { tailscaleRemovalsInFlight.remove(record) }
        guard let executable = tailscalePath else { return }
        let cli = TailscaleCLI(executable: executable)
        guard let config = await cli.serveConfig() else { return }
        // Never remove a port someone else has since pointed elsewhere.
        if record.stillOwned(in: config) {
            do {
                try await cli.run(TailscaleShare.stopArguments(port: record.port, isPublic: record.isPublic), timeout: 8)
            } catch {
                notice = AppNotice(.warning, "Couldn't remove the Tailscale share on port \(record.port) yet: \(error.localizedDescription). OpenTraffic will try again.")
                return
            }
        }
        tailscaleRecords.removeAll { $0 == record }
        saveTailscaleRecords()
    }

    private func saveTailscaleRecords() {
        do { try tailscaleRecordPersistence.save(tailscaleRecords) }
        catch { notice = AppNotice(.error, "Could not save Tailscale share records: \(error.localizedDescription)") }
    }

    // MARK: Health

    func tailscaleEdgeCheck(for definition: TunnelDefinition) -> TunnelHealthCheck {
        guard let status = tailscaleStatus else {
            return TunnelHealthCheck(kind: .edge, state: .skipped, detail: "Tailscale status unavailable.")
        }
        guard status.isRunning else {
            return TunnelHealthCheck(kind: .edge, state: .failed, detail: "Tailscale is disconnected. Open Tailscale to reconnect.")
        }
        if definition.tailscalePublic, !status.funnelEnabled {
            return TunnelHealthCheck(kind: .edge, state: .failed, detail: "Funnel isn't enabled for this Mac, so the public share can't be reached.")
        }
        if let record = tailscaleRecords.first(where: { $0.tunnelID == definition.id }),
           let config = tailscaleServeConfig, !record.stillOwned(in: config) {
            return TunnelHealthCheck(kind: .edge, state: .failed, detail: "The share on port \(record.port) was changed or removed outside OpenTraffic. Stop and start it again.")
        }
        return TunnelHealthCheck(
            kind: .edge,
            state: .ok,
            detail: definition.tailscalePublic
                ? "Connected. Public on the internet through Funnel."
                : "Connected. Only devices on your tailnet can open it."
        )
    }

    func runningConnectorDetail(for definition: TunnelDefinition) -> String {
        if definition.kind == .opentunnel { return openTunnelRunningDetail(for: definition) }
        guard definition.kind == .tailscale else { return "Connector running" }
        let port = tailscaleRecords.first(where: { $0.tunnelID == definition.id })?.port
        let relay = tailscaleForwarders[definition.id] != nil ? " through OpenTraffic's local relay" : ""
        return port.map { "Shared on HTTPS port \($0)\(relay)." } ?? "Shared\(relay)."
    }
}

import Darwin
import Foundation
import OpenTrafficCore

enum NgrokSupport {
    /// "https://me.ngrok.app/" → "me.ngrok.app"
    static func host(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")?.host ?? trimmed
        return host.lowercased()
    }

    /// A loopback port nobody is listening on right now, for an agent's private inspection API.
    static func freeLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw OpenTrafficError.process("Couldn't reserve a local port for ngrok.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw OpenTrafficError.process("Couldn't reserve a local port for ngrok.") }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw OpenTrafficError.process("Couldn't reserve a local port for ngrok.") }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Ports ngrok picks for its inspection API when the default is busy.
    static let conventionalAPIPorts: [UInt16] = Array(4040...4049)

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }()
}

extension AppStore {
    var ngrokPath: URL? {
        ExecutableLocator.resolve(.ngrok)
    }

    var ngrokAuthtokenConfigured: Bool {
        guard let text = try? String(contentsOf: NgrokAgent.defaultConfigURL, encoding: .utf8) else { return false }
        return NgrokAgent.hasAuthtoken(configText: text)
    }

    /// Why ngrok sharing can't be used right now, or nil when it's ready.
    var ngrokBlocker: String? {
        guard ngrokPath != nil else { return "ngrok isn't installed." }
        guard ngrokAuthtokenConfigured else { return "ngrok has no authtoken yet." }
        return nil
    }

    // MARK: Start

    func startNgrok(_ definition: TunnelDefinition, generation: UInt64, executable: URL) {
        // Every agent on a free account serves the same domain, so a second one is rejected by ngrok.
        // A share without an explicit domain uses the account's default, which may be any running one's.
        if let other = definitions.first(where: {
            $0.id != definition.id && $0.kind == .ngrok && isActive($0.id)
                && (definition.hostname == nil || $0.hostname == definition.hostname)
        }) {
            setFailure("“\(other.name)” is already sharing with this ngrok domain. The free plan serves one ngrok share at a time — stop it first.", for: definition.id, generation: generation)
            return
        }
        if let domain = definition.hostname,
           externalNgrokTunnels.contains(where: { URL(string: $0.publicURL)?.host?.lowercased() == domain }) {
            setFailure("ngrok is already serving \(domain) outside OpenTraffic (for example, in Terminal). Stop it there first.", for: definition.id, generation: generation)
            return
        }
        do {
            let apiPort = try NgrokSupport.freeLoopbackPort()
            let userConfig = FileManager.default.fileExists(atPath: NgrokAgent.defaultConfigURL.path) ? NgrokAgent.defaultConfigURL : nil
            try processSupervisor.startNgrok(
                id: definition.id,
                generation: generation,
                executable: executable,
                localURL: definition.localURL,
                domain: definition.hostname,
                apiPort: apiPort,
                userConfig: userConfig,
                trafficPolicy: NgrokTrafficPolicy.yaml(
                    hostHeader: definition.rewriteHostHeader ? definition.originHostHeader : nil,
                    basicAuthCredentials: try ngrokCredentials(for: definition),
                    oauth: ngrokOAuth(for: definition)
                )
            )
            if var runtime = runtimes[definition.id], runtime.generation == generation {
                runtime.metricsPort = apiPort
                runtimes[definition.id] = runtime
            }
            ngrokRequests[definition.id] = []
        } catch {
            setFailure(error.localizedDescription, for: definition.id, generation: generation)
        }
    }

    /// ngrok reports the domain at runtime; remember it so it can be shown (and requested) while stopped.
    func rememberNgrokDomain(_ publicURL: String, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }),
              definitions[index].kind == .ngrok,
              let host = URL(string: publicURL)?.host?.lowercased(),
              definitions[index].hostname != host else { return }
        definitions[index].hostname = host
        saveDefinitions()
    }

    func terminationMessage(for id: UUID, status: Int32) -> String {
        guard let definition = definitions.first(where: { $0.id == id }) else {
            return "The connector exited with status \(status)."
        }
        switch definition.kind.provider {
        case .ngrok:
            let recent = logEntries(for: id).suffix(40)
            let errors = recent.filter { LogConsole.rank($0.level) >= 2 || ($0.rawLine ?? $0.message).contains("ERR_NGROK") }
            let text = errors.map { $0.rawLine ?? $0.message }.joined(separator: "\n")
            return text.isEmpty ? "ngrok exited with status \(status)." : NgrokAgent.explain(text)
        case .cloudflare, .tailscale, .opentunnel:
            return "\(definition.kind.provider.executableName) exited with status \(status)."
        }
    }

    func noEdgeStatusDetail(for kind: TunnelKind) -> String {
        switch kind {
        case .ngrok: "ngrok has no separate edge status; it's up while the agent is connected."
        default: "Quick Tunnels have no Cloudflare tunnel status."
        }
    }

    // MARK: Polling

    /// Traffic and captured requests from each running agent's private API, plus agents started elsewhere.
    func refreshNgrokAgents() async {
        guard DemoCapture.demoPorts == nil else { return }
        var ownPorts = Set<UInt16>()
        for definition in definitions where definition.kind == .ngrok {
            let runtime = runtime(for: definition.id)
            guard runtime.state == .running || runtime.state == .starting, let port = runtime.metricsPort else { continue }
            ownPorts.insert(port)
            let tunnels = await Self.fetch("http://127.0.0.1:\(port)/api/tunnels").map(NgrokTunnelInfo.parse) ?? []
            let requests = await Self.fetch("http://127.0.0.1:\(port)/api/requests/http?limit=100").map(NgrokRequest.parse)
            guard var current = runtimes[definition.id], current.generation == runtime.generation else { continue }
            if let requests, ngrokRequests[definition.id] != requests { ngrokRequests[definition.id] = requests }
            if let tunnel = tunnels.first {
                var byCode: [String: Int64] = [:]
                for request in ngrokRequests[definition.id] ?? [] {
                    if let code = request.statusCode { byCode[String(code), default: 0] += 1 }
                }
                let statistics = TunnelStatistics(
                    totalRequests: tunnel.totalRequests,
                    requestErrors: byCode.filter { $0.key.hasPrefix("5") }.values.reduce(0, +),
                    responseByCode: byCode,
                    processStartedAt: current.startedAt
                )
                current.statistics = statistics
                if runtimes[definition.id] != current { runtimes[definition.id] = current }
                recordRequests(statistics, for: definition.id)
            }
        }
        var external: [NgrokTunnelInfo] = []
        for port in NgrokSupport.conventionalAPIPorts where !ownPorts.contains(port) {
            if let data = await Self.fetch("http://127.0.0.1:\(port)/api/tunnels") {
                external += NgrokTunnelInfo.parse(data)
            }
        }
        if external != externalNgrokTunnels { externalNgrokTunnels = external }
    }

    func replayNgrokRequest(_ request: NgrokRequest, for id: UUID) async throws {
        guard let port = runtime(for: id).metricsPort,
              let url = URL(string: "http://127.0.0.1:\(port)/api/requests/http") else {
            throw OpenTrafficError.process("Start the tunnel to replay requests.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["id": request.id])
        let (_, response) = try await NgrokSupport.session.data(for: urlRequest)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw OpenTrafficError.process("ngrok didn't accept the replay.")
        }
        await refreshNgrokAgents()
    }

    private static func fetch(_ address: String) async -> Data? {
        guard let url = URL(string: address),
              let (data, response) = try? await NgrokSupport.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

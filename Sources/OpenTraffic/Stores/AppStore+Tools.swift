import AppKit
import OpenTrafficCore

/// Where installing a tool is up to, for the install rows.
enum ToolInstallState: Equatable {
    case idle
    case preparing
    case downloading(received: Int64, total: Int64?)
    case verifying
    case installing
    case installed(version: String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .downloading, .verifying, .installing: true
        default: false
        }
    }
}

/// Installing cloudflared, OpenTunnel, and ngrok from their makers' official releases, in one click
/// (see `ToolInstaller`), and getting the ngrok account and the Tailscale app connected.
extension AppStore {
    static let tailscaleAppStore = URL(string: "macappstore://apps.apple.com/app/id1475387142")!

    func toolState(_ provider: TunnelProvider) -> ToolInstallState {
        toolInstallStates[provider] ?? .idle
    }

    func toolPath(_ provider: TunnelProvider) -> URL? {
        switch provider {
        case .cloudflare: cloudflaredPath
        case .ngrok: ngrokPath
        case .opentunnel: openTunnelPath
        case .tailscale: tailscalePath
        }
    }

    /// Looks up the newest release once, so a row can say what it would download before anyone clicks.
    func loadToolRelease(_ provider: TunnelProvider) async {
        guard ManagedTools.canInstall(provider), toolReleases[provider] == nil else { return }
        if let release = try? await ToolCatalog.latestRelease(for: provider) {
            toolReleases[provider] = release
        }
    }

    /// Downloads, checks, and installs `provider`'s tool. Safe to call while it's already installing.
    @discardableResult
    func installTool(_ provider: TunnelProvider) async -> Bool {
        guard ManagedTools.canInstall(provider), !toolState(provider).isBusy else { return false }
        toolInstallStates[provider] = .preparing
        do {
            let release: ToolRelease
            if let known = toolReleases[provider] {
                release = known
            } else {
                release = try await ToolCatalog.latestRelease(for: provider)
                toolReleases[provider] = release
            }
            let installed = try await ToolInstaller.install(release) { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.toolState(provider).isBusy else { return }
                    self.toolInstallStates[provider] = switch phase {
                    case let .downloading(received, total): .downloading(received: received, total: total)
                    case .verifying: .verifying
                    case .installing: .installing
                    }
                }
            }
            toolInstallStates[provider] = .installed(version: installed.version)
            toolsRevision += 1
            if provider == .opentunnel { await refreshOpenTunnel() }
            return true
        } catch {
            toolInstallStates[provider] = .failed(error.localizedDescription)
            return false
        }
    }

    /// Installs several at once (the setup assistant's "install both").
    func installTools(_ providers: [TunnelProvider]) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers where toolPath(provider) == nil {
                group.addTask { await self.installTool(provider) }
            }
        }
    }

    /// Saves an ngrok authtoken the way ngrok itself does (`ngrok config add-authtoken`).
    func connectNgrok(authtoken: String) async throws {
        let token = authtoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw OpenTrafficError.api("That doesn't look like an ngrok authtoken. Copy it from the ngrok dashboard.")
        }
        guard let ngrok = ngrokPath else { throw OpenTrafficError.api("Install ngrok first.") }
        try await Task.detached {
            let process = Process()
            process.executableURL = ngrok
            process.arguments = ["config", "add-authtoken", token]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw OpenTrafficError.api(output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "ngrok couldn't save the authtoken.")
            }
        }.value
        toolsRevision += 1
    }

    func openTailscaleInAppStore() {
        NSWorkspace.shared.open(Self.tailscaleAppStore)
    }

    // MARK: API

    func apiTool(_ provider: TunnelProvider) -> APITool {
        let path = toolPath(provider)
        let managed = path?.path == ManagedTools.path(for: provider).path
        return APITool(
            name: provider.executableName,
            provider: provider.rawValue,
            installed: path != nil,
            path: path?.path,
            version: managed ? ManagedTools.installedVersion(of: provider) : nil,
            installable: ManagedTools.canInstall(provider)
        )
    }

    func apiTools() -> [APITool] {
        TunnelProvider.allCases.map(apiTool)
    }

    /// Installing doesn't publish anything, so unlike sharing it doesn't ask first.
    func apiInstallTool(_ name: String) async throws -> APITool {
        guard let provider = TunnelProvider.allCases.first(where: { [$0.executableName, $0.rawValue].contains(name.lowercased()) }) else {
            throw OpenTrafficAPIError.notFound("No tool named “\(name)”. Use cloudflared, opentunnel, or ngrok.")
        }
        guard ManagedTools.canInstall(provider) else {
            throw OpenTrafficAPIError(status: 409, code: "not_installable", message: "Tailscale is a Mac app: install it from the App Store (search for Tailscale), then sign in.")
        }
        if toolPath(provider) == nil {
            await installTool(provider)
            if case let .failed(message) = toolState(provider) {
                throw OpenTrafficAPIError(status: 502, code: "install_failed", message: message)
            }
        }
        return apiTool(provider)
    }
}

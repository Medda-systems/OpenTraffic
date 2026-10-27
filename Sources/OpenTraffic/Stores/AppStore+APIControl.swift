import Foundation
import OpenTrafficCore

/// The local API's answers for what the app's windows can do (create any kind of share, edit, protect,
/// restart, remove, projects, local services), so the command-line tool can do all of it too.
/// Publishing asks first, as everywhere else in the API; see `confirmAPIPublishing`.
extension AppStore {
    // MARK: Status

    func apiAppStatus() async -> APIAppStatus {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let cloudflaredMissing = cloudflaredPath == nil ? missingExecutableMessage(for: .cloudflare) : nil
        func provider(_ name: String, _ blocker: String?, warning: String? = nil) -> APIProviderStatus {
            APIProviderStatus(name: name, ready: blocker == nil, detail: blocker, warning: blocker == nil ? warning : nil)
        }
        // Some networks' DNS filters keep Quick Tunnels from getting an address (cached; a few seconds at most).
        let quickWarning = cloudflaredMissing == nil ? await checkQuickTunnelNetwork().value.warning : nil
        return APIAppStatus(
            version: version,
            shares: definitions.count,
            running: definitions.filter { isActive($0.id) }.count,
            providers: [
                provider("quick", cloudflaredMissing, warning: quickWarning),
                provider("opentunnel", hintedBlocker(.opentunnel)),
                provider("tailscale", hintedBlocker(.tailscale)),
                provider("ngrok", hintedBlocker(.ngrok)),
                provider("domain", cloudflaredMissing ?? (hasSavedAPIToken ? nil : "No Cloudflare account is connected. Add an API token in Settings → Cloudflare.")),
            ],
            publishesWithoutAsking: apiAllowsPublishingWithoutAsking
        )
    }

    // MARK: Creating

    /// `port` or `url` (a port given as text counts too) as the local service's address.
    func apiLocalURL(port: Int?, url: String?) throws -> String {
        if let port {
            guard (1...65_535).contains(port) else { throw OpenTrafficAPIError.badRequest("port must be 1–65535.") }
            return "http://localhost:\(port)"
        }
        guard let url = url?.nilIfBlank else { throw OpenTrafficAPIError.badRequest("Give a port or a url.") }
        if let port = Int(url) { return try apiLocalURL(port: port, url: nil) }
        let address = url.contains("://") ? url : "http://\(url)"
        guard let components = URLComponents(string: address), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil else {
            throw OpenTrafficAPIError.badRequest("url must be a port, host:port, or an http(s) address.")
        }
        return address
    }

    func apiCreateShare(_ request: APIShareRequest, client: String) async throws -> APIShare {
        // A Mac app you're building, by its path or name: `opentraffic share Orbit`.
        if let reference = request.macApp {
            return try await apiShareMacApp(APIMacAppReference(reference), request: request, client: client)
        }
        // An app by its path: `opentraffic share ~/code/orbit/dist/Orbit.app`. A finished Electron app
        // of yours, or else a Mac app.
        if let path = request.url, path.hasPrefix("/"), path.hasSuffix(".app") || path.hasSuffix(".app/") {
            let electron = URL(fileURLWithPath: path).appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            guard FileManager.default.fileExists(atPath: electron.path) else {
                return try await apiShareMacApp(.path(path), request: request, client: client)
            }
            return try await apiShareElectronApp(atPath: path, request: request, client: client)
        }
        let localURL = try apiLocalURL(port: request.port, url: request.url)
        let start = request.start ?? true
        if let name = request.name?.nilIfBlank, let other = definitions.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           other.localURL != localURL || request.provider.map({ Self.apiKind($0) != other.kind }) == true {
            throw OpenTrafficAPIError.conflict("A share named “\(other.name)” already exists. Pick another name, or remove it first.")
        }
        let provider = request.provider?.lowercased() ?? "quick"
        if provider == "domain" {
            return try await apiCreateDomainShare(request, localURL: localURL, start: start, client: client)
        }
        guard let kind = Self.apiKind(provider) else {
            throw OpenTrafficAPIError.badRequest("provider must be quick, opentunnel, tailscale, ngrok, or domain.")
        }
        if request.collaboration == true, !kind.supportsCollaboration {
            throw OpenTrafficAPIError.badRequest("\(kind.provider.title) shares don't support live collaboration.")
        }
        if request.branch == true, request.collaboration != true {
            throw OpenTrafficAPIError.badRequest("Working on a branch needs live collaboration (collaboration: true).")
        }
        if request.funnel == true, kind != .tailscale {
            throw OpenTrafficAPIError.badRequest("Funnel is for Tailscale shares.")
        }
        let domain = request.hostname?.nilIfBlank?.lowercased()
        if domain != nil, kind != .ngrok {
            throw OpenTrafficAPIError.badRequest("A hostname is for ngrok domains and custom-domain shares (provider \"domain\").")
        }
        let collaboration = request.collaboration ?? false
        let funnel = request.funnel ?? false
        let target = AutomationCommand.target(of: localURL)
        let existing = definitions.first(where: {
            $0.kind == kind && $0.localURL == localURL && (kind != .tailscale || $0.tailscalePublic == funnel)
                && (domain == nil || $0.hostname?.lowercased() == domain)
        })
        // Like the New Tunnel sheet: a way of sharing that isn't set up is refused before asking,
        // and nothing is created for it.
        if existing == nil || start, let blocker = await apiBlocker(for: kind, funnel: funnel) {
            throw OpenTrafficAPIError(status: 409, code: "not_ready", message: blocker)
        }
        if request.branch == true {
            let name = request.name?.nilIfBlank ?? existing?.name ?? target?.display ?? localURL
            try await apiRequireBranchReady(existing ?? TunnelDefinition(name: name, kind: kind, localURL: localURL))
        }
        if start {
            let audience = kind == .tailscale && !funnel ? "on your tailnet" : "publicly"
            try confirmAPIPublishing(
                "share \(target?.display ?? localURL) \(audience) with \(kind.provider.title)\(collaboration ? " and live collaboration" : "")",
                client: client,
                offMac: target?.isLoopback != true
            )
        }
        var definition: TunnelDefinition
        if let existing {
            if collaboration, !existing.collaboration {
                if isActive(existing.id) {
                    await setCollaboration(true, for: existing.id)
                } else if let index = definitions.firstIndex(where: { $0.id == existing.id }) {
                    definitions[index].collaboration = true
                    saveDefinitions()
                }
            }
            definition = definitions.first { $0.id == existing.id } ?? existing
        } else {
            let title = request.name?.nilIfBlank ?? TunnelRowPresentation.localEndpoint(localURL).map { "localhost\($0)" } ?? "Local site"
            do {
                definition = switch kind {
                case .tailscale: try addTailscale(name: title, localURL: localURL, isPublic: funnel)
                case .ngrok: try addNgrok(name: title, localURL: localURL, domain: domain)
                case .opentunnel: try addOpenTunnel(name: title, localURL: localURL, collaboration: collaboration)
                default: try addQuick(name: title, localURL: localURL, collaboration: collaboration)
                }
            } catch {
                throw OpenTrafficAPIError.badRequest(error.localizedDescription)
            }
        }
        if request.branch == true, let index = definitions.firstIndex(where: { $0.id == definition.id }), !definitions[index].workOnBranch {
            if isCollaborating(definition.id) {
                await setWorkOnBranch(true, for: definition.id)
            } else {
                definitions[index].workOnBranch = true
                saveDefinitions()
            }
            definition = definitions[index]
        }
        // An Electron app's dev server: share the app itself (its main process runs sandboxed here).
        if kind.supportsCollaboration, let app = await electronApp(serving: localURL),
           let index = definitions.firstIndex(where: { $0.id == definition.id }), definitions[index].electronApp == nil {
            definitions[index].electronApp = app.id
            definitions[index].electronData = definitions[index].electronData ?? .copy
            definitions[index].collaboration = true
            definitions[index].agentDirectory = definitions[index].agentDirectory ?? app.appDirectory.path
            saveDefinitions()
            definition = definitions[index]
        }
        guard start else { return apiShare(definition) }
        if !isActive(definition.id) { startSharing(definition) }
        return try await apiWaitUntilLive(definition.id)
    }

    private func apiShareElectronApp(atPath path: String, request: APIShareRequest, client: String) async throws -> APIShare {
        let bundle = URL(fileURLWithPath: path).standardizedFileURL
        await scanElectronApps()
        guard let app = detectedElectronApps.first(where: { $0.bundle.map { ElectronDiscovery.realURL($0).path } == ElectronDiscovery.realURL(bundle).path }) else {
            throw OpenTrafficAPIError.notFound("\(bundle.lastPathComponent) isn't a running Electron app of yours. Open it first; apps you only installed can't be shared.")
        }
        let kind: TunnelKind
        switch request.provider?.lowercased() {
        case nil, "quick", "cloudflare", "temporary": kind = .quick
        case "opentunnel": kind = .opentunnel
        default: throw OpenTrafficAPIError.badRequest("Electron apps are shared with quick or opentunnel.")
        }
        // Like a Mac app: `name` names a new share; one this app had keeps its own.
        let name = request.name?.nilIfBlank
        if let name, let other = definitions.share(named: name, except: { $0.electronApp == app.id && $0.kind == kind }) {
            throw OpenTrafficAPIError.conflict("A share named “\(other.name)” already exists. Pick another name, or remove it first.")
        }
        if let blocker = await apiBlocker(for: kind, funnel: false) {
            throw OpenTrafficAPIError(status: 409, code: "not_ready", message: blocker)
        }
        try confirmAPIPublishing("share \(app.name) publicly with \(kind.provider.title) and live collaboration", client: client)
        share(app, kind: kind, name: name)
        guard let definition = definitions.first(where: { $0.electronApp == app.id && $0.kind == kind }) else {
            throw OpenTrafficAPIError.badRequest("Couldn't share \(app.name).")
        }
        return try await apiWaitUntilLive(definition.id)
    }

    // MARK: Mac apps

    /// Shares a Mac app you're building, like its Share menu: an isolated copy, mirrored to viewers,
    /// with live collaboration. Sharing an app that's already shared this way answers with that share.
    private func apiShareMacApp(_ reference: APIMacAppReference, request: APIShareRequest, client: String) async throws -> APIShare {
        let kind: TunnelKind
        switch request.provider?.lowercased() {
        case nil, "quick", "cloudflare", "temporary": kind = .quick
        case "opentunnel": kind = .opentunnel
        default: throw OpenTrafficAPIError.badRequest("Mac apps are shared with quick or opentunnel.")
        }
        let data: MacAppSession.DataSource
        switch request.macAppData?.lowercased() {
        case nil, "copy": data = .copy
        case "empty": data = .empty
        default: throw OpenTrafficAPIError.badRequest("macAppData must be copy or empty.")
        }
        if request.start == false {
            throw OpenTrafficAPIError.badRequest("A Mac app share starts right away: it can't be saved without starting.")
        }
        let app = try await apiMacApp(reference)
        let shares = definitions.filter { $0.macApp == app.id && (isActive($0.id) || runtime(for: $0.id).state == .stopping) }
        if let running = shares.first(where: { $0.kind == kind && isActive($0.id) }) {
            return try await apiWaitUntilLive(running.id)
        }
        if let other = shares.first {
            throw OpenTrafficAPIError.conflict("\(app.name) is already shared by “\(other.name)”. Stop that share first.")
        }
        try apiCheckMacAppSupport()
        let name = request.name?.nilIfBlank
        if let name, let other = definitions.share(named: name, except: { $0.macApp == app.id && $0.kind == kind }) {
            throw OpenTrafficAPIError.conflict("A share named “\(other.name)” already exists. Pick another name, or remove it first.")
        }
        if let blocker = await apiBlocker(for: kind) {
            throw OpenTrafficAPIError(status: 409, code: "not_ready", message: blocker)
        }
        try confirmAPIPublishing("share the Mac app \(app.name) publicly with \(kind.provider.title) and live collaboration", client: client)
        let earlierNotice = notice?.id
        share(app, kind: kind, data: data, name: name)
        guard let definition = definitions.first(where: { $0.macApp == app.id && $0.kind == kind }) else {
            let message = notice.flatMap { $0.id != earlierNotice && $0.severity == .error ? $0.message : nil }
            throw OpenTrafficAPIError.badRequest(message ?? "Couldn't share \(app.name).")
        }
        return try await apiWaitUntilLive(definition.id)
    }

    /// The app a `macApp` names: an .app of yours by its path, or a Mac app OpenTraffic lists (or
    /// has shared before) by its name.
    private func apiMacApp(_ reference: APIMacAppReference) async throws -> MacApp {
        await scanMacApps() // one built a moment ago may not be listed yet
        // Apps in the Simulator are listed (services) but can't be shared yet.
        let detectedMacApps = detectedMacApps.filter { $0.simulator == nil || Self.sharesSimulatorApps }
        switch reference {
        case .path(let path):
            guard path.hasPrefix("/") || path.hasPrefix("~") else {
                throw OpenTrafficAPIError.badRequest("Give the full path of the .app, like /Users/me/code/Orbit/build/Orbit.app.")
            }
            let expanded = (path as NSString).expandingTildeInPath
            if let found = detectedMacApps.first(where: { ElectronDiscovery.realURL($0.bundle).path == ElectronDiscovery.realURL(URL(fileURLWithPath: expanded)).path }) {
                return found
            }
            guard FileManager.default.fileExists(atPath: expanded) else { throw OpenTrafficAPIError.notFound("There is no app at \(path).") }
            do {
                return try await Task.detached { try MacAppDiscovery.resolve(path: expanded) }.value
            } catch let refusal as MacAppRefusal {
                throw OpenTrafficAPIError.badRequest(refusal.message)
            }
        case .name(let name):
            switch APIMacAppReference.match(name, in: detectedMacApps) {
            case .found(let app):
                return app
            case .ambiguous(let apps):
                throw OpenTrafficAPIError.conflict("Several Mac apps are called \(name): \(apps.map(\.bundle.path).joined(separator: ", ")). Give the path of the one to share.")
            case .none:
                // An app shared before whose build is no longer recent enough to be listed.
                let saved = definitions.filter { $0.macApp != nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }.compactMap(\.macApp)
                    + definitions.compactMap(\.macApp).filter { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
                if let path = saved.first(where: { FileManager.default.fileExists(atPath: $0) }),
                   let app = try? await Task.detached(operation: { try MacAppDiscovery.resolve(path: path) }).value {
                    return app
                }
                throw OpenTrafficAPIError.notFound("No Mac app called “\(name)” was found. OpenTraffic lists the debug builds of yours that are running and recent builds (see services); give the .app's path for any other build.")
            }
        }
    }

    /// Mac apps need OpenTraffic's viewer and the Accessibility and Screen Recording permissions.
    private func apiCheckMacAppSupport() throws {
        guard Self.macAppViewer != nil, Self.collaborationScript != nil else {
            throw OpenTrafficAPIError(status: 500, code: "internal", message: "OpenTraffic's Mac app support is missing from the app. Reinstall OpenTraffic.")
        }
        refreshMacAppPermissions()
        if !missingMacAppPermissions.isEmpty {
            // The command can't turn them on; the person at this Mac can, with the wizard.
            showPermissionsWizard()
            throw OpenTrafficAPIError.missingMacAppPermissions(missingMacAppPermissions, wizardOpened: true)
        }
    }

    /// A saved Mac app share that is about to start: refused (before asking) without the permissions,
    /// or while another share runs a copy of the same app.
    func apiCheckMacAppShareReady(_ definition: TunnelDefinition) throws {
        guard let path = definition.macApp, !isActive(definition.id) else { return }
        try apiCheckMacAppSupport()
        if let other = definitions.first(where: { $0.id != definition.id && $0.macApp == path && (isActive($0.id) || runtime(for: $0.id).state == .stopping) }) {
            throw OpenTrafficAPIError.conflict("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) is already shared by “\(other.name)”. Stop that share first.")
        }
    }

    /// Restarts a running Mac app share's app on the same address (from its latest build), or with
    /// `resetData` starts it over from the data it started with; answers once it's back.
    func apiRestartMacApp(_ reference: String, resetData: Bool) async throws -> APIShare {
        let definition = try apiDefinition(reference)
        let id = definition.id
        // An Electron app's sandboxed main process, like the Restart and Reset Data buttons on its card.
        if definition.electronApp != nil {
            guard let work = resetData ? resetElectronData(id) : restartElectronApp(id) else {
                throw OpenTrafficAPIError.conflict("“\(definition.name)” isn't running. Start it first.")
            }
            if let failure = await work.value {
                throw OpenTrafficAPIError(status: 502, code: "restart_failed", message: failure)
            }
            return apiShare(definitions.first { $0.id == id } ?? definition)
        }
        guard definition.macApp != nil else { throw OpenTrafficAPIError.badRequest("“\(definition.name)” doesn't share a Mac app or an Electron app.") }
        guard let work = resetData ? resetMacAppData(id) : restartMacApp(id) else {
            throw OpenTrafficAPIError.conflict("“\(definition.name)” isn't running. Start it first.")
        }
        if let failure = await work.value {
            throw OpenTrafficAPIError(status: 502, code: "restart_failed", message: failure)
        }
        // The session's state reaches the store as an event, a moment later.
        for _ in 0..<20 where macAppStatus[id]?.state != .running {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return apiShare(definitions.first { $0.id == id } ?? definition)
    }

    /// Ask to control from the API, like Allow, Not Now and Take Back on the share's card; answers
    /// with the share once its status shows the change.
    func apiControlMacApp(_ reference: String, action: APIMacAppControl.Action, viewer: String?) async throws -> APIShare {
        let definition = try apiDefinition(reference)
        let id = definition.id
        guard definition.macApp != nil else { throw OpenTrafficAPIError.badRequest("“\(definition.name)” doesn't share a Mac app.") }
        guard isActive(id), let server = macAppSessions[id]?.server else {
            throw OpenTrafficAPIError.conflict("“\(definition.name)” isn't running. Start it first.")
        }
        let target = try APIMacAppControl.target(of: action, viewer: viewer, in: await server.controlState(), share: definition.name)
        switch action {
        case .allow: target.map { allowMacAppControl(viewer: $0, for: id) }
        case .deny: target.map { denyMacAppControl(viewer: $0, for: id) }
        case .takeBack: revokeMacAppControl(for: id)
        }
        // The server has applied it once it answers; its event reaches the status a moment later.
        let state = await server.controlState()
        for _ in 0..<40 where isActive(id) && macAppStatus[id]?.control != state {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return apiShare(definitions.first { $0.id == id } ?? definition)
    }

    /// Rebuilding a shared Mac app from its sources, while the share runs and rebuilds it.
    func apiMacAppBuild(_ id: UUID) -> APIMacAppBuild? {
        guard isActive(id), let session = macAppSessions[id], let plan = session.buildPlan else { return nil }
        return APIMacAppBuild(macAppStatus[id]?.build ?? session.buildState, log: session.buildLog, command: plan.summary)
    }

    /// The Mac app a share publishes and how its copy is doing, for `APIShare.macApp`.
    func apiMacAppInfo(_ definition: TunnelDefinition) -> APIShareMacApp? {
        guard let path = definition.macApp else { return nil }
        let status = isActive(definition.id) ? macAppStatus[definition.id] : nil
        let described = status.map { APIShareMacApp.describe($0.state) }
        let name = macAppSessions[definition.id]?.name ?? detectedMacApps.first { $0.id == path }?.name
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // The mode as the host set it; who has control and who asks while the share runs.
        let mode = (definition.macAppOptions ?? MacAppViewerOptions()).control
        let control = status?.control.flatMap { $0.mode == mode ? APIMacAppControl($0) : nil } ?? APIMacAppControl(mode: mode.rawValue)
        return APIShareMacApp(
            path: path, name: name, data: (definition.macAppData ?? .copy).rawValue,
            state: described?.state, viewers: status?.viewers, warning: status?.warning, error: described?.error,
            control: control, build: apiMacAppBuild(definition.id)
        )
    }

    func apiMacApps() async -> [APIMacApp] {
        await scanMacApps()
        return detectedMacApps.map { app in
            APIMacApp(app, sharedAs: definitions.first { $0.macApp == app.id && isActive($0.id) }?.name)
        }
    }

    /// The Electron app in development whose dev server `localURL` is, if any.
    private func electronApp(serving localURL: String) async -> ElectronApp? {
        guard let port = URL(string: localURL)?.port else { return nil }
        await scanElectronApps() // one started a moment ago may not be listed yet
        return detectedElectronApps.first { (electronAppPorts[$0.id] ?? Set($0.environmentPorts)).contains(port) && rendererURL(for: $0).flatMap { URL(string: $0)?.port } == port }
    }

    /// A hostname in the connected Cloudflare account, like the New Tunnel sheet's Your Domain.
    private func apiCreateDomainShare(_ request: APIShareRequest, localURL: String, start: Bool, client: String) async throws -> APIShare {
        guard let hostname = request.hostname?.nilIfBlank?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
            throw OpenTrafficAPIError.badRequest("A domain share needs a hostname.")
        }
        if request.funnel == true { throw OpenTrafficAPIError.badRequest("Funnel is for Tailscale shares.") }
        if let existing = definitions.first(where: { $0.kind.usesCloudflareAccount && $0.hostname?.lowercased() == hostname }) {
            guard Self.sameService(existing.localURL, localURL) else {
                throw OpenTrafficAPIError.conflict("“\(existing.name)” already serves \(hostname) from \(existing.localURL). Change its local service, or remove it first.")
            }
            guard start else { return apiShare(existing) }
            if !isActive(existing.id) {
                try confirmAPIPublishing("start “\(existing.name)” at https://\(hostname)", client: client)
                startSharing(existing)
            }
            return try await apiWaitUntilLive(existing.id)
        }
        let zones = try await apiZones()
        // The most specific domain that contains the hostname.
        let zone = zones
            .filter { hostname == $0.name.lowercased() || hostname.hasSuffix(".\($0.name.lowercased())") }
            .max { $0.name.count < $1.name.count }
        guard let zone else {
            let names = zones.map(\.name).joined(separator: ", ")
            throw OpenTrafficAPIError.badRequest("\(hostname) isn't in your Cloudflare account\(names.isEmpty ? "." : ", whose domains are \(names).")")
        }
        // A record from elsewhere is only replaced when asked to; say so before asking to publish.
        if request.replaceDNS != true, let cloudflare = try? await self.client(for: accountID),
           let record = try? await cloudflare.dnsRecord(zoneID: zone.id, hostname: hostname), let content = record.content?.nilIfBlank {
            throw OpenTrafficAPIError(
                status: 409,
                code: "dns_record_exists",
                message: "A DNS record for \(hostname) already exists and points to \(content). Send replaceDNS: true to replace it, or pick another hostname."
            )
        }
        let target = AutomationCommand.target(of: localURL)
        // Creating the tunnel and its DNS record changes the Cloudflare account, so it always asks.
        try confirmAPIPublishing(
            "serve \(target?.display ?? localURL) at https://\(hostname) with a new Cloudflare tunnel\(request.replaceDNS == true ? ", replacing the hostname's existing DNS record" : "")",
            client: client,
            offMac: target?.isLoopback != true
        )
        guard let definition = await createRemote(
            name: request.name?.nilIfBlank ?? hostname,
            hostname: hostname,
            localURL: localURL,
            zoneID: zone.id,
            replacingDNS: request.replaceDNS ?? false
        ) else {
            throw OpenTrafficAPIError(status: 502, code: "create_failed", message: accountError ?? "The tunnel couldn't be created.")
        }
        if request.collaboration == true {
            guard definition.kind.supportsCollaboration else {
                throw OpenTrafficAPIError.badRequest("Custom-domain shares don't support live collaboration.")
            }
            await setCollaboration(true, for: definition.id)
        }
        guard start else { return apiShare(definitions.first { $0.id == definition.id } ?? definition) }
        startSharing(definitions.first { $0.id == definition.id } ?? definition)
        return try await apiWaitUntilLive(definition.id)
    }

    /// Why a new share of this kind can't be made yet (what the New Tunnel sheet shows as "Not set up"),
    /// or, with `funnel`, why a Tailscale share can't be public.
    /// Why a provider can't be used, with what to do about it (for the command line and agents).
    func hintedBlocker(_ provider: TunnelProvider) -> String? {
        switch provider {
        case .cloudflare:
            return cloudflaredPath == nil ? missingExecutableMessage(for: .cloudflare) : nil
        case .ngrok:
            return ngrokBlocker.map { ngrokPath == nil ? "\($0) Run `opentraffic install ngrok`, then connect your account in OpenTraffic → Settings → ngrok." : "\($0) Connect your account in OpenTraffic → Settings → ngrok." }
        case .opentunnel:
            return openTunnelBlocker.map { openTunnelPath == nil ? "\($0) Run `opentraffic install opentunnel`." : $0 }
        case .tailscale:
            return tailscaleBlocker.map { tailscalePath == nil ? "\($0) Run `opentraffic install tailscale` (it asks for your Mac's password), then sign in to Tailscale." : $0 }
        }
    }

    private func apiBlocker(for kind: TunnelKind, funnel: Bool = false) async -> String? {
        // Tailscale's status may not have been read yet, or be older than a change in the tailnet.
        if kind == .tailscale, tailscaleStatus == nil || (funnel && tailscaleStatus?.funnelEnabled != true) {
            await refreshTailscale()
        }
        switch kind.provider {
        case .cloudflare:
            if cloudflaredPath == nil { return missingExecutableMessage(for: .cloudflare) }
            // A network that filters api.trycloudflare.com can't get a temporary address (cached check).
            return kind == .quick ? await checkQuickTunnelNetwork().value.warning : nil
        case .ngrok: return hintedBlocker(.ngrok)
        case .opentunnel: return hintedBlocker(.opentunnel)
        case .tailscale:
            if let blocker = hintedBlocker(.tailscale) { return blocker }
            guard funnel, tailscaleStatus?.funnelEnabled != true else { return nil }
            return "Funnel isn't enabled for this Mac, so it can't share publicly. Allow Funnel in your tailnet's access controls (OpenTraffic → Settings → Tailscale links to them), or share on your tailnet only."
        }
    }

    /// A Tailscale share that can't start (Tailscale is off, or Funnel isn't allowed) is refused before asking.
    func apiCheckTailscaleReady(_ definition: TunnelDefinition) async throws {
        guard definition.kind == .tailscale, let blocker = await apiBlocker(for: .tailscale, funnel: definition.tailscalePublic) else { return }
        throw OpenTrafficAPIError(status: 409, code: "not_ready", message: blocker)
    }

    static func apiKind(_ provider: String) -> TunnelKind? {
        switch provider.lowercased() {
        case "quick", "cloudflare", "temporary": .quick
        case "tailscale", "tailnet": .tailscale
        case "ngrok": .ngrok
        case "opentunnel": .opentunnel
        case "domain", "remote": .remote
        default: nil
        }
    }

    /// The same host and port, whatever the scheme defaults or trailing slashes.
    private static func sameService(_ a: String, _ b: String) -> Bool {
        AutomationCommand.target(of: a)?.display == AutomationCommand.target(of: b)?.display
    }

    // MARK: Changing

    func apiUpdateShare(_ reference: String, _ update: APIShareUpdate, client: String) async throws -> APIShare {
        let definition = try apiDefinition(reference)
        let id = definition.id
        if let name = update.name {
            guard let name = name.nilIfBlank else { throw OpenTrafficAPIError.badRequest("name can't be empty.") }
            if definitions.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw OpenTrafficAPIError.conflict("A share named “\(name)” already exists.")
            }
        }
        if update.collaboration == true, !definition.kind.supportsCollaboration {
            throw OpenTrafficAPIError.badRequest("\(definition.kind.provider.title) shares don't support live collaboration.")
        }
        if update.branch == true, !(update.collaboration ?? definition.collaboration) {
            throw OpenTrafficAPIError.badRequest("Working on a branch needs live collaboration (turn it on too).")
        }
        let autoStop = try update.autoStop.map { raw -> ShareDuration in
            guard let duration = ShareDuration(apiValue: raw) else {
                throw OpenTrafficAPIError.badRequest("autoStop must be never, 15m, 1h, or 4h.")
            }
            return duration
        }
        let newLocalURL = try update.url.map { try apiLocalURL(port: nil, url: $0) }
        let macAppOptions = try apiMacAppOptions(update, for: definition)
        if update.rewriteHostHeader == true {
            var updated = definition
            updated.localURL = newLocalURL ?? definition.localURL
            guard updated.supportsHostHeaderRewrite else {
                throw OpenTrafficAPIError.conflict("OpenTraffic can't rewrite the Host header for an https local service on \(definition.kind.provider.title). Allow the public hostname in your dev server instead.")
            }
        }
        if update.name != nil || update.url != nil {
            let localURL = newLocalURL ?? definition.localURL
            if let message = updateManagedTunnel(id, name: update.name?.nilIfBlank ?? definition.name, localURL: localURL) {
                throw OpenTrafficAPIError.badRequest(message)
            }
        }
        if let collaboration = update.collaboration { await setCollaboration(collaboration, for: id) }
        if let captureErrors = update.captureErrors { setCaptureErrors(captureErrors, for: id) }
        if let branch = update.branch {
            if branch, let current = definitions.first(where: { $0.id == id }), !current.workOnBranch { try await apiRequireBranchReady(current) }
            await setWorkOnBranch(branch, for: id)
        }
        if let autoStart = update.autoStart { setAutoStart(autoStart, for: id) }
        if let project = update.project { setProject(project.nilIfBlank, for: id) }
        if let rewrite = update.rewriteHostHeader {
            await setHostHeaderRewrite(rewrite, for: id)
            // Custom domains change it on Cloudflare, which can fail; the app shows why as a notice.
            if definitions.first(where: { $0.id == id })?.rewriteHostHeader != rewrite {
                throw OpenTrafficAPIError(status: 502, code: "cloudflare", message: notice.flatMap { $0.severity == .error ? $0.message : nil } ?? "The Host header setting couldn't be changed.")
            }
        }
        if let autoStop { setAutoStop(id, after: autoStop) }
        if let macAppOptions { setMacAppOptions(macAppOptions, for: id) }
        return try apiShare(apiDefinition(id.uuidString))
    }

    /// The share's viewer options with the update's changes, nil when it changes none.
    private func apiMacAppOptions(_ update: APIShareUpdate, for definition: TunnelDefinition) throws -> MacAppViewerOptions? {
        guard update.macAppControl != nil || update.macAppAppearance != nil || update.macAppWindowSize != nil else { return nil }
        guard definition.macApp != nil else { throw OpenTrafficAPIError.badRequest("Viewer options are for Mac app shares.") }
        var options = definition.macAppOptions ?? MacAppViewerOptions()
        if let raw = update.macAppControl {
            guard let control = MirrorProtocol.ControlMode(rawValue: raw) else { throw OpenTrafficAPIError.badRequest("macAppControl must be everyone, watchOnly, or askToControl.") }
            options.control = control
        }
        if let raw = update.macAppAppearance {
            guard let appearance = MacAppViewerOptions.Appearance(rawValue: raw) else { throw OpenTrafficAPIError.badRequest("macAppAppearance must be viewer, mac, light, or dark.") }
            options.appearance = appearance
        }
        if let raw = update.macAppWindowSize {
            guard let size = MacAppViewerOptions.WindowSize(rawValue: raw) else { throw OpenTrafficAPIError.badRequest("macAppWindowSize must be fitViewer or app.") }
            options.windowSize = size
        }
        return options
    }

    func apiRestartShare(_ reference: String, client: String) async throws -> APIShare {
        let definition = try apiDefinition(reference)
        try await apiCheckTailscaleReady(definition)
        try apiCheckMacAppShareReady(definition)
        if isActive(definition.id) {
            await restart(definition.id)
        } else {
            try confirmAPIPublishing("start “\(definition.name)”", client: client)
            startSharing(definition)
        }
        return try await apiWaitUntilLive(definition.id)
    }

    func apiDeleteShare(_ reference: String) throws {
        remove(try apiDefinition(reference).id)
    }

    // MARK: Protection

    func apiProtection(_ reference: String) throws -> APIProtection {
        apiProtectionInfo(try apiDefinition(reference))
    }

    private func apiProtectionInfo(_ definition: TunnelDefinition) -> APIProtection {
        switch definition.protection {
        case .none:
            APIProtection(mode: "none", username: nil, password: nil, emails: [])
        case .password where definition.kind.passwordInProxy:
            APIProtection(mode: "password", username: nil, password: sharePassword(for: definition.id), emails: [], link: inviteLink(for: definition.id))
        case .password(let username):
            APIProtection(mode: "password", username: username, password: sharePassword(for: definition.id), emails: [])
        case .login(let provider, let emails):
            APIProtection(mode: Self.apiProtectionMode(.login(provider, allowedEmails: emails)), username: nil, password: nil, emails: emails)
        }
    }

    static func apiProtectionMode(_ protection: ShareProtection) -> String {
        switch protection {
        case .none: "none"
        case .password: "password"
        case .login(.google, _): "google"
        case .login(.github, _): "github"
        case .login(.cloudflareEmail, _): "email"
        }
    }

    func apiSetProtection(_ reference: String, _ request: APIProtectionRequest) async throws -> APIProtection {
        let definition = try apiDefinition(reference)
        guard let emails = EmailList.parse((request.emails ?? []).joined(separator: ", ")) else {
            throw OpenTrafficAPIError.badRequest("Check the email addresses.")
        }
        let protection: ShareProtection
        switch request.mode.lowercased() {
        case "none", "off":
            protection = .none
        case "password":
            let username = request.username?.trimmingCharacters(in: .whitespaces).nilIfBlank ?? "guest"
            guard !username.contains(":") else { throw OpenTrafficAPIError.badRequest("The username can't contain a colon.") }
            protection = .password(username: username)
        case "google":
            protection = .login(.google, allowedEmails: emails)
        case "github":
            protection = .login(.github, allowedEmails: emails)
        case "email":
            guard !emails.isEmpty else { throw OpenTrafficAPIError.badRequest("Email codes need at least one allowed email address.") }
            protection = .login(.cloudflareEmail, allowedEmails: emails)
        default:
            throw OpenTrafficAPIError.badRequest("mode must be none, password, google, github, or email.")
        }
        guard protection == .none || definition.kind.protectionOptions.contains(protection.option) else {
            let options = definition.kind.protectionOptions.filter { $0 != .none }.map { Self.apiProtectionMode(Self.protection(for: $0)) }
            throw OpenTrafficAPIError.badRequest(options.isEmpty
                ? "\(definition.kind.provider.title) shares can't be protected. Temporary, OpenTunnel, and ngrok shares take a password; ngrok also takes a sign-in; custom domains take email codes."
                : "This share can be protected with: \(options.joined(separator: ", ")).")
        }
        if let message = await setProtection(protection, for: definition.id) {
            throw OpenTrafficAPIError.badRequest(message)
        }
        return apiProtectionInfo(try apiDefinition(definition.id.uuidString))
    }

    private static func protection(for option: ProtectionOption) -> ShareProtection {
        switch option {
        case .none: .none
        case .password: .password(username: "guest")
        case .google: .login(.google, allowedEmails: [])
        case .github: .login(.github, allowedEmails: [])
        case .cloudflareEmail: .login(.cloudflareEmail, allowedEmails: [])
        }
    }

    func apiRegeneratePassword(_ reference: String) async throws -> APIProtection {
        let definition = try apiDefinition(reference)
        guard case .password = definition.protection else {
            throw OpenTrafficAPIError.badRequest("“\(definition.name)” isn't password protected.")
        }
        await regenerateSharePassword(for: definition.id)
        return apiProtectionInfo(try apiDefinition(definition.id.uuidString))
    }

    // MARK: Comments

    func apiDeleteComment(_ reference: String, commentID: String) async throws {
        let definition = try apiDefinition(reference)
        loadComments(for: definition.id)
        guard comments(for: definition.id).contains(where: { $0.id == commentID }) else {
            throw OpenTrafficAPIError.notFound("No comment \(commentID) on “\(definition.name)”.")
        }
        await deleteComment(commentID, for: definition.id)
    }

    // MARK: Local services, projects, domains

    func apiLocalServices() async -> [APILocalService] {
        await scanLocalServices(showsProgress: false)
        return detectedLocalServices.map { service in
            let shared = definitions.first {
                guard let target = AutomationCommand.target(of: $0.localURL), target.isLoopback else { return false }
                return target.display.hasSuffix(":\(service.port)")
            }
            let app = detectedElectronApps.first { app in rendererURL(for: app).flatMap { URL(string: $0)?.port } == service.port }
            return APILocalService(
                port: service.port,
                url: service.url,
                title: app.map { "\($0.name) (Electron app)" } ?? service.title,
                process: service.processName,
                statusCode: service.statusCode,
                upSince: service.upSince,
                sharedAs: shared?.name
            )
        }
    }

    func apiProjects() -> [APIProject] {
        projectNames.map(apiProject)
    }

    private func apiProject(_ name: String) -> APIProject {
        let members = tunnels(inProject: name)
        return APIProject(name: members.first?.project ?? name, shares: members.map(\.name), running: members.filter { isActive($0.id) }.count)
    }

    func apiStartProject(_ name: String, client: String) async throws -> APIProject {
        let members = tunnels(inProject: name)
        guard !members.isEmpty else { throw OpenTrafficAPIError.notFound("No project named “\(name)”.") }
        if members.contains(where: { !isActive($0.id) }) {
            try confirmAPIPublishing("start the project “\(members.first?.project ?? name)” (\(members.map(\.name).joined(separator: ", ")))", client: client)
            startProject(name)
        }
        // Like starting one share: wait until each is live or has failed.
        for member in members {
            _ = try? await apiWaitUntilLive(member.id)
        }
        return apiProject(name)
    }

    func apiStopProject(_ name: String) async throws -> APIProject {
        let members = tunnels(inProject: name)
        guard !members.isEmpty else { throw OpenTrafficAPIError.notFound("No project named “\(name)”.") }
        stopProject(name)
        // Like stopping one share: answer once they've stopped, up to 10 seconds.
        for _ in 0..<50 where members.contains(where: { runtime(for: $0.id).state == .stopping }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return apiProject(name)
    }

    func apiZones() async throws -> [APIZone] {
        guard hasSavedAPIToken else {
            throw OpenTrafficAPIError(status: 409, code: "no_account", message: "No Cloudflare account is connected. Add an API token in OpenTraffic → Settings → Cloudflare.")
        }
        if zones.isEmpty { await refreshAccount() }
        if zones.isEmpty, let zoneError {
            throw OpenTrafficAPIError(status: 502, code: "cloudflare", message: zoneError)
        }
        return zones.map { APIZone(id: $0.id, name: $0.name) }
    }
}

extension ShareDuration {
    /// "never", "15m", "1h", or "4h", as the API and the command-line tool write them.
    init?(apiValue: String) {
        switch apiValue.lowercased() {
        case "never", "off", "0": self = .never
        case "15m", "15min", "15": self = .minutes15
        case "1h", "60m", "60": self = .hour1
        case "4h", "240m", "240": self = .hours4
        default: return nil
        }
    }
}

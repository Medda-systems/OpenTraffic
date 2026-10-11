import Foundation
import OpenTrafficCore

/// The local API's answers for what the app's windows can do (create any kind of share, edit, protect,
/// restart, remove, projects, local services), so the command-line tool can do all of it too.
/// Publishing asks first, as everywhere else in the API; see `confirmAPIPublishing`.
extension AppStore {
    // MARK: Status

    func apiAppStatus() -> APIAppStatus {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let cloudflaredMissing = cloudflaredPath == nil ? missingExecutableMessage(for: .cloudflare) : nil
        func provider(_ name: String, _ blocker: String?) -> APIProviderStatus {
            APIProviderStatus(name: name, ready: blocker == nil, detail: blocker)
        }
        return APIAppStatus(
            version: version,
            shares: definitions.count,
            running: definitions.filter { isActive($0.id) }.count,
            providers: [
                provider("quick", cloudflaredMissing),
                provider("opentunnel", openTunnelBlocker),
                provider("tailscale", tailscaleBlocker),
                provider("ngrok", ngrokBlocker),
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
        if start {
            let audience = kind == .tailscale && !funnel ? "on your tailnet" : "publicly"
            try confirmAPIPublishing(
                "share \(target?.display ?? localURL) \(audience) with \(kind.provider.title)\(collaboration ? " and live collaboration" : "")",
                client: client,
                offMac: target?.isLoopback != true
            )
        }
        var definition: TunnelDefinition
        if let existing = definitions.first(where: {
            $0.kind == kind && $0.localURL == localURL && (kind != .tailscale || $0.tailscalePublic == funnel)
                && (domain == nil || $0.hostname?.lowercased() == domain)
        }) {
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
            // Like the New Tunnel sheet: nothing is created for a way of sharing that isn't set up.
            if let blocker = apiBlocker(for: kind) {
                throw OpenTrafficAPIError(status: 409, code: "not_ready", message: blocker)
            }
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
        guard start else { return apiShare(definition) }
        if !isActive(definition.id) { startSharing(definition) }
        return try await apiWaitUntilLive(definition.id)
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

    /// Why a new share of this kind can't be made yet (what the New Tunnel sheet shows as "Not set up").
    private func apiBlocker(for kind: TunnelKind) -> String? {
        switch kind.provider {
        case .cloudflare: cloudflaredPath == nil ? missingExecutableMessage(for: .cloudflare) : nil
        case .ngrok: ngrokBlocker.map { "\($0) Set it up in OpenTraffic → Settings → ngrok." }
        case .tailscale: tailscaleBlocker
        case .opentunnel: openTunnelBlocker.map { "\($0) \(OpenTunnel.installCommand)" }
        }
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
        let autoStop = try update.autoStop.map { raw -> ShareDuration in
            guard let duration = ShareDuration(apiValue: raw) else {
                throw OpenTrafficAPIError.badRequest("autoStop must be never, 15m, 1h, or 4h.")
            }
            return duration
        }
        if update.name != nil || update.url != nil {
            let localURL = try update.url.map { try apiLocalURL(port: nil, url: $0) } ?? definition.localURL
            if let message = updateManagedTunnel(id, name: update.name?.nilIfBlank ?? definition.name, localURL: localURL) {
                throw OpenTrafficAPIError.badRequest(message)
            }
        }
        if let collaboration = update.collaboration { await setCollaboration(collaboration, for: id) }
        if let captureErrors = update.captureErrors { setCaptureErrors(captureErrors, for: id) }
        if let autoStart = update.autoStart { setAutoStart(autoStart, for: id) }
        if let project = update.project { setProject(project.nilIfBlank, for: id) }
        if let rewrite = update.rewriteHostHeader { await setHostHeaderRewrite(rewrite, for: id) }
        if let autoStop { setAutoStop(id, after: autoStop) }
        return try apiShare(apiDefinition(id.uuidString))
    }

    func apiRestartShare(_ reference: String, client: String) async throws -> APIShare {
        let definition = try apiDefinition(reference)
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
                ? "\(definition.kind.provider.title) shares can't be protected. ngrok shares take a password or a sign-in; custom domains take email codes."
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
            return APILocalService(
                port: service.port,
                url: service.url,
                title: service.title,
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

    func apiStopProject(_ name: String) throws -> APIProject {
        guard !tunnels(inProject: name).isEmpty else { throw OpenTrafficAPIError.notFound("No project named “\(name)”.") }
        stopProject(name)
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

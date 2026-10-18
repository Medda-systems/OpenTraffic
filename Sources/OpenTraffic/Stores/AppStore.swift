import AppKit
import Darwin
import Foundation
import Observation
import OpenTrafficCore

@MainActor
@Observable
final class AppStore {
    static let shared: AppStore = {
        // Before anything reads its files: data from when the app was called TunnelBar.
        LegacyData.migrate()
        return AppStore()
    }()
    static let apiTokenKeyPrefix = "cloudflare-api-token:"

    var definitions: [TunnelDefinition]
    var runtimes: [UUID: TunnelRuntime] = [:]
    var logs: [UUID: BoundedLogBuffer] = [:]
    var remoteStatuses: [UUID: RemoteTunnelStatus] = [:]
    var remoteStatusUpdatedAt: [UUID: Date] = [:]
    var discoveredTunnels: [DiscoveredQuickTunnel] = []
    private(set) var effectiveOrigins: [UUID: EffectiveOrigin] = [:]
    var selectedID: UUID? {
        didSet {
            defaults.set(selectedID?.uuidString, forKey: "selectedTunnelID")
            // Only ngrok tunnels have a Requests tab; don't leave the picker with nothing selected.
            if detailTab == .requests, selectedDefinition?.kind != .ngrok { detailTab = .overview }
            if detailTab == .feedback, selectedDefinition?.kind.supportsCollaboration != true { detailTab = .overview }
        }
    }
    var availableRemoteTunnels: [CloudflareTunnel] = []
    var remoteTunnelHostnames: [String: String] = [:]
    var zones: [CloudflareZone] = []
    var isRefreshingAccount = false
    var accountError: String?
    var zoneError: String?
    var notice: AppNotice?
    var tunnelHealth: [UUID: TunnelHealth] = [:]
    var setupProgressSteps: [SetupProgressStep] = []
    var setupProgressTunnelID: UUID?
    var presentedSheet: PresentedSheet?
    var detailTab = DetailTab.overview
    private(set) var requestHistory: [UUID: RequestHistory] = [:]
    private(set) var recentlyCopiedID: UUID?
    private(set) var trafficPulse = false
    @ObservationIgnored private var trafficPulseTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledHealthRechecks = Set<UUID>()
    @ObservationIgnored private var pendingAutoCopy = Set<UUID>()
    @ObservationIgnored private var copyFeedbackTask: Task<Void, Never>?

    var autoCopyPublicURL: Bool {
        didSet { defaults.set(autoCopyPublicURL, forKey: "autoCopyPublicURL") }
    }
    var notifyWhenReady: Bool {
        didSet {
            defaults.set(notifyWhenReady, forKey: "notifyWhenReady")
            if notifyWhenReady { TunnelNotifications.requestAuthorizationIfNeeded() }
        }
    }
    /// Notify when someone joins a collaborative share or leaves a comment.
    var notifyCollaboration: Bool {
        didSet {
            defaults.set(notifyCollaboration, forKey: "notifyCollaboration")
            if notifyCollaboration { TunnelNotifications.requestAuthorizationIfNeeded() }
        }
    }
    /// Settings → Integrations: whether apps on this Mac may use OpenTraffic's local API.
    var apiEnabled: Bool {
        didSet {
            defaults.set(apiEnabled, forKey: "apiEnabled")
            scheduleAPISettings()
        }
    }
    var apiPort: Int {
        didSet {
            defaults.set(apiPort, forKey: "apiPort")
            scheduleAPISettings()
        }
    }
    /// The running API server's address, or why it isn't running.
    var apiStatus: APIStatus = .off
    /// Endpoints are kept in preferences; their signing secrets in the Keychain.
    var webhookEndpoints: [WebhookEndpoint] {
        didSet {
            Self.saveWebhookEndpoints(webhookEndpoints, previous: oldValue, defaults: defaults)
            webhookDispatcher.setEndpoints(webhookEndpoints)
        }
    }
    var webhookStatuses: [UUID: WebhookDeliveryStatus] = [:]
    @ObservationIgnored var apiServer: LocalAPIServer?
    /// The private channel for OpenTraffic's own command-line tool and MCP bridge (always on).
    @ObservationIgnored var trustedChannel: LocalAPIServer?
    @ObservationIgnored lazy var webhookDispatcher = WebhookDispatcher(events: apiEvents)
    /// Apps may share and start tunnels through the API without OpenTraffic asking each time.
    var apiAllowsPublishingWithoutAsking: Bool {
        didSet { defaults.set(apiAllowsPublishingWithoutAsking, forKey: "apiAllowsPublishingWithoutAsking") }
    }
    /// The host's name in shared sessions; empty shows "Host".
    var collaborationHostName: String {
        didSet { defaults.set(collaborationHostName, forKey: "collaborationHostName") }
    }
    var notifyOnFailure: Bool {
        didSet {
            defaults.set(notifyOnFailure, forKey: "notifyOnFailure")
            if notifyOnFailure { TunnelNotifications.requestAuthorizationIfNeeded() }
        }
    }
    var dockVisibility: DockVisibility {
        didSet {
            defaults.set(dockVisibility.rawValue, forKey: "dockVisibility")
            MainWindowController.shared.applyActivationPolicy()
        }
    }
    /// What a plain click on Share does: a temporary Cloudflare URL, a tailnet share, or ngrok.
    var defaultShareKind: TunnelKind {
        didSet { defaults.set(defaultShareKind.rawValue, forKey: "defaultShareKind") }
    }
    /// How long new shares stay up before stopping themselves.
    var defaultShareDuration: ShareDuration {
        didSet { defaults.set(defaultShareDuration.rawValue, forKey: "defaultShareDuration") }
    }
    /// When each running tunnel stops itself. Not persisted: tunnels stop when OpenTraffic quits anyway.
    var autoStopDeadlines: [UUID: Date] = [:]
    /// Restart tunnels whose connector exits unexpectedly.
    var restartCrashedTunnels: Bool {
        didSet { defaults.set(restartCrashedTunnels, forKey: "restartCrashedTunnels") }
    }
    /// Let opentraffic:// links share and start tunnels without asking. Off by default, because any
    /// app or web page can open such a link.
    var allowUnconfirmedAutomation: Bool {
        didSet { defaults.set(allowUnconfirmedAutomation, forKey: "allowUnconfirmedAutomation") }
    }
    var globalHotKeysEnabled: Bool {
        didSet {
            defaults.set(globalHotKeysEnabled, forKey: "globalHotKeysEnabled")
            GlobalHotKeys.shared.setEnabled(globalHotKeysEnabled)
        }
    }
    /// Where installing each tool is up to (see AppStore+Tools), the newest release of each, and a counter
    /// bumped after an install so views that look tools up on disk check again.
    var toolInstallStates: [TunnelProvider: ToolInstallState] = [:]
    var toolReleases: [TunnelProvider: ToolRelease] = [:]
    var toolsRevision = 0
    /// Whether the Cloudflare token may manage Access applications (nil: unknown).
    var cloudflareAccessPermission: Bool?
    /// Cloudflare refused an Access change with this token (it may still read Access). Reset with the token.
    @ObservationIgnored var accessEditDenied = false
    @ObservationIgnored var autoStartTracker = AutoStartTracker()
    @ObservationIgnored var restartHistory: [UUID: [Date]] = [:]
    @ObservationIgnored var pendingRestarts: Set<UUID> = []
    /// The latest check of whether this network lets Quick Tunnels get an address, and when it started.
    @ObservationIgnored var quickTunnelNetworkCheck: (task: Task<QuickTunnelNetwork, Never>, startedAt: Date)?
    /// Quick Tunnel failures still being explained (see `explainQuickTunnelFailure`).
    @ObservationIgnored var failureDiagnoses: [UUID: Task<Void, Never>] = [:]
    /// Set when the app starts quitting; nothing may start or restart a connector after that.
    @ObservationIgnored private(set) var isTerminating = false
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    private(set) var hasSavedAPIToken = false
    private(set) var isAPITokenUnlocked = false
    private(set) var requiresLegacyTokenAuthorization = false
    var credentialError: String?
    private(set) var sessionUnlockLabel = "Unlock / Connect"
    private(set) var tokenStorageKind: SecretStorageKind?
    let signingReadiness = SigningReadinessInspector.current()
    var credentialMigrationMessage: String?
    private(set) var persistenceLoadError: String?

    var accountID: String {
        didSet {
            defaults.set(accountID, forKey: "cloudflareAccountID")
            hasSavedAPIToken = false
            isAPITokenUnlocked = false
            requiresLegacyTokenAuthorization = false
            tokenStorageKind = nil
            credentialMigrationMessage = nil
            credentialError = nil
            refreshAPITokenPresence()
        }
    }
    var customCloudflaredPath: String {
        didSet { defaults.set(customCloudflaredPath, forKey: "cloudflaredPath") }
    }
    var customTailscalePath: String {
        didSet { defaults.set(customTailscalePath, forKey: "tailscalePath") }
    }
    var tailscaleStatus: TailscaleStatus?
    var tailscaleServeConfig: TailscaleServeConfig?
    var tailscaleRecords: [TailscaleShareRecord]
    let tailscaleRecordPersistence: TailscaleShareRecordPersistence
    @ObservationIgnored var tailscaleForwarders: [UUID: LoopbackForwarder] = [:]
    /// Live collaboration proxies of running shares, and who is connected to each.
    @ObservationIgnored var collabProxies: [UUID: CollabProxy] = [:]
    var collabPeers: [UUID: [CollabPeer]] = [:]
    /// Comments per share, loaded from disk on first use and kept in sync with the hub.
    var collabComments: [UUID: [CollabComment]] = [:]
    @ObservationIgnored let feedbackPersistence = FeedbackPersistence()
    /// Local ports a collaborative share's app tried to reach that the host hasn't allowed yet.
    var collabBridgeCandidates: [UUID: Set<Int>] = [:]
    /// Browser errors visitors ran into, grouped, per share (this session only).
    var collabErrors: [UUID: [CollabErrorGroup]] = [:]
    /// Comments apps are working on (claimed through the API), for every share.
    var agentClaims = AgentClaimBook()
    /// The agent command's latest run per share, and the comments waiting for it.
    var agentRuns: [UUID: AgentRun] = [:]
    var agentQueues: [UUID: [String]] = [:]
    /// Comments that didn't start the agent by themselves, and why, so the Feedback tab can say.
    var agentHolds: [UUID: [String: AgentHold]] = [:]
    @ObservationIgnored var agentProcesses: [UUID: AgentProcess] = [:]
    /// The user's PATH from their shell, looked up once for the agent command.
    @ObservationIgnored var agentShellPath: Task<String, Never>?
    /// Processes that called OpenTraffic during a run of the agent command, and that run's comment: they
    /// stay held to it even once the run is over (when it's over, to nothing at all).
    @ObservationIgnored var agentRunCallers: [pid_t: AgentRunScope] = [:]
    /// Each collaborative share's project folder, watched so its pages catch up with changes.
    @ObservationIgnored var projectWatchers: [UUID: ProjectWatcher] = [:]
    /// Runs the agent command started by itself recently, against the budget.
    @ObservationIgnored var agentRunBudget = AgentRunBudget()
    /// Shares working on a branch: their repositories (by root), what was already changed when the
    /// branch started or last got a commit, and what was changed when each comment was claimed.
    @ObservationIgnored var gitRepositories: [String: GitRepository] = [:]
    @ObservationIgnored var gitBaselines: [UUID: GitSnapshot] = [:]
    @ObservationIgnored var claimSnapshots: [UUID: [String: GitSnapshot]] = [:]
    /// Settings → Integrations: the command OpenTraffic runs to have an agent handle a comment (empty: none).
    var agentCommand: String {
        didSet { defaults.set(agentCommand, forKey: "agentCommand") }
    }
    /// Run the agent command by itself for new comments when no app is watching the share.
    var agentRunsAutomatically: Bool {
        didSet { defaults.set(agentRunsAutomatically, forKey: "agentRunsAutomatically") }
    }
    /// The model picked for each agent (by `AgentPreset` raw value); none: the agent's own default.
    var agentModels: [String: String] {
        didSet { defaults.set(agentModels, forKey: "agentModels") }
    }
    /// The models each agent offers, found when Settings asks (see `AgentModels`).
    var agentModelLists: [AgentPreset: AgentModelList] = [:]
    var detectingAgentModels: Set<AgentPreset> = []
    /// Everything apps using the local API can follow (long polling, MCP, webhooks).
    @ObservationIgnored let apiEvents = APIEventLog()
    @ObservationIgnored var pendingJoinNames: [UUID: [String]] = [:]
    @ObservationIgnored var lastJoinNotification: [UUID: Date] = [:]
    /// People who just left a session, by share and name: a page change reconnects them a moment later.
    @ObservationIgnored var recentDepartures: [UUID: [String: CollabPeer]] = [:]
    @ObservationIgnored var pendingCommentNotices: [UUID: [CollabComment]] = [:]
    /// Comments reopened here or through the API, whose reopening needs no notification.
    @ObservationIgnored var quietReopens: Set<String> = []
    @ObservationIgnored var lastCommentNotification: [UUID: Date] = [:]
    /// Shares whose comments changed and haven't been written to disk yet.
    @ObservationIgnored var unsavedComments: Set<UUID> = []
    @ObservationIgnored var commentSaveTask: Task<Void, Never>?
    @ObservationIgnored var apiSettingsTask: Task<Void, Never>?
    /// Ports chosen by Tailscale starts that haven't been applied yet, so two starts can't pick the same one.
    @ObservationIgnored var tailscaleReservedPorts: [UUID: Int] = [:]
    /// Records being removed right now, so a retry doesn't run alongside a removal.
    @ObservationIgnored var tailscaleRemovalsInFlight: Set<TailscaleShareRecord> = []
    /// OpenTunnel's service for OpenTraffic's profile, when it's running.
    var openTunnelStatus: OpenTunnelStatus?
    /// OpenTraffic's tunnel address on OpenTunnel, once created.
    var openTunnelHostname: String?
    var openTunnelRecords: [OpenTunnelRouteRecord]
    let openTunnelRecordPersistence: OpenTunnelRouteRecordPersistence
    @ObservationIgnored var openTunnelRemovalsInFlight: Set<OpenTunnelRouteRecord> = []
    /// Recent requests captured by each running ngrok agent, newest first.
    var ngrokRequests: [UUID: [NgrokRequest]] = [:]
    /// ngrok agents on this Mac that OpenTraffic didn't start (for example, run in Terminal).
    var externalNgrokTunnels: [NgrokTunnelInfo] = []

    private let persistence: TunnelPersistence
    private let credentialService: CredentialService
    private let defaults: UserDefaults
    let processSupervisor: ProcessSupervisor
    private let externalDiscovery: ExternalTunnelDiscovery
    private let discoveryPreferencesPersistence: DiscoveryPreferencesPersistence
    private let originReachabilityChecker: LocalOriginReachabilityChecker
    private let managedConnectorInspector: any ManagedConnectorInspecting
    private let effectiveOriginPersistence: EffectiveOriginPersistence
    private var discoveryPreferences: DiscoveryPreferencesState
    private var externalAdoptionsInProgress = Set<ProcessIdentity>()
    @ObservationIgnored private var statusPollingTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryPollingTask: Task<Void, Never>?
    @ObservationIgnored private var healthPollingTask: Task<Void, Never>?

    private static func loadWebhookEndpoints(defaults: UserDefaults) -> [WebhookEndpoint] {
        let stored = defaults.data(forKey: "webhookEndpoints")
            .flatMap { try? JSONDecoder().decode([WebhookEndpoint].self, from: $0) } ?? []
        var movedSecrets = false
        let endpoints = stored.map { endpoint in
            var endpoint = endpoint
            if let secret = WebhookSecretStore.store.secret(for: endpoint.id) {
                endpoint.secret = secret
            } else if !endpoint.secret.isEmpty {
                // Saved before secrets moved to the Keychain.
                movedSecrets = WebhookSecretStore.store.set(endpoint.secret, for: endpoint.id) || movedSecrets
            }
            return endpoint
        }
        if movedSecrets { saveWebhookEndpoints(endpoints, previous: endpoints, defaults: defaults) }
        return endpoints
    }

    private static func saveWebhookEndpoints(_ endpoints: [WebhookEndpoint], previous: [WebhookEndpoint], defaults: UserDefaults) {
        let before = Dictionary(previous.map { ($0.id, $0.secret) }, uniquingKeysWith: { first, _ in first })
        for endpoint in endpoints where before[endpoint.id] != endpoint.secret || WebhookSecretStore.store.secret(for: endpoint.id) == nil {
            WebhookSecretStore.store.set(endpoint.secret, for: endpoint.id)
        }
        let current = Set(endpoints.map(\.id))
        for removed in previous where !current.contains(removed.id) {
            WebhookSecretStore.store.delete(for: removed.id)
        }
        let withoutSecrets = endpoints.map { endpoint in
            var endpoint = endpoint
            endpoint.secret = ""
            return endpoint
        }
        defaults.set(try? JSONEncoder().encode(withoutSecrets), forKey: "webhookEndpoints")
    }

    /// Settings from when the app was called TunnelBar carry over once, newest bundle ID first.
    private static func migrateLegacyDefaults(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: "migratedLegacyDefaults") else { return }
        for legacyDomain in LegacyData.bundleIDs where Bundle.main.bundleIdentifier != legacyDomain {
            for (key, value) in defaults.persistentDomain(forName: legacyDomain) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }

    init(
        persistence: TunnelPersistence = TunnelPersistence(),
        secretStore: any SecretStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        externalDiscovery: ExternalTunnelDiscovery = ExternalTunnelDiscovery(),
        discoveryPreferencesPersistence: DiscoveryPreferencesPersistence = DiscoveryPreferencesPersistence(),
        originReachabilityChecker: LocalOriginReachabilityChecker = LocalOriginReachabilityChecker(),
        managedConnectorInspector: any ManagedConnectorInspecting = ManagedConnectorInspector(),
        effectiveOriginPersistence: EffectiveOriginPersistence = EffectiveOriginPersistence(),
        tailscaleRecordPersistence: TailscaleShareRecordPersistence = TailscaleShareRecordPersistence(),
        openTunnelRecordPersistence: OpenTunnelRouteRecordPersistence = OpenTunnelRouteRecordPersistence()
    ) {
        if defaults === UserDefaults.standard { Self.migrateLegacyDefaults(into: defaults) }
        self.persistence = persistence
        self.credentialService = CredentialService(store: secretStore)
        self.defaults = defaults
        self.processSupervisor = processSupervisor
        self.externalDiscovery = externalDiscovery
        self.discoveryPreferencesPersistence = discoveryPreferencesPersistence
        self.originReachabilityChecker = originReachabilityChecker
        self.managedConnectorInspector = managedConnectorInspector
        self.effectiveOriginPersistence = effectiveOriginPersistence
        self.tailscaleRecordPersistence = tailscaleRecordPersistence
        self.tailscaleRecords = tailscaleRecordPersistence.load()
        self.openTunnelRecordPersistence = openTunnelRecordPersistence
        self.openTunnelRecords = openTunnelRecordPersistence.load()
        self.openTunnelHostname = OpenTunnel.hostname()
        self.discoveryPreferences = (try? discoveryPreferencesPersistence.load()) ?? DiscoveryPreferencesState()
        let loadedDefinitions: [TunnelDefinition]
        var loadFailed = false
        do {
            loadedDefinitions = try persistence.load()
            self.persistenceLoadError = nil
        } catch {
            loadedDefinitions = []
            loadFailed = true
            self.persistenceLoadError = error.localizedDescription
        }
        self.definitions = loadedDefinitions
        self.accountID = defaults.string(forKey: "cloudflareAccountID") ?? ""
        self.customCloudflaredPath = defaults.string(forKey: "cloudflaredPath") ?? ""
        self.customTailscalePath = defaults.string(forKey: "tailscalePath") ?? ""
        self.autoCopyPublicURL = defaults.object(forKey: "autoCopyPublicURL") as? Bool ?? true
        self.notifyWhenReady = defaults.object(forKey: "notifyWhenReady") as? Bool ?? true
        self.notifyOnFailure = defaults.object(forKey: "notifyOnFailure") as? Bool ?? true
        self.notifyCollaboration = defaults.object(forKey: "notifyCollaboration") as? Bool ?? true
        self.collaborationHostName = defaults.string(forKey: "collaborationHostName") ?? ""
        // A preset as an earlier version set it becomes the preset as it is now.
        self.agentCommand = AgentPreset.upgraded(defaults.string(forKey: "agentCommand") ?? "")
        self.agentRunsAutomatically = defaults.object(forKey: "agentRunsAutomatically") as? Bool ?? false
        self.agentModels = defaults.dictionary(forKey: "agentModels") as? [String: String] ?? [:]
        self.apiEnabled = defaults.object(forKey: "apiEnabled") as? Bool ?? false
        self.apiPort = (defaults.object(forKey: "apiPort") as? Int).flatMap { (1024...65_535).contains($0) ? $0 : nil } ?? 47777
        self.apiAllowsPublishingWithoutAsking = defaults.object(forKey: "apiAllowsPublishingWithoutAsking") as? Bool ?? false
        self.webhookEndpoints = Self.loadWebhookEndpoints(defaults: defaults)
        self.dockVisibility = defaults.string(forKey: "dockVisibility").flatMap(DockVisibility.init(rawValue:)) ?? .always
        self.defaultShareKind = defaults.string(forKey: "defaultShareKind").flatMap(TunnelKind.init(rawValue:)) ?? .quick
        self.defaultShareDuration = defaults.string(forKey: "defaultShareDuration").flatMap(ShareDuration.init(rawValue:)) ?? .never
        self.restartCrashedTunnels = defaults.object(forKey: "restartCrashedTunnels") as? Bool ?? true
        self.allowUnconfirmedAutomation = defaults.object(forKey: "allowUnconfirmedAutomation") as? Bool ?? false
        self.globalHotKeysEnabled = defaults.object(forKey: "globalHotKeysEnabled") as? Bool ?? false
        // Only brand-new users see the setup assistant; any sign of prior use counts as set up.
        let isExistingInstall = !loadedDefinitions.isEmpty
            || loadFailed
            || defaults.string(forKey: "cloudflareAccountID")?.isEmpty == false
            || defaults.string(forKey: "cloudflaredPath")?.isEmpty == false
        self.hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? isExistingInstall
        let restoredSelection = defaults.string(forKey: "selectedTunnelID").flatMap(UUID.init(uuidString:))
        self.selectedID = restoredSelection.flatMap { id in definitions.contains(where: { $0.id == id }) ? id : nil } ?? definitions.first?.id
        for persisted in (try? effectiveOriginPersistence.load()) ?? [] where definitions.contains(where: { $0.id == persisted.tunnelID }) {
            effectiveOrigins[persisted.tunnelID] = EffectiveOrigin(
                url: persisted.url,
                source: .lastKnownLiveConnector,
                updatedAt: persisted.verifiedAt
            )
        }
        if let persistenceLoadError {
            self.notice = AppNotice(.error, "Saved tunnels could not be read. OpenTraffic will not overwrite them: \(persistenceLoadError)")
        }
        if !hasCompletedOnboarding { presentedSheet = .onboarding }

        processSupervisor.onLogs = { [weak self] id, generation, entries in
            self?.receive(entries: entries, for: id, generation: generation)
        }
        processSupervisor.onPublicURL = { [weak self] id, generation, url in
            self?.receive(publicURL: url, for: id, generation: generation)
        }
        processSupervisor.onTermination = { [weak self] id, generation, status in
            self?.processTerminated(id: id, generation: generation, status: status)
        }

        for definition in definitions {
            runtimes[definition.id] = TunnelRuntime()
            logs[definition.id] = BoundedLogBuffer()
        }
        statusPollingTask = Task { [weak self] in
            // Clean up what a previous run left behind (crash, force quit) before anything else.
            self?.terminateOrphanedConnectors()
            await self?.reconcileTailscaleShares()
            await self?.reconcileOpenTunnelRoutes()
            while !Task.isCancelled {
                await self?.refreshTailscale()
                await self?.refreshSavedRemoteStatuses()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        discoveryPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDiscoveredTunnels()
                await self?.refreshManagedStatistics()
                await self?.refreshNgrokAgents()
                await self?.refreshOpenTunnel()
                self?.enforceAutoStop()
                self?.expireAgentClaims()
                await self?.startTunnelsWhoseServicesAreRunning()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        healthPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAllHealth()
                try? await Task.sleep(for: .seconds(45))
            }
        }
        startWatchingLocalServices()
        startTrustedChannel()
        webhookDispatcher.setEndpoints(webhookEndpoints)
        webhookDispatcher.setStatusHandler { [weak self] id, status in
            Task { @MainActor in self?.webhookStatuses[id] = status }
        }
        Task { [weak self] in await self?.applyAPISettings() }
        refreshAPITokenPresence()
        Task { [weak self] in
            guard let self else { return }
            switch await self.credentialService.authenticationCapability() {
            case .biometrics: self.sessionUnlockLabel = "Unlock with Touch ID"
            case .deviceAuthentication: self.sessionUnlockLabel = "Unlock with Mac Authentication"
            case .unavailable: self.sessionUnlockLabel = "Authorize Saved Token"
            }
        }
    }

    var selectedDefinition: TunnelDefinition? {
        guard let selectedID else { return nil }
        return definitions.first(where: { $0.id == selectedID })
    }

    var selectedDiscoveredTunnel: DiscoveredQuickTunnel? {
        guard let selectedID else { return nil }
        return discoveredTunnels.first(where: { $0.id == selectedID })
    }

    var runningCount: Int {
        runtimes.values.filter { $0.state == .running || $0.state == .starting }.count
    }

    var hiddenDiscoveryPreferences: [DiscoveryPreference] {
        discoveryPreferences.entries.filter(\.isHidden).sorted {
            ($0.alias ?? $0.origin ?? $0.executablePath) < ($1.alias ?? $1.origin ?? $1.executablePath)
        }
    }

    var localOriginOptions: [LocalOriginOption] {
        localOriginSections.flattened
    }

    var localOriginSections: LocalOriginResolver.OriginSections {
        LocalOriginResolver.sections(
            definitions: definitionsUsingEffectiveOrigins,
            discovered: discoveredTunnels,
            discoveredAliases: discoveredAliasMap,
            detected: detectedLocalServices.filter { !ShareSuggestions.isInfrastructure($0) }.map {
                LocalOriginOption(id: "detected:\($0.port)", name: $0.displayName, url: $0.url)
            }
        )
    }

    var detectedLocalServices: [DiscoveredLocalService] = []
    var isScanningLocalServices = false
    @ObservationIgnored private var localServiceTracker = LocalServiceUptimeTracker()
    @ObservationIgnored private var localServiceScanInFlight = false
    @ObservationIgnored private var lastLocalServiceScan = Date.distantPast
    /// Views showing the Ready to Share list right now; while any are, the list refreshes every few seconds.
    @ObservationIgnored private var localServiceWatchers: Set<String> = []
    @ObservationIgnored private var localServicesTask: Task<Void, Never>?
    static let watchedLocalServiceInterval: TimeInterval = 4
    static let backgroundLocalServiceInterval: TimeInterval = 60

    /// Rescans local servers. `showsProgress` is for scans the user asked for; the regular refresh is quiet.
    func scanLocalServices(showsProgress: Bool = true) async {
        guard !localServiceScanInFlight else { return }
        localServiceScanInFlight = true
        if showsProgress { isScanningLocalServices = true }
        defer {
            localServiceScanInFlight = false
            if showsProgress { isScanningLocalServices = false }
        }
        var scan = await LocalServiceScanner().scan()
        if let ports = DemoCapture.demoPorts { scan = scan.filter { ports.contains($0.port) } }
        let services = localServiceTracker.update(with: scan)
        lastLocalServiceScan = Date()
        if services != detectedLocalServices { detectedLocalServices = services }
    }

    /// Marks a view as showing local services (or not anymore). Becoming visible refreshes right away.
    func setLocalServicesWatched(_ watched: Bool, by watcher: String) {
        if watched {
            guard localServiceWatchers.insert(watcher).inserted,
                  Date().timeIntervalSince(lastLocalServiceScan) >= 2 else { return }
            Task { await scanLocalServices(showsProgress: false) }
        } else {
            localServiceWatchers.remove(watcher)
        }
    }

    /// Keeps the list of local servers current, so servers that stop answering drop off and uptimes
    /// reset after downtime: every few seconds while the list is on screen, once a minute otherwise.
    private func startWatchingLocalServices() {
        localServicesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let interval = self.localServiceWatchers.isEmpty ? Self.backgroundLocalServiceInterval : Self.watchedLocalServiceInterval
                if Date().timeIntervalSince(self.lastLocalServiceScan) >= interval {
                    await self.scanLocalServices(showsProgress: false)
                }
            }
        }
    }

    var selectedLocalOriginSeed: LocalOriginOption? {
        LocalOriginResolver.pickerSeed(
            selected: LocalOriginResolver.selectedSeed(
                selectedID: selectedID,
                definitions: definitionsUsingEffectiveOrigins,
                discovered: discoveredTunnels,
                discoveredAliases: discoveredAliasMap
            ),
            options: localOriginOptions
        )
    }

    var cloudflaredPath: URL? {
        _ = toolsRevision
        return ExecutableLocator.resolve(.cloudflare, customPath: customCloudflaredPath)
    }

    func effectiveOrigin(for definition: TunnelDefinition) -> EffectiveOrigin {
        EffectiveOriginResolver.resolve(
            savedURL: definition.localURL,
            cached: effectiveOrigins[definition.id]
        )
    }

    func runtime(for id: UUID) -> TunnelRuntime {
        runtimes[id] ?? TunnelRuntime()
    }

    func logEntries(for id: UUID) -> [TunnelLogEntry] {
        logs[id]?.entries ?? []
    }

    func errorLogCount(for id: UUID) -> Int {
        logs[id]?.errorCount ?? 0
    }

    // MARK: Presentation

    func displayState(for definition: TunnelDefinition) -> TunnelDisplayState {
        let runtime = runtime(for: definition.id)
        return TunnelDisplayState.resolve(
            health: overallHealth(for: definition),
            connector: runtime.state,
            hasError: runtime.lastError != nil
        )
    }

    func publicURL(for definition: TunnelDefinition) -> String? {
        runtime(for: definition.id).publicURL
            ?? definition.hostname?.nilIfBlank.map { "https://\($0)" }
            ?? lastKnownTailscaleURL(for: definition)
            ?? lastKnownOpenTunnelURL(for: definition)
    }

    func isActive(_ id: UUID) -> Bool {
        let state = runtime(for: id).state
        return state == .running || state == .starting
    }

    /// Detected services that no running tunnel publishes yet.
    var shareableLocalServices: [DiscoveredLocalService] {
        let active = definitions
            .filter { [.running, .starting, .stopping].contains(runtime(for: $0.id).state) }
            .map { effectiveOrigin(for: $0).url }
            + discoveredTunnels.map(\.localURL)
        return ShareSuggestions.unshared(detectedLocalServices, activeOrigins: active)
    }

    /// One-step sharing: reuse a saved Quick Tunnel for the port or create one, then start it.
    func share(_ service: DiscoveredLocalService, kind: TunnelKind = .quick) {
        if let existing = ShareSuggestions.existingTunnel(for: service, kind: kind, in: definitions) {
            startSharing(existing)
        } else {
            do {
                let definition = switch kind {
                case .tailscale: try addTailscale(name: service.displayName, localURL: service.url, isPublic: false)
                case .ngrok: try addNgrok(name: service.displayName, localURL: service.url, domain: nil)
                case .opentunnel: try addOpenTunnel(name: service.displayName, localURL: service.url)
                default: try addQuick(name: service.displayName, localURL: service.url)
                }
                startSharing(definition)
            } catch {
                notice = AppNotice(.error, error.localizedDescription)
            }
        }
    }

    /// Starts a tunnel and copies its public URL once cloudflared reports it.
    func startSharing(_ definition: TunnelDefinition) {
        selectedID = definition.id
        setAutoStop(definition.id, after: defaultShareDuration)
        if autoCopyPublicURL { pendingAutoCopy.insert(definition.id) }
        start(definition)
        // start() returns early when the tunnel can't start right now; don't leave a copy pending.
        if runtime(for: definition.id).state != .starting { pendingAutoCopy.remove(definition.id) }
        // Custom domains know their URL up front.
        if !definition.kind.hasEphemeralURL, runtime(for: definition.id).state != .failed,
           pendingAutoCopy.remove(definition.id) != nil, let url = publicURL(for: definition) {
            copy(url, feedbackFor: definition.id)
        }
    }

    func copyPublicURL(_ id: UUID) {
        if let definition = definitions.first(where: { $0.id == id }), let url = publicURL(for: definition) {
            copy(url, feedbackFor: id)
        } else if let tunnel = discoveredTunnels.first(where: { $0.id == id }) {
            copy(tunnel.publicURL, feedbackFor: id)
        }
    }

    func copy(_ text: String, feedbackFor id: UUID) {
        Pasteboard.copy(text)
        recentlyCopiedID = id
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.recentlyCopiedID = nil
        }
    }

    /// Stops cloudflared/ngrok processes a previous OpenTraffic run started and lost. Each is
    /// re-verified by PID and start time right before it's signalled.
    func terminateOrphanedConnectors() {
        let provider = MacProcessSnapshotProvider(executableNames: ["cloudflared", "ngrok"])
        let orphans = OrphanedConnectorDetector.orphans(
            in: provider.snapshots(),
            currentRunDirectory: processSupervisor.runDirectory
        )
        guard !orphans.isEmpty else { return }
        let current = Set(provider.snapshots().map(\.identity))
        var stopped = 0
        for orphan in orphans where current.contains(orphan.identity) {
            if Darwin.kill(orphan.identity.pid, SIGTERM) == 0 { stopped += 1 }
        }
        if stopped > 0 {
            notice = AppNotice(.info, "Stopped \(stopped) connector\(stopped == 1 ? "" : "s") left running by a previous OpenTraffic session.")
        }
    }

    func toggle(_ definition: TunnelDefinition) {
        switch runtime(for: definition.id).state {
        case .running, .starting: stop(definition.id)
        case .stopped, .failed: startSharing(definition)
        case .stopping: break
        }
    }

    /// Presents a sheet unless one is already open; replacing it would discard in-progress work.
    func present(_ sheet: PresentedSheet) {
        guard presentedSheet == nil else { return }
        presentedSheet = sheet
    }

    func recordRequests(_ statistics: TunnelStatistics?, for id: UUID) {
        guard let total = statistics?.totalRequests else { return }
        let previous = requestHistory[id]?.samples.last?.total
        requestHistory[id, default: RequestHistory()].record(total: total)
        if let previous, total > previous { pulseTraffic() }
    }

    /// Blinks the menu bar icon once; repeated traffic within the blink just extends it.
    private func pulseTraffic() {
        trafficPulse = true
        trafficPulseTask?.cancel()
        trafficPulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.trafficPulse = false
        }
    }

    @discardableResult
    func addQuick(name: String, localURL: String, collaboration: Bool = false) throws -> TunnelDefinition {
        try validateLocalURL(localURL)
        let definition = TunnelDefinition(
            name: name.nilIfBlank ?? "Local site",
            kind: .quick,
            localURL: localURL,
            collaboration: collaboration
        )
        definitions.append(definition)
        runtimes[definition.id] = TunnelRuntime()
        logs[definition.id] = BoundedLogBuffer()
        selectedID = definition.id
        saveDefinitions()
        return definition
    }

    /// A public share through the user's ngrok account; `domain` empty means their default domain.
    @discardableResult
    func addNgrok(name: String, localURL: String, domain: String?) throws -> TunnelDefinition {
        try validateLocalURL(localURL)
        let definition = TunnelDefinition(
            name: name.nilIfBlank ?? "Local site",
            kind: .ngrok,
            localURL: localURL,
            hostname: domain?.nilIfBlank.map(NgrokSupport.host(from:))
        )
        definitions.append(definition)
        runtimes[definition.id] = TunnelRuntime()
        logs[definition.id] = BoundedLogBuffer()
        selectedID = definition.id
        saveDefinitions()
        return definition
    }

    /// A share of a local service on this Mac's Tailscale name: private to the tailnet, or public through Funnel.
    @discardableResult
    func addTailscale(name: String, localURL: String, isPublic: Bool) throws -> TunnelDefinition {
        try validateLocalURL(localURL)
        let definition = TunnelDefinition(
            name: name.nilIfBlank ?? "Local site",
            kind: .tailscale,
            localURL: localURL,
            tailscalePublic: isPublic
        )
        definitions.append(definition)
        runtimes[definition.id] = TunnelRuntime()
        logs[definition.id] = BoundedLogBuffer()
        selectedID = definition.id
        saveDefinitions()
        return definition
    }

    func remove(_ id: UUID) {
        endBranchSessionNow(for: id)
        invalidateAndStop(id)
        unsavedComments.remove(id)
        feedbackPersistence.delete(id)
        collabComments[id] = nil
        stopAgentRun(for: id)
        agentQueues[id] = nil
        agentHolds[id] = nil
        agentRuns[id] = nil
        agentClaims.releaseAll(share: id)
        if let definition = definitions.first(where: { $0.id == id }) {
            let origins = Set([definition.localURL, effectiveOrigin(for: definition).url])
            for origin in origins {
                let cacheIdentity = SitePreviewService.cacheIdentity(
                    identity: "managed:\(id.uuidString)",
                    originURL: origin
                )
                SitePreviewService.shared.remove(identity: cacheIdentity)
            }
        }
        definitions.removeAll { $0.id == id }
        SharePasswordStore.deletePassword(for: id)
        runtimes[id] = nil
        logs[id] = nil
        requestHistory[id] = nil
        autoStopDeadlines[id] = nil
        remoteStatuses[id] = nil
        effectiveOrigins[id] = nil
        saveEffectiveOrigins()
        if selectedID == id { selectedID = definitions.first?.id }
        saveDefinitions()
    }

    func rename(_ id: UUID, to proposedName: String) {
        guard let name = proposedName.nilIfBlank,
              let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].name = name
        saveDefinitions()
    }

    func discoveredDisplayName(_ tunnel: DiscoveredQuickTunnel) -> String {
        discoveryPreference(for: tunnel.preferenceKey)?.alias?.nilIfBlank
            ?? tunnel.publicURL.replacingOccurrences(of: "https://", with: "")
    }

    func hasDiscoveryAlias(_ tunnel: DiscoveredQuickTunnel) -> Bool {
        discoveryPreference(for: tunnel.preferenceKey)?.alias?.nilIfBlank != nil
    }

    func renameDiscovered(_ tunnel: DiscoveredQuickTunnel, to proposedName: String) {
        updateDiscoveryPreference(for: tunnel) { preference in
            preference.alias = proposedName.nilIfBlank
        }
    }

    func hideDiscovered(_ tunnel: DiscoveredQuickTunnel) {
        updateDiscoveryPreference(for: tunnel) { $0.isHidden = true }
        discoveredTunnels.removeAll { $0.preferenceKey == tunnel.preferenceKey }
        if selectedID == tunnel.id { selectedID = definitions.first?.id ?? discoveredTunnels.first?.id }
    }

    func restoreDiscoveredPreference(_ key: String) {
        guard let index = discoveryPreferences.entries.firstIndex(where: { $0.key == key }) else { return }
        discoveryPreferences.entries[index].isHidden = false
        saveDiscoveryPreferences()
        Task { await refreshDiscoveredTunnels() }
    }

    func start(_ definition: TunnelDefinition) {
        guard !isTerminating else { return }
        guard let executable = executablePath(for: definition.kind.provider) else {
            setFailure(missingExecutableMessage(for: definition.kind.provider), for: definition.id)
            return
        }
        if !definition.kind.usesCloudflareAccount {
            do {
                try validateLocalURL(definition.localURL)
            } catch {
                setFailure(error.localizedDescription, for: definition.id)
                return
            }
        }

        var runtime = runtime(for: definition.id)
        guard runtime.state != .running, runtime.state != .starting, runtime.state != .stopping else { return }
        runtime.generation &+= 1
        runtime.state = .starting
        runtime.lastError = nil
        runtime.publicURL = definition.kind.hasEphemeralURL ? nil : definition.hostname.map { "https://\($0)" }
        runtime.startedAt = Date()
        runtimes[definition.id] = runtime
        let generation = runtime.generation

        switch definition.kind {
        case .quick:
            if quickNeedsProxy(definition) {
                Task { [weak self] in
                    await self?.startQuickWithProxy(definition, generation: generation, executable: executable)
                }
            } else {
                startQuickConnector(definition, localURL: definition.localURL, generation: generation, executable: executable)
            }
        case .remote:
            Task { [weak self] in
                await self?.startRemote(definition, generation: generation, executable: executable)
            }
        case .tailscale:
            Task { [weak self] in
                await self?.startTailscale(definition, generation: generation, executable: executable)
            }
        case .ngrok:
            startNgrok(definition, generation: generation, executable: executable)
        case .opentunnel:
            Task { [weak self] in
                await self?.startOpenTunnel(definition, generation: generation, executable: executable)
            }
        }
        Task { [weak self] in await self?.refreshHealth(for: definition.id) }
    }

    func startQuickConnector(_ definition: TunnelDefinition, localURL: String, generation: UInt64, executable: URL) {
        do {
            try processSupervisor.startQuick(
                id: definition.id,
                generation: generation,
                executable: executable,
                localURL: localURL,
                hostHeader: definition.rewriteHostHeader ? definition.originHostHeader : nil
            )
        } catch {
            setFailure(error.localizedDescription, for: definition.id, generation: generation)
        }
    }

    /// Stops a share. `endingSession: false` (a restart) keeps its branch going.
    func stop(_ id: UUID, endingSession: Bool = true) {
        autoStartTracker.userStopped(id)
        stopCollaboration(id)
        if endingSession { Task { await endBranchSession(for: id) } }
        pendingRestarts.remove(id)
        guard var runtime = runtimes[id] else { return }
        if isActive(id), let share = apiShareRef(id) { apiEvents.append(.shareStopped, share: share) }
        runtime.generation &+= 1
        runtime.state = .stopping
        if definitions.first(where: { $0.id == id })?.kind.hasEphemeralURL == true {
            runtime.publicURL = nil
        }
        runtime.metricsPort = nil
        runtime.statistics = nil
        runtimes[id] = runtime
        requestHistory[id] = nil
        pendingAutoCopy.remove(id)
        autoStopDeadlines[id] = nil
        markEffectiveOriginLastKnown(id: id)
        if let provider = definitions.first(where: { $0.id == id })?.kind.provider, provider == .tailscale || provider == .opentunnel {
            let generation = runtime.generation
            Task { [weak self] in
                if provider == .tailscale {
                    await self?.removeTailscaleShare(for: id)
                } else {
                    await self?.removeOpenTunnelRoute(for: id)
                }
                guard let self, var current = self.runtimes[id], current.generation == generation else { return }
                current.state = .stopped
                self.runtimes[id] = current
                await self.refreshHealth(for: id)
            }
            return
        }
        processSupervisor.stop(id: id)
        if !processSupervisor.isRunning(id: id) {
            runtime.state = .stopped
            runtimes[id] = runtime
        }
        Task { [weak self] in await self?.refreshHealth(for: id) }
    }

    func stopAll(completion: (() -> Void)? = nil) {
        isTerminating = true
        pendingRestarts.removeAll()
        stopAllCollaboration()
        stopAllAgentRuns()
        for definition in definitions where definition.branchSession != nil { endBranchSessionNow(for: definition.id) }
        if let server = apiServer {
            apiServer = nil
            Task { await server.stop() }
        }
        if let channel = trustedChannel {
            trustedChannel = nil
            Task { await channel.stop() }
        }
        for task in [statusPollingTask, discoveryPollingTask, healthPollingTask, localServicesTask] { task?.cancel() }
        for id in definitions.map(\.id) {
            if var runtime = runtimes[id], runtime.state != .stopped {
                runtime.generation &+= 1
                runtime.state = .stopped
                runtimes[id] = runtime
            }
        }
        // Tailscale shares and OpenTunnel routes live in their own services, not in a child
        // process, so remove them explicitly.
        Task { [weak self] in
            await self?.removeAllTailscaleShares()
            await self?.removeAllOpenTunnelRoutes()
            self?.processSupervisor.shutdown(completion: completion ?? {})
        }
    }

    func clearLogs(_ id: UUID) {
        logs[id]?.removeAll()
    }

    func preflightLocalOrigin(_ url: String) async -> LocalOriginReachability {
        await originReachabilityChecker.check(url)
    }

    func health(for id: UUID) -> TunnelHealth? {
        tunnelHealth[id]
    }

    func overallHealth(for definition: TunnelDefinition) -> TunnelHealthState {
        if let health = tunnelHealth[definition.id] {
            return TunnelHealthEvaluator.overall(checks: health.checks)
        }
        switch runtime(for: definition.id).state {
        case .failed:
            return .failed
        case .running, .starting, .stopping:
            return .working
        case .stopped:
            return runtime(for: definition.id).lastError == nil ? .stopped : .failed
        }
    }

    var needsAttention: Bool {
        definitions.contains { displayState(for: $0) == .attention }
    }

    var menuBarState: MenuBarIconState {
        let active = definitions.filter { displayState(for: $0).isActive }.count + discoveredTunnels.count
        return MenuBarIconState.resolve(activeTunnels: active, needsAttention: needsAttention)
    }

    func clearError(_ id: UUID) {
        guard var runtime = runtimes[id] else { return }
        runtime.lastError = nil
        if runtime.state == .failed { runtime.state = .stopped }
        runtimes[id] = runtime
        Task { [weak self] in await self?.refreshHealth(for: id) }
    }

    func refreshHealth(for id: UUID) async {
        guard let definition = definitions.first(where: { $0.id == id }) else { return }
        let runtime = runtime(for: id)
        var checks: [TunnelHealthCheck] = []
        switch runtime.state {
        case .running:
            checks.append(TunnelHealthCheck(kind: .connector, state: .ok, detail: runningConnectorDetail(for: definition)))
        case .starting:
            checks.append(TunnelHealthCheck(kind: .connector, state: .working, detail: runtime.startupNote ?? "Connector starting"))
        case .stopping:
            checks.append(TunnelHealthCheck(kind: .connector, state: .working, detail: "Connector stopping"))
        case .stopped:
            if let error = runtime.lastError {
                checks.append(TunnelHealthCheck(kind: .connector, state: .failed, detail: error))
            } else {
                checks.append(TunnelHealthCheck(kind: .connector, state: .skipped, detail: "Stopped. Start the tunnel to serve traffic."))
            }
        case .failed:
            checks.append(TunnelHealthCheck(kind: .connector, state: .failed, detail: runtime.lastError ?? "Connector failed."))
        }
        let quietlyStopped = (runtime.state == .stopped || runtime.state == .stopping) && runtime.lastError == nil
        if quietlyStopped {
            checks.append(TunnelHealthCheck(kind: .localOrigin, state: .skipped, detail: "Stopped"))
            if definition.kind.usesCloudflareAccount {
                checks.append(TunnelHealthCheck(kind: .edge, state: .skipped, detail: "Stopped"))
                checks.append(TunnelHealthCheck(kind: .dns, state: .skipped, detail: "Stopped"))
            } else if definition.kind.reportsEdgeStatus {
                checks.append(TunnelHealthCheck(kind: .edge, state: .skipped, detail: "Stopped"))
            } else {
                checks.append(TunnelHealthCheck(kind: .edge, state: .skipped, detail: noEdgeStatusDetail(for: definition.kind)))
            }
            checks.append(TunnelHealthCheck(kind: .publicSite, state: .skipped, detail: "Stopped"))
            tunnelHealth[id] = TunnelHealth(checks: checks)
            return
        }
        // While a share is starting, its provider takes a moment to answer; that's not a failure yet.
        let isNew = runtime.startedAt.map { Date().timeIntervalSince($0) < Self.newHostnameGracePeriod } ?? false
        var localStatus: Int?
        switch await originReachabilityChecker.check(effectiveOrigin(for: definition).url) {
        case .reachable(let statusCode):
            localStatus = statusCode
            checks.append(TunnelHealthCheck(kind: .localOrigin, state: .ok, detail: "Local service responded with HTTP \(statusCode)."))
        case .invalid(let message):
            checks.append(TunnelHealthCheck(kind: .localOrigin, state: .failed, detail: message))
        case .unreachable(let message):
            checks.append(TunnelHealthCheck(kind: .localOrigin, state: .failed, detail: message))
        }
        if definition.kind.usesCloudflareAccount {
            switch remoteStatuses[id] ?? .unknown {
            case .healthy:
                checks.append(TunnelHealthCheck(kind: .edge, state: .ok, detail: "Cloudflare reports the tunnel healthy."))
            case .degraded:
                checks.append(TunnelHealthCheck(kind: .edge, state: .working, detail: "Cloudflare reports the tunnel as degraded."))
            case .inactive:
                checks.append(TunnelHealthCheck(kind: .edge, state: .failed, detail: "Cloudflare reports the tunnel as inactive. The connector may not have registered yet."))
            case .down:
                checks.append(TunnelHealthCheck(kind: .edge, state: .failed, detail: "Cloudflare reports the tunnel as down."))
            case .unknown:
                checks.append(TunnelHealthCheck(kind: .edge, state: .skipped, detail: "Cloudflare status unavailable. Unlock your API token to check."))
            }
        } else if definition.kind.provider == .tailscale {
            checks.append(tailscaleEdgeCheck(for: definition))
        } else if definition.kind == .opentunnel {
            checks.append(openTunnelEdgeCheck(for: definition))
        } else {
            checks.append(TunnelHealthCheck(kind: .edge, state: .skipped, detail: noEdgeStatusDetail(for: definition.kind)))
        }
        let siteHostname: String? = definition.kind.usesCloudflareAccount ? definition.hostname?.nilIfBlank : nil
        if let hostname = siteHostname {
            if let exists = await SiteHealthChecker.probeDNS(hostname) {
                if exists {
                    checks.append(TunnelHealthCheck(kind: .dns, state: .ok, detail: "DNS resolves \(hostname)."))
                } else {
                    checks.append(TunnelHealthCheck(kind: .dns, state: .failed, detail: "No DNS record found for \(hostname). Finish Setup to create it."))
                }
            } else {
                checks.append(TunnelHealthCheck(kind: .dns, state: .skipped, detail: "Could not verify DNS."))
            }
        } else if definition.kind.hasEphemeralURL {
            checks.append(TunnelHealthCheck(kind: .dns, state: .skipped, detail: "\(definition.kind.provider.title) manages this hostname; no DNS record is needed."))
        } else if definition.kind.provider == .tailscale {
            checks.append(TunnelHealthCheck(kind: .dns, state: .skipped, detail: "Tailscale provides this MagicDNS name; no DNS record is needed."))
        } else if definition.kind == .opentunnel {
            checks.append(TunnelHealthCheck(kind: .dns, state: .skipped, detail: "OpenTunnel's wildcard name covers every route; no DNS record is needed."))
        } else {
            checks.append(TunnelHealthCheck(kind: .dns, state: .skipped, detail: "This tunnel has no saved hostname."))
        }
        let siteURLString: String? = runtime.publicURL ?? siteHostname.map { "https://\($0)" }
        if runtime.state != .running {
            checks.append(TunnelHealthCheck(kind: .publicSite, state: .skipped, detail: "Start the tunnel to check the public site."))
        } else if let siteURLString, let siteURL = URL(string: siteURLString) {
            let host = siteURL.host ?? siteURLString
            // A brand-new Quick Tunnel hostname takes a few seconds to appear in DNS. Asking the system
            // resolver too early makes macOS cache "not found" for minutes, so check public DNS first.
            if definition.kind.hasEphemeralURL, await SiteHealthChecker.probeDNS(host) == false {
                checks.append(TunnelHealthCheck(
                    kind: .publicSite,
                    state: isNew ? .working : .failed,
                    detail: isNew ? "Waiting for the new hostname to appear in DNS…" : "\(host) doesn't resolve in public DNS."
                ))
                if isNew { scheduleHealthRecheck(id) }
                tunnelHealth[id] = TunnelHealth(checks: checks)
                return
            }
            let probe = await SiteHealthChecker.probePublicSite(siteURL)
            let framework = PublicSiteBlockDetector.blockingFramework(probe: probe)
            if definition.protection.isProtected, let statusCode = probe.statusCode,
               statusCode == 401 || (200..<400).contains(statusCode) {
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .ok, detail: "Reachable. Visitors must sign in first (HTTP \(statusCode))."))
            } else if let framework, let hint = PublicSiteBlockDetector.hint(hostname: host, probe: probe) {
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .failed, detail: hint, remedy: .hostBlocked(framework)))
            } else if let statusCode = probe.statusCode, (200..<400).contains(statusCode) {
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .ok, detail: "Public site returned HTTP \(statusCode)."))
            } else if let statusCode = probe.statusCode, statusCode == localStatus, !PublicSiteBlockDetector.isProviderError(probe: probe) {
                // The app's own answer (an API with nothing at /, say) came through the tunnel.
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .ok, detail: "Reachable. It answers the same as the local server (HTTP \(statusCode))."))
            } else if probe.statusCode != nil, isNew {
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .working, detail: "Waiting for \(definition.kind.provider.title) to start answering…"))
                scheduleHealthRecheck(id)
            } else if let hint = PublicSiteBlockDetector.hint(hostname: host, probe: probe) {
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .failed, detail: hint))
            } else if isNew {
                checks.append(TunnelHealthCheck(
                    kind: .publicSite,
                    state: .working,
                    detail: definition.kind.provider == .tailscale
                        ? "Waiting for Tailscale to issue the HTTPS certificate…"
                        : "Waiting for the public site to become reachable…"
                ))
                scheduleHealthRecheck(id)
            } else if probe.hostNotFound, await SiteHealthChecker.probeDNS(host) == true {
                // Public DNS has the name, but macOS cached "not found" from an earlier lookup (often
                // before the record existed). Everyone else can open it; this Mac catches up by itself.
                checks.append(TunnelHealthCheck(
                    kind: .publicSite,
                    state: .working,
                    detail: "\(host) is in public DNS, but this Mac still remembers an older \"not found\" answer. Others can open it now; this Mac catches up within minutes."
                ))
            } else {
                checks.append(TunnelHealthCheck(kind: .publicSite, state: .failed, detail: probe.transportError ?? "Could not reach the public site. DNS may still be propagating."))
            }
        } else {
            checks.append(TunnelHealthCheck(kind: .publicSite, state: .skipped, detail: "No public URL yet."))
        }
        // Cloudflare's tunnel status is cached and lags a fresh start. If the public site already answers
        // through the tunnel, it's serving; while starting, "inactive" just means "not registered yet".
        if definition.kind.usesCloudflareAccount, let edge = checks.firstIndex(where: { $0.kind == .edge }), checks[edge].state == .failed {
            if checks.contains(where: { $0.kind == .publicSite && $0.state == .ok }) {
                checks[edge] = TunnelHealthCheck(kind: .edge, state: .ok, detail: "Serving traffic. Cloudflare's dashboard status catches up shortly.")
            } else if isNew {
                checks[edge] = TunnelHealthCheck(kind: .edge, state: .working, detail: "Registering with Cloudflare…")
                scheduleHealthRecheck(id)
            }
        }
        tunnelHealth[id] = TunnelHealth(checks: checks)
    }

    /// How long a freshly started tunnel's public hostname gets before reachability failures count.
    private static let newHostnameGracePeriod: TimeInterval = 120

    /// Rechecks soon, at most once at a time per tunnel, while a share starts or a new hostname propagates:
    /// every second at first (see `HealthRecheck`), so the app shows a share online as soon as it is.
    private func scheduleHealthRecheck(_ id: UUID) {
        guard scheduledHealthRechecks.insert(id).inserted else { return }
        let elapsed = runtime(for: id).startedAt.map { Date().timeIntervalSince($0) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(HealthRecheck.delay(sinceStart: elapsed)))
            self?.scheduledHealthRechecks.remove(id)
            await self?.refreshHealth(for: id)
        }
    }

    func refreshAllHealth() async {
        await withTaskGroup(of: Void.self) { group in
            for id in definitions.map(\.id) {
                group.addTask { [weak self] in await self?.refreshHealth(for: id) }
            }
        }
    }

    private func refreshHealthForAccount(_ account: String) async {
        let ids = definitions
            .filter { $0.kind.usesCloudflareAccount && $0.accountID == account }
            .map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in await self?.refreshHealth(for: id) }
            }
        }
    }

    func validateTunnelLocalURL(_ value: String, kind: TunnelKind) -> String? {
        do {
            try validateLocalURL(value)
            if kind.usesCloudflareAccount { _ = try CloudflareClient.ingressService(from: value) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func updateManagedTunnel(_ id: UUID, name: String, localURL: String) -> String? {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return "This tunnel no longer exists." }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Enter a name for the tunnel." }
        let trimmedURL = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = validateTunnelLocalURL(trimmedURL, kind: definitions[index].kind) { return message }
        let runtime = runtime(for: id)
        if (runtime.state == .running || runtime.state == .starting || runtime.state == .stopping),
           definitions[index].localURL != trimmedURL {
            return "Stop the tunnel to change its local service."
        }
        definitions[index].name = trimmedName
        if definitions[index].localURL != trimmedURL {
            definitions[index].localURL = trimmedURL
            effectiveOrigins[id] = nil
            saveEffectiveOrigins()
        }
        saveDefinitions()
        Task { [weak self] in await self?.refreshHealth(for: id) }
        return nil
    }

    func lookupDNSRecord(zoneID: String, hostname: String) async throws -> CloudflareDNSRecord? {
        let client = try await client(for: accountID)
        return try await client.dnsRecord(zoneID: zoneID, hostname: hostname)
    }

    private func setSetupStep(_ id: String, to state: SetupProgressState) {
        guard let index = setupProgressSteps.firstIndex(where: { $0.id == id }) else { return }
        setupProgressSteps[index].state = state
    }

    func refreshDiscoveredTunnels() async {
        // Demo captures show only the demo's own shares.
        guard DemoCapture.demoPorts == nil else { return }
        let external = await externalDiscovery.scan(excludingProcessIDs: processSupervisor.ownedProcessIDs)
        let currentlyOwned = processSupervisor.ownedProcessIDs
        let filtered = external.filter {
            !currentlyOwned.contains($0.identity.pid) && discoveryPreference(for: $0.preferenceKey)?.isHidden != true
        }
        // Assigning notifies every observer even when nothing changed; skip the common "still none" case.
        if !(discoveredTunnels.isEmpty && filtered.isEmpty) { discoveredTunnels = filtered }
        let liveIDs = Set(filtered.map(\.id))
        for tunnel in filtered { recordRequests(tunnel.statistics, for: tunnel.id) }
        for id in requestHistory.keys where !liveIDs.contains(id) && !definitions.contains(where: { $0.id == id }) {
            requestHistory[id] = nil
        }
        if let selectedID,
           definitions.allSatisfy({ $0.id != selectedID }),
           filtered.allSatisfy({ $0.id != selectedID }) {
            self.selectedID = definitions.first?.id ?? filtered.first?.id
        }
    }

    func refreshManagedStatistics() async {
        let endpoints = runtimes.compactMap { id, runtime -> (UUID, UInt16, OwnedConnectorIdentity, TunnelDefinition)? in
            guard runtime.state == .running || runtime.state == .starting,
                  let port = runtime.metricsPort,
                  let identity = processSupervisor.ownedConnectorIdentity(id: id),
                  identity.generation == runtime.generation,
                  let definition = definitions.first(where: { $0.id == id }),
                  definition.kind.provider == .cloudflare else { return nil }
            return (id, port, identity, definition)
        }
        for (id, port, identity, definition) in endpoints {
            let inspection = await managedConnectorInspector.inspect(identity: identity, metricsPort: port)
            guard var runtime = runtimes[id],
                  runtime.metricsPort == port,
                  runtime.generation == identity.generation,
                  runtime.state == .running || runtime.state == .starting,
                  processSupervisor.ownedConnectorIdentity(id: id) == identity else { continue }
            runtime.statistics = inspection?.statistics
            if runtimes[id] != runtime { runtimes[id] = runtime }
            recordRequests(inspection?.statistics, for: id)
            guard let configuration = inspection?.configuration,
                  let origin = ManagedIngressResolver.origin(
                    kind: definition.kind,
                    hostname: definition.hostname,
                    configuration: configuration
                  ) else {
                markEffectiveOriginLastKnown(id: id)
                continue
            }
            setLiveEffectiveOrigin(originBehindCollaboration(origin, for: definition), for: id)
        }
    }

    func manageInOpenTraffic(_ external: DiscoveredQuickTunnel) async {
        guard let localURL = external.localURL else {
            notice = AppNotice(.error, "OpenTraffic could not determine this tunnel's local service, so it cannot safely restart it.")
            return
        }
        guard persistenceLoadError == nil else {
            notice = AppNotice(.error, "Saved tunnels are unreadable, so OpenTraffic will not stop an external process it cannot safely persist.")
            return
        }
        guard cloudflaredPath != nil else {
            notice = AppNotice(.error, OpenTrafficError.cloudflaredMissing.localizedDescription, actionTitle: "Open Settings", action: .openSettings)
            return
        }
        do {
            try validateLocalURL(localURL)
        } catch {
            notice = AppNotice(.error, error.localizedDescription)
            return
        }
        guard discoveredTunnels.contains(where: { $0.identity == external.identity }) else {
            notice = AppNotice(.warning, "The external tunnel changed or disappeared. Nothing was stopped.")
            return
        }
        guard externalAdoptionsInProgress.insert(external.identity).inserted else {
            notice = AppNotice(.info, "OpenTraffic is already moving this external tunnel.")
            return
        }
        defer { externalAdoptionsInProgress.remove(external.identity) }
        do {
            try await externalDiscovery.stopVerified(external.identity)
            discoveredTunnels.removeAll { $0.identity == external.identity }
            let added = try addQuick(name: discoveredDisplayName(external), localURL: localURL)
            guard let definition = definitions.first(where: { $0.id == added.id }) else {
                notice = AppNotice(.warning, "The external process stopped and the tunnel was saved, but it could not be started automatically.")
                return
            }
            start(definition)
            let runtime = runtime(for: definition.id)
            if runtime.state == .failed {
                notice = AppNotice(.error, "The external process stopped and the tunnel was saved, but it failed to start: \(runtime.lastError ?? "Unknown error")")
            } else {
                notice = AppNotice(.success, "Now managed by OpenTraffic. A new public URL is being created.")
            }
        } catch {
            notice = AppNotice(.error, error.localizedDescription)
        }
    }

    func saveAPIToken(_ token: String, useKeychainUserPresence: Bool) async throws {
        let account = try validatedAccountID(accountID)
        guard let token = token.nilIfBlank else { throw OpenTrafficError.api("Enter an API token to save.") }
        if useKeychainUserPresence, !signingReadiness.isReadyForProtectedKeychain {
            throw SecretStoreError.protectedStorageUnavailable
        }
        try await credentialService.save(
            token,
            key: Self.apiTokenKeyPrefix + account,
            protection: useKeychainUserPresence ? .userPresence : .standard
        )
        guard accountID.nilIfBlank == account else { throw CancellationError() }
        hasSavedAPIToken = true
        isAPITokenUnlocked = true
        tokenStorageKind = useKeychainUserPresence ? .userPresence : .standard
        credentialError = nil
        requiresLegacyTokenAuthorization = false
        accessEditDenied = false
    }

    func forgetAPIToken() async throws {
        let account = try validatedAccountID(accountID)
        try await credentialService.delete(key: Self.apiTokenKeyPrefix + account)
        guard accountID.nilIfBlank == account else { throw CancellationError() }
        hasSavedAPIToken = false
        isAPITokenUnlocked = false
        tokenStorageKind = nil
        credentialError = nil
        requiresLegacyTokenAuthorization = false
        accessEditDenied = false
    }

    func hasAPIToken() -> Bool {
        hasSavedAPIToken
    }

    func migrateTokenToUserPresence() async {
        let requestedAccount = accountID
        do {
            guard signingReadiness.isReadyForProtectedKeychain else {
                throw SecretStoreError.protectedStorageUnavailable
            }
            let account = try validatedAccountID(requestedAccount)
            guard isAPITokenUnlocked, tokenStorageKind == .standard else { throw SecretStoreError.locked }
            let result = try await credentialService.migrateLegacyToUserPresence(
                key: Self.apiTokenKeyPrefix + account,
                reason: "Verify the Touch ID-protected Cloudflare token before migration"
            )
            guard accountID == requestedAccount else { return }
            tokenStorageKind = .userPresence
            credentialMigrationMessage = result == .migrated
                ? "Token migrated to Touch ID-protected Keychain storage."
                : "Protected token verified and selected. The legacy backup could not be removed and will never be used automatically."
            credentialError = nil
        } catch {
            guard accountID == requestedAccount else { return }
            credentialMigrationMessage = nil
            credentialError = error.localizedDescription
        }
    }

    func unlockAPIToken() async {
        let requestedAccount = accountID
        do {
            let account = try validatedAccountID(requestedAccount)
            let result = try await credentialService.unlock(
                key: Self.apiTokenKeyPrefix + account,
                reason: "Unlock your Cloudflare API token for this OpenTraffic session"
            )
            guard accountID == requestedAccount else { return }
            switch result {
            case .unlocked:
                hasSavedAPIToken = true
                isAPITokenUnlocked = true
                requiresLegacyTokenAuthorization = false
                credentialError = nil
            case .missing:
                throw OpenTrafficError.accountNotConfigured
            case .requiresLegacyAuthorization:
                isAPITokenUnlocked = false
                requiresLegacyTokenAuthorization = true
                credentialError = "Session authentication succeeded. This legacy token still needs one Keychain authorization for the current app build."
            }
        } catch {
            guard accountID == requestedAccount else { return }
            isAPITokenUnlocked = false
            credentialError = error.localizedDescription
        }
    }

    func authorizeLegacyAPIToken() async {
        let requestedAccount = accountID
        do {
            let account = try validatedAccountID(requestedAccount)
            let result = try await credentialService.authorizeLegacy(
                key: Self.apiTokenKeyPrefix + account,
                reason: "Authorize the saved Cloudflare token for this OpenTraffic build"
            )
            guard accountID == requestedAccount else { return }
            guard result == .unlocked else { throw OpenTrafficError.accountNotConfigured }
            isAPITokenUnlocked = true
            requiresLegacyTokenAuthorization = false
            credentialError = nil
        } catch {
            guard accountID == requestedAccount else { return }
            isAPITokenUnlocked = false
            credentialError = error.localizedDescription
        }
    }

    func refreshAccount() async {
        let requestedAccount = accountID
        isRefreshingAccount = true
        accountError = nil
        zoneError = nil
        defer { isRefreshingAccount = false }
        do {
            let client = try await client(for: requestedAccount)
            let tunnels = try await client.listTunnels()
            guard accountID == requestedAccount else { return }
            availableRemoteTunnels = tunnels
            let loadedZones: [CloudflareZone]
            do {
                loadedZones = try await client.listZones()
                guard accountID == requestedAccount else { return }
                zones = loadedZones
            } catch {
                zones = []
                zoneError = "Zones unavailable: \(error.localizedDescription) Import still works."
                loadedZones = []
            }
            var definitionsChanged = false
            var effectiveOriginsChanged = false
            for definition in definitions where definition.kind.usesCloudflareAccount && definition.accountID == requestedAccount {
                let value = tunnels.first(where: { $0.id == definition.cloudflareTunnelID })?.status
                remoteStatuses[definition.id] = RemoteTunnelStatus(apiValue: value)
                remoteStatusUpdatedAt[definition.id] = Date()
                guard let tunnelID = definition.cloudflareTunnelID, definition.hostname != nil else { continue }
                if let configuration = try? await client.tunnelConfiguration(id: tunnelID),
                   accountID == requestedAccount,
                   let index = definitions.firstIndex(where: { $0.id == definition.id }) {
                    let configuredHostnames = configuration.ingress.compactMap(\.hostname)
                    if !configuredHostnames.isEmpty {
                        let summary = configuredHostnames.count == 1
                            ? configuredHostnames[0]
                            : "\(configuredHostnames[0]) +\(configuredHostnames.count - 1) more"
                        if remoteTunnelHostnames[tunnelID] != summary {
                            remoteTunnelHostnames[tunnelID] = summary
                        }
                    }
                    let ingress = RemoteIngressMetadataResolver.matching(hostname: definition.hostname, in: configuration)
                    if let ingress {
                        // A wildcard or catch-all rule says where traffic goes, not what the hostname is.
                        let named = RemoteIngressMetadataResolver.namesHostname(ingress, definitions[index].hostname)
                        if definitions[index].localURL != ingress.service || (named && definitions[index].hostname != ingress.hostname) {
                            definitions[index].localURL = ingress.service
                            if named { definitions[index].hostname = ingress.hostname }
                            definitionsChanged = true
                        }
                        if effectiveOrigins[definition.id]?.source != .liveConnector {
                            effectiveOrigins[definition.id] = EffectiveOrigin(
                                url: ingress.service,
                                source: .cloudflareConfiguration,
                                updatedAt: Date()
                            )
                            effectiveOriginsChanged = true
                        }
                    }
                    var detectedIncomplete = ingress == nil
                    if !detectedIncomplete,
                       let hostname = definitions[index].hostname,
                       let zone = Self.zone(for: hostname, in: loadedZones) {
                        do {
                            if try await client.dnsRecord(zoneID: zone.id, hostname: hostname) == nil {
                                detectedIncomplete = true
                            }
                        } catch {}
                    }
                    // Re-resolve after the DNS lookup: the list may have changed while it ran.
                    if setupProgressTunnelID != definition.id,
                       let current = definitions.firstIndex(where: { $0.id == definition.id }),
                       definitions[current].setupIncomplete != detectedIncomplete {
                        definitions[current].setupIncomplete = detectedIncomplete
                        definitionsChanged = true
                    }
                }
            }
            if definitionsChanged { saveDefinitions() }
            if effectiveOriginsChanged { saveEffectiveOrigins() }
            await refreshHealthForAccount(requestedAccount)
            await refreshAccessPermission()
        } catch {
            accountError = error.localizedDescription
        }
    }

    func refreshSavedRemoteStatuses() async {
        let remoteDefinitions = definitions.filter { $0.kind.usesCloudflareAccount && $0.accountID != nil }
        let byAccount = Dictionary(grouping: remoteDefinitions, by: { $0.accountID ?? "" })
        for (account, accountDefinitions) in byAccount {
            guard !Task.isCancelled else { return }
            do {
                let client = try await client(for: account)
                let tunnels = try await client.listTunnels()
                guard !Task.isCancelled else { return }
                let refreshedAt = Date()
                for definition in accountDefinitions {
                    let status = tunnels.first(where: { $0.id == definition.cloudflareTunnelID })?.status
                    remoteStatuses[definition.id] = RemoteTunnelStatus(apiValue: status)
                    remoteStatusUpdatedAt[definition.id] = refreshedAt
                }
            } catch {
                for definition in accountDefinitions {
                    remoteStatuses[definition.id] = .unknown
                    remoteStatusUpdatedAt[definition.id] = nil
                }
            }
        }
    }

    func importRemote(_ tunnel: CloudflareTunnel) async {
        let requestedAccount = accountID
        accountError = nil
        guard tunnel.configSource == "cloudflare" else {
            accountError = "Tunnel \(tunnel.name) uses a local configuration file. OpenTraffic currently imports remotely managed (cloudflare config) tunnels only."
            return
        }
        guard !definitions.contains(where: { $0.cloudflareTunnelID == tunnel.id && $0.accountID == requestedAccount }) else {
            accountError = "That tunnel is already in OpenTraffic."
            return
        }
        do {
            let client = try await client(for: requestedAccount)
            let config = try await client.tunnelConfiguration(id: tunnel.id)
            guard accountID == requestedAccount else { return }
            let route = config.ingress.first(where: { $0.hostname != nil })
            let definition = TunnelDefinition(
                name: tunnel.name,
                kind: .remote,
                localURL: route?.service.nilIfBlank ?? "http://localhost:3000",
                hostname: route?.hostname,
                cloudflareTunnelID: tunnel.id,
                accountID: requestedAccount
            )
            appendRemote(definition, status: tunnel.status)
            notice = AppNotice(.success, "Imported \(tunnel.name). Its existing Cloudflare configuration was left unchanged.")
        } catch {
            accountError = error.localizedDescription
        }
    }

    @discardableResult
    /// Creates a remotely managed tunnel for `hostname`. `replacingDNS` lets it take over a hostname that
    /// already has a DNS record (see `CloudflareClient.ensureDNSRoute`); otherwise that's an error.
    func createRemote(name: String, hostname: String, localURL: String, zoneID: String, replacingDNS: Bool = false) async -> TunnelDefinition? {
        let requestedAccount = accountID
        accountError = nil
        setupProgressSteps = SetupProgressStep.tunnelSteps()
        setupProgressTunnelID = nil
        do {
            try validateLocalURL(localURL)
            let service = try CloudflareClient.ingressService(from: localURL)
            guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenTrafficError.api("Enter a hostname for the custom tunnel.")
            }
            guard !zoneID.isEmpty else { throw OpenTrafficError.api("Choose a Cloudflare zone.") }
            guard let zone = zones.first(where: { $0.id == zoneID }) else {
                throw OpenTrafficError.api("The selected zone is no longer available. Refresh the account and choose it again.")
            }
            let normalizedHostname = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let normalizedZone = zone.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard normalizedHostname == normalizedZone || normalizedHostname.hasSuffix(".\(normalizedZone)") else {
                throw OpenTrafficError.api("The hostname must belong to the selected \(zone.name) zone.")
            }
            let client = try await client(for: requestedAccount)
            if !replacingDNS,
               let existing = try? await client.dnsRecord(zoneID: zoneID, hostname: normalizedHostname),
               existing.content?.nilIfBlank != nil {
                throw OpenTrafficError.api("A DNS record for \(normalizedHostname) already exists and points to \(existing.content ?? "another target"). Choose to replace it, or pick another hostname.")
            }
            setSetupStep("create", to: .active)
            let shareName = name.nilIfBlank ?? normalizedHostname
            let remote = try await client.createRemoteTunnel(uniquelyNamed: shareName)
            setSetupStep("create", to: .done)
            let definition = TunnelDefinition(
                name: shareName,
                kind: .remote,
                localURL: service,
                hostname: normalizedHostname,
                cloudflareTunnelID: remote.id,
                accountID: requestedAccount,
                setupIncomplete: true
            )
            appendRemote(definition, status: remote.status)
            setupProgressTunnelID = definition.id
            guard accountID == requestedAccount else {
                let message = "Cloudflare tunnel \(remote.id) was created, but the selected account changed. The entry was saved under account \(requestedAccount) so you can recover it."
                setFailure(message, for: definition.id)
                accountError = message
                await refreshHealth(for: definition.id)
                return nil
            }
            do {
                setSetupStep("ingress", to: .active)
                try await client.applyHostnameConfiguration(tunnelID: remote.id, hostname: normalizedHostname, service: service)
                setSetupStep("ingress", to: .done)
                setSetupStep("dns", to: .active)
                try await client.ensureDNSRoute(zoneID: zoneID, hostname: normalizedHostname, tunnelID: remote.id, replacing: replacingDNS)
                setSetupStep("dns", to: .done)
                if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
                    definitions[index].setupIncomplete = false
                    saveDefinitions()
                }
                await refreshHealth(for: definition.id)
                return definitions.first(where: { $0.id == definition.id })
            } catch {
                setFailure("Cloudflare tunnel \(remote.id) was created, but setup did not finish: \(error.localizedDescription). The tunnel remains imported so you can recover it.", for: definition.id)
                accountError = runtime(for: definition.id).lastError
                await refreshHealth(for: definition.id)
                return nil
            }
        } catch {
            accountError = error.localizedDescription
            setupProgressSteps = []
            setupProgressTunnelID = nil
            return nil
        }
    }

    func finishSetup(_ id: UUID) async {
        guard let definition = definitions.first(where: { $0.id == id }), definition.kind.usesCloudflareAccount else { return }
        guard let tunnelID = definition.cloudflareTunnelID else {
            setFailure(OpenTrafficError.remoteTunnelMissingID.localizedDescription, for: id)
            return
        }
        guard let account = definition.accountID else {
            setFailure(OpenTrafficError.accountNotConfigured.localizedDescription, for: id)
            return
        }
        guard let hostname = definition.hostname?.nilIfBlank else {
            setFailure("This tunnel has no saved public hostname for OpenTraffic to finish.", for: id)
            return
        }
        setupProgressSteps = SetupProgressStep.applySteps()
        setupProgressTunnelID = id
        do {
            let client = try await client(for: account)
            setSetupStep("ingress", to: .active)
            // With rewriting on, the Host header follows the (possibly just edited) local address.
            try await client.applyHostnameConfiguration(
                tunnelID: tunnelID,
                hostname: hostname,
                service: definition.localURL,
                hostHeader: definition.rewriteHostHeader ? definition.originHostHeader.map { .set($0) } ?? .keep : .keep
            )
            setSetupStep("ingress", to: .done)
            let zones = try await client.listZones()
            guard let zone = Self.zone(for: hostname, in: zones) else {
                setSetupStep("dns", to: .failed(message: "No matching zone"))
                throw OpenTrafficError.api("None of the account's zones matches \(hostname), so OpenTraffic cannot create its DNS record.")
            }
            setSetupStep("dns", to: .active)
            try await client.ensureDNSRoute(zoneID: zone.id, hostname: hostname, tunnelID: tunnelID)
            setSetupStep("dns", to: .done)
            if let index = definitions.firstIndex(where: { $0.id == id }) {
                definitions[index].setupIncomplete = false
                saveDefinitions()
            }
            if var runtime = runtimes[id] {
                // Only clear a failure; a live connector keeps running and picks up the new route.
                if runtime.state == .failed { runtime.state = .stopped }
                runtime.lastError = nil
                runtimes[id] = runtime
            }
            notice = isActive(id)
                ? AppNotice(.success, "Finished setup for \(hostname).")
                : AppNotice(.success, "Finished setup for \(hostname). Start the tunnel when your service is ready.")
        } catch {
            setFailure(error.localizedDescription, for: id)
            if let index = definitions.firstIndex(where: { $0.id == id }) {
                definitions[index].setupIncomplete = true
                saveDefinitions()
            }
        }
        await refreshHealth(for: id)
    }

    private static func zone(for hostname: String, in zones: [CloudflareZone]) -> CloudflareZone? {
        let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return zones
            .map { (zone: $0, name: $0.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
            .filter { host == $0.name || host.hasSuffix(".\($0.name)") }
            .max { $0.name.count < $1.name.count }?
            .zone
    }

    private func startRemote(_ definition: TunnelDefinition, generation: UInt64, executable: URL) async {
        do {
            guard let tunnelID = definition.cloudflareTunnelID else { throw OpenTrafficError.remoteTunnelMissingID }
            guard let account = definition.accountID else { throw OpenTrafficError.accountNotConfigured }
            if !isAPITokenUnlocked { setStartupNote("Waiting for Keychain access to your Cloudflare token…", for: definition.id, generation: generation) }
            let client = try await client(for: account)
            setStartupNote("Fetching the connector token from Cloudflare…", for: definition.id, generation: generation)
            let token = try await client.connectorToken(id: tunnelID)
            setStartupNote(nil, for: definition.id, generation: generation)
            guard definitions.contains(where: { $0.id == definition.id }), runtime(for: definition.id).generation == generation else { return }
            try processSupervisor.startRemote(
                id: definition.id,
                generation: generation,
                executable: executable,
                token: token
            )
        } catch {
            setFailure(error.localizedDescription, for: definition.id, generation: generation)
        }
    }

    func setStartupNote(_ note: String?, for id: UUID, generation: UInt64) {
        guard var runtime = runtimes[id], runtime.generation == generation else { return }
        runtime.startupNote = note
        runtimes[id] = runtime
    }

    func client(for account: String) async throws -> CloudflareClient {
        let account = try validatedAccountID(account)
        guard let token = await credentialService.cachedCredential(key: Self.apiTokenKeyPrefix + account)?.nilIfBlank else {
            throw OpenTrafficError.accountNotConfigured
        }
        return CloudflareClient(accountID: account, token: token)
    }

    private func refreshAPITokenPresence() {
        guard let account = try? validatedAccountID(accountID) else {
            hasSavedAPIToken = false
            isAPITokenUnlocked = false
            requiresLegacyTokenAuthorization = false
            return
        }
        let key = Self.apiTokenKeyPrefix + account
        let credentials = credentialService
        Task { [weak self] in
            let exists = await credentials.contains(key: key)
            let storageKind = try? await credentials.storageKind(key: key)
            guard let self, self.accountID == account else { return }
            self.hasSavedAPIToken = exists
            self.tokenStorageKind = storageKind
            self.requiresLegacyTokenAuthorization = false
            if await credentials.cachedCredential(key: key)?.nilIfBlank != nil {
                self.isAPITokenUnlocked = true
                return
            }
            self.isAPITokenUnlocked = false
            guard exists else { return }
            if await credentials.silentUnlock(key: key) {
                guard self.accountID == account else { return }
                self.isAPITokenUnlocked = true
                await self.refreshAccount()
            }
        }
    }

    private func validatedAccountID(_ value: String) throws -> String {
        guard let account = value.nilIfBlank else { throw OpenTrafficError.accountNotConfigured }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard account.count == 32, account.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw OpenTrafficError.api("Enter the 32-character hexadecimal Cloudflare Account ID, not the account name.")
        }
        return account
    }

    private func appendRemote(_ definition: TunnelDefinition, status: String?) {
        definitions.append(definition)
        runtimes[definition.id] = TunnelRuntime()
        logs[definition.id] = BoundedLogBuffer()
        remoteStatuses[definition.id] = RemoteTunnelStatus(apiValue: status)
        remoteStatusUpdatedAt[definition.id] = Date()
        selectedID = definition.id
        saveDefinitions()
    }

    private func invalidateAndStop(_ id: UUID) {
        if var runtime = runtimes[id] {
            runtime.generation &+= 1
            runtimes[id] = runtime
        }
        processSupervisor.stop(id: id)
        stopCollaboration(id)
        switch definitions.first(where: { $0.id == id })?.kind.provider {
        case .tailscale: Task { [weak self] in await self?.removeTailscaleShare(for: id) }
        case .opentunnel: Task { [weak self] in await self?.removeOpenTunnelRoute(for: id) }
        default: break
        }
    }

    private func receive(entries: [TunnelLogEntry], for id: UUID, generation: UInt64) {
        guard runtime(for: id).generation == generation else { return }
        if logs[id] == nil { logs[id] = BoundedLogBuffer() }
        logs[id]?.append(contentsOf: entries)
        if let port = entries.lazy.compactMap({ Self.metricsPort(in: $0.rawLine ?? $0.message) }).first,
           var runtime = runtimes[id], runtime.generation == generation {
            runtime.metricsPort = port
            runtimes[id] = runtime
        }
        if entries.contains(where: { $0.message.localizedCaseInsensitiveContains("Registered tunnel connection") }),
           var runtime = runtimes[id], runtime.generation == generation {
            let wasStarting = runtime.state == .starting
            runtime.state = .running
            runtimes[id] = runtime
            // Quick Tunnels announce readiness when their URL arrives; custom domains are ready once connected.
            if wasStarting, notifyWhenReady,
               let definition = definitions.first(where: { $0.id == id }), !definition.kind.hasEphemeralURL,
               let url = publicURL(for: definition) {
                TunnelNotifications.post(title: "\(definition.name) is live", body: url, identifier: "ready-\(id.uuidString)", category: .ready, tunnelID: id)
            }
        }
    }

    func receive(publicURL: String, for id: UUID, generation: UInt64) {
        guard var runtime = runtimes[id], runtime.generation == generation else { return }
        let firstURL = runtime.publicURL != publicURL || runtime.state == .starting
        runtime.publicURL = publicURL
        runtime.startupNote = nil
        if runtime.state == .starting { runtime.state = .running }
        runtimes[id] = runtime
        rememberNgrokDomain(publicURL, for: id)
        // A temporary address arrived, so whatever the last network check said no longer holds.
        if definitions.first(where: { $0.id == id })?.kind == .quick { quickTunnelNetworkCheck = nil }
        collaborationReceived(publicURL: publicURL, for: id)
        if firstURL, let share = apiShareRef(id) { apiEvents.append(.shareStarted, share: share) }
        let name = definitions.first(where: { $0.id == id })?.name ?? "Tunnel"
        let copied = pendingAutoCopy.remove(id) != nil
        if copied { copy(publicURL, feedbackFor: id) }
        if notifyWhenReady {
            TunnelNotifications.post(
                title: copied ? "\(name) is live — URL copied" : "\(name) is live",
                body: publicURL,
                identifier: "ready-\(id.uuidString)",
                category: .ready,
                tunnelID: id
            )
        }
    }

    private func processTerminated(id: UUID, generation: UInt64, status: Int32) {
        guard var runtime = runtimes[id] else { return }
        if runtime.generation != generation {
            if runtime.state == .stopping { runtime.state = .stopped }
            runtimes[id] = runtime
            return
        }
        runtime.state = status == 0 ? .stopped : .failed
        runtime.metricsPort = nil
        runtime.statistics = nil
        if definitions.first(where: { $0.id == id })?.kind.hasEphemeralURL == true {
            runtime.publicURL = nil
        }
        if status != 0 { runtime.lastError = terminationMessage(for: id, status: status) }
        runtimes[id] = runtime
        pendingAutoCopy.remove(id)
        if let share = apiShareRef(id) { apiEvents.append(.shareStopped, share: share) }
        stopCollaboration(id)
        if status != 0, definitions.first(where: { $0.id == id })?.kind == .quick,
           cloudflaredExitReason(for: id).map(CloudflaredFailure.isQuickTunnelRequest) == true {
            explainQuickTunnelFailure(id, generation: generation)
        } else if status != 0 {
            notifyFailure(id: id, message: runtime.lastError ?? "")
        }
        markEffectiveOriginLastKnown(id: id)
        // The generation still matched, so nobody asked for this exit.
        scheduleRestartAfterCrash(id)
        Task { [weak self] in await self?.refreshHealth(for: id) }
    }

    func setFailure(_ message: String, for id: UUID, generation: UInt64? = nil) {
        guard var runtime = runtimes[id], generation == nil || runtime.generation == generation else { return }
        runtime.startupNote = nil
        runtime.state = .failed
        runtime.lastError = message
        runtimes[id] = runtime
        pendingAutoCopy.remove(id)
        notifyFailure(id: id, message: message)
    }

    private func notifyFailure(id: UUID, message: String) {
        guard notifyOnFailure, let name = definitions.first(where: { $0.id == id })?.name else { return }
        TunnelNotifications.post(title: "\(name) needs attention", body: message, identifier: "failure-\(id.uuidString)", category: .failure, tunnelID: id)
    }

    /// What cloudflared said last in its current run that explains why it exited.
    func cloudflaredExitReason(for id: UUID) -> String? {
        let since = runtime(for: id).startedAt?.addingTimeInterval(-2) ?? .distantPast
        return CloudflaredFailure.reason(in: logEntries(for: id).filter { $0.timestamp >= since })
    }

    /// Whether this network lets Quick Tunnels get an address. Checked at most every ten minutes, or
    /// again with `refresh` (after a failure); it runs in the background and callers await it.
    func checkQuickTunnelNetwork(refresh: Bool = false) -> Task<QuickTunnelNetwork, Never> {
        if !refresh, let check = quickTunnelNetworkCheck, Date().timeIntervalSince(check.startedAt) < 600 { return check.task }
        let task = Task.detached { await QuickTunnelNetwork.check() }
        quickTunnelNetworkCheck = (task, Date())
        return task
    }

    /// A Quick Tunnel couldn't get an address. Before saying so (in the share and a notification),
    /// checks whether the network's DNS filter is why.
    private func explainQuickTunnelFailure(_ id: UUID, generation: UInt64) {
        let check = checkQuickTunnelNetwork(refresh: true)
        failureDiagnoses[id] = Task { [weak self] in
            let network = await check.value
            guard let self else { return }
            if runtimes[id]?.generation == generation { failureDiagnoses[id] = nil }
            guard var runtime = runtimes[id], runtime.generation == generation, runtime.state == .failed else { return }
            if let warning = network.warning {
                runtime.lastError = warning
                runtimes[id] = runtime
            }
            notifyFailure(id: id, message: runtime.lastError ?? "")
        }
    }

    func validateLocalURL(_ value: String) throws {
        guard
            let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil
        else { throw OpenTrafficError.invalidLocalURL }
    }

    func saveDefinitions() {
        guard persistenceLoadError == nil else {
            notice = AppNotice(.error, "Saved tunnels remain unreadable, so OpenTraffic did not overwrite the file.")
            return
        }
        do { try persistence.save(definitions) }
        catch { notice = AppNotice(.error, "Could not save tunnels: \(error.localizedDescription)") }
    }

    private func discoveryPreference(for key: String) -> DiscoveryPreference? {
        discoveryPreferences.entries.first(where: { $0.key == key })
    }

    private var discoveredAliasMap: [String: String] {
        Dictionary(uniqueKeysWithValues: discoveryPreferences.entries.compactMap { preference in
            guard let alias = preference.alias?.nilIfBlank else { return nil }
            return (preference.key, alias)
        })
    }

    private var definitionsUsingEffectiveOrigins: [TunnelDefinition] {
        definitions.map { definition in
            var resolved = definition
            resolved.localURL = effectiveOrigin(for: definition).url
            return resolved
        }
    }


    private func updateDiscoveryPreference(
        for tunnel: DiscoveredQuickTunnel,
        mutate: (inout DiscoveryPreference) -> Void
    ) {
        if let index = discoveryPreferences.entries.firstIndex(where: { $0.key == tunnel.preferenceKey }) {
            mutate(&discoveryPreferences.entries[index])
        } else {
            var preference = DiscoveryPreference(
                key: tunnel.preferenceKey,
                origin: tunnel.localURL,
                executablePath: tunnel.executablePath
            )
            mutate(&preference)
            discoveryPreferences.entries.append(preference)
        }
        saveDiscoveryPreferences()
    }

    private func saveDiscoveryPreferences() {
        do { try discoveryPreferencesPersistence.save(discoveryPreferences) }
        catch { notice = AppNotice(.error, "Could not save discovery preferences: \(error.localizedDescription)") }
    }

    private func setLiveEffectiveOrigin(_ url: String, for id: UUID) {
        let previous = effectiveOrigins[id]
        let changed = previous?.url != url || previous?.source != .liveConnector
        // The verification time is shown to the minute; refreshing it on every 5-second poll would
        // make every view that shows this tunnel re-render each time for no visible change.
        guard changed || Date().timeIntervalSince(previous?.updatedAt ?? .distantPast) >= 60 else { return }
        effectiveOrigins[id] = EffectiveOrigin(url: url, source: .liveConnector, updatedAt: Date())
        if changed { saveEffectiveOrigins() }
    }

    private func markEffectiveOriginLastKnown(id: UUID) {
        guard let lastKnown = EffectiveOriginResolver.markUnavailable(effectiveOrigins[id]),
              lastKnown != effectiveOrigins[id] else { return }
        effectiveOrigins[id] = lastKnown
    }

    private func saveEffectiveOrigins() {
        let values = effectiveOrigins.compactMap { id, origin -> PersistedEffectiveOrigin? in
            guard origin.source == .liveConnector || origin.source == .lastKnownLiveConnector,
                  let verifiedAt = origin.updatedAt else { return nil }
            return PersistedEffectiveOrigin(tunnelID: id, url: origin.url, verifiedAt: verifiedAt)
        }
        do { try effectiveOriginPersistence.save(values) }
        catch { notice = AppNotice(.error, "Could not save verified connector origins: \(error.localizedDescription)") }
    }

    private static func metricsPort(in text: String) -> UInt16? {
        let pattern = #"(?:127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})/metrics"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let portRange = Range(match.range(at: 1), in: text) else { return nil }
        return UInt16(text[portRange])
    }
}

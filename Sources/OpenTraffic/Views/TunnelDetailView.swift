import AppKit
import SwiftUI
import OpenTrafficCore

struct TunnelDetailView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var store: AppStore
    let tunnel: TunnelDefinition
    @State private var pendingRemoval: TunnelDefinition?
    @State private var finishingSetup = false

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                previewIdentity: "managed:\(tunnel.id.uuidString)",
                originURL: effectiveOrigin.url,
                title: tunnel.name,
                state: state,
                caption: tunnel.kind.title,
                provider: tunnel.kind.provider
            ) {
                HStack(spacing: Spacing.m) {
                    if let deadline = store.autoStopDeadlines[tunnel.id], store.isActive(tunnel.id) {
                        AutoStopBadge(deadline: deadline)
                    }
                    primaryControl
                }
            }
            Divider()
            switch store.detailTab {
            case .overview:
                overview
            case .requests where tunnel.kind == .ngrok:
                RequestInspector(store: store, tunnel: tunnel)
            case .requests:
                overview
            case .feedback where showsFeedback:
                FeedbackView(store: store, tunnel: tunnel)
            case .feedback:
                overview
            case .logs:
                LogConsole(entries: store.logEntries(for: tunnel.id)) { store.clearLogs(tunnel.id) }
            }
        }
        .task(id: tunnel.id) { store.loadComments(for: tunnel.id) }
        .task(id: "\(tunnel.id.uuidString)-\(runtime.state.rawValue)") {
            await store.refreshHealth(for: tunnel.id)
        }
        .toolbar {
            DetailTabPicker(
                selection: $store.detailTab,
                tabs: tabs,
                logBadge: errorLogCount,
                feedbackBadge: (store.collabComments[tunnel.id] ?? []).filter { !$0.resolved }.count
            )
            ToolbarItem {
                Menu {
                    Button(Vocabulary.copyURL, systemImage: "doc.on.doc") { store.copyPublicURL(tunnel.id) }
                        .disabled(publicURL == nil)
                    Button(Vocabulary.openInBrowser, systemImage: "safari", action: openPublicURL)
                        .disabled(publicURL == nil)
                    Divider()
                    StopAfterMenu(store: store, id: tunnel.id)
                    Button("Protection…", systemImage: "lock") { store.present(.protection(tunnel.id)) }
                    Button("Host Header…", systemImage: "arrow.left.arrow.right.square") { store.present(.hostHeader(tunnel.id)) }
                    Divider()
                    Button(Vocabulary.edit, systemImage: "pencil") { store.present(.edit(tunnel.id)) }
                    Button(Vocabulary.remove, systemImage: "trash", role: .destructive) { pendingRemoval = tunnel }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
        .confirmsRemoval(of: $pendingRemoval, store: store)
    }

    private var runtime: TunnelRuntime { store.runtime(for: tunnel.id) }
    private var effectiveOrigin: EffectiveOrigin { store.effectiveOrigin(for: tunnel) }
    private var state: TunnelDisplayState { store.displayState(for: tunnel) }
    private var publicURL: String? { store.publicURL(for: tunnel) }

    private var showsFeedback: Bool {
        tunnel.kind.supportsCollaboration && (tunnel.collaboration || !(store.collabComments[tunnel.id] ?? []).isEmpty)
    }

    private var tabs: [DetailTab] {
        var tabs: [DetailTab] = [.overview, .logs]
        if tunnel.kind == .ngrok { tabs.append(.requests) }
        if showsFeedback { tabs.append(.feedback) }
        return tabs
    }

    private var errorLogCount: Int {
        store.errorLogCount(for: tunnel.id)
    }

    private var canApplyCloudflareSetup: Bool {
        tunnel.kind.usesCloudflareAccount
            && tunnel.hostname?.nilIfBlank != nil
            && tunnel.cloudflareTunnelID != nil
            && tunnel.accountID != nil
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                Card {
                    ConnectionPathView(
                        stages: stages,
                        provider: tunnel.kind.provider,
                        localOrigin: effectiveOrigin.url,
                        activity: activity,
                        fixes: fixes(for:)
                    )
                    .padding(.vertical, Spacing.xs)
                    Divider()
                    PublicURLCard(
                        url: publicURL,
                        placeholder: runtime.state == .starting ? "Creating…" : "Available once the tunnel starts"
                    ) {
                        HStack(spacing: Spacing.s) {
                            Text(Vocabulary.localService).foregroundStyle(.secondary)
                            Text(effectiveOrigin.url)
                                .monospaced()
                                .textSelection(.enabled)
                            Button("Change…") { store.present(.edit(tunnel.id)) }
                                .buttonStyle(.borderless)
                            Spacer(minLength: Spacing.s)
                            Text(originFootnote)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.top, Spacing.xs)
                        if case .password(let username) = tunnel.protection {
                            SharePasswordRow(store: store, tunnel: tunnel, username: username)
                        }
                        HStack(spacing: Spacing.s) {
                            Button {
                                store.present(.protection(tunnel.id))
                            } label: {
                                Label(tunnel.protection.summary, systemImage: tunnel.protection.symbol)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(tunnel.protection.isProtected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .help("Choose who can open this URL")
                            SavedPathsMenu(store: store, tunnel: tunnel)
                            if let publicURL, let url = URL(string: publicURL) {
                                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.borderless)
                                    .help("Send the URL with AirDrop, Messages, Mail…")
                            }
                            Spacer()
                        }
                        .font(.callout)
                    }
                }

                CollaborationCard(store: store, tunnel: tunnel)

                if needsSetup || setupInProgressOrFailed {
                    Card {
                        if needsSetup {
                            InlineMessage(
                                severity: .warning,
                                message: "The Cloudflare route or DNS record for \(tunnel.hostname ?? "this hostname") isn't in place yet. Finishing setup reapplies them and keeps routes for other hostnames.",
                                title: "Setup incomplete"
                            ) {
                                Button("Finish Setup", action: finishSetup)
                                    .disabled(finishingSetup)
                            }
                        }
                        if showsSetupProgress {
                            SetupProgressView(steps: store.setupProgressSteps)
                        }
                    }
                }

                HealthDetailsCard(
                    health: store.health(for: tunnel.id),
                    provider: tunnel.kind.provider,
                    collapsed: state == .stopped,
                    fixes: fixes(for:),
                    onRecheck: { Task { await store.refreshHealth(for: tunnel.id) } }
                )

                if tunnel.kind.reportsTraffic {
                    TrafficCard(
                        statistics: runtime.statistics,
                        startedAt: runtime.state == .running ? runtime.startedAt : nil,
                        history: store.requestHistory[tunnel.id]
                    )
                }

                Card(title: "Technical Details") {
                    FactRows(rows: technicalRows)
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    private var stages: [ConnectionStage] {
        ConnectionPath.stages(
            checks: store.health(for: tunnel.id)?.checks ?? [],
            kind: tunnel.kind,
            localLabel: TunnelRowPresentation.localEndpoint(effectiveOrigin.url) ?? effectiveOrigin.url,
            publicLabel: publicURL.flatMap { URL(string: $0)?.host } ?? tunnel.kind.publicHostPlaceholder
        )
    }

    /// Recent requests per poll, scaled to 0…1 for the path animation.
    private var activity: Double {
        let recent = store.requestHistory[tunnel.id]?.deltas.suffix(3).reduce(0) { $0 + $1.count } ?? 0
        return min(1, Double(recent) / 15)
    }

    private var technicalRows: [(label: String, value: String, monospaced: Bool)] {
        var rows: [(label: String, value: String, monospaced: Bool)] = [
            ("Type", tunnel.kind.title, false),
            ("Origin source", originSourceDescription, false),
        ]
        if let id = tunnel.cloudflareTunnelID { rows.append(("Tunnel ID", id, true)) }
        if let account = tunnel.accountID { rows.append(("Account", account, true)) }
        if let port = runtime.metricsPort {
            rows.append((tunnel.kind == .ngrok ? "Inspection API" : "Metrics", "127.0.0.1:\(port)", true))
        }
        if tunnel.kind == .ngrok {
            rows.append(("Domain", tunnel.hostname ?? "Assigned by ngrok on first start", tunnel.hostname != nil))
        }
        if tunnel.kind == .tailscale {
            rows.append(("Exposure", tunnel.tailscalePublic ? "Public (Funnel)" : "Private (tailnet only)", false))
            if let port = tunnel.tailscalePort { rows.append(("HTTPS port", "\(port)", true)) }
            if store.tailscaleForwarders[tunnel.id] != nil {
                rows.append(("Local relay", "On — the server isn't reachable on 127.0.0.1", false))
            }
        }
        return rows
    }

    private var needsSetup: Bool {
        tunnel.setupIncomplete && canApplyCloudflareSetup
    }

    private var showsSetupProgress: Bool {
        store.setupProgressTunnelID == tunnel.id && !store.setupProgressSteps.isEmpty
    }

    /// Completed (all-green) progress from an earlier run isn't worth a section of its own.
    private var setupInProgressOrFailed: Bool {
        showsSetupProgress && store.setupProgressSteps.contains { $0.state != .done }
    }

    private var originFootnote: String {
        switch tunnel.kind {
        case .quick: "Changes every time the tunnel starts"
        case .remote: "Served from this Mac while running"
        case .tailscale: tunnel.tailscalePublic ? "Public on the internet via Funnel" : "Only your tailnet's devices can open it"
        case .ngrok: "Your ngrok domain · free-plan visitors see an ngrok notice first"
        case .opentunnel: "Stays the same between starts · anyone with the link can open it"
        }
    }

    private var originSourceDescription: String {
        guard let updatedAt = effectiveOrigin.updatedAt else { return effectiveOrigin.source.title }
        return "\(effectiveOrigin.source.title) · \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: Actions

    @ViewBuilder
    private var primaryControl: some View {
        switch runtime.state {
        case .running, .starting:
            Button { store.stop(tunnel.id) } label: {
                Label(Vocabulary.stop, systemImage: "stop.fill")
            }
            .help("Stop the tunnel (⌘⏎)")
        case .stopping:
            Button {} label: {
                Label("Stopping…", systemImage: "stop.fill")
            }
            .disabled(true)
        case .stopped, .failed:
            Button { store.startSharing(tunnel) } label: {
                Label(Vocabulary.start, systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Start the tunnel (⌘⏎)")
        }
    }

    private func fixes(for check: TunnelHealthCheck) -> [HealthFix] {
        switch (check.kind, check.state) {
        case (.connector, .failed):
            var fixes: [HealthFix] = []
            if runtime.lastError == OpenTrafficError.cloudflaredMissing.localizedDescription {
                fixes.append(HealthFix(title: "Open Settings", isProminent: true) { openSettings() })
            } else {
                fixes.append(HealthFix(title: Vocabulary.showLogs) { store.detailTab = .logs })
            }
            if runtime.lastError != nil {
                fixes.append(HealthFix(title: "Dismiss") { store.clearError(tunnel.id) })
            }
            return fixes
        case (.connector, .skipped):
            return [HealthFix(title: Vocabulary.start) { store.startSharing(tunnel) }]
        case (.localOrigin, .failed):
            return [HealthFix(title: "Change…") { store.present(.edit(tunnel.id)) }]
        case (.edge, .skipped) where tunnel.kind.usesCloudflareAccount && !store.isAPITokenUnlocked:
            if store.hasAPIToken() {
                return [HealthFix(title: "Unlock") { Task { await store.unlockAPIToken(); await store.refreshAccount() } }]
            }
            return [HealthFix(title: "Connect…") { openSettings() }]
        case (.dns, .failed) where canApplyCloudflareSetup:
            return [HealthFix(title: "Finish Setup", isProminent: true, action: finishSetup)]
        case (.publicSite, .failed) where check.remedy != nil:
            var fixes: [HealthFix] = []
            if tunnel.kind.supportsHostHeaderRewrite, !tunnel.rewriteHostHeader {
                fixes.append(HealthFix(title: "Fix Host Header", isProminent: true) {
                    Task { await store.setHostHeaderRewrite(true, for: tunnel.id) }
                })
            }
            fixes.append(HealthFix(title: "Config Snippet…") { store.present(.hostHeader(tunnel.id)) })
            return fixes
        case (.publicSite, .failed) where publicURL != nil:
            return [HealthFix(title: "Open", action: openPublicURL)]
        default:
            return []
        }
    }

    private func finishSetup() {
        finishingSetup = true
        Task {
            await store.finishSetup(tunnel.id)
            finishingSetup = false
        }
    }

    private func openPublicURL() {
        if let publicURL, let url = URL(string: publicURL) { NSWorkspace.shared.open(url) }
    }
}

/// "Stops in 42 min" next to the primary control while an auto-stop deadline is set.
struct AutoStopBadge: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label("Stops in \(Countdown.text(until: deadline, now: context.date))", systemImage: "timer")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .help("This share stops itself at \(deadline.formatted(date: .omitted, time: .shortened))")
    }
}

/// Set or clear how long a running share stays up.
struct StopAfterMenu: View {
    let store: AppStore
    let id: UUID

    var body: some View {
        Menu {
            ForEach(ShareDuration.allCases) { duration in
                Button(duration == .never ? "Never" : duration.title) { store.setAutoStop(id, after: duration) }
            }
        } label: {
            Label("Stop After", systemImage: "timer")
        }
        .disabled(!store.isActive(id))
    }
}

/// Saved paths: copy the public URL with a path in one click, add or remove paths.
struct SavedPathsMenu: View {
    let store: AppStore
    let tunnel: TunnelDefinition
    @State private var addingPath = false
    @State private var draft = ""

    var body: some View {
        Menu {
            let paths = store.definitions.first(where: { $0.id == tunnel.id })?.savedPaths ?? []
            ForEach(paths, id: \.self) { path in
                Button("Copy URL + \(path)") { store.copyPublicURL(tunnel.id, path: path) }
            }
            if !paths.isEmpty {
                Divider()
                Menu("Remove Path") {
                    ForEach(paths, id: \.self) { path in
                        Button(path, role: .destructive) { store.removeSavedPath(path, from: tunnel.id) }
                    }
                }
            }
            Button("Add Path…") { draft = ""; addingPath = true }
        } label: {
            Label("Paths", systemImage: "link")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.publicURL(for: tunnel) == nil)
        .help("Copy the public URL with a saved path, like /api/webhooks")
        .alert("Add Path", isPresented: $addingPath) {
            TextField("/api/webhooks/stripe", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Add") { store.addSavedPath(draft, to: tunnel.id) }
                .disabled(draft.nilIfBlank == nil)
        } message: {
            Text("Saved paths can be copied together with the public URL.")
        }
    }
}

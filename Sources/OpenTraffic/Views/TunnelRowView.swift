import AppKit
import SwiftUI
import OpenTrafficCore

enum TunnelRowStyle {
    case sidebar
    /// Compact row in the menu bar popover, used for tunnels that aren't running.
    case popover
    /// Rich card in the menu bar popover, used for running tunnels.
    case card
}

/// Opens the main window and optionally routes to a tunnel, tab, or sheet.
@MainActor
struct MainWindowRouter {
    let store: AppStore
    let openWindow: OpenWindowAction

    func show(tunnel id: UUID? = nil, tab: DetailTab? = nil, sheet: PresentedSheet? = nil) {
        if let id { store.selectedID = id }
        if let tab { store.detailTab = tab }
        MainWindowController.shared.show { openWindow(id: "main") }
        if let sheet { store.present(sheet) }
    }
}

struct ManagedTunnelRow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: AppStore
    let tunnel: TunnelDefinition
    let style: TunnelRowStyle
    @State private var pendingRemoval: TunnelDefinition?
    @State private var hovering = false

    var body: some View {
        Group {
            if style == .card { cardLayout } else { rowLayout }
        }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tunnel.name), \(state.label)")
        .confirmsRemoval(of: $pendingRemoval, store: store)
    }

    private var cardLayout: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                TunnelIcon(originURL: origin, state: state, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.s - 2) {
                        Text(tunnel.name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if state == .online { LivePulse() }
                        if tunnel.protection.isProtected {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(tunnel.protection.summary)
                        }
                        if !store.peers(for: tunnel.id).isEmpty {
                            PeopleBadge(count: store.peers(for: tunnel.id).count)
                        }
                    }
                    Text(cardSubtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(justCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: Spacing.xs)
                HStack(spacing: 0) {
                    if publicURL != nil {
                        RowIconButton(
                            title: Vocabulary.copyURL,
                            systemImage: justCopied ? "checkmark" : "doc.on.doc",
                            tint: justCopied ? .green : .primary
                        ) { store.copyPublicURL(tunnel.id) }
                        QRCodeButton(url: publicURL)
                            .buttonStyle(.borderless)
                            .frame(width: 24, height: 24)
                    }
                    playbackButton
                    actionsMenu.revealedOnHover(hovering)
                }
            }
            if state == .attention, let problem = runtime.lastError ?? failingCheck {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Text(statsLine)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .padding(Spacing.m)
        .glassCard(tint: state == .attention ? .red : (state == .online ? .green : nil))
        .contentShape(RoundedRectangle(cornerRadius: Radius.large))
        .onTapGesture(perform: primaryClick)
        .onHover { hovering = $0 }
        .help(rowHelp)
        .animation(.snappy, value: justCopied)
    }

    /// Endpoint, uptime, and requests; providers without metrics show who can reach the share instead.
    private var statsLine: String {
        let base: String
        if tunnel.kind.reportsTraffic {
            base = TunnelRowPresentation.compact(
                localURL: origin,
                statistics: runtime.statistics,
                fallbackStartedAt: runtime.state == .running ? runtime.startedAt : nil
            )
        } else {
            let endpoint = TunnelRowPresentation.localEndpoint(origin) ?? origin
            let reach = switch tunnel.kind {
            case .tailscale: tunnel.tailscalePublic ? "public via Funnel" : "tailnet only"
            default: "anyone with the link"
            }
            base = "\(endpoint) · \(reach)"
        }
        guard let deadline = store.autoStopDeadlines[tunnel.id], state.isActive else { return base }
        return base + " · stops in " + Countdown.text(until: deadline)
    }

    private var cardSubtitle: String {
        if justCopied { return "Copied to clipboard" }
        if runtime.state == .starting, let note = runtime.startupNote { return note }
        if runtime.state == .starting, publicURL == nil || tunnel.kind.hasEphemeralURL { return "Creating public URL…" }
        return publicURL.flatMap { URL(string: $0)?.host } ?? "Waiting for public URL…"
    }

    private var origin: String { store.effectiveOrigin(for: tunnel).url }

    private var rowLayout: some View {
        HStack(spacing: Spacing.s) {
            TunnelIcon(originURL: origin, state: state, size: style == .sidebar ? 24 : 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.xs) {
                    Text(tunnel.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !store.peers(for: tunnel.id).isEmpty {
                        PeopleBadge(count: store.peers(for: tunnel.id).count)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    // In the sidebar the icon already signals trouble, and red is unreadable on the selection highlight.
                    .foregroundStyle(style == .popover && state == .attention ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    // Error sentences read best from the start; hostnames keep both ends.
                    .truncationMode(state == .attention ? .tail : .middle)
                    .help(subtitle)
            }
            Spacer(minLength: Spacing.xs)
            if style == .popover { popoverControls }
            if style == .sidebar { actionsMenu.revealedOnHover(hovering) }
        }
        .padding(.vertical, style == .sidebar ? Spacing.xxs : Spacing.s - 2)
        .padding(.horizontal, style == .sidebar ? 0 : Spacing.s)
        .contentShape(Rectangle())
        .modifier(PopoverRowBehavior(enabled: style == .popover, help: rowHelp, action: primaryClick))
        .onHover { hovering = $0 }
    }

    private var router: MainWindowRouter { MainWindowRouter(store: store, openWindow: openWindow) }
    private var runtime: TunnelRuntime { store.runtime(for: tunnel.id) }
    private var state: TunnelDisplayState { store.displayState(for: tunnel) }
    private var publicURL: String? { store.publicURL(for: tunnel) }
    private var justCopied: Bool { store.recentlyCopiedID == tunnel.id }

    private var subtitle: String {
        if justCopied { return "Copied to clipboard" }
        switch style {
        case .popover, .card:
            switch state {
            case .starting: return runtime.startupNote ?? (tunnel.kind.hasEphemeralURL ? "Creating public URL…" : "Connecting…")
            case .stopping: return "Stopping…"
            case .attention: return runtime.lastError ?? failingCheck ?? state.label
            case .stopped: return "Stopped · \(TunnelRowPresentation.localEndpoint(store.effectiveOrigin(for: tunnel).url) ?? "no local service")"
            default: return publicURL.flatMap { URL(string: $0)?.host } ?? "Waiting for public URL…"
            }
        case .sidebar:
            let origin = store.effectiveOrigin(for: tunnel).url
            if tunnel.kind.usesCloudflareAccount, runtime.statistics == nil {
                return [TunnelRowPresentation.localEndpoint(origin), tunnel.hostname].compactMap { $0 }.joined(separator: " → ")
            }
            if !state.isActive, runtime.statistics == nil {
                return TunnelRowPresentation.localEndpoint(origin) ?? origin
            }
            if !tunnel.kind.reportsTraffic { return statsLine }
            return TunnelRowPresentation.compact(
                localURL: origin,
                statistics: runtime.statistics,
                fallbackStartedAt: runtime.state == .running ? runtime.startedAt : nil
            )
        }
    }

    private var failingCheck: String? {
        store.health(for: tunnel.id)?.checks.first(where: { $0.state == .failed })?.detail
    }

    private var rowHelp: String {
        publicURL != nil && state.isActive ? "Click to copy \(publicURL ?? "")" : "Click to show details"
    }

    private func primaryClick() {
        if state.isActive, publicURL != nil {
            store.copyPublicURL(tunnel.id)
        } else {
            router.show(tunnel: tunnel.id)
        }
    }

    @ViewBuilder
    private var popoverControls: some View {
        if state.isActive, publicURL != nil {
            RowIconButton(
                title: Vocabulary.copyURL,
                systemImage: justCopied ? "checkmark" : "doc.on.doc",
                tint: justCopied ? .green : .primary
            ) { store.copyPublicURL(tunnel.id) }
        }
        playbackButton
        actionsMenu.revealedOnHover(hovering)
    }

    @ViewBuilder
    private var playbackButton: some View {
        switch runtime.state {
        case .running, .starting:
            RowIconButton(title: Vocabulary.stop, systemImage: "stop.fill") { store.stop(tunnel.id) }
        case .stopping:
            ProgressView().controlSize(.mini).frame(width: 24, height: 24)
        case .stopped, .failed:
            RowIconButton(title: Vocabulary.start, systemImage: "play.fill") { store.startSharing(tunnel) }
        }
    }

    private var actionsMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More actions")
        }
        .tint(.secondary)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var actions: some View {
        switch runtime.state {
        case .running, .starting:
            Button(Vocabulary.stop, systemImage: "stop.fill") { store.stop(tunnel.id) }
        case .stopped, .failed:
            Button(Vocabulary.start, systemImage: "play.fill") { store.startSharing(tunnel) }
        case .stopping:
            EmptyView()
        }
        Divider()
        Button(Vocabulary.copyURL, systemImage: "doc.on.doc") { store.copyPublicURL(tunnel.id) }
            .disabled(publicURL == nil)
        Button(Vocabulary.openInBrowser, systemImage: "safari") {
            if let publicURL, let url = URL(string: publicURL) { NSWorkspace.shared.open(url) }
        }
        .disabled(publicURL == nil)
        if store.isCollaborating(tunnel.id) {
            Button("Open as Host", systemImage: "person.crop.circle.badge.checkmark") { store.openAsCollaborationHost(tunnel.id) }
        }
        Divider()
        if style != .sidebar {
            Button(Vocabulary.showDetails, systemImage: "info.circle") { router.show(tunnel: tunnel.id, tab: .overview) }
        }
        if store.isActive(tunnel.id) {
            StopAfterMenu(store: store, id: tunnel.id)
        }
        Button(Vocabulary.showLogs, systemImage: "text.alignleft") { router.show(tunnel: tunnel.id, tab: .logs) }
        Button(Vocabulary.edit, systemImage: "pencil") { router.show(tunnel: tunnel.id, sheet: .edit(tunnel.id)) }
        Divider()
        Button(Vocabulary.remove, systemImage: "trash", role: .destructive) { pendingRemoval = tunnel }
    }
}

struct DiscoveredTunnelRow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: AppStore
    let tunnel: DiscoveredQuickTunnel
    let style: TunnelRowStyle
    @State private var hovering = false

    var body: some View {
        Group {
            if style == .card { cardLayout } else { rowLayout }
        }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.discoveredDisplayName(tunnel)), \(TunnelDisplayState.external.label)")
    }

    private var cardLayout: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                TunnelIcon(originURL: tunnel.localURL, state: .external, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.s - 2) {
                        Text(store.discoveredDisplayName(tunnel))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Elsewhere")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 5)
                            .background(Color.indigo.opacity(0.14), in: Capsule())
                    }
                    Text(justCopied ? "Copied to clipboard" : (URL(string: tunnel.publicURL)?.host ?? tunnel.publicURL))
                        .font(.caption.monospaced())
                        .foregroundStyle(justCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Spacing.xs)
                HStack(spacing: 0) {
                    RowIconButton(
                        title: Vocabulary.copyURL,
                        systemImage: justCopied ? "checkmark" : "doc.on.doc",
                        tint: justCopied ? .green : .primary
                    ) { store.copyPublicURL(tunnel.id) }
                    QRCodeButton(url: tunnel.publicURL)
                        .buttonStyle(.borderless)
                        .frame(width: 24, height: 24)
                    actionsMenu.revealedOnHover(hovering)
                }
            }
            Text(subtitle)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.m)
        .glassCard(tint: .indigo)
        .contentShape(RoundedRectangle(cornerRadius: Radius.large))
        .onTapGesture { store.copyPublicURL(tunnel.id) }
        .onHover { hovering = $0 }
        .help("Click to copy \(tunnel.publicURL)")
    }

    private var rowLayout: some View {
        HStack(spacing: Spacing.s) {
            TunnelIcon(originURL: tunnel.localURL, state: .external, size: style == .sidebar ? 24 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.discoveredDisplayName(tunnel))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Spacing.xs)
            if style == .popover {
                RowIconButton(
                    title: Vocabulary.copyURL,
                    systemImage: justCopied ? "checkmark" : "doc.on.doc",
                    tint: justCopied ? .green : .primary
                ) { store.copyPublicURL(tunnel.id) }
            }
            actionsMenu.revealedOnHover(hovering)
        }
        .padding(.vertical, style == .sidebar ? Spacing.xxs : Spacing.s - 2)
        .padding(.horizontal, style == .sidebar ? 0 : Spacing.s)
        .contentShape(Rectangle())
        .modifier(PopoverRowBehavior(enabled: style == .popover, help: "Click to copy \(tunnel.publicURL)") {
            store.copyPublicURL(tunnel.id)
        })
        .onHover { hovering = $0 }
    }

    private var router: MainWindowRouter { MainWindowRouter(store: store, openWindow: openWindow) }
    private var justCopied: Bool { store.recentlyCopiedID == tunnel.id }

    private var subtitle: String {
        if justCopied, style != .card { return "Copied to clipboard" }
        if style == .popover {
            return URL(string: tunnel.publicURL)?.host ?? tunnel.publicURL
        }
        return TunnelRowPresentation.compact(
            localURL: tunnel.localURL,
            statistics: tunnel.statistics,
            fallbackStartedAt: Date(timeIntervalSince1970: TimeInterval(tunnel.identity.startTimeMicroseconds) / 1_000_000)
        )
    }

    private var actionsMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More actions")
        }
        .tint(.secondary)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var actions: some View {
        Button(Vocabulary.copyURL, systemImage: "doc.on.doc") { store.copyPublicURL(tunnel.id) }
        Button(Vocabulary.openInBrowser, systemImage: "safari") {
            if let url = URL(string: tunnel.publicURL) { NSWorkspace.shared.open(url) }
        }
        Divider()
        if style != .sidebar {
            Button(Vocabulary.showDetails, systemImage: "info.circle") { router.show(tunnel: tunnel.id, tab: .overview) }
        }
        Button(Vocabulary.showLogs, systemImage: "text.alignleft") { router.show(tunnel: tunnel.id, tab: .logs) }
        Button(Vocabulary.rename, systemImage: "pencil") {
            router.show(tunnel: tunnel.id, sheet: .renameDiscovered(tunnel.id))
        }
        if store.hasDiscoveryAlias(tunnel) {
            Button("Use Current Hostname", systemImage: "arrow.uturn.backward") {
                store.renameDiscovered(tunnel, to: "")
            }
        }
        Divider()
        Button("Hide", systemImage: "eye.slash") { store.hideDiscovered(tunnel) }
    }
}

private extension View {
    /// Keeps the control's space reserved so neighbouring buttons never shift on hover.
    func revealedOnHover(_ hovering: Bool) -> some View {
        modifier(RevealedOnHover(hovering: hovering))
    }
}

/// Invisible controls drop out of the accessibility tree, so with VoiceOver on they stay shown.
private struct RevealedOnHover: ViewModifier {
    let hovering: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        let shown = hovering || voiceOver
        content.opacity(shown ? 1 : 0).allowsHitTesting(shown)
    }
}

/// In the menu bar popover, a row click performs the row's primary action and rows highlight on hover.
private struct PopoverRowBehavior: ViewModifier {
    let enabled: Bool
    let help: String
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .hoverHighlight()
                .onTapGesture(perform: action)
                .help(help)
        } else {
            content
        }
    }
}

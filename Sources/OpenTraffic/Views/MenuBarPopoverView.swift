import AppKit
import SwiftUI
import OpenTrafficCore

struct MenuBarPopoverView: View {
    @Environment(\.openWindow) private var openWindow
    /// The popover is on screen (from `pausesAnimationsWhenHidden`).
    @Environment(\.animationsActive) private var popoverVisible
    @Bindable var store: AppStore
    @State private var showingAllServices = false
    @State private var showingAllApps = false
    @State private var showingAllMacApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        if store.cloudflaredPath == nil { setupWarning }
                        if !store.projectNames.isEmpty {
                            sectionTitle("Projects")
                            ForEach(store.projectNames, id: \.self) { name in
                                ProjectRow(store: store, name: name)
                                    .padding(.horizontal, Spacing.s)
                                    .padding(.vertical, Spacing.xxs)
                                    .hoverHighlight()
                            }
                            .padding(.bottom, Spacing.s)
                        }
                        tunnelsSection
                        readyToShareSection
                    }
                    .padding(Spacing.s)
                }
                // The menu bar window is reused between openings; always start at the live tunnels.
                .onAppear { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .frame(width: 360)
        .onChange(of: popoverVisible, initial: true) { _, visible in
            store.setLocalServicesWatched(visible, by: "menu bar")
            // Turned on in System Settings since the last look?
            if visible { store.refreshMacAppPermissions() }
        }
    }

    private var router: MainWindowRouter { MainWindowRouter(store: store, openWindow: openWindow) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Image(nsImage: BrandAssets.menuIcon)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 16)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text("OpenTraffic").font(.headline)
            Spacer()
            HStack(spacing: Spacing.s - 2) {
                if store.menuBarState == .live { LivePulse() }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(store.needsAttention ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText())
            }
            .animation(.snappy, value: statusText)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private var statusText: String {
        let states = store.definitions.map { store.displayState(for: $0) }
        let attention = states.filter { $0 == .attention }.count
        let active = states.filter(\.isActive).count + store.discoveredTunnels.count
        var parts: [String] = []
        if active > 0 { parts.append("\(active) running") }
        if attention > 0 { parts.append("\(attention) need\(attention == 1 ? "s" : "") attention") }
        return parts.isEmpty ? "Nothing shared" : parts.joined(separator: " · ")
    }

    // MARK: Sections

    private var setupWarning: some View {
        InlineMessage(
            severity: .warning,
            message: "cloudflared isn't installed, so tunnels can't start.",
            title: "Finish setup"
        ) {
            Button("Set Up…") { router.show(sheet: .onboarding) }
        }
        .padding(Spacing.s)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.medium))
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder
    private var tunnelsSection: some View {
        let live = store.definitions.filter { isRunning($0) }
        let saved = store.definitions.filter { !isRunning($0) }
        if !live.isEmpty || !store.discoveredTunnels.isEmpty {
            sectionTitle("Live")
            VStack(spacing: Spacing.s) {
                ForEach(live) { tunnel in
                    ManagedTunnelRow(store: store, tunnel: tunnel, style: .card)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                ForEach(store.discoveredTunnels) { tunnel in
                    DiscoveredTunnelRow(store: store, tunnel: tunnel, style: .card)
                }
            }
            .padding(.bottom, Spacing.s)
        }
        if !saved.isEmpty {
            sectionTitle("Saved")
            ForEach(saved) { tunnel in
                ManagedTunnelRow(store: store, tunnel: tunnel, style: .popover)
                    .transition(.opacity)
            }
        }
    }

    /// Running includes connectors that are up but failing; they still serve (or try to serve) traffic.
    private func isRunning(_ tunnel: TunnelDefinition) -> Bool {
        [.running, .starting].contains(store.runtime(for: tunnel.id).state)
    }

    @ViewBuilder
    private var readyToShareSection: some View {
        let services = store.shareableLocalServices
        let apps = store.shareableElectronApps
        let macApps = store.shareableMacApps
        HStack {
            sectionTitle("Localhost")
            Spacer()
            if store.isScanningLocalServices {
                ProgressView().controlSize(.mini)
            } else {
                RowIconButton(title: "Scan for local services", systemImage: "arrow.clockwise") {
                    Task { await store.scanLocalServices() }
                }
            }
        }
        .padding(.top, store.definitions.isEmpty && store.discoveredTunnels.isEmpty ? 0 : Spacing.s)
        if services.isEmpty {
            Text(store.isScanningLocalServices
                 ? "Looking for web servers on this Mac…"
                 : "No unshared web servers found. Start a dev server, or create a tunnel manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, Spacing.xs)
        } else {
            let visible = showingAllServices ? services : Array(services.prefix(Self.collapsedCount))
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, service in
                // Services are sorted newest first; the newest is almost always the one you just started.
                ShareableServiceRow(
                    service: service,
                    isSuggested: index == 0 && apps.isEmpty && macApps.isEmpty,
                    canShare: store.cloudflaredPath != nil,
                    canShareOnTailnet: store.tailscaleBlocker == nil,
                    canShareWithNgrok: store.ngrokBlocker == nil,
                    canShareWithOpenTunnel: store.openTunnelBlocker == nil,
                    defaultKind: store.effectiveDefaultShareKind
                ) { kind in
                    withAnimation(.snappy) { store.share(service, kind: kind) }
                } shareWithCollaboration: {
                    withAnimation(.snappy) { store.shareWithCollaboration(localURL: service.url, name: service.displayName) }
                }
            }
            showMoreButton(total: services.count, expanded: $showingAllServices)
        }
        if !apps.isEmpty {
            sectionTitle("Electron Apps")
                .padding(.top, Spacing.s)
            let visible = showingAllApps ? apps : Array(apps.prefix(Self.collapsedCount))
            ForEach(visible) { app in
                ElectronAppRow(
                    app: app,
                    // An app in development is what you're working on: suggested over plain servers.
                    isSuggested: app.id == apps.first?.id,
                    canShare: store.cloudflaredPath != nil,
                    canShareWithOpenTunnel: store.openTunnelBlocker == nil,
                    defaultKind: store.effectiveDefaultShareKind == .opentunnel ? .opentunnel : .quick
                ) { kind, data in
                    withAnimation(.snappy) { store.share(app, kind: kind, data: data) }
                }
            }
            showMoreButton(total: apps.count, expanded: $showingAllApps)
        }
        if !macApps.isEmpty || store.pendingMacAppShare != nil {
            sectionTitle("Mac Apps")
                .padding(.top, Spacing.s)
            if let pending = store.pendingMacAppShare, !store.missingMacAppPermissions.isEmpty {
                MacAppPermissionsMessage(store: store, waitingApp: pending.app.name) {
                    withAnimation(.snappy) { store.cancelPendingMacAppShare() }
                }
                .padding(Spacing.s)
                .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.medium))
                .padding(.bottom, Spacing.xs)
            }
            let visible = showingAllMacApps ? macApps : Array(macApps.prefix(Self.collapsedCount))
            ForEach(visible) { app in
                MacAppRow(
                    app: app,
                    isSuggested: apps.isEmpty && app.id == macApps.first?.id,
                    canShare: store.cloudflaredPath != nil,
                    canShareWithOpenTunnel: store.openTunnelBlocker == nil,
                    defaultKind: store.effectiveDefaultShareKind == .opentunnel ? .opentunnel : .quick
                ) { kind, data in
                    withAnimation(.snappy) { store.share(app, kind: kind, data: data) }
                }
            }
            showMoreButton(total: macApps.count, expanded: $showingAllMacApps)
        }
    }

    @ViewBuilder
    private func showMoreButton(total: Int, expanded: Binding<Bool>) -> some View {
        if total > Self.collapsedCount {
            Button {
                withAnimation(.snappy) { expanded.wrappedValue.toggle() }
            } label: {
                Label(
                    expanded.wrappedValue ? "Show Fewer" : "Show \(total - Self.collapsedCount) More",
                    systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.xxs)
        }
    }

    private static let collapsedCount = 5
    private static let topAnchor = "popover-top"

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            Button {
                router.show()
            } label: {
                Label("Open OpenTraffic", systemImage: "macwindow")
            }
            Menu {
                ForEach(NewTunnelKind.allCases) { kind in
                    Button { router.show(sheet: .newTunnel(kind)) } label: {
                        Label { Text(kind.title) } icon: { Image(nsImage: BrandAssets.logo(kind.provider, style: .menu)).renderingMode(.template) }
                    }
                }
                .untintedMenuItems()
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Vocabulary.newTunnel)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
            }
            .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        // The accent is for primary actions; utility controls stay neutral.
        .tint(.primary)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }
}

private struct ShareableServiceRow: View {
    let service: DiscoveredLocalService
    var isSuggested = false
    let canShare: Bool
    var canShareOnTailnet = false
    var canShareWithNgrok = false
    var canShareWithOpenTunnel = false
    var defaultKind: TunnelKind = .quick
    let share: (TunnelKind) -> Void
    var shareWithCollaboration: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.s) {
            // Clicking the service itself opens it locally, for a quick look before sharing.
            Button(action: openLocally) {
                HStack(spacing: Spacing.s) {
                    TunnelIcon(originURL: service.url, fallbackSymbol: "server.rack", size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.displayName)
                            .lineLimit(1)
                        // Ticks once a minute so "up 12 min" stays current while the menu is open.
                        TimelineView(.everyMinute) { _ in
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Spacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(service.url) in your browser")
            .accessibilityLabel("Open \(service.displayName) in your browser")
            .contextMenu {
                Group {
                    Button("Open in Browser", systemImage: "safari", action: openLocally)
                    Button("Copy Address", systemImage: "doc.on.doc") { Pasteboard.copy(service.url) }
                }
                .untintedMenuItems()
            }
            Menu {
                shareItems.untintedMenuItems()
            } label: {
                Text(Vocabulary.share)
            } primaryAction: {
                share(defaultKind)
            }
            .menuStyle(.button)
            .buttonStyle(isSuggested ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
            .controlSize(.small)
            .fixedSize()
            .disabled(!canShare && !canShareOnTailnet && !canShareWithNgrok && !canShareWithOpenTunnel)
                .help(shareHelp)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var shareItems: some View {
        shareItem("Temporary Public URL", provider: .cloudflare) { share(.quick) }
            .disabled(!canShare)
        shareItem("Private on Your Tailnet", provider: .tailscale) { share(.tailscale) }
            .disabled(!canShareOnTailnet)
        shareItem("Public with ngrok", provider: .ngrok) { share(.ngrok) }
            .disabled(!canShareWithNgrok)
        shareItem("Lasting Address with OpenTunnel", provider: .opentunnel) { share(.opentunnel) }
            .disabled(!canShareWithOpenTunnel || !service.url.lowercased().hasPrefix("http://"))
        if let shareWithCollaboration {
            Divider()
            Button("Temporary URL with Live Collaboration", systemImage: "person.2.wave.2", action: shareWithCollaboration)
                .disabled(!canShare || !service.url.lowercased().hasPrefix("http://"))
        }
    }

    private func openLocally() {
        guard let url = URL(string: service.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private var shareHelp: String {
        switch defaultKind {
        case .tailscale: "Share \(service.url) privately on your tailnet and copy the URL"
        case .ngrok: "Share \(service.url) with ngrok and copy the URL"
        case .opentunnel: "Share \(service.url) at a lasting OpenTunnel address and copy the URL"
        default: "Create a temporary public URL for \(service.url) and copy it"
        }
    }

    @ViewBuilder
    private func shareItem(_ title: String, provider: TunnelProvider, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { Image(nsImage: BrandAssets.logo(provider, style: .menu)).renderingMode(.template) } }
    }

    private var details: String {
        var parts = [":\(service.port)"]
        if let process = service.processName?.nilIfBlank { parts.insert(process, at: 0) }
        if let upSince = service.upSince ?? service.startedAt {
            parts.append(ShareableServiceUptime.text(since: upSince))
        }
        return parts.joined(separator: " · ")
    }
}

/// An Electron app in development, shared like a web server: its windows open in viewers'
/// browsers and its main process runs sandboxed here, with a copy of its data.
private struct ElectronAppRow: View {
    let app: ElectronApp
    var isSuggested = false
    let canShare: Bool
    var canShareWithOpenTunnel = false
    var defaultKind: TunnelKind = .quick
    let share: (TunnelKind, ElectronHostSession.DataSource) -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(nsImage: AppStore.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .lineLimit(1)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Spacing.xs)
            }
            .contentShape(Rectangle())
            .help("\(app.name), an Electron app in \((app.bundle ?? app.appDirectory).path)")
            .contextMenu {
                Group {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([app.bundle ?? app.appDirectory]) }
                    Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy((app.bundle ?? app.appDirectory).path) }
                }
                .untintedMenuItems()
            }
            Menu {
                Group {
                    shareItem("Temporary Public URL", provider: .cloudflare) { share(.quick, .copy) }
                        .disabled(!canShare)
                    shareItem("Lasting Address with OpenTunnel", provider: .opentunnel) { share(.opentunnel, .copy) }
                        .disabled(!canShareWithOpenTunnel)
                    if !app.isPackaged {
                        Divider()
                        Button("Share with Empty Data", systemImage: "tray") { share(defaultKind, .empty) }
                            .disabled(defaultKind == .quick ? !canShare : !canShareWithOpenTunnel)
                    }
                }
                .untintedMenuItems()
            } label: {
                Text(Vocabulary.share)
            } primaryAction: {
                share(defaultKind, .copy)
            }
            .menuStyle(.button)
            .buttonStyle(isSuggested ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
            .controlSize(.small)
            .fixedSize()
            .disabled(!canShare && !canShareWithOpenTunnel)
            .help("Share \(app.name) with live collaboration and copy the URL. Its main process runs sandboxed on this Mac, with \(app.isPackaged ? "empty data" : "a copy of its data").")
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [app.isPackaged ? "Electron · built app" : "Electron"]
        let home = ElectronSandbox.realHomeDirectory
        var path = (app.bundle ?? app.appDirectory).path
        if path.hasPrefix("/private/tmp/") { path.removeFirst("/private".count) } // as it's usually typed
        parts.append(path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func shareItem(_ title: String, provider: TunnelProvider, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { Image(nsImage: BrandAssets.logo(provider, style: .menu)).renderingMode(.template) } }
    }
}

/// A Mac app being developed, shared like a web server: an isolated copy runs hidden on this Mac
/// with a copy of its data, and its window opens in viewers' browsers.
private struct MacAppRow: View {
    let app: MacApp
    var isSuggested = false
    let canShare: Bool
    var canShareWithOpenTunnel = false
    var defaultKind: TunnelKind = .quick
    let share: (TunnelKind, MacAppSession.DataSource) -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(nsImage: AppStore.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .lineLimit(1)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Spacing.xs)
            }
            .contentShape(Rectangle())
            .help("\(app.name), a Mac app\(app.isRunning ? " (running)" : "") at \(app.bundle.path)")
            .contextMenu {
                Group {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([app.bundle]) }
                    Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(app.bundle.path) }
                }
                .untintedMenuItems()
            }
            Menu {
                Group {
                    shareItem("Temporary Public URL", provider: .cloudflare) { share(.quick, .copy) }
                        .disabled(!canShare)
                    shareItem("Lasting Address with OpenTunnel", provider: .opentunnel) { share(.opentunnel, .copy) }
                        .disabled(!canShareWithOpenTunnel)
                    Divider()
                    Button("Share with Empty Data", systemImage: "tray") { share(defaultKind, .empty) }
                        .disabled(defaultKind == .quick ? !canShare : !canShareWithOpenTunnel)
                }
                .untintedMenuItems()
            } label: {
                Text(Vocabulary.share)
            } primaryAction: {
                share(defaultKind, .copy)
            }
            .menuStyle(.button)
            .buttonStyle(isSuggested ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
            .controlSize(.small)
            .fixedSize()
            .disabled(!canShare && !canShareWithOpenTunnel)
            .help("Share \(app.name) with live collaboration and copy the URL. A separate copy runs hidden on this Mac with a copy of its data.")
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }

    /// `Mac app · ~/code/orbit`: where it's built from (or the app itself when that isn't known).
    private var details: String {
        let home = ElectronSandbox.realHomeDirectory
        var path = (app.projectDirectory ?? app.bundle).path
        if path.hasPrefix("/private/tmp/") { path.removeFirst("/private".count) }
        return "Mac app · " + (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }

    @ViewBuilder
    private func shareItem(_ title: String, provider: TunnelProvider, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { Image(nsImage: BrandAssets.logo(provider, style: .menu)).renderingMode(.template) } }
    }
}

/// Type-erased primitive button style, for choosing prominence at runtime.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

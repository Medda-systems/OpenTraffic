import AppKit
import SwiftUI
import OpenTrafficCore

struct MenuBarPopoverView: View {
    @Environment(\.openWindow) private var openWindow
    /// The popover is on screen (from `pausesAnimationsWhenHidden`).
    @Environment(\.animationsActive) private var popoverVisible
    @Bindable var store: AppStore
    @State private var showingAllServices = false

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
        HStack {
            sectionTitle("Ready to Share")
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
            let visible = showingAllServices ? services : Array(services.prefix(Self.collapsedServiceCount))
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, service in
                // Services are sorted newest first; the newest is almost always the one you just started.
                ShareableServiceRow(
                    service: service,
                    isSuggested: index == 0,
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
            if services.count > Self.collapsedServiceCount {
                Button {
                    withAnimation(.snappy) { showingAllServices.toggle() }
                } label: {
                    Label(
                        showingAllServices ? "Show Fewer" : "Show \(services.count - Self.collapsedServiceCount) More",
                        systemImage: showingAllServices ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, Spacing.s)
                .padding(.top, Spacing.xxs)
            }
        }
    }

    private static let collapsedServiceCount = 5
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

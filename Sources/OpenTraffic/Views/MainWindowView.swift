import SwiftUI
import OpenTrafficCore

struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.windowIsOpen) private var windowIsOpen
    @Bindable var store: AppStore

    var body: some View {
        // SwiftUI keeps a closed window's views alive; without this they'd keep re-rendering
        // on every status poll while nobody can see them.
        Group {
            if windowIsOpen {
                content
            } else {
                Color.clear
            }
        }
        .background(MainWindowAccessor())
    }

    private var content: some View {
        NavigationSplitView {
            TunnelSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let tunnel = store.selectedDefinition {
                // A fresh identity per tunnel, so in-progress state, filters, and selections
                // don't carry over from the previously selected one.
                TunnelDetailView(store: store, tunnel: tunnel)
                    .id(tunnel.id)
            } else if let tunnel = store.selectedDiscoveredTunnel {
                DiscoveredTunnelDetailView(store: store, tunnel: tunnel)
                    .id(tunnel.id)
            } else {
                emptyState
            }
        }
        .navigationTitle("OpenTraffic")
        .sheet(item: $store.presentedSheet) { sheet in
            switch sheet {
            case .newTunnel(let kind):
                NewTunnelSheet(store: store, initialKind: kind)
            case .edit(let id):
                if let tunnel = store.definitions.first(where: { $0.id == id }) {
                    EditTunnelSheet(store: store, tunnel: tunnel)
                } else {
                    Color.clear.onAppear { store.presentedSheet = nil }
                }
            case .renameDiscovered(let id):
                if let tunnel = store.discoveredTunnels.first(where: { $0.id == id }) {
                    RenameDiscoveredSheet(store: store, tunnel: tunnel)
                } else {
                    Color.clear.onAppear { store.presentedSheet = nil }
                }
            case .hostHeader(let id):
                if let tunnel = store.definitions.first(where: { $0.id == id }) {
                    HostHeaderSheet(store: store, tunnel: tunnel)
                } else {
                    Color.clear.onAppear { store.presentedSheet = nil }
                }
            case .protection(let id):
                if let tunnel = store.definitions.first(where: { $0.id == id }) {
                    ProtectionSheet(store: store, tunnel: tunnel)
                } else {
                    Color.clear.onAppear { store.presentedSheet = nil }
                }
            case .onboarding:
                OnboardingView(store: store)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                NoticeToast(notice: notice) { action in
                    store.notice = nil
                    switch action {
                    case .openSettings: openSettings()
                    }
                } onDismiss: {
                    if store.notice?.id == notice.id { store.notice = nil }
                }
                .padding(Spacing.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.notice?.id)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Share a Local Server", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Give a dev server on this Mac a public URL. Use a temporary address for quick demos, or a hostname on your own Cloudflare domain. A Mac app you built can be shared too: people use it in their browser.")
        } actions: {
            Button("New Tunnel…") { store.present(.newTunnel(.quick)) }
                .buttonStyle(.borderedProminent)
            Button("Share a Mac App…") { store.chooseMacAppToShare() }
            Button("Import from Cloudflare…") { store.present(.newTunnel(.importExisting)) }
        }
    }
}

struct RenameDiscoveredSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: AppStore
    let tunnel: DiscoveredQuickTunnel
    @State private var name = ""

    var body: some View {
        SheetScaffold(
            title: "Rename Tunnel",
            subtitle: "This name follows the same cloudflared executable and local service across restarts."
        ) {
            Form {
                TextField("Name", text: $name, prompt: Text(tunnel.publicURL.replacingOccurrences(of: "https://", with: "")))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        } trailingFooter: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Rename") {
                store.renameDiscovered(tunnel, to: name)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(name.nilIfBlank == nil)
        }
        .frame(width: 440)
        .onAppear { name = store.hasDiscoveryAlias(tunnel) ? store.discoveredDisplayName(tunnel) : "" }
    }
}

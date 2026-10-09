import SwiftUI
import OpenTrafficCore

struct TunnelSidebarView: View {
    @Bindable var store: AppStore
    @State private var pendingRemoval: TunnelDefinition?

    var body: some View {
        List(selection: $store.selectedID) {
            if !store.projectNames.isEmpty {
                Section("Projects") {
                    ForEach(store.projectNames, id: \.self) { name in
                        ProjectRow(store: store, name: name)
                    }
                }
            }
            ForEach(TunnelKind.allCases, id: \.self) { kind in
                tunnelSection(kind.sectionTitle, kind: kind)
            }
            if !store.discoveredTunnels.isEmpty {
                Section {
                    ForEach(store.discoveredTunnels) { tunnel in
                        DiscoveredTunnelRow(store: store, tunnel: tunnel, style: .sidebar)
                            .tag(tunnel.id)
                    }
                } header: {
                    Text("Running Elsewhere")
                        .help("Quick Tunnels started outside OpenTraffic, for example in Terminal")
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let definition = store.selectedDefinition { pendingRemoval = definition }
        }
        .overlay {
            if store.definitions.isEmpty && store.discoveredTunnels.isEmpty {
                ContentUnavailableView {
                    Label("No Tunnels", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Share a local server to see it here.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    ForEach(NewTunnelKind.allCases) { kind in
                        Button { store.present(.newTunnel(kind)) } label: {
                        Label { Text(kind.title) } icon: { Image(nsImage: BrandAssets.logo(kind.provider, style: .menu)) }
                    }
                    }
                } label: {
                    Label("New Tunnel", systemImage: "plus")
                } primaryAction: {
                    store.present(.newTunnel(.quick))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New Tunnel (⌘N)")
                Spacer()
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
        }
        .confirmsRemoval(of: $pendingRemoval, store: store)
    }

    @ViewBuilder
    private func tunnelSection(_ title: String, kind: TunnelKind) -> some View {
        let tunnels = store.definitions.filter { $0.kind == kind }
        if !tunnels.isEmpty {
            Section {
                ForEach(tunnels) { tunnel in
                    ManagedTunnelRow(store: store, tunnel: tunnel, style: .sidebar)
                        .tag(tunnel.id)
                }
            } header: {
                HStack(spacing: Spacing.s - 2) {
                    ProviderLogo(provider: kind.provider, height: 10, tint: .secondary)
                    Text(title)
                }
            }
        }
    }
}

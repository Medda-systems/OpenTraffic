import AppKit
import SwiftUI
import OpenTrafficCore

struct DiscoveredTunnelDetailView: View {
    @Bindable var store: AppStore
    let tunnel: DiscoveredQuickTunnel
    @State private var confirmingManagement = false

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                previewIdentity: "discovered:\(tunnel.preferenceKey)",
                originURL: tunnel.localURL,
                title: store.discoveredDisplayName(tunnel),
                state: .external,
                caption: "Quick Tunnel · PID \(tunnel.identity.pid)"
            ) {
                Button("Manage in OpenTraffic…") { confirmingManagement = true }
                    .disabled(tunnel.localURL == nil)
                    .help(tunnel.localURL == nil
                          ? "OpenTraffic couldn't determine this tunnel's local service."
                          : "Stop the external process and recreate the tunnel inside OpenTraffic")
            }
            Divider()
            switch store.detailTab {
            case .overview, .requests, .feedback: overview
            case .logs: logs
            }
        }
        .toolbar {
            DetailTabPicker(selection: $store.detailTab)
            ToolbarItem {
                Menu {
                    Group {
                        Button(Vocabulary.copyURL, systemImage: "doc.on.doc") { store.copyPublicURL(tunnel.id) }
                        Button(Vocabulary.openInBrowser, systemImage: "safari") {
                            if let url = URL(string: tunnel.publicURL) { NSWorkspace.shared.open(url) }
                        }
                        Divider()
                        Button(Vocabulary.rename, systemImage: "pencil") { store.present(.renameDiscovered(tunnel.id)) }
                        Button("Hide", systemImage: "eye.slash") { store.hideDiscovered(tunnel) }
                    }
                    .untintedMenuItems()
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Move this tunnel into OpenTraffic?", isPresented: $confirmingManagement) {
            Button("Stop External Process and Manage") {
                Task { await store.manageInOpenTraffic(tunnel) }
            }
        } message: {
            Text("OpenTraffic will verify and gracefully stop PID \(tunnel.identity.pid), then start its own Quick Tunnel for \(tunnel.localURL ?? "the same local service"). The public URL will change. The external process is never force-quit.")
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                Card {
                    PublicURLCard(url: tunnel.publicURL) {
                        HStack(spacing: Spacing.s) {
                            Text(Vocabulary.localService).foregroundStyle(.secondary)
                            Text(tunnel.localURL ?? "Unknown").monospaced().textSelection(.enabled)
                            Spacer()
                        }
                        .font(.callout)
                        .padding(.top, Spacing.xs)
                    }
                    Divider()
                    InlineMessage(
                        severity: .info,
                        message: "OpenTraffic is only observing this process. Stop, Remove, and Quit never affect it unless you choose Manage in OpenTraffic."
                    )
                }

                TrafficCard(
                    statistics: tunnel.statistics,
                    startedAt: startedAt,
                    history: store.requestHistory[tunnel.id],
                    emptyMessage: "This process doesn't expose metrics."
                )

                Card(title: "Process") {
                    FactRows(rows: [
                        ("PID", "\(tunnel.identity.pid)", true),
                        ("Started", startedAt.formatted(date: .abbreviated, time: .standard), false),
                        ("Executable", tunnel.executablePath, true),
                        ("Metrics", tunnel.metricsPort.map { "127.0.0.1:\($0)" } ?? "Unavailable", true),
                    ])
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var logs: some View {
        if tunnel.logFilePath == nil {
            ContentUnavailableView {
                Label("Logs Unavailable", systemImage: "text.alignleft")
            } description: {
                Text("OpenTraffic can't read another process's Terminal output. Start cloudflared with an absolute --logfile path to see a read-only tail here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogConsole(
                entries: tunnel.logEntries,
                source: tunnel.logFilePath,
                emptyTitle: "No readable log entries",
                emptyMessage: "The log file is empty, unavailable, or not a regular file owned by you."
            )
        }
    }

    private var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(tunnel.identity.startTimeMicroseconds) / 1_000_000)
    }
}

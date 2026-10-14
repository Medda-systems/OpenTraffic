import AppKit
import SwiftUI
import OpenTrafficCore

enum OpenTunnelLinks {
    static let website = URL(string: "https://opentunnel.xyz")!
    static let repository = URL(string: "https://github.com/anomalyco/opentunnel")!
}

/// OpenTunnel's CLI, OpenTraffic's tunnel address, and its service. Renders Form sections.
struct OpenTunnelStatusView: View {
    @Bindable var store: AppStore
    var showsSettings = false
    @State private var isRefreshing = false

    var body: some View {
        Section {
            // Missing, the install row says everything; the status headline is for an installed OpenTunnel.
            if store.openTunnelPath != nil {
                HStack(spacing: Spacing.m) {
                    Image(systemName: headline.symbol)
                        .font(.title2)
                        .foregroundStyle(headline.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(headline.title).fontWeight(.semibold)
                        Text(headline.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Again", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(isRefreshing)
                        .help("Check OpenTunnel again")
                }
            }
            if store.openTunnelPath == nil {
                ToolInstallRow(store: store, provider: .opentunnel, purpose: "A lasting opentunnel.xyz address, encrypted until it reaches your Mac. No account needed.", prominent: true)
            } else {
                LabeledContent("Address") {
                    Text(store.openTunnelHostname ?? "Created with the first share")
                        .foregroundStyle(store.openTunnelHostname == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                LabeledContent("Service") {
                    Text(serviceText).foregroundStyle(.secondary)
                }
                if let error = store.openTunnelStatus?.lastError {
                    InlineMessage(severity: .warning, message: error, title: "Last error")
                }
            }
        } header: {
            Text("OpenTunnel")
        } footer: {
            Text("OpenTunnel gives this Mac one lasting address on opentunnel.xyz; each shared app is a name in front of it. TLS ends on this Mac, so the relay can't read the traffic. OpenTraffic uses its own “\(OpenTunnel.profile)” profile and never changes routes you add yourself. OpenTunnel is an early beta from Anomaly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.refreshOpenTunnel() }

        if showsSettings {
            Section {
                Text("Anyone with a share's link can open it. When the tunnel is created its address is published in certificate transparency logs, and route names are easy to guess, so anything private should ask visitors to sign in itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            }
        }
    }

    private var serviceText: String {
        guard let status = store.openTunnelStatus else { return "Not running (starts with the first share)" }
        switch status.phase {
        case .running where status.isConnected:
            return "Connected · \(status.routes.count == 1 ? "1 route" : "\(status.routes.count) routes")" + (status.version.map { " · v\($0)" } ?? "")
        case .provisioning: return "Waiting for its certificate…"
        case .stopped: return "Stopped after an error"
        case .noTunnel: return "Waiting for a tunnel"
        case .running: return (status.state ?? "Connecting").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private var headline: (title: String, detail: String, symbol: String, tint: Color) {
        guard let path = store.openTunnelPath else {
            return ("OpenTunnel isn't installed", "Install its command-line tool, then check again.", "exclamationmark.triangle.fill", .orange)
        }
        return ("OpenTunnel is ready", path.path, "checkmark.circle.fill", .green)
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await store.refreshOpenTunnel()
            isRefreshing = false
        }
    }
}

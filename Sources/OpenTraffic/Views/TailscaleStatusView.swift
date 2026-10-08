import AppKit
import SwiftUI
import OpenTrafficCore

enum TailscaleLinks {
    static let dnsSettings = URL(string: "https://login.tailscale.com/admin/dns")!
    static let accessControls = URL(string: "https://login.tailscale.com/admin/acls/file")!
    static let download = URL(string: "https://tailscale.com/download/mac")!

    static func openApp() {
        let candidates = ["/Applications/Tailscale.app"]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.open(download)
        }
    }
}

extension AppStore {
    /// Why Tailscale sharing can't be used right now, or nil when it's ready.
    var tailscaleBlocker: String? {
        guard tailscalePath != nil else { return "Tailscale isn't installed." }
        guard let status = tailscaleStatus else { return "Checking Tailscale…" }
        guard status.isRunning else { return "Tailscale isn't connected." }
        guard status.httpsEnabled else { return "HTTPS certificates are off for your tailnet." }
        return nil
    }
}

/// Tailscale connection, capabilities, and other shares on this Mac. Renders Form sections.
struct TailscaleStatusView: View {
    @Bindable var store: AppStore
    var showsSettings = false
    @State private var isRefreshing = false

    var body: some View {
        Section {
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
                } else if store.tailscalePath == nil {
                    Button("Get Tailscale…") { NSWorkspace.shared.open(TailscaleLinks.download) }
                } else if store.tailscaleStatus?.isRunning != true {
                    Button("Open Tailscale") { TailscaleLinks.openApp() }
                }
                Button("Check Again", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isRefreshing)
                    .help("Check Tailscale again")
            }
            if let status = store.tailscaleStatus, status.isRunning {
                capabilityRow(
                    "HTTPS certificates",
                    enabled: status.httpsEnabled,
                    help: "Needed for every share. Turn on HTTPS on the DNS page of the admin console.",
                    link: TailscaleLinks.dnsSettings
                )
                capabilityRow(
                    "Public sharing (Funnel)",
                    enabled: status.funnelEnabled,
                    help: "Optional. Lets a share be opened by anyone on the internet. Allow Funnel for this device in your access controls.",
                    link: TailscaleLinks.accessControls
                )
            }
        } header: {
            Text("Tailscale")
        } footer: {
            Text("Private shares can only be opened by devices signed in to your tailnet. Each app gets its own HTTPS port on this Mac's name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if showsSettings {
            let others = store.otherTailscaleShares
            if !others.isEmpty {
                Section("Other Shares on This Mac") {
                    ForEach(others, id: \.port) { entry in
                        LabeledContent {
                            Text(entry.proxy ?? "—").monospaced().textSelection(.enabled)
                        } label: {
                            Text("Port \(String(entry.port))")
                            Text(entry.isFunnel ? "Public (Funnel)" : "Private")
                        }
                    }
                    Text("Created outside OpenTraffic. OpenTraffic never changes or removes these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Tailscale CLI") {
                LabeledContent("Status") {
                    if let path = store.tailscalePath?.path {
                        Label(path, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                LabeledContent("Custom location") {
                    TextField("Custom location", text: $store.customTailscalePath, prompt: Text("Automatic"))
                        .labelsHidden()
                }
            }
        }
    }

    private func capabilityRow(_ title: String, enabled: Bool, help: String, link: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                if !enabled {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !enabled {
                Button("Admin Console…") { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
            }
        }
    }

    private var headline: (title: String, detail: String, symbol: String, tint: Color) {
        guard store.tailscalePath != nil else {
            return ("Not installed", "Install the Tailscale app to share privately with your devices.", "xmark.circle", .secondary)
        }
        guard let status = store.tailscaleStatus else {
            return ("Checking…", "Asking Tailscale for its status.", "circle.dotted", .secondary)
        }
        guard status.isRunning else {
            return ("Not connected", "Tailscale is \(status.backendState.lowercased()). Open Tailscale and sign in.", "network.slash", .yellow)
        }
        return ("Connected", status.dnsName ?? "This Mac", "checkmark.shield.fill", .green)
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await store.refreshTailscale()
            isRefreshing = false
        }
    }
}

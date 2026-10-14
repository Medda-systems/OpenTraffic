import AppKit
import OpenTrafficCore
import SwiftUI

/// One tool OpenTraffic shares through: whether it's ready, and if not, a single Install button that
/// says exactly what it downloads (version, size, where from, who signed it) and shows each step.
struct ToolInstallRow: View {
    @Bindable var store: AppStore
    let provider: TunnelProvider
    var purpose: String
    var recommended = false
    /// The Install button is the main action here (one tool on its own), not one of several.
    var prominent = false

    private var state: ToolInstallState { store.toolState(provider) }
    private var path: URL? { store.toolPath(provider) }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(nsImage: BrandAssets.logo(provider, style: .toolbar))
                .frame(width: 38, height: 38)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.s) {
                    Text(title).font(.body.weight(.semibold))
                    if recommended, path == nil {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Spacing.xs)
        .task(id: path == nil) {
            if path == nil { await store.loadToolRelease(provider) }
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch provider {
        case .cloudflare: "Cloudflare"
        case .opentunnel: "OpenTunnel"
        case .ngrok: "ngrok"
        case .tailscale: "Tailscale"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .preparing:
            caption("Finding the latest version…")
        case let .downloading(received, total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: total.map { $0 > 0 ? Double(received) / Double($0) : 0 })
                caption("Downloading \(provider.executableName) · \(megabytes(received))\(total.map { " of \(megabytes($0))" } ?? "")")
            }
        case .verifying:
            if let release = store.toolReleases[provider], release.teamID != nil {
                // "Cloudflare, Inc." → "Checking Cloudflare's signature…"
                caption("Checking \(release.publisher.components(separatedBy: ",")[0])'s signature…")
            } else {
                caption("Checking it matches the published checksum…")
            }
        case .installing:
            caption(provider == .tailscale ? "Finish in the Installer window. It asks for your Mac's password…" : "Installing…")
        case let .installed(version):
            caption("Installed just now · \(provider.executableName) \(version)")
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .idle:
            if provider == .tailscale, path != nil, let blocker = store.tailscaleBlocker {
                caption("Installed · \(blocker) Open Tailscale to sign in.")
            } else if let path {
                caption(readyText(path))
            } else {
                caption(purpose)
                if let release = store.toolReleases[provider] {
                    caption(downloadSummary(release)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if state.isBusy {
            ProgressView().controlSize(.small).frame(width: 24)
        } else if case .failed = state {
            Button("Try Again") { Task { await store.installTool(provider) } }
        } else if provider == .tailscale, path != nil, store.tailscaleBlocker != nil {
            Button("Open Tailscale") { NSWorkspace.shared.open(ManagedTools.tailscaleApp) }
        } else if path != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Ready")
        } else {
            HStack(spacing: Spacing.xs) {
                Button("Install") { Task { await store.installTool(provider) } }
                    .buttonStyle(InstallButtonStyle(prominent: recommended || prominent))
                if provider == .tailscale {
                    // The same app, installed another way.
                    Menu {
                        Button("Get It from the App Store") { store.openTailscaleInAppStore() }
                        Button("Copy Homebrew Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(AppStore.tailscaleHomebrewCommand, forType: .string)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Other ways to install Tailscale")
                }
            }
        }
    }

    private func readyText(_ path: URL) -> String {
        if path.path == ManagedTools.path(for: provider).path, let version = ManagedTools.installedVersion(of: provider) {
            return "Ready · \(provider.executableName) \(version), installed by OpenTraffic"
        }
        return provider == .tailscale ? "Ready · the Tailscale app is installed" : "Ready · \(path.path)"
    }

    /// "2026.10.0 · 19.8 MB from github.com · signed by Cloudflare, Inc."
    private func downloadSummary(_ release: ToolRelease) -> String {
        var parts: [String] = []
        if let version = release.version { parts.append(version) }
        parts.append([release.size.map(megabytes), "from \(release.host)"].compactMap { $0 }.joined(separator: " "))
        parts.append(release.teamID != nil ? "signed by \(release.publisher)" : "checksum-verified")
        if release.needsPassword { parts.append("asks for your Mac's password") }
        return parts.joined(separator: " · ")
    }

    private func caption(_ text: String) -> Text {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

/// A thin bar that fills with the download (or pulses when the size isn't known).
private struct ProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(6, geometry.size.width * min(1, fraction ?? 0.3)))
                    .animation(.linear(duration: 0.15), value: fraction)
            }
        }
        .frame(height: 5)
        .frame(maxWidth: 360)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// The recommended tool's Install button is the prominent one; the others are quieter.
private struct InstallButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}

/// After ngrok is installed: connecting the account with an authtoken pasted from ngrok's dashboard.
struct NgrokConnectRow: View {
    @Bindable var store: AppStore
    @State private var token = ""
    @State private var error: String?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text("Connect your ngrok account").font(.callout.weight(.semibold))
                Spacer()
                Button("Get Your Authtoken") { NSWorkspace.shared.open(NgrokLinks.authtoken) }
                    .buttonStyle(.link)
            }
            HStack(spacing: Spacing.s) {
                SecureField("ngrok authtoken", text: $token, prompt: Text("Paste your authtoken"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                Button(connecting ? "Connecting…" : "Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
            }
            Text(error ?? "ngrok's free plan is enough. OpenTraffic saves the token in ngrok's own settings, like ngrok config add-authtoken does.")
                .font(.caption)
                .foregroundStyle(error == nil ? .secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 38 + Spacing.m)
        .padding(.vertical, Spacing.xs)
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        Task {
            do {
                try await store.connectNgrok(authtoken: token)
                token = ""
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

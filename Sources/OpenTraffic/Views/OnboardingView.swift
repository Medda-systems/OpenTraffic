import AppKit
import SwiftUI
import OpenTrafficCore

/// First-run setup: install the tools to share with (one click each), optionally connect Cloudflare, choose preferences.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    @State private var step = Step.cloudflared

    private enum Step: Int, CaseIterable {
        case cloudflared
        case cloudflare
        case preferences

        var title: String {
            switch self {
            case .cloudflared: "Choose how you'll share"
            case .cloudflare: "Connect Cloudflare"
            case .preferences: "Finishing Touches"
            }
        }

        var subtitle: String {
            switch self {
            case .cloudflared: "OpenTraffic shares through these free tools. Install the ones you want now, or add more any time in Settings."
            case .cloudflare: "Optional. Needed only for stable hostnames on your own domain. Temporary URLs work without an account."
            case .preferences: "You can change these any time in Settings."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(step == .cloudflared ? "Welcome to OpenTraffic" : step.title)
                        .font(.title2.weight(.semibold))
                    Text(step.subtitle).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Spacing.xl)

            StepIndicator(current: step.rawValue, count: Step.allCases.count)
                .padding(.horizontal, Spacing.xl)

            Form {
                switch step {
                case .cloudflared:
                    ToolsSetupSection(store: store)
                case .cloudflare:
                    CloudflareConnectionView(store: store, mode: .inline)
                case .preferences:
                    Section {
                        Toggle("Copy the public URL when a tunnel starts", isOn: $store.autoCopyPublicURL)
                        Toggle("Notify when a public URL is ready", isOn: $store.notifyWhenReady)
                        Toggle("Notify when a tunnel needs attention", isOn: $store.notifyOnFailure)
                        Picker("Show in Dock", selection: $store.dockVisibility) {
                            ForEach(DockVisibility.allCases) { Text($0.title).tag($0) }
                        }
                    } footer: {
                        Text("Tip: the menu bar icon lists web servers running on this Mac. Click Share next to one to get a public URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if step != .cloudflared {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .cloudflared }
                }
                Spacer()
                Button("Skip Setup") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                if step == .preferences {
                    Button("Share a Server…") {
                        finish()
                        // Hand off directly; present() won't replace the sheet that is closing.
                        store.presentedSheet = .newTunnel(.quick)
                    }
                    Button("Done") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .cloudflare && !isConnected ? "Skip for Now" : "Continue") {
                        step = Step(rawValue: step.rawValue + 1) ?? .preferences
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.l)
        }
        .frame(width: 620, height: 600)
        .interactiveDismissDisabled()
        // Tailscale comes from the App Store, so look again whenever OpenTraffic is back in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.toolsRevision += 1
        }
    }

    private var isConnected: Bool {
        !store.accountID.isEmpty && store.hasAPIToken() && store.isAPITokenUnlocked
    }

    private func finish() {
        store.hasCompletedOnboarding = true
        if store.notifyWhenReady || store.notifyOnFailure {
            TunnelNotifications.requestAuthorizationIfNeeded()
        }
        dismiss()
    }
}

private struct StepIndicator: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The tools to share with, each installable in one click; the two that need no account can be
/// installed together.
struct ToolsSetupSection: View {
    @Bindable var store: AppStore

    private var missingFree: [TunnelProvider] {
        [TunnelProvider.cloudflare, .opentunnel].filter { store.toolPath($0) == nil }
    }

    var body: some View {
        Section {
            ToolInstallRow(store: store, provider: .cloudflare, purpose: "Temporary trycloudflare.com URLs, or your own domain. No account needed.", recommended: true)
            ToolInstallRow(store: store, provider: .opentunnel, purpose: "A lasting address that stays the same every time. No account needed.")
            ToolInstallRow(store: store, provider: .ngrok, purpose: "Your ngrok domain, with a request inspector and password protection. Free account.")
            if store.ngrokPath != nil, !store.ngrokAuthtokenConfigured {
                NgrokConnectRow(store: store)
            }
            ToolInstallRow(store: store, provider: .tailscale, purpose: "Private to your own devices, or public through Funnel.")
        } footer: {
            HStack(alignment: .top, spacing: Spacing.l) {
                Text("Each tool comes from its maker's official release and is checked before it's installed. The command-line tools go in OpenTraffic's own folder, with no password; Tailscale, a Mac app, opens in Apple's Installer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if missingFree.count == 2 {
                    Button("Install Cloudflare and OpenTunnel") { Task { await store.installTools(missingFree) } }
                        .disabled(missingFree.contains { store.toolState($0).isBusy })
                }
            }
        }
    }
}

import SwiftUI
import OpenTrafficCore

/// First-run setup: install cloudflared, optionally connect Cloudflare, choose preferences.
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
            case .cloudflared: "Install cloudflared"
            case .cloudflare: "Connect Cloudflare"
            case .preferences: "Finishing Touches"
            }
        }

        var subtitle: String {
            switch self {
            case .cloudflared: "OpenTraffic uses Cloudflare's connector to publish servers running on this Mac."
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
                    CloudflaredSettingsSection(store: store)
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
        .frame(width: 600, height: 540)
        .interactiveDismissDisabled()
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

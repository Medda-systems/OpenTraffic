import AppKit
import ServiceManagement
import SwiftUI
import OpenTrafficCore

struct SettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form {
                CloudflareConnectionView(store: store, mode: .settings)
            }
            .formStyle(.grouped)
            .tabItem { providerTab(.cloudflare) }
            Form {
                TailscaleStatusView(store: store, showsSettings: true)
            }
            .formStyle(.grouped)
            .task { await store.refreshTailscale() }
            .tabItem { providerTab(.tailscale) }
            Form {
                NgrokStatusView(store: store, showsSettings: true)
            }
            .formStyle(.grouped)
            .tabItem { providerTab(.ngrok) }
            Form {
                OpenTunnelStatusView(store: store, showsSettings: true)
            }
            .formStyle(.grouped)
            .tabItem { providerTab(.opentunnel) }
            IntegrationsSettingsView(store: store)
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 600, height: 560)
    }

    @ViewBuilder
    private func providerTab(_ provider: TunnelProvider) -> some View {
        Label { Text(provider.title) } icon: { Image(nsImage: BrandAssets.logo(provider, style: .toolbar)) }
    }
}

private struct GeneralSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: AppStore
    @State private var loginItemStatus = LoginItem.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open OpenTraffic at login", isOn: launchAtLogin)
                if loginItemStatus == .requiresApproval {
                    InlineMessage(severity: .warning, message: "macOS needs your approval in Login Items.") {
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginItemError {
                    InlineMessage(severity: .error, message: loginItemError)
                }
                Picker("Show in Dock", selection: $store.dockVisibility) {
                    ForEach(DockVisibility.allCases) { Text($0.title).tag($0) }
                }
            }

            UpdatesSettingsSection()

            Section {
                Picker("Share button uses", selection: $store.defaultShareKind) {
                    Text("Temporary URL (Cloudflare)").tag(TunnelKind.quick)
                    Text("Private on your tailnet (Tailscale)").tag(TunnelKind.tailscale)
                    Text("ngrok").tag(TunnelKind.ngrok)
                    Text("Lasting address (OpenTunnel)").tag(TunnelKind.opentunnel)
                }
                Picker("Stop shares after", selection: $store.defaultShareDuration) {
                    ForEach(ShareDuration.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Copy the public URL when a tunnel starts", isOn: $store.autoCopyPublicURL)
                Toggle("Notify when a public URL is ready", isOn: $store.notifyWhenReady)
                Toggle("Notify when a tunnel needs attention", isOn: $store.notifyOnFailure)
            } header: {
                Text("Sharing")
            }

            Section {
                TextField("Your name", text: $store.collaborationHostName, prompt: Text("Host"))
                Toggle("Notify when someone joins or comments", isOn: $store.notifyCollaboration)
            } header: {
                Text("Live Collaboration")
            } footer: {
                Text("Shown to everyone in your collaborative shares when you open them as the host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Restart tunnels that stop unexpectedly", isOn: $store.restartCrashedTunnels)
                Toggle("Global shortcuts", isOn: $store.globalHotKeysEnabled)
                if store.globalHotKeysEnabled {
                    LabeledContent("Share the newest local server", value: GlobalHotKeys.Action.shareNewest.display)
                    LabeledContent("Copy the latest tunnel's URL", value: GlobalHotKeys.Action.copyLatestURL.display)
                }
            } header: {
                Text("Reliability & Shortcuts")
            }

            Section {
                Toggle("Allow automation without confirmation", isOn: $store.allowUnconfirmedAutomation)
                if store.allowUnconfirmedAutomation {
                    InlineMessage(severity: .warning, message: "Any app or web page that opens an opentraffic:// link can now share local servers without asking.")
                }
                CommandLineToolRow()
            } header: {
                Text("Automation")
            } footer: {
                Text("The opentraffic command and Shortcuts' Open URLs action control OpenTraffic with links like opentraffic://share?port=3000&via=tailscale. Sharing and starting ask first unless the switch above is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CloudflaredSettingsSection(store: store)

            if !store.hiddenDiscoveryPreferences.isEmpty {
                Section("Hidden Tunnels Running Elsewhere") {
                    ForEach(store.hiddenDiscoveryPreferences) { preference in
                        LabeledContent {
                            Button("Show") { store.restoreDiscoveredPreference(preference.key) }
                        } label: {
                            Text(preference.alias ?? preference.origin ?? "Discovered tunnel")
                            if let origin = preference.origin {
                                Text(origin)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Run Setup Assistant…") {
                    MainWindowRouter(store: store, openWindow: openWindow).show(sheet: .onboarding)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItemStatus = LoginItem.status }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } set: { enabled in
            do {
                try LoginItem.setEnabled(enabled)
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
            loginItemStatus = LoginItem.status
        }
    }
}

/// cloudflared location and install status. Shared by Settings and the setup assistant.
struct CloudflaredSettingsSection: View {
    @Bindable var store: AppStore
    @State private var refreshToken = 0

    var body: some View {
        Section {
            ToolInstallRow(store: store, provider: .cloudflare, purpose: "Cloudflare's connector, for temporary URLs and your own domain.", prominent: true)
                .id(refreshToken)
            LabeledContent("Custom location") {
                HStack {
                    TextField("Custom location", text: $store.customCloudflaredPath, prompt: Text("Automatic"))
                        .labelsHidden()
                    Button("Choose…", action: chooseExecutable)
                }
            }
        } header: {
            Text("cloudflared")
        } footer: {
            Text("OpenTraffic uses cloudflared from /opt/homebrew/bin, /usr/local/bin, /opt/local/bin, or ~/.local/bin, then the copy it installed itself, unless you choose a location.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose cloudflared"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.customCloudflaredPath = url.path
        }
    }
}

/// The `opentraffic` command on the PATH, which OpenTraffic keeps linked (see `OpenTrafficCommandLink`).
private struct CommandLineToolRow: View {
    @State private var installs = OpenTrafficCommandLink.installsAutomatically
    @State private var installedPath = OpenTrafficCommandLink.installedPath
    @State private var problem: String?

    var body: some View {
        Toggle("Install the opentraffic command", isOn: $installs)
            .disabled(!OpenTrafficCommandLink.isInstalledCopy && installedPath == nil)
            .onChange(of: installs) { _, on in apply(on) }
        Group {
            if let problem {
                InlineMessage(severity: .warning, message: problem)
            } else if let installedPath {
                Text("Linked at \(installedPath). Run `opentraffic setup` once, then `opentraffic help`.")
            } else if !OpenTrafficCommandLink.isInstalledCopy {
                Text("Available once OpenTraffic is in the Applications folder.")
            } else {
                Text("Share, inspect, and answer feedback from a terminal or script.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func apply(_ on: Bool) {
        OpenTrafficCommandLink.installsAutomatically = on
        problem = nil
        if on {
            switch OpenTrafficCommandLink.install() {
            case .installed: break
            case .blocked(let message), .failed(let message): problem = message
            }
        } else {
            OpenTrafficCommandLink.uninstall()
        }
        installedPath = OpenTrafficCommandLink.installedPath
    }
}

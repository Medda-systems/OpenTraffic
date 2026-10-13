import SwiftUI
import OpenTrafficCore

struct EditTunnelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let tunnel: TunnelDefinition
    @State private var name = ""
    @State private var localURL = ""
    @State private var updateCloudflare = true
    @State private var error: String?
    @State private var didSeed = false
    @State private var isApplying = false
    @State private var rewriteHostHeader = false
    @State private var project = ""
    @State private var autoStart = false
    /// The local URL was saved but pushing it to Cloudflare failed; Save retries the push.
    @State private var cloudflarePending = false

    var body: some View {
        SheetScaffold(title: "Edit \(tunnel.name)", subtitle: tunnel.kind.title) {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section {
                    TextField(Vocabulary.localService, text: $localURL, prompt: Text("http://localhost:3000"))
                        .disabled(isRunning)
                    if let hint = urlHint {
                        InlineMessage(severity: hint.severity, message: hint.message)
                    }
                    if isRunning {
                        InlineMessage(severity: .info, message: "Stop the tunnel to change its local service. You can still rename it.")
                    }
                    if tunnel.kind.usesCloudflareAccount, let hostname = tunnel.hostname?.nilIfBlank {
                        LabeledContent(Vocabulary.publicURL) {
                            Text("https://\(hostname)").textSelection(.enabled)
                        }
                        if urlChanged || cloudflarePending {
                            Toggle("Also update the Cloudflare route and DNS record", isOn: $updateCloudflare)
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Project", text: $project, prompt: Text("None"))
                        if !store.projectNames.isEmpty {
                            Menu {
                                ForEach(store.projectNames, id: \.self) { name in
                                    Button(name) { project = name }
                                }
                                Divider()
                                Button("No Project") { project = "" }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choose an existing project")
                        }
                    }
                    Toggle("Start automatically when \(TunnelRowPresentation.localEndpoint(localURL) ?? "the local service") is running", isOn: $autoStart)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Tunnels in the same project start and stop together. Auto-start waits for the server; after you stop the tunnel it stays stopped until the server restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if tunnel.supportsHostHeaderRewrite {
                    Section {
                        Toggle("Send \(tunnel.originHostHeader ?? "the local host") as the Host header", isOn: $rewriteHostHeader)
                    } footer: {
                        Text("For dev servers that reject unknown hostnames (Vite, Next.js, Django). \(tunnel.kind.usesCloudflareAccount ? "Updates the Cloudflare route." : "Restarts the tunnel if it's running.")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isApplying || showsProgress {
                    Section("Updating Cloudflare") {
                        SetupProgressView(steps: store.setupProgressSteps)
                    }
                }
                if let error {
                    Section { InlineMessage(severity: .error, message: error) }
                }
            }
            .formStyle(.grouped)
            .disabled(isApplying)
        } trailingFooter: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
            Button(action: save) {
                if isApplying {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(saveDisabled || isApplying)
        }
        .frame(width: 520, height: tunnel.kind.usesCloudflareAccount ? 620 : 570)
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            name = tunnel.name
            localURL = tunnel.localURL
            rewriteHostHeader = tunnel.rewriteHostHeader
            project = tunnel.project ?? ""
            autoStart = tunnel.autoStart
        }
    }

    private var runtime: TunnelRuntime { store.runtime(for: tunnel.id) }

    private var isRunning: Bool {
        [.running, .starting, .stopping].contains(runtime.state)
    }

    private var showsProgress: Bool {
        store.setupProgressTunnelID == tunnel.id && !store.setupProgressSteps.isEmpty && error != nil
    }

    private var urlChanged: Bool {
        localURL.trimmingCharacters(in: .whitespacesAndNewlines) != tunnel.localURL
    }

    private var urlHint: (severity: Severity, message: String)? {
        guard let trimmed = localURL.nilIfBlank else { return nil }
        if let message = store.validateTunnelLocalURL(trimmed, kind: tunnel.kind) {
            return (.error, message)
        }
        if tunnel.kind.usesCloudflareAccount,
           let normalized = try? CloudflareClient.ingressService(from: trimmed),
           normalized != trimmed {
            return (.info, "Cloudflare will use \(normalized).")
        }
        return nil
    }

    private var saveDisabled: Bool {
        name.nilIfBlank == nil || localURL.nilIfBlank == nil
    }

    private func save() {
        let pushToCloudflare = updateCloudflare && (urlChanged || cloudflarePending)
            && tunnel.kind.usesCloudflareAccount && tunnel.hostname?.nilIfBlank != nil
        if let message = store.updateManagedTunnel(tunnel.id, name: name, localURL: localURL) {
            error = message
            return
        }
        if project.nilIfBlank != tunnel.project { store.setProject(project, for: tunnel.id) }
        if autoStart != tunnel.autoStart { store.setAutoStart(autoStart, for: tunnel.id) }
        let hostHeaderChange: Bool? = rewriteHostHeader != tunnel.rewriteHostHeader ? rewriteHostHeader : nil
        guard pushToCloudflare else {
            if let enabled = hostHeaderChange {
                Task { await store.setHostHeaderRewrite(enabled, for: tunnel.id) }
            }
            dismiss()
            return
        }
        // Keep the sheet open so progress and failures appear where the change was made. Both
        // Cloudflare writes run one after the other, so neither overwrites the other's route.
        isApplying = true
        error = nil
        Task {
            if let enabled = hostHeaderChange { await store.setHostHeaderRewrite(enabled, for: tunnel.id) }
            await store.finishSetup(tunnel.id)
            isApplying = false
            if let failure = store.runtime(for: tunnel.id).lastError {
                cloudflarePending = true
                error = "Saved locally, but Cloudflare wasn't updated: \(failure)"
            } else {
                dismiss()
            }
        }
    }
}

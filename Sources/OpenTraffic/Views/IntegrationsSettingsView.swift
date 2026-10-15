import SwiftUI
import OpenTrafficCore

/// Settings → Integrations: the local API, MCP setup for coding agents, and webhooks.
struct IntegrationsSettingsView: View {
    @Bindable var store: AppStore
    @State private var revealToken = false
    @State private var confirmingRegenerate = false
    @State private var setup = AppStore.MCPSetup.claudeCode
    @State private var portText = ""
    @State private var addingWebhook = false
    @State private var agentPreset: AgentPreset?

    var body: some View {
        Form {
            Section {
                LabeledContent("App") {
                    IconSegmentedControl(
                        segments: AppStore.MCPSetup.allCases.map { app in
                            .init(value: app, title: app.rawValue, image: AgentBrand(agentName: app.rawValue).flatMap { BrandAssets.agentMark($0, points: 14) })
                        },
                        selection: $setup
                    )
                }
                Text(store.mcpSetupText(setup))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small))
                HStack {
                    Text(setupHint).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    CopyButton(text: store.mcpSetupText(setup), label: "Copy", iconOnly: false)
                }
            } header: {
                Text("Coding agents (MCP)")
            } footer: {
                Text("The bridge is part of OpenTraffic, like the opentraffic command: it needs no token or local API, and doesn't ask before sharing. Any other MCP client can run the same command"
                    + (store.apiEnabled ? ", or connect to http://127.0.0.1:\(String(store.apiPort))/mcp with the token as a Bearer header." : "."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Agent", selection: $agentPreset) {
                    Text("None").tag(AgentPreset?.none)
                    ForEach(AgentPreset.allCases) { preset in
                        Label { Text(preset.title) } icon: { AgentMenuIcon(name: preset.clientName) }
                            .tag(Optional(preset))
                    }
                }
                .onChange(of: agentPreset) { _, preset in choose(preset) }
                if agentPreset != nil {
                    TextField("Command", text: $store.agentCommand, axis: .vertical)
                        .font(.callout.monospaced())
                        .lineLimit(1...4)
                        // An edited preset is a custom command (and its agent is just "Agent").
                        .onChange(of: store.agentCommand) { _, command in
                            if store.agentCommandIsSet { agentPreset = AgentPreset.matching(command) ?? .custom }
                        }
                    Toggle("Run it by itself for new comments when no agent is watching", isOn: $store.agentRunsAutomatically)
                }
            } header: {
                Text("Agent for comments")
            } footer: {
                Text(agentFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow apps on this Mac to use OpenTraffic", isOn: $store.apiEnabled)
                if store.apiEnabled {
                    LabeledContent("Status") { statusText }
                    LabeledContent("Port") {
                        TextField("Port", text: $portText, prompt: Text(verbatim: String(LocalAPIServer.defaultPort)))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                    }
                    LabeledContent("Token") {
                        HStack(spacing: Spacing.s) {
                            Text(revealToken ? (store.apiToken ?? "—") : "••••••••••••••••")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                            CopyButton(label: "Copy Token", concealed: true) { store.apiToken }
                            Button("New Token…") { confirmingRegenerate = true }
                        }
                        .buttonStyle(.borderless)
                    }
                    Toggle("Apps can share without asking", isOn: $store.apiAllowsPublishingWithoutAsking)
                }
            } header: {
                Text("Local API for other apps")
            } footer: {
                Text("Your own apps and scripts can start and stop shares, read live-collaboration feedback, reply, and resolve comments. Only apps running on this Mac as you can connect, using the token; web pages can't. Unless allowed above, OpenTraffic asks before an app makes anything public. The opentraffic command and the MCP bridge don't need this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.apiEnabled {
                Section {
                    if store.webhookEndpoints.isEmpty {
                        Text("No webhooks yet.").foregroundStyle(.secondary)
                    }
                    ForEach($store.webhookEndpoints) { $endpoint in
                        WebhookRow(endpoint: $endpoint, status: store.webhookStatuses[endpoint.id]) {
                            store.webhookEndpoints.removeAll { $0.id == endpoint.id }
                        }
                    }
                    Button("Add Webhook…") { addingWebhook = true }
                } header: {
                    Text("Webhooks")
                } footer: {
                    Text("OpenTraffic POSTs share, session, comment, and error events as JSON, signed with the webhook's secret in X-OpenTraffic-Signature (HMAC-SHA256).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(store.apiPort)
            agentPreset = store.agentCommandIsSet ? (AgentPreset.matching(store.agentCommand) ?? .custom) : nil
        }
        .confirmationDialog("Create a new API token?", isPresented: $confirmingRegenerate) {
            Button("New Token", role: .destructive) { store.regenerateAPIToken() }
        } message: {
            Text("Apps set up with the current token stop working until they get the new one. The MCP bridge reads it automatically.")
        }
        .sheet(isPresented: $addingWebhook) {
            AddWebhookSheet { store.webhookEndpoints.append($0) }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch store.apiStatus {
        case .off:
            Text("Starting…").foregroundStyle(.secondary)
        case .running(let port):
            Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(TunnelDisplayState.online.textTint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(TunnelDisplayState.attention.textTint)
                .lineLimit(2)
        }
    }

    private var setupHint: String {
        switch setup {
        case .claudeCode: "Run in Terminal."
        case .codex: "Add to ~/.codex/config.toml."
        case .cursor: "Add to ~/.cursor/mcp.json."
        case .opencode: "Add to opencode.json."
        }
    }

    private var agentFooter: String {
        guard agentPreset != nil else {
            return "OpenTraffic can start a coding agent to handle a comment when no agent is watching the share: you send comments to it from the Feedback tab, or let it run by itself. The agent uses its own sign-in or API key; OpenTraffic doesn't run any model."
        }
        return "Runs in the share's project folder with $OPENTRAFFIC_PROMPT, $OPENTRAFFIC_SHARE and $OPENTRAFFIC_COMMENT_ID set, and needs OpenTraffic's MCP server (above) to read and answer the comment. Running by itself lets anyone with a share's link start the agent on this Mac: comments reach it as untrusted feedback, but only turn this on for people you trust."
    }

    private func choose(_ preset: AgentPreset?) {
        switch preset {
        case nil:
            store.agentCommand = ""
            store.agentRunsAutomatically = false
        case .custom:
            // Keep what's there to edit, or start from an example.
            if !store.agentCommandIsSet { store.agentCommand = AgentPreset.custom.command }
        case let preset?:
            if AgentPreset.matching(store.agentCommand) != preset { store.agentCommand = preset.command }
        }
    }

    private func applyPort() {
        guard let port = Int(portText), (1024...65_535).contains(port) else {
            portText = String(store.apiPort)
            return
        }
        if port != store.apiPort { store.apiPort = port }
    }
}

private struct WebhookRow: View {
    @Binding var endpoint: WebhookEndpoint
    let status: WebhookDeliveryStatus?
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Toggle("", isOn: $endpoint.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.url).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(endpoint.events.isEmpty ? "All events" : endpoint.events.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let status {
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundStyle(status.succeeded ? TunnelDisplayState.online.textTint : TunnelDisplayState.attention.textTint)
                }
            }
            Spacer()
            CopyButton(label: "Copy Secret", concealed: true) { endpoint.secret }
                .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove webhook")
                .accessibilityLabel("Remove webhook")
        }
    }

    private func statusText(_ status: WebhookDeliveryStatus) -> String {
        let outcome = status.succeeded ? "Delivered" : (status.statusCode.map { "Failed (HTTP \($0))" } ?? "Failed: \(status.error ?? "unknown error")")
        return "\(outcome) · \(status.event) · \(status.at.formatted(date: .omitted, time: .shortened))"
    }
}

private struct AddWebhookSheet: View {
    let onAdd: (WebhookEndpoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var events: Set<String> = []
    @State private var secret = SharePassword.generate(length: 32)

    var body: some View {
        SheetScaffold(title: "Add Webhook") {
            Form {
                TextField("URL", text: $url, prompt: Text("https://example.com/hooks/opentraffic"))
                LabeledContent("Secret") {
                    HStack {
                        Text(secret).font(.callout.monospaced()).textSelection(.enabled)
                        CopyButton(label: "Copy Secret", concealed: true) { secret }.buttonStyle(.borderless)
                    }
                }
                Section("Events (none selected = all)") {
                    ForEach(APIEvent.Kind.allCases, id: \.rawValue) { kind in
                        Toggle(kind.rawValue, isOn: Binding(
                            get: { events.contains(kind.rawValue) },
                            set: { if $0 { events.insert(kind.rawValue) } else { events.remove(kind.rawValue) } }
                        ))
                        .font(.callout.monospaced())
                    }
                }
            }
            .formStyle(.grouped)
        } trailingFooter: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                onAdd(WebhookEndpoint(url: url.trimmingCharacters(in: .whitespaces), events: events.sorted(), secret: secret))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!WebhookEndpoint(url: url.trimmingCharacters(in: .whitespaces), secret: secret).isValidURL)
        }
        .frame(width: 520, height: 520)
    }
}

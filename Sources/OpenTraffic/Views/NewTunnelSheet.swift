import SwiftUI
import OpenTrafficCore

/// The single place to create a tunnel: choose a kind, then fill in only what that kind needs.
struct NewTunnelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    @State private var kind: NewTunnelKind
    /// True while Cloudflare resources are being created; switching panes would lose the result.
    @State private var isBusy = false

    init(store: AppStore, initialKind: NewTunnelKind) {
        self.store = store
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        HStack(spacing: 0) {
            KindList(store: store, selection: $kind)
                .frame(width: 270)
                .disabled(isBusy)
            Divider()
            VStack(spacing: 0) {
                KindSummary(kind: kind)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.xl)
                    .padding(.bottom, Spacing.xs)
                pane
            }
        }
        .frame(width: 960, height: 700)
        .interactiveDismissDisabled(isBusy)
        .onAppear { store.setLocalServicesWatched(true, by: "new tunnel") }
        .onDisappear { store.setLocalServicesWatched(false, by: "new tunnel") }
    }

    @ViewBuilder
    private var pane: some View {
        switch kind {
        case .quick:
            QuickTunnelPane(store: store, dismiss: { dismiss() })
        case .tailscale:
            TailscalePane(store: store, dismiss: { dismiss() })
        case .ngrok:
            NgrokPane(store: store, dismiss: { dismiss() })
        case .opentunnel:
            OpenTunnelPane(store: store, dismiss: { dismiss() })
        case .customDomain:
            CloudflareGate(store: store, dismiss: { dismiss() }) {
                CustomDomainPane(store: store, isBusy: $isBusy, dismiss: { dismiss() })
            }
        case .importExisting:
            CloudflareGate(store: store, dismiss: { dismiss() }) {
                ImportTunnelPane(store: store, dismiss: { dismiss() })
            }
        }
    }
}

/// Every way to share, grouped by what it needs: a name and what sets it apart, plus a badge when
/// it isn't ready to use yet. Arrow keys move through it.
private struct KindList: View {
    @Bindable var store: AppStore
    @Binding var selection: NewTunnelKind

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let kind = $0 { selection = kind } })) {
            Section {
                EmptyView()
            } header: {
                Text("New Tunnel")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, Spacing.s)
            }
            ForEach(NewTunnelKind.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(NewTunnelKind.allCases.filter { $0.group == group }) { kind in
                        row(kind).tag(kind)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ kind: NewTunnelKind) -> some View {
        HStack(spacing: Spacing.s) {
            ProviderLogo(provider: kind.provider, height: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).fontWeight(.semibold)
                Text(kind.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let badge = readiness(kind) {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Spacing.xs + 1)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// Why an option can't be used yet, in a word or two.
    private func readiness(_ kind: NewTunnelKind) -> String? {
        switch kind {
        case .quick:
            store.cloudflaredPath == nil ? "Not installed" : nil
        case .opentunnel:
            store.openTunnelPath == nil ? "Not installed" : nil
        case .tailscale:
            store.tailscalePath == nil ? "Not installed" : store.tailscaleStatus?.isRunning == false ? "Not connected" : nil
        case .ngrok:
            store.ngrokPath == nil ? "Not installed" : store.ngrokAuthtokenConfigured ? nil : "Not set up"
        case .customDomain, .importExisting:
            store.accountID.isEmpty ? "Not connected" : nil
        }
    }
}

/// The chosen option: when to pick it, and the same three facts for every option.
struct KindSummary: View {
    let kind: NewTunnelKind

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                ProviderLogo(provider: kind.provider, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.title2.weight(.semibold))
                    Text(kind.pitch)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.xs + 2) {
                fact("person.2", "Who can open it", kind.audience)
                fact("link", "Address", kind.address)
                fact("checkmark.seal", "Needs", kind.requirement)
            }
            .font(.callout)
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.medium))
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ symbol: String, _ label: String, _ value: String) -> some View {
        GridRow {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Bottom bar used by every pane in the New Tunnel sheet.
private struct PaneFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                leading
                Spacer()
                trailing
            }
            .padding(Spacing.l)
        }
    }
}

// MARK: - Temporary URL

private struct QuickTunnelPane: View {
    @Bindable var store: AppStore
    let dismiss: () -> Void
    @State private var name = ""
    @State private var namePlaceholder = "Local site"
    @State private var localURL = ""
    @State private var originSelectionID = "manual"
    @State private var error: String?
    @State private var didSeed = false
    @State private var collaboration = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LocalOriginPicker(
                    store: store,
                    selectionID: $originSelectionID,
                    localURL: $localURL,
                    validationMessage: validation
                ) { option in
                    namePlaceholder = option.name
                }
                Section {
                    TextField("Name", text: $name, prompt: Text(namePlaceholder))
                } footer: {
                    Text("The public URL is random and changes every time the tunnel starts. \(store.autoCopyPublicURL ? "It's copied to your clipboard as soon as it's ready." : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Live collaboration", isOn: $collaboration)
                        .disabled(!localURL.lowercased().hasPrefix("http://"))
                } footer: {
                    Text(localURL.lowercased().hasPrefix("https://")
                        ? "Live collaboration needs an http:// local address for now."
                        : "Everyone who opens the link sees each other's cursors and can follow you as you browse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section { InlineMessage(severity: .error, message: error) }
                }
                if store.cloudflaredPath == nil {
                    Section {
                        InlineMessage(
                            severity: .warning,
                            message: "cloudflared isn't installed. Install it with Homebrew (brew install cloudflared), download it from Cloudflare, or choose it in Settings."
                        ) {
                            Link("Download cloudflared", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")!)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            PaneFooter {
                EmptyView()
            } trailing: {
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save Without Starting", action: { create(start: false) })
                    .disabled(localURL.nilIfBlank == nil)
                Button("Start Sharing", action: { create(start: true) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(localURL.nilIfBlank == nil || store.cloudflaredPath == nil)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: store.localOriginSections.detected.first?.id) { seed() }
    }

    private var validation: LocalOriginPicker.InlineValidation? {
        guard let url = localURL.nilIfBlank else { return nil }
        if let message = store.validateTunnelLocalURL(url, kind: .quick) {
            return .init(severity: .error, message: message)
        }
        return nil
    }

    /// Preselect the newest detected service so the common case is a single click.
    private func seed() {
        guard !didSeed, localURL.isEmpty, let first = store.localOriginSections.detected.first else { return }
        didSeed = true
        originSelectionID = first.id
        localURL = first.url
        namePlaceholder = first.name
    }

    private func create(start: Bool) {
        do {
            let definition = try store.addQuick(
                name: name.nilIfBlank ?? namePlaceholder,
                localURL: localURL,
                collaboration: collaboration && localURL.lowercased().hasPrefix("http://")
            )
            if start { store.startSharing(definition) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Cloudflare account gate

/// Shows the connection form inline until the account is connected and unlocked.
private struct CloudflareGate<Content: View>: View {
    @Bindable var store: AppStore
    let dismiss: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if store.accountID.isEmpty || !store.hasAPIToken() || !store.isAPITokenUnlocked {
            VStack(spacing: 0) {
                Form {
                    CloudflareConnectionView(store: store, mode: .inline)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                PaneFooter {
                    EmptyView()
                } trailing: {
                    Button("Cancel", role: .cancel, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Your Domain

private struct CustomDomainPane: View {
    @Bindable var store: AppStore
    @Binding var isBusy: Bool
    let dismiss: () -> Void
    @State private var name = ""
    @State private var subdomain = ""
    @State private var useApex = false
    @State private var localURL = ""
    @State private var originSelectionID = "manual"
    @State private var didSeed = false
    @State private var zoneID = ""
    @State private var isCreating = false
    @State private var unreachableOriginMessage: String?
    @State private var confirmingUnreachableOrigin = false
    @State private var pendingDraft: CreateDraft?
    @State private var localURLCheck = LocalURLCheck.idle
    @State private var dnsCheck = DNSCheck.idle
    @State private var replaceDNS = false
    @State private var createdTunnel: TunnelDefinition?

    private enum LocalURLCheck: Equatable {
        case idle, checking
        case reachable(Int)
        case invalid(String)
        case unreachable(String)
    }

    private enum DNSCheck: Equatable {
        case idle, checking, absent, unknown
        case present(content: String)
    }

    private struct CreateDraft: Equatable {
        let name: String
        let hostname: String
        let localURL: String
        let zoneID: String
        let replaceDNS: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if let createdTunnel {
                success(createdTunnel)
            } else {
                form
                PaneFooter {
                    if let blocker = createBlocker, !isCreating {
                        Text(blocker).font(.caption).foregroundStyle(.secondary)
                    }
                } trailing: {
                    Button("Cancel", role: .cancel, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isCreating)
                    Button {
                        create()
                    } label: {
                        if isCreating {
                            HStack(spacing: Spacing.s) {
                                ProgressView().controlSize(.small)
                                Text("Creating…")
                            }
                        } else {
                            Text("Create Tunnel")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || createBlocker != nil)
                }
            }
        }
        .task {
            seed()
            if store.zones.isEmpty { await store.refreshAccount() }
            if zoneID.isEmpty { zoneID = store.zones.first?.id ?? "" }
        }
        .onChange(of: isCreating) { isBusy = isCreating }
        .task(id: localURL) { await checkLocalURL() }
        .task(id: "\(zoneID)-\(hostname)") { await checkDNS() }
        .confirmationDialog("The local service didn't respond", isPresented: $confirmingUnreachableOrigin) {
            Button("Create Anyway") {
                if let pendingDraft { create(draft: pendingDraft, skipPreflight: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unreachableOriginMessage ?? "Check the local service before continuing.")
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Hostname") {
                    HStack(spacing: Spacing.xs) {
                        TextField("Subdomain", text: $subdomain, prompt: Text(useApex ? "—" : "app"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .disabled(useApex)
                            .onChange(of: subdomain) {
                                guard let zoneName, !useApex else { return }
                                let stripped = TunnelHostname.subdomain(of: subdomain, zoneName: zoneName)
                                if stripped != subdomain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                                    subdomain = stripped
                                }
                            }
                        Text(".").foregroundStyle(.secondary)
                        Picker("Zone", selection: $zoneID) {
                            if store.zones.isEmpty { Text("No zones").tag("") }
                            ForEach(store.zones) { zone in Text(zone.name).tag(zone.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: zoneID) {
                            guard let zoneName, !useApex, !subdomain.isEmpty else { return }
                            subdomain = TunnelHostname.subdomain(of: subdomain, zoneName: zoneName)
                        }
                    }
                }
                Toggle("Use the zone apex (no subdomain)", isOn: $useApex)
                if let subdomainError {
                    InlineMessage(severity: .error, message: subdomainError)
                }
                dnsStatus
            } header: {
                Text("Public Hostname")
            } footer: {
                if !hostname.isEmpty {
                    Text("Will serve https://\(hostname)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let zoneError = store.zoneError {
                Section { InlineMessage(severity: .warning, message: zoneError) }
            }

            LocalOriginPicker(
                store: store,
                selectionID: $originSelectionID,
                localURL: $localURL,
                validationMessage: localURLValidation
            ) { option in
                if name.nilIfBlank == nil { name = option.name }
            }

            Section {
                TextField("Name", text: $name, prompt: Text(hostname.isEmpty ? "My app" : hostname))
            } footer: {
                Text("OpenTraffic creates a remotely managed tunnel, routes the hostname to your local service, and adds a proxied DNS record. An existing DNS record is only replaced if you choose to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let accountError = store.accountError {
                Section { InlineMessage(severity: .error, message: accountError) }
            }
            if !store.setupProgressSteps.isEmpty, isCreating || store.accountError != nil {
                Section("Progress") { SetupProgressView(steps: store.setupProgressSteps) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .disabled(isCreating)
    }

    @ViewBuilder
    private var dnsStatus: some View {
        switch dnsCheck {
        case .idle, .unknown:
            EmptyView()
        case .checking:
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.mini)
                Text("Checking DNS…").font(.callout).foregroundStyle(.secondary)
            }
        case .absent:
            InlineMessage(severity: .success, message: "Hostname is available. OpenTraffic will create its DNS record.")
        case .present(let content):
            VStack(alignment: .leading, spacing: Spacing.s) {
                InlineMessage(severity: .warning, message: "This hostname already has a DNS record, pointing to \(Self.describe(target: content)).")
                Toggle("Replace it with this tunnel's record", isOn: $replaceDNS)
                Text(replaceDNS
                    ? "Whatever it points to now stops receiving traffic at this hostname. Other records there, like TXT or MX, are left alone."
                    : "Or choose another subdomain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What an existing record points to, in words: a leftover Cloudflare tunnel is the usual case.
    private static func describe(target: String) -> String {
        target.lowercased().hasSuffix(".cfargotunnel.com")
            ? "another Cloudflare tunnel (often one that was removed)"
            : target
    }

    private var localURLValidation: LocalOriginPicker.InlineValidation? {
        switch localURLCheck {
        case .idle: nil
        case .checking: .init(severity: .info, message: "Checking local service…", isChecking: true)
        case .reachable(let code): .init(severity: .success, message: "Local service responds (HTTP \(code)).")
        case .invalid(let message): .init(severity: .error, message: message)
        case .unreachable(let message): .init(severity: .warning, message: message)
        }
    }

    private func success(_ tunnel: TunnelDefinition) -> some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("Tunnel Created", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } description: {
                Text("https://\(tunnel.hostname ?? tunnel.name) is set up. Start the tunnel to begin serving traffic from this Mac.")
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            PaneFooter {
                EmptyView()
            } trailing: {
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Start Now") {
                    store.startSharing(tunnel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Derived

    private var zoneName: String? { store.zones.first(where: { $0.id == zoneID })?.name }

    private var hostname: String {
        guard let zoneName else { return "" }
        return TunnelHostname.compose(subdomain: useApex ? "" : subdomain, zoneName: zoneName)
    }

    private var subdomainError: String? {
        useApex ? nil : TunnelHostname.validateSubdomain(subdomain)
    }

    private var createBlocker: String? {
        if let subdomainError { return subdomainError }
        if zoneID.isEmpty || zoneName == nil { return "Choose a zone." }
        if !useApex && subdomain.nilIfBlank == nil { return "Enter a subdomain, or use the zone apex." }
        if localURL.nilIfBlank == nil { return "Choose a local service." }
        if case .present = dnsCheck, !replaceDNS { return "That hostname already has a DNS record." }
        return nil
    }

    // MARK: Actions

    private func seed() {
        guard !didSeed else { return }
        didSeed = true
        if store.setupProgressTunnelID == nil { store.setupProgressSteps = [] }
        store.accountError = nil
        if let seed = store.selectedLocalOriginSeed ?? store.localOriginSections.detected.first {
            originSelectionID = seed.id
            localURL = seed.url
            if name.isEmpty { name = seed.name }
        }
    }

    private func checkLocalURL() async {
        guard let url = localURL.nilIfBlank else { localURLCheck = .idle; return }
        localURLCheck = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        switch await store.preflightLocalOrigin(url) {
        case .reachable(let statusCode): localURLCheck = .reachable(statusCode)
        case .invalid(let message): localURLCheck = .invalid(message)
        case .unreachable(let message): localURLCheck = .unreachable(message)
        }
    }

    private func checkDNS() async {
        replaceDNS = false
        guard !zoneID.isEmpty, !hostname.isEmpty, subdomainError == nil else { dnsCheck = .idle; return }
        dnsCheck = .checking
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        do {
            if let record = try await store.lookupDNSRecord(zoneID: zoneID, hostname: hostname) {
                dnsCheck = .present(content: record.content ?? "another target")
            } else {
                dnsCheck = .absent
            }
        } catch {
            dnsCheck = .unknown
        }
    }

    private func create(draft: CreateDraft? = nil, skipPreflight: Bool = false) {
        let draft = draft ?? CreateDraft(name: name, hostname: hostname, localURL: localURL, zoneID: zoneID, replaceDNS: replaceDNS)
        isCreating = true
        Task {
            if !skipPreflight {
                switch await store.preflightLocalOrigin(draft.localURL) {
                case .reachable:
                    break
                case .invalid(let message):
                    localURLCheck = .invalid(message)
                    isCreating = false
                    return
                case .unreachable(let message):
                    pendingDraft = draft
                    unreachableOriginMessage = "\(message) You can create the tunnel now and start your server later."
                    confirmingUnreachableOrigin = true
                    isCreating = false
                    return
                }
            }
            pendingDraft = nil
            let created = await store.createRemote(
                name: draft.name,
                hostname: draft.hostname,
                localURL: draft.localURL,
                zoneID: draft.zoneID,
                replacingDNS: draft.replaceDNS
            )
            isCreating = false
            if store.accountError == nil, let created { createdTunnel = created }
        }
    }
}

// MARK: - Existing Tunnel

private struct ImportTunnelPane: View {
    @Bindable var store: AppStore
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let accountError = store.accountError {
                    Section { InlineMessage(severity: .error, message: accountError) }
                }
                Section {
                    if store.availableRemoteTunnels.isEmpty {
                        Text(store.isRefreshingAccount ? "Loading tunnels…" : "No tunnels found in this account.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.availableRemoteTunnels) { tunnel in
                        row(for: tunnel)
                    }
                } header: {
                    HStack {
                        Text("Tunnels in Your Account")
                        Spacer()
                        if store.isRefreshingAccount { ProgressView().controlSize(.mini) }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshAccount() } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(store.isRefreshingAccount)
                    }
                } footer: {
                    Text("Importing leaves the tunnel's Cloudflare configuration unchanged. Tunnels configured with a local YAML file stay managed by that file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            PaneFooter {
                EmptyView()
            } trailing: {
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            store.accountError = nil
            await store.refreshAccount()
        }
    }

    private func row(for tunnel: CloudflareTunnel) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.name).fontWeight(.medium)
                Text(subtitle(for: tunnel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isImported(tunnel) {
                Label("Imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else if tunnel.configSource == "cloudflare" {
                Button("Import") { Task { await store.importRemote(tunnel) } }
            } else {
                Text("Local config file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This tunnel is configured with a YAML file, so OpenTraffic can't run it safely.")
            }
        }
    }

    private func subtitle(for tunnel: CloudflareTunnel) -> String {
        let status = tunnel.status?.capitalized ?? "Unknown status"
        if let hostnames = store.remoteTunnelHostnames[tunnel.id], !hostnames.isEmpty {
            return "\(status) · \(hostnames)"
        }
        return status
    }

    private func isImported(_ tunnel: CloudflareTunnel) -> Bool {
        store.definitions.contains { $0.cloudflareTunnelID == tunnel.id && $0.accountID == store.accountID }
    }
}

// MARK: - Your Tailnet

private struct TailscalePane: View {
    @Bindable var store: AppStore
    let dismiss: () -> Void
    @State private var name = ""
    @State private var namePlaceholder = "Local site"
    @State private var localURL = ""
    @State private var originSelectionID = "manual"
    @State private var isPublic = false
    @State private var error: String?
    @State private var didSeed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let blocker = store.tailscaleBlocker {
                    TailscaleStatusView(store: store)
                    Section {
                        InlineMessage(severity: .info, message: "\(blocker) Fix that above, then come back here.")
                    }
                } else {
                    LocalOriginPicker(
                        store: store,
                        selectionID: $originSelectionID,
                        localURL: $localURL,
                        validationMessage: validation
                    ) { option in
                        namePlaceholder = option.name
                    }
                    Section {
                        TextField("Name", text: $name, prompt: Text(namePlaceholder))
                        Toggle("Public on the internet (Funnel)", isOn: $isPublic)
                            .disabled(store.tailscaleStatus?.funnelEnabled != true)
                    } footer: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(isPublic
                                 ? "Anyone with the link can open it. Funnel uses ports 443, 8443, or 10000."
                                 : "Only devices signed in to your tailnet can open it. Servers on IPv6 or other machines on your network work too.")
                            if store.tailscaleStatus?.funnelEnabled != true {
                                Text("Public sharing needs Funnel, which isn't enabled for this Mac. Settings → Tailscale explains how.")
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if let error {
                        Section { InlineMessage(severity: .error, message: error) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            PaneFooter {
                EmptyView()
            } trailing: {
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save Without Starting", action: { create(start: false) })
                    .disabled(localURL.nilIfBlank == nil || store.tailscaleBlocker != nil)
                Button("Start Sharing", action: { create(start: true) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(localURL.nilIfBlank == nil || store.tailscaleBlocker != nil)
            }
        }
        .task { await store.refreshTailscale() }
        .onAppear(perform: seed)
        .onChange(of: store.localOriginSections.detected.first?.id) { seed() }
    }

    private var validation: LocalOriginPicker.InlineValidation? {
        guard let url = localURL.nilIfBlank else { return nil }
        if let message = store.validateTunnelLocalURL(url, kind: .tailscale) {
            return .init(severity: .error, message: message)
        }
        return nil
    }

    private func seed() {
        guard !didSeed, localURL.isEmpty, let first = store.localOriginSections.detected.first else { return }
        didSeed = true
        originSelectionID = first.id
        localURL = first.url
        namePlaceholder = first.name
    }

    private func create(start: Bool) {
        do {
            let definition = try store.addTailscale(name: name.nilIfBlank ?? namePlaceholder, localURL: localURL, isPublic: isPublic)
            if start { store.startSharing(definition) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - OpenTunnel

private struct OpenTunnelPane: View {
    @Bindable var store: AppStore
    let dismiss: () -> Void
    @State private var name = ""
    @State private var namePlaceholder = "Local site"
    @State private var localURL = ""
    @State private var originSelectionID = "manual"
    @State private var collaboration = false
    @State private var error: String?
    @State private var didSeed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if store.openTunnelBlocker != nil {
                    OpenTunnelStatusView(store: store)
                } else {
                    LocalOriginPicker(
                        store: store,
                        selectionID: $originSelectionID,
                        localURL: $localURL,
                        validationMessage: validation
                    ) { option in
                        namePlaceholder = option.name
                    }
                    Section {
                        TextField("Name", text: $name, prompt: Text(namePlaceholder))
                    } footer: {
                        Text(addressFootnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Section {
                        Toggle("Live collaboration", isOn: $collaboration)
                    } footer: {
                        Text("Everyone who opens the link sees each other's cursors and can follow you as you browse. The link stays the same between starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Section { InlineMessage(severity: .error, message: error) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            PaneFooter {
                EmptyView()
            } trailing: {
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save Without Starting", action: { create(start: false) })
                    .disabled(!canCreate)
                Button("Start Sharing", action: { create(start: true) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .task { await store.refreshOpenTunnel() }
        .onAppear(perform: seed)
        .onChange(of: store.localOriginSections.detected.first?.id) { seed() }
    }

    private var canCreate: Bool {
        localURL.nilIfBlank != nil && store.openTunnelBlocker == nil && validation == nil
    }

    private var addressFootnote: String {
        let route = OpenTunnel.routeName(for: name.nilIfBlank ?? namePlaceholder, taken: Set(store.definitions.compactMap(\.openTunnelRoute)))
        let address = store.openTunnelHostname.map { OpenTunnel.url(route: route, hostname: $0) } ?? "https://\(route).<your-id>.opentunnel.xyz"
        return "Shared at \(address). It stays the same each time you start it. Anyone with the link can open it, and the address appears in public certificate logs."
    }

    private var validation: LocalOriginPicker.InlineValidation? {
        guard let url = localURL.nilIfBlank else { return nil }
        if let message = store.validateTunnelLocalURL(url, kind: .opentunnel) {
            return .init(severity: .error, message: message)
        }
        if OpenTunnel.target(for: url) == nil {
            return .init(severity: .error, message: "OpenTunnel shares need an http:// local address.")
        }
        return nil
    }

    private func seed() {
        guard !didSeed, localURL.isEmpty, let first = store.localOriginSections.detected.first else { return }
        didSeed = true
        originSelectionID = first.id
        localURL = first.url
        namePlaceholder = first.name
    }

    private func create(start: Bool) {
        do {
            let definition = try store.addOpenTunnel(name: name.nilIfBlank ?? namePlaceholder, localURL: localURL, collaboration: collaboration)
            if start { store.startSharing(definition) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - ngrok

private struct NgrokPane: View {
    @Bindable var store: AppStore
    let dismiss: () -> Void
    @State private var name = ""
    @State private var namePlaceholder = "Local site"
    @State private var localURL = ""
    @State private var domain = ""
    @State private var originSelectionID = "manual"
    @State private var error: String?
    @State private var didSeed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if store.ngrokBlocker != nil {
                    NgrokStatusView(store: store)
                } else {
                    LocalOriginPicker(
                        store: store,
                        selectionID: $originSelectionID,
                        localURL: $localURL,
                        validationMessage: validation
                    ) { option in
                        namePlaceholder = option.name
                    }
                    Section {
                        TextField("Name", text: $name, prompt: Text(namePlaceholder))
                        TextField("Domain", text: $domain, prompt: Text(defaultDomainPrompt))
                    } footer: {
                        Text("Leave the domain empty to use your account's domain. The free plan serves one ngrok share at a time, and browser visitors see an ngrok notice before your site.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error {
                        Section { InlineMessage(severity: .error, message: error) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            PaneFooter {
                EmptyView()
            } trailing: {
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save Without Starting", action: { create(start: false) })
                    .disabled(localURL.nilIfBlank == nil || store.ngrokBlocker != nil)
                Button("Start Sharing", action: { create(start: true) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(localURL.nilIfBlank == nil || store.ngrokBlocker != nil)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: store.localOriginSections.detected.first?.id) { seed() }
    }

    /// Shows the domain an earlier ngrok share used, which is almost always the account's free domain.
    private var defaultDomainPrompt: String {
        store.definitions.first(where: { $0.kind == .ngrok && $0.hostname != nil })?.hostname ?? "Your ngrok domain (automatic)"
    }

    private var validation: LocalOriginPicker.InlineValidation? {
        guard let url = localURL.nilIfBlank else { return nil }
        if let message = store.validateTunnelLocalURL(url, kind: .ngrok) {
            return .init(severity: .error, message: message)
        }
        return nil
    }

    private func seed() {
        guard !didSeed, localURL.isEmpty, let first = store.localOriginSections.detected.first else { return }
        didSeed = true
        originSelectionID = first.id
        localURL = first.url
        namePlaceholder = first.name
    }

    private func create(start: Bool) {
        do {
            let definition = try store.addNgrok(name: name.nilIfBlank ?? namePlaceholder, localURL: localURL, domain: domain)
            if start { store.startSharing(definition) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

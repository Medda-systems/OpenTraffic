import SwiftUI
import OpenTrafficCore

/// Turns live collaboration on for a share and shows who's connected.
struct CollaborationCard: View {
    let store: AppStore
    let tunnel: TunnelDefinition
    @State private var pendingChange: Bool?
    @State private var applying = false

    var body: some View {
        if tunnel.kind.supportsCollaboration {
            supportedCard
        } else {
            Card(title: "Live Collaboration") {
                Text("Everyone who opens a collaborative link sees each other's cursors and can follow you as you browse. \(laterKinds) get it in a later update; for now it runs on a temporary share of the same local site.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Share \(TunnelRowPresentation.localEndpoint(tunnel.localURL) ?? "This Site") with Live Collaboration", systemImage: "person.2.wave.2") {
                        store.shareWithCollaboration(localURL: tunnel.localURL, name: "\(tunnel.name) · Live")
                    }
                    .disabled(!tunnel.localURL.lowercased().hasPrefix("http://") || store.cloudflaredPath == nil)
                    Spacer()
                }
                if !tunnel.localURL.lowercased().hasPrefix("http://") {
                    InlineMessage(severity: .info, message: "Live collaboration needs an http:// local address for now.")
                }
            }
        }
    }

    private var laterKinds: String {
        switch tunnel.kind {
        case .remote: "Custom domains"
        case .tailscale: "Tailscale shares"
        case .ngrok: "ngrok shares"
        case .quick: "Temporary shares"
        case .opentunnel: "OpenTunnel shares"
        }
    }

    private var supportedCard: some View {
        Card(title: "Live Collaboration") {
            Toggle(isOn: toggleBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show who's here")
                    Text("Everyone who opens the link sees each other's cursors and can follow you as you browse.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Show who's here")
            // A shared Electron app always runs with it: its preload goes in with the overlay. So does
            // a Mac app: its viewer page is how people see it.
            .disabled(blocker != nil || applying || tunnel.electronApp != nil || tunnel.macApp != nil)

            if let blocker {
                InlineMessage(severity: .info, message: blocker)
            } else if tunnel.collaboration {
                if store.isCollaborating(tunnel.id) {
                    peopleList
                    rolesSection
                    HStack {
                        Button("Open as Host", systemImage: "person.crop.circle.badge.checkmark") {
                            store.openAsCollaborationHost(tunnel.id)
                        }
                        .help("Open the site in your browser as the host, so you can lead everyone else")
                        if tunnel.protection.isProtected {
                            Button("Copy Link with Password", systemImage: "link") { store.copyInviteLink(tunnel.id) }
                                .disabled(store.publicURL(for: tunnel) == nil)
                                .help("Copy the link with the password built in, so the people you send it to skip the sign-in page")
                        } else {
                            Button("Copy Invite Link", systemImage: "link") { store.copyPublicURL(tunnel.id) }
                                .disabled(store.publicURL(for: tunnel) == nil)
                                .help("Copy the link to send to the people you're sharing with")
                        }
                        Spacer()
                    }
                } else {
                    Text(store.isActive(tunnel.id) ? "Starting…" : "Starts with the share.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if tunnel.electronApp != nil { electronSection }
                if tunnel.macApp != nil { macAppSection }
                bridgeSection
                Toggle("Collect browser errors from visitors", isOn: Binding(
                    get: { tunnel.captureErrors },
                    set: { store.setCaptureErrors($0, for: tunnel.id) }
                ))
                .help("Visitors' uncaught errors, console errors, and failed requests show up in the Feedback tab and with their comments. Pages opened from now on follow this.")
                Toggle(isOn: Binding(
                    get: { tunnel.workOnBranch },
                    set: { enabled in Task { await store.requestWorkOnBranch(enabled, for: tunnel.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work on a branch")
                        Text(branchCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help("Fixes for comments are committed one by one on a branch of their own; your other uncommitted changes stay uncommitted.")
                Text("Visitors see each other's names, cursors, and which page they're on. Page content and form fields are never shared; a comment includes a short label of the element it's pinned to, a picture of it, and the visitor's browser and window size.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Restart “\(tunnel.name)” to \(pendingChange == true ? "turn on" : "turn off") live collaboration?",
            isPresented: Binding(get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } })
        ) {
            Button("Restart") { apply(pendingChange ?? false) }
        } message: {
            Text(tunnel.kind.hasEphemeralURL
                ? "Temporary shares get a new address when they restart. Anyone using the current link will need the new one."
                : "The share keeps its address, but anyone connected right now will reconnect.")
        }
    }

    private var branchCaption: String {
        if let session = tunnel.branchSession {
            return "On \(session.branch). Stopping the share merges it into \(session.original) when that's clean."
        }
        return "While the share runs, the project is on a branch of its own with a commit for each fixed comment. Stopping merges it back when that's clean."
    }

    /// Other local services the app talks to (localhost bridge): new ones to allow, and allowed ones.
    @ViewBuilder
    private var bridgeSection: some View {
        let candidates = (store.collabBridgeCandidates[tunnel.id] ?? []).sorted()
        ForEach(candidates, id: \.self) { port in
            InlineMessage(
                severity: AppStore.databasePorts.contains(port) ? .warning : .info,
                message: bridgeMessage(port),
                title: "Share localhost:\(port) as part of this share?"
            ) {
                Button("Allow") { store.allowBridgedPort(port, for: tunnel.id) }
                Button("Not Now") { store.dismissBridgeCandidate(port, for: tunnel.id) }
            }
        }
        if !tunnel.bridgedPorts.isEmpty {
            HStack(spacing: Spacing.s) {
                Text("Also reachable:").foregroundStyle(.secondary)
                ForEach(tunnel.bridgedPorts, id: \.self) { port in
                    HStack(spacing: 2) {
                        Text("localhost:\(String(port))").monospaced()
                        Button {
                            store.removeBridgedPort(port, for: tunnel.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop sharing localhost:\(String(port))")
                        .accessibilityLabel("Stop sharing localhost:\(String(port))")
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            .font(.callout)
        }
    }

    private func bridgeMessage(_ port: Int) -> String {
        var message = tunnel.electronApp != nil
            ? "\(tunnel.name) asked to reach localhost:\(port). Its sandboxed copy and visitors' browsers can't reach it unless you allow it. Only allow services this app really uses."
            : "A page in this share asked to reach localhost:\(port). Visitors' browsers can't reach it unless you share it too. Only allow services this app really uses."
        if AppStore.databasePorts.contains(port) {
            message += " This looks like a database: it's your real one, not a copy, so what visitors do changes its data."
        }
        return message
    }

    /// A shared Electron app: its main process runs sandboxed here, on a copy of its data.
    @ViewBuilder
    private var electronSection: some View {
        let viewers = store.electronViewers[tunnel.id] ?? 0
        HStack(spacing: Spacing.s) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Desktop app, sandboxed")
                Text("Its main process runs on this Mac with \(tunnel.electronData == .empty ? "empty data" : "a copy of its data"), and can't read your files or reach other local services. \(store.isActive(tunnel.id) ? "\(viewers) \(viewers == 1 ? "window" : "windows") open." : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Reset Data") { store.resetElectronData(tunnel.id) }
                .help("Start the app over from its original data")
                .disabled(!store.isActive(tunnel.id))
            Button("Restart") { store.restartElectronApp(tunnel.id) }
                .help("Restart the app's main process. Open pages stay open.")
                .disabled(!store.isActive(tunnel.id))
        }
        .font(.callout)
    }

    /// A shared Mac app: an isolated copy runs hidden on this Mac, with its own data.
    @ViewBuilder
    private var macAppSection: some View {
        let status = store.macAppStatus[tunnel.id]
        let canAct = store.isActive(tunnel.id) && status.map { $0.state == .running || $0.state.isProblem } == true
        HStack(spacing: Spacing.s) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac app, isolated copy")
                Text(macAppCaption(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Reset Data") { store.resetMacAppData(tunnel.id) }
                .help("Quit the app and start it over from the data it started with. Viewers stay connected.")
                .disabled(!canAct)
            Button("Restart App") { store.restartMacApp(tunnel.id) }
                .help("Quit the app and open it again with the same data; a new build is copied first. Viewers stay connected.")
                .disabled(!canAct)
        }
        .font(.callout)
        .onAppear { store.refreshMacAppPermissions() }
        if let warning = status?.warning {
            InlineMessage(severity: .info, message: warning)
        }
        if store.missingMacAppPermissions.isEmpty {
            Label("Accessibility and Screen Recording are on for OpenTraffic.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            MacAppPermissionsMessage(store: store)
        }
    }

    private func macAppCaption(_ status: MacAppShareStatus?) -> String {
        let name = tunnel.macApp.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? tunnel.name
        let data = tunnel.macAppData == .empty ? "empty data" : "a copy of its data"
        let about = "\(name) runs hidden on this Mac as a separate copy with \(data); your own copy and its data aren't touched."
        guard store.isActive(tunnel.id), let status else { return about }
        let state = switch status.state {
        case .idle, .starting: "Starting…"
        case .running: status.viewers == 1 ? "Running, 1 viewer." : "Running, \(status.viewers) viewers."
        case .restarting: "Restarting…"
        case .crashed(let message): message
        case .failed(let message): message
        case .stopped: "Stopped."
        }
        return "\(about) \(state)"
    }

    private var blocker: String? {
        store.collaborationBlocker(for: tunnel)
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { tunnel.collaboration },
            set: { enabled in
                if store.isActive(tunnel.id) {
                    pendingChange = enabled
                } else {
                    apply(enabled)
                }
            }
        )
    }

    private func apply(_ enabled: Bool) {
        applying = true
        Task {
            await store.setCollaboration(enabled, for: tunnel.id)
            applying = false
        }
    }

    @ViewBuilder
    private var peopleList: some View {
        let peers = store.peers(for: tunnel.id)
        if peers.isEmpty {
            Text("No one's here yet. Share the link, or open it yourself as the host.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(peers) { peer in
                    HStack(spacing: Spacing.s) {
                        if peer.isAgent {
                            AgentAvatar(name: peer.name, size: 22)
                        } else {
                            InitialsAvatar(name: peer.name, color: peer.color, size: 22)
                        }
                        Text(peer.name).lineLimit(1)
                        if peer.isHost || peer.isAgent {
                            Text(peer.isHost ? "Host" : "Agent")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        if let device = peer.device {
                            Text("\(device.viewport.replacingOccurrences(of: "x", with: "×")) · \(device.os)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("\(device.browser), \(device.os), window \(device.viewport)")
                        }
                        Spacer(minLength: Spacing.s)
                        Text(peer.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !peer.isHost, !peer.isAgent, let client = peer.client {
                            roleMenu(current: peer.role, client: client, name: peer.name)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    /// What new people may do, and the people given a role who aren't here now.
    @ViewBuilder
    private var rolesSection: some View {
        let present = Set(store.peers(for: tunnel.id).compactMap(\.client))
        let away = tunnel.collabMembers.filter { !present.contains($0.key) }.sorted { $0.value.name < $1.value.name }
        Picker("New people can", selection: Binding(
            get: { tunnel.collabDefaultRole },
            set: { store.setCollabDefaultRole($0, in: tunnel.id) }
        )) {
            ForEach(CollabRole.allCases, id: \.self) { role in Text(role.title).tag(role) }
        }
        .help("What people can do unless you give them a role. Only trusted people's comments start your agent by themselves.")
        ForEach(away, id: \.key) { client, member in
            HStack(spacing: Spacing.s) {
                Text(member.name).lineLimit(1).foregroundStyle(.secondary)
                Text("not here").font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: Spacing.s)
                roleMenu(current: member.role, client: client, name: member.name)
            }
        }
    }

    private func roleMenu(current: CollabRole, client: String, name: String) -> some View {
        Menu {
            ForEach(CollabRole.allCases, id: \.self) { role in
                Button {
                    store.setCollabRole(role == tunnel.collabDefaultRole ? nil : role, forClient: client, name: name, in: tunnel.id)
                } label: {
                    if role == current { Label(role.title, systemImage: "checkmark") } else { Text(role.title) }
                }
            }
        } label: {
            Text(current.shortTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What \(name) can do here. Roles follow their browser.")
    }
}

extension CollabRole {
    var title: String {
        switch self {
        case .trusted: "Comment and start your agent"
        case .commenter: "Comment"
        case .viewer: "Only view"
        }
    }

    var shortTitle: String {
        switch self {
        case .trusted: "Trusted"
        case .commenter: "Can comment"
        case .viewer: "View only"
        }
    }
}

/// A colored circle with someone's initials.
struct InitialsAvatar: View {
    let name: String
    let color: String
    var size: CGFloat = 20

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: color) ?? .gray, in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// "3 here" next to a share that has people connected.
struct PeopleBadge: View {
    let count: Int

    var body: some View {
        Label("\(count)", systemImage: "person.2.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .help(count == 1 ? "1 person here" : "\(count) people here")
            .accessibilityLabel(count == 1 ? "1 person here" : "\(count) people here")
    }
}

extension Color {
    /// `#rrggbb`.
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension MacAppSession.State {
    /// It quit or failed: Restart and Reset may bring it back.
    var isProblem: Bool {
        switch self {
        case .crashed, .failed: true
        default: false
        }
    }
}

/// What sharing a Mac app needs from System Settings, with buttons that ask macOS for it (its prompt
/// lists OpenTraffic there) and open the pane where it's turned on.
struct MacAppPermissionsMessage: View {
    let store: AppStore
    /// The app a share is waiting to start, if any.
    var waitingApp: String?
    var onCancel: (() -> Void)?

    var body: some View {
        let missing = store.missingMacAppPermissions
        InlineMessage(severity: .warning, message: message(missing), title: missing.count == 1 ? "One permission needed" : "Two permissions needed") {
            ForEach(missing, id: \.self) { permission in
                Button("\(Self.shortTitle(permission))…") { store.requestMacAppPermission(permission) }
                    .help("Ask macOS for \(permission.title) and open System Settings > Privacy & Security > \(permission.title)")
            }
            if let onCancel { Button("Cancel", action: onCancel) }
        }
    }

    static func shortTitle(_ permission: MacAppSession.Permission) -> String {
        switch permission {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    private func message(_ missing: [MacAppSession.Permission]) -> String {
        let names = missing.map(Self.shortTitle).joined(separator: " and ")
        var parts = ["To share \(waitingApp ?? "Mac apps"), switch OpenTraffic on for \(names) in System Settings > Privacy & Security."]
        if missing.contains(.accessibility) { parts.append("Accessibility lets it read and press the app's controls.") }
        if missing.contains(.screenRecording) { parts.append("Screen Recording lets it show the app's window, and only that window.") }
        if waitingApp != nil { parts.append("The share starts once \(missing.count == 1 ? "it's" : "both are") on.") }
        if missing.contains(.screenRecording) { parts.append("If Screen Recording stays off, quit and reopen OpenTraffic.") }
        return parts.joined(separator: " ")
    }
}

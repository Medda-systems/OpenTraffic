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
            .disabled(blocker != nil || applying)

            if let blocker {
                InlineMessage(severity: .info, message: blocker)
            } else if tunnel.collaboration {
                if store.isCollaborating(tunnel.id) {
                    peopleList
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
                severity: .info,
                message: "A page in this share asked to reach localhost:\(port). Visitors' browsers can't reach it unless you share it too. Only allow services this app really uses.",
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
                        Spacer(minLength: Spacing.s)
                        Text(peer.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
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

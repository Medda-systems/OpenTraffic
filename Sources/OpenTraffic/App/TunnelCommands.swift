import AppKit
import SwiftUI
import OpenTrafficCore

/// Menu bar commands and keyboard shortcuts. Follows macOS conventions:
/// ⌘N new, ⌘R refresh, ⌘⏎ primary action, Delete removes (in the sidebar).
struct TunnelCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let store: AppStore

    var body: some Commands {
        let _ = MainWindowController.shared.registerOpener(openWindow)
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: Updates.checkForUpdates)
                .disabled(!Updates.isAvailable)
        }

        CommandGroup(replacing: .newItem) {
            Button(Vocabulary.newTunnel) { router.show(sheet: .newTunnel(.quick)) }
                .keyboardShortcut("n")
            Button("Import from Cloudflare…") { router.show(sheet: .newTunnel(.importExisting)) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandMenu("Tunnel") {
            Button(toggleTitle) {
                if let definition = store.selectedDefinition { store.toggle(definition) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store.selectedDefinition == nil || selectedState == .stopping)

            Divider()

            Button(Vocabulary.copyURL) {
                if let id = store.selectedID { store.copyPublicURL(id) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selectedPublicURL == nil)

            Button(Vocabulary.openInBrowser) {
                if let selectedPublicURL, let url = URL(string: selectedPublicURL) { NSWorkspace.shared.open(url) }
            }
            .keyboardShortcut("o")
            .disabled(selectedPublicURL == nil)

            Button("Recheck Health") {
                if let id = store.selectedDefinition?.id { Task { await store.refreshHealth(for: id) } }
            }
            .keyboardShortcut("r")
            .disabled(store.selectedDefinition == nil)

            Divider()

            Button("Show Overview") { store.detailTab = .overview }
                .keyboardShortcut("1")
                .disabled(store.selectedID == nil)
            Button(Vocabulary.showLogs) { store.detailTab = .logs }
                .keyboardShortcut("2")
                .disabled(store.selectedID == nil)
            Button("Show Requests") { store.detailTab = .requests }
                .keyboardShortcut("3")
                .disabled(store.selectedDefinition?.kind != .ngrok)
            Button("Show Feedback") { store.detailTab = .feedback }
                .keyboardShortcut("4")
                .disabled(store.selectedDefinition?.kind.supportsCollaboration != true)

            Divider()

            Button(Vocabulary.edit) {
                if let id = store.selectedDefinition?.id { store.present(.edit(id)) }
            }
            .disabled(store.selectedDefinition == nil)
            Button("Protection…") {
                if let id = store.selectedDefinition?.id { store.present(.protection(id)) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(store.selectedDefinition == nil)
            Button("Host Header…") {
                if let id = store.selectedDefinition?.id { store.present(.hostHeader(id)) }
            }
            .disabled(store.selectedDefinition == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Show OpenTraffic") { router.show() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Setup Assistant…") { router.show(sheet: .onboarding) }
            Button("Cloudflare Tunnel Documentation") {
                NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/")!)
            }
        }
    }

    private var router: MainWindowRouter { MainWindowRouter(store: store, openWindow: openWindow) }

    private var selectedState: LocalTunnelState? {
        store.selectedDefinition.map { store.runtime(for: $0.id).state }
    }

    private var toggleTitle: String {
        switch selectedState {
        case .running, .starting: Vocabulary.stop
        case .stopping: "Stopping…"
        default: Vocabulary.start
        }
    }

    private var selectedPublicURL: String? {
        if let definition = store.selectedDefinition { return store.publicURL(for: definition) }
        return store.selectedDiscoveredTunnel?.publicURL
    }
}

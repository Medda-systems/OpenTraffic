import AppKit
import SwiftUI
import OpenTrafficCore

enum NgrokLinks {
    static let authtoken = URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!
    static let domains = URL(string: "https://dashboard.ngrok.com/domains")!
    static let download = URL(string: "https://ngrok.com/download")!
}

/// ngrok installation, authtoken, plan notes, and agents running elsewhere. Renders Form sections.
struct NgrokStatusView: View {
    @Bindable var store: AppStore
    var showsSettings = false
    @State private var recheck = 0

    var body: some View {
        Section {
            row(
                "ngrok CLI",
                ok: store.ngrokPath != nil,
                detail: store.ngrokPath?.path ?? "Not installed. Install it with Homebrew: brew install ngrok"
            ) {
                if store.ngrokPath == nil {
                    CopyButton(text: "brew install ngrok", label: "Copy Install Command", iconOnly: false)
                }
            }
            row(
                "Authtoken",
                ok: store.ngrokAuthtokenConfigured,
                detail: store.ngrokAuthtokenConfigured
                    ? "Configured in ngrok's own config file. OpenTraffic reuses it and never edits that file."
                    : "Copy your authtoken from the ngrok dashboard, then run the command below in Terminal."
            ) {
                if !store.ngrokAuthtokenConfigured {
                    Button("Open Dashboard…") { NSWorkspace.shared.open(NgrokLinks.authtoken) }
                    CopyButton(text: "ngrok config add-authtoken ", label: "Copy Command", iconOnly: false)
                }
            }
        } header: {
            HStack {
                Text("ngrok")
                Spacer()
                Button("Check Again", systemImage: "arrow.clockwise") { recheck += 1 }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        } footer: {
            Text("The free plan gives your account one domain and serves one ngrok share at a time. Browser visitors see an ngrok notice before your site; API clients and webhooks don't.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(recheck)

        if showsSettings, !store.externalNgrokTunnels.isEmpty {
            Section("Running Elsewhere") {
                ForEach(store.externalNgrokTunnels, id: \.publicURL) { tunnel in
                    LabeledContent {
                        Text(tunnel.address ?? "—").monospaced().textSelection(.enabled)
                    } label: {
                        Text(tunnel.publicURL)
                        Text("Started outside OpenTraffic")
                    }
                }
            }
        }
    }

    private func row<Actions: View>(_ title: String, ok: Bool, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            actions().controlSize(.small)
        }
    }
}

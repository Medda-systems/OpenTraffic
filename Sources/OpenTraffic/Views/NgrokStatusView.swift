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
            ToolInstallRow(store: store, provider: .ngrok, purpose: "ngrok's agent, for your ngrok domain. Needs a free ngrok account.", prominent: true)
            if store.ngrokPath != nil {
                if store.ngrokAuthtokenConfigured {
                    row(
                        "Authtoken",
                        ok: true,
                        detail: "Configured in ngrok's own config file. OpenTraffic reuses it."
                    ) {
                        EmptyView()
                    }
                } else {
                    NgrokConnectRow(store: store)
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

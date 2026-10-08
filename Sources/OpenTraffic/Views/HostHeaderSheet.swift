import SwiftUI
import OpenTrafficCore

/// Explains "host not allowed" errors and offers both fixes: rewrite the Host header in the tunnel,
/// or allow the public hostname in the dev server's config.
struct HostHeaderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let tunnel: TunnelDefinition
    @State private var framework: BlockingFramework = .vite
    @State private var isApplying = false

    var body: some View {
        SheetScaffold(
            title: "Host Header",
            subtitle: "Dev servers like Vite, Next.js, and Django reject requests for hostnames they don't know, such as your public URL."
        ) {
            Form {
                if tunnel.kind.supportsHostHeaderRewrite {
                    Section {
                        Toggle(isOn: rewriteBinding) {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("Send \(tunnel.originHostHeader ?? "the local host") as the Host header")
                                Text("Easiest fix. Your server sees requests as if they came to \(tunnel.originHostHeader ?? "localhost"). Links your app builds from the Host header will point at localhost.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isApplying)
                        if isApplying {
                            HStack(spacing: Spacing.s) {
                                ProgressView().controlSize(.small)
                                Text(tunnel.kind.usesCloudflareAccount ? "Updating Cloudflare…" : "Restarting the tunnel…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Fix in the tunnel")
                    }
                } else {
                    Section {
                        InlineMessage(severity: .info, message: "\(tunnel.kind.provider.title) shares can't rewrite the Host header, so allow the hostname in your dev server instead.")
                    }
                }

                Section {
                    Picker("Framework", selection: $framework) {
                        ForEach(BlockingFramework.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(framework.snippet(hostname: publicHost))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.s)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.small))
                    HStack {
                        Spacer()
                        CopyButton(text: framework.snippet(hostname: publicHost), label: "Copy Snippet", iconOnly: false)
                    }
                } header: {
                    Text("Or allow the hostname in your dev server")
                }
            }
            .formStyle(.grouped)
        } trailingFooter: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            if case .hostBlocked(let detected) = store.health(for: tunnel.id)?.checks.compactMap(\.remedy).first {
                framework = detected
            }
        }
    }

    private var publicHost: String {
        store.publicURL(for: tunnel).flatMap { URL(string: $0)?.host } ?? "your-public-hostname"
    }

    private var rewriteBinding: Binding<Bool> {
        Binding {
            store.definitions.first(where: { $0.id == tunnel.id })?.rewriteHostHeader ?? false
        } set: { enabled in
            isApplying = true
            Task {
                await store.setHostHeaderRewrite(enabled, for: tunnel.id)
                isApplying = false
            }
        }
    }
}

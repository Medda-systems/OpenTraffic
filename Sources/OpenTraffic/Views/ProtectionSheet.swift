import SwiftUI
import OpenTrafficCore

extension ShareProtection {
    var summary: String {
        switch self {
        case .none: "Anyone with the link"
        case .password(let username): "Password protected (\(username))"
        case .login(let provider, let emails):
            emails.isEmpty ? "Sign in with \(provider.title)" : "Sign in with \(provider.title) · \(emails.count) allowed"
        }
    }

    var symbol: String {
        self == .none ? "lock.open" : "lock.fill"
    }

    var option: ProtectionOption {
        switch self {
        case .none: .none
        case .password: .password
        case .login(.google, _): .google
        case .login(.github, _): .github
        case .login(.cloudflareEmail, _): .cloudflareEmail
        }
    }
}

/// Who can open the public URL: anyone, a password, or a sign-in (with an optional email allow-list).
struct ProtectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let tunnel: TunnelDefinition
    @State private var option: ProtectionOption = .none
    @State private var username = "guest"
    @State private var emails = ""
    @State private var isApplying = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Protection", subtitle: "Choose who can open \(store.publicURL(for: tunnel) ?? "this tunnel's URL").") {
            Form {
                if tunnel.kind.protectionOptions.isEmpty {
                    Section { InlineMessage(severity: .info, message: unsupportedMessage) }
                } else {
                    Section {
                        Picker("Who can open it", selection: $option) {
                            ForEach(tunnel.kind.protectionOptions) { option in
                                Text(title(for: option)).tag(option)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }
                    details
                    if let error {
                        Section { InlineMessage(severity: .error, message: error) }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isApplying)
        } trailingFooter: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
            if !tunnel.kind.protectionOptions.isEmpty {
                Button(action: apply) {
                    if isApplying {
                        HStack(spacing: Spacing.s) { ProgressView().controlSize(.small); Text("Applying…") }
                    } else {
                        Text("Apply")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || validationProblem != nil || protection == currentProtection)
            }
        }
        .frame(width: 540, height: 520)
        .onAppear(perform: seed)
    }

    @ViewBuilder
    private var details: some View {
        switch option {
        case .none:
            Section {
                Text("No sign-in. Anyone who has the link can open your local service.")
                    .foregroundStyle(.secondary)
            }
        case .password:
            Section {
                TextField("Username", text: $username)
            } footer: {
                Text("OpenTraffic generates a strong password and keeps it in your Keychain. Browsers show a sign-in prompt; scripts can use the username and password.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .google, .github:
            Section {
                TextField("Allowed emails", text: $emails, prompt: Text("alice@example.com, bob@example.com"), axis: .vertical)
                    .lineLimit(2...4)
                if emails.nilIfBlank == nil {
                    InlineMessage(severity: .warning, message: "With no emails listed, anyone with a \(option == .google ? "Google" : "GitHub") account can sign in.")
                }
            } footer: {
                Text("Visitors sign in through ngrok's \(option == .google ? "Google" : "GitHub") app before reaching your site.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .cloudflareEmail:
            Section {
                TextField("Allowed emails", text: $emails, prompt: Text("alice@example.com, bob@example.com"), axis: .vertical)
                    .lineLimit(2...4)
                switch store.cloudflareAccessPermission {
                case false?:
                    InlineMessage(severity: .warning, message: "Your API token can't manage Cloudflare Access yet. Edit the token and add Account → Access: Apps and Policies → Edit.")
                case true?:
                    InlineMessage(severity: .info, message: "Your API token can read Cloudflare Access. Creating the application also needs the Edit level of Access: Apps and Policies.")
                case nil:
                    EmptyView()
                }
            } footer: {
                Text("Creates a Cloudflare Access application for \(tunnel.hostname ?? "this hostname"). Listed people get a one-time code by email. Access needs a Zero Trust organization (free) in your Cloudflare account. Removing the tunnel from OpenTraffic leaves the application in place — turn protection off first to delete it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var unsupportedMessage: String {
        switch tunnel.kind {
        case .tailscale:
            tunnel.tailscalePublic
                ? "Public Funnel shares can't add a password. Share privately instead: only devices on your tailnet can open it."
                : "Private Tailscale shares are already limited to devices signed in to your tailnet."
        case .opentunnel:
            "OpenTunnel shares can't add a password or sign-in. Anyone with the link can open them, and the tunnel's address appears in public certificate logs, so put sign-in in the app itself."
        default:
            "Temporary URLs can't be protected. Use ngrok (password or sign-in) or your own domain (email codes) instead."
        }
    }

    private func title(for option: ProtectionOption) -> String {
        switch option {
        case .none: "Anyone with the link"
        case .password: "Password"
        case .google: "Sign in with Google"
        case .github: "Sign in with GitHub"
        case .cloudflareEmail: "Email code (Cloudflare Access)"
        }
    }

    private var validationProblem: String? {
        switch option {
        case .password:
            return username.nilIfBlank == nil || username.contains(":") ? "Enter a username without a colon." : nil
        case .google, .github:
            return EmailList.parse(emails) == nil ? "Check the email addresses." : nil
        case .cloudflareEmail:
            guard let list = EmailList.parse(emails) else { return "Check the email addresses." }
            return list.isEmpty ? "Add at least one email." : nil
        case .none:
            return nil
        }
    }

    private var protection: ShareProtection {
        let list = EmailList.parse(emails) ?? []
        switch option {
        case .none: return .none
        case .password: return .password(username: username.trimmingCharacters(in: .whitespaces))
        case .google: return .login(.google, allowedEmails: list)
        case .github: return .login(.github, allowedEmails: list)
        case .cloudflareEmail: return .login(.cloudflareEmail, allowedEmails: list)
        }
    }

    /// Applying an unchanged setting would restart a running ngrok share for nothing.
    private var currentProtection: ShareProtection {
        store.definitions.first(where: { $0.id == tunnel.id })?.protection ?? .none
    }

    private func seed() {
        let current = currentProtection
        option = current.option
        switch current {
        case .password(let name): username = name
        case .login(_, let list): emails = list.joined(separator: ", ")
        case .none: break
        }
    }

    private func apply() {
        isApplying = true
        error = nil
        Task {
            let message = await store.setProtection(protection, for: tunnel.id)
            isApplying = false
            if let message { error = message } else { dismiss() }
        }
    }
}

/// The share's username and password, with copy, reveal, and replace.
struct SharePasswordRow: View {
    let store: AppStore
    let tunnel: TunnelDefinition
    let username: String
    @State private var revealed = false
    @State private var confirmingNewPassword = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Text(username).monospaced()
            Text(revealed ? (store.sharePassword(for: tunnel.id) ?? "—") : "••••••••••")
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(revealed ? .primary : .secondary)
            Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                .buttonStyle(.borderless)
            CopyButton(label: "Copy Password", concealed: true) { store.sharePassword(for: tunnel.id) }
                .buttonStyle(.borderless)
            Button("New Password…") { confirmingNewPassword = true }
                .buttonStyle(.borderless)
                .help("Replace the password; the old one stops working")
        }
        .font(.callout)
        .confirmationDialog("Replace the password for “\(tunnel.name)”?", isPresented: $confirmingNewPassword) {
            Button("New Password", role: .destructive) { Task { await store.regenerateSharePassword(for: tunnel.id) } }
        } message: {
            Text("Anyone using the current password is locked out\(store.isActive(tunnel.id) ? ", and the share restarts briefly" : "").")
        }
    }
}

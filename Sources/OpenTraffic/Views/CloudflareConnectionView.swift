import AppKit
import SwiftUI
import OpenTrafficCore

/// Connects OpenTraffic to a Cloudflare account. Renders Form sections, so place it inside a Form.
/// Used by Settings, the New Tunnel flow, and the setup assistant.
struct CloudflareConnectionView: View {
    enum Mode {
        /// Everything, including token storage options.
        case settings
        /// Only what's needed to get connected.
        case inline
    }

    @Bindable var store: AppStore
    var mode: Mode = .settings
    @State private var token = ""
    @State private var message: (severity: Severity, text: String)?
    @State private var useKeychainUserPresence = false
    @State private var isWorking = false

    var body: some View {
        if mode == .settings || !store.hasAPIToken() || store.accountID.isEmpty {
            statusSection
            credentialsSection
            if mode == .settings, showsProtectedStorage { storageSection }
        } else if !store.isAPITokenUnlocked {
            unlockSection
        } else {
            statusSection
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack(spacing: Spacing.m) {
                Image(systemName: connection.symbol)
                    .font(.title2)
                    .foregroundStyle(connection.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(connection.title).fontWeight(.semibold)
                    Text(connection.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if store.isRefreshingAccount || isWorking {
                    ProgressView().controlSize(.small)
                } else if store.isAPITokenUnlocked {
                    Button("Verify") { Task { await store.refreshAccount() } }
                } else if store.hasAPIToken() {
                    if store.requiresLegacyTokenAuthorization {
                        Button("Authorize Saved Token", action: authorizeLegacy)
                    }
                    Button(store.sessionUnlockLabel, action: unlock)
                }
            }
            if let accountError = store.accountError, store.isAPITokenUnlocked {
                InlineMessage(severity: .error, message: accountError)
            }
            if mode == .settings, store.isAPITokenUnlocked, let permission = store.cloudflareAccessPermission {
                LabeledContent("Email sign-in (Access)") {
                    Label(permission ? "Token can read Access" : "Token needs Access: Apps and Policies → Edit",
                          systemImage: permission ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(permission ? .green : .secondary)
                        .help(permission ? "Protecting a domain also needs the Edit level of that permission; OpenTraffic can only check read access without changing anything." : "")
                }
            }
        }
    }

    private var connection: (title: String, detail: String, symbol: String, tint: Color) {
        if store.accountID.isEmpty || !store.hasAPIToken() {
            return ("Not connected", "Custom domains and imports need a Cloudflare account. Temporary URLs work without one.", "cloud", .secondary)
        }
        if !store.isAPITokenUnlocked {
            return ("Token locked", "Unlock the saved token for this session to use your account.", "lock.fill", .yellow)
        }
        if store.accountError != nil {
            return ("Connection problem", "Account \(store.accountID)", "exclamationmark.icloud.fill", .red)
        }
        let zones = store.zones.count
        let zoneText = zones == 0 ? "no zones loaded" : "\(zones) zone\(zones == 1 ? "" : "s")"
        return ("Connected", "Account \(store.accountID) · \(zoneText)", "checkmark.icloud.fill", .green)
    }

    // MARK: Credentials

    private var credentialsSection: some View {
        Section {
            TextField("Account ID", text: $store.accountID, prompt: Text("32-character ID from the dashboard URL"))
            SecureField(
                "API token",
                text: $token,
                prompt: Text(store.hasAPIToken() ? "Saved in Keychain — enter a new one to replace it" : "Paste a scoped API token")
            )
            if let accountIDProblem {
                InlineMessage(severity: .warning, message: accountIDProblem)
            }
            if let message {
                InlineMessage(severity: message.severity, message: message.text)
            }
            if let credentialError = store.credentialError {
                InlineMessage(severity: .error, message: credentialError)
            }
            HStack {
                Button("Create Token in Cloudflare…") {
                    NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                }
                Spacer()
                if mode == .settings, store.hasAPIToken() {
                    Button("Forget Token", role: .destructive, action: forgetToken)
                }
                Button(store.hasAPIToken() ? "Replace Token" : "Connect", action: saveToken)
                    .buttonStyle(.borderedProminent)
                    .disabled(token.nilIfBlank == nil || accountIDProblem != nil || store.accountID.isEmpty || isWorking)
            }
        } header: {
            Text("Credentials")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Create a custom token with exactly these permissions, scoped to your account and the zones OpenTraffic should manage:")
                Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.xxs) {
                    permissionRow("Account", "Cloudflare Tunnel", "Edit")
                    permissionRow("Zone", "Zone", "Read")
                    permissionRow("Zone", "DNS", "Edit")
                }
                .padding(.leading, Spacing.s)
                Text("The token is stored in your macOS Keychain, never in preferences.")
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ scope: String, _ resource: String, _ level: String) -> some View {
        GridRow {
            Text(scope)
            Image(systemName: "chevron.right").font(.caption2)
            Text(resource)
            Image(systemName: "chevron.right").font(.caption2)
            Text(level).fontWeight(.semibold)
        }
    }

    private var accountIDProblem: String? {
        let value = store.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if value.count != 32 || !value.unicodeScalars.allSatisfy(hexadecimal.contains) {
            return "That doesn't look like an account ID. Use the 32-character hexadecimal ID, not the account name."
        }
        return nil
    }

    // MARK: Unlock

    private var unlockSection: some View {
        Section {
            InlineMessage(
                severity: .info,
                message: store.credentialError ?? "Authorize the saved token once for this session. Background refresh never prompts.",
                title: "Unlock Cloudflare"
            ) {
                Button(store.sessionUnlockLabel, action: unlock)
                    .buttonStyle(.borderedProminent)
                if store.requiresLegacyTokenAuthorization {
                    Button("Authorize Saved Token", action: authorizeLegacy)
                }
            }
        }
    }

    // MARK: Storage

    /// Touch ID–protected storage needs a paid-program signing setup, so the option only appears
    /// when the build can actually use it, or when a token is already stored that way.
    private var showsProtectedStorage: Bool {
        store.signingReadiness.isReadyForProtectedKeychain || store.tokenStorageKind == .userPresence
    }

    private var storageSection: some View {
        Section("Token Storage") {
            Toggle("Require Touch ID to unlock the token", isOn: $useKeychainUserPresence)
                .disabled(!store.signingReadiness.isReadyForProtectedKeychain)
            InlineMessage(
                severity: store.signingReadiness.isReadyForProtectedKeychain ? .success : .warning,
                message: store.signingReadiness.message
            )
            if store.hasAPIToken(), store.tokenStorageKind == .standard {
                LabeledContent("Existing token") {
                    Button("Migrate to Touch ID…") { Task { await store.migrateTokenToUserPresence() } }
                        .disabled(!store.isAPITokenUnlocked || !store.signingReadiness.isReadyForProtectedKeychain)
                }
            }
            if let migrationMessage = store.credentialMigrationMessage {
                InlineMessage(severity: .success, message: migrationMessage)
            }
            Text("Standard Keychain tokens unlock automatically at launch. Touch ID–protected tokens ask once per session and need a consistently signed build with the Keychain capability.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func saveToken() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await store.saveAPIToken(token, useKeychainUserPresence: useKeychainUserPresence)
                token = ""
                await store.refreshAccount()
                if let error = store.accountError {
                    message = (.error, "Saved, but Cloudflare rejected the request: \(error)")
                } else {
                    message = (.success, useKeychainUserPresence
                        ? "Connected. Token saved with Touch ID protection."
                        : "Connected. Token saved in your Keychain.")
                }
            } catch {
                message = (.error, error.localizedDescription)
            }
        }
    }

    private func forgetToken() {
        Task {
            do {
                try await store.forgetAPIToken()
                token = ""
                message = (.info, "Token removed from Keychain.")
            } catch {
                message = (.error, error.localizedDescription)
            }
        }
    }

    private func authorizeLegacy() {
        Task {
            await store.authorizeLegacyAPIToken()
            if store.isAPITokenUnlocked { await store.refreshAccount() }
        }
    }

    private func unlock() {
        Task {
            await store.unlockAPIToken()
            if store.isAPITokenUnlocked { await store.refreshAccount() }
        }
    }
}

import Foundation
import OpenTrafficCore

extension AppStore {
    /// Changes who can open a tunnel's URL. ngrok shares restart with the new policy; custom domains
    /// create or delete a Cloudflare Access application. Returns an error message, or nil on success.
    @discardableResult
    func setProtection(_ protection: ShareProtection, for id: UUID) async -> String? {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return "This tunnel no longer exists." }
        let definition = definitions[index]
        switch definition.kind {
        case .ngrok:
            if case .password = protection, SharePasswordStore.password(for: id) == nil {
                guard SharePasswordStore.setPassword(SharePassword.generate(), for: id) else {
                    return "Couldn't save the password in the Keychain."
                }
            }
            if protection == .none { SharePasswordStore.deletePassword(for: id) }
        case .remote:
            if let message = await applyAccessProtection(protection, to: definition) { return message }
        case .quick, .opentunnel:
            if case .password = protection, SharePasswordStore.password(for: id) == nil {
                guard SharePasswordStore.setPassword(SharePassword.generate(), for: id) else {
                    return "Couldn't save the password in the Keychain."
                }
            }
        case .tailscale:
            return "\(definition.kind.title) shares can't be protected by OpenTraffic."
        }
        guard let current = definitions.firstIndex(where: { $0.id == id }) else { return nil }
        definitions[current].protection = protection
        saveDefinitions()
        if definition.kind.passwordInProxy {
            if protection == .none { SharePasswordStore.deletePassword(for: id) }
            if let proxy = collabProxies[id] {
                // The proxy checks it: no restart, so the share keeps its address.
                proxy.setAccess(try? shareAccess(for: definitions[current]))
            } else if isActive(id), protection != .none {
                // Nothing in between yet: restart through the proxy.
                await restart(id)
            }
            await refreshHealth(for: id)
        } else if definition.kind == .ngrok, isActive(id) {
            await restart(id)
        } else {
            await refreshHealth(for: id)
        }
        return nil
    }

    func sharePassword(for id: UUID) -> String? {
        SharePasswordStore.password(for: id)
    }

    /// Replaces the password; anyone using the old one is locked out.
    func regenerateSharePassword(for id: UUID) async {
        guard SharePasswordStore.setPassword(SharePassword.generate(), for: id) else {
            notice = AppNotice(.error, "Couldn't save the new password in the Keychain.")
            return
        }
        if let definition = definitions.first(where: { $0.id == id }), definition.kind.passwordInProxy {
            collabProxies[id]?.setAccess(try? shareAccess(for: definition))
        } else if isActive(id) {
            await restart(id)
        }
        notice = AppNotice(.success, "New password set. Anyone with the old password is locked out.")
    }

    /// Basic-auth credentials for the ngrok policy, if the share is password protected.
    /// Throws rather than returning nothing when the password can't be read, so a protected share
    /// never starts open.
    func ngrokCredentials(for definition: TunnelDefinition) throws -> [String] {
        guard case .password(let username) = definition.protection else { return [] }
        guard let password = SharePasswordStore.password(for: definition.id)?.nilIfBlank else {
            throw OpenTrafficError.process("OpenTraffic couldn't read this share's password from the Keychain, so it didn't start the share unprotected. Open Protection and choose New Password.")
        }
        return ["\(username):\(password)"]
    }

    /// The password OpenTraffic's proxy asks for, if the share has one checked there. Throws rather
    /// than returning nothing when the password can't be read, so a protected share never starts open.
    func shareAccess(for definition: TunnelDefinition) throws -> ShareAccess? {
        guard definition.kind.passwordInProxy, case .password = definition.protection else { return nil }
        guard let password = SharePasswordStore.password(for: definition.id)?.nilIfBlank else {
            throw OpenTrafficError.process("OpenTraffic couldn't read this share's password from the Keychain, so it didn't start the share unprotected. Open Protection and choose New Password.")
        }
        return ShareAccess(password: password, shareKey: definition.id.uuidString, shareName: definition.name)
    }

    /// The share's address with sign-in built in: whoever opens it skips the password page.
    func inviteLink(for id: UUID) -> String? {
        guard let definition = definitions.first(where: { $0.id == id }), let url = publicURL(for: definition),
              let access = try? shareAccess(for: definition) else { return nil }
        return access.inviteURL(publicURL: url)
    }

    func copyInviteLink(_ id: UUID) {
        if let link = inviteLink(for: id) { copy(link, feedbackFor: id) }
    }

    func ngrokOAuth(for definition: TunnelDefinition) -> (provider: LoginProvider, allowedEmails: [String])? {
        guard case .login(let provider, let emails) = definition.protection, provider != .cloudflareEmail else { return nil }
        return (provider, emails)
    }

    // MARK: Cloudflare Access

    private func applyAccessProtection(_ protection: ShareProtection, to definition: TunnelDefinition) async -> String? {
        guard let account = definition.accountID, let hostname = definition.hostname?.nilIfBlank else {
            return "This tunnel has no Cloudflare hostname to protect."
        }
        if case .login(.cloudflareEmail, let emails) = protection, emails.isEmpty {
            return "Add at least one email address that may sign in."
        }
        do {
            let client = try await client(for: account)
            let name = "OpenTraffic · \(definition.name)"
            if case .login(.cloudflareEmail, let emails) = protection {
                // Change emails in place: deleting first would leave the site open if creating failed.
                if let existing = definition.accessApplicationID {
                    do {
                        try await client.updateAccessApplication(id: existing, name: name, hostname: hostname, allowedEmails: emails)
                        return nil
                    } catch let error as OpenTrafficError where error.isNotFound {
                        // Deleted in the dashboard; create a new one below.
                    }
                }
                let id = try await client.createAccessApplication(name: name, hostname: hostname, allowedEmails: emails)
                setAccessApplicationID(id, for: definition.id)
            } else if let existing = definition.accessApplicationID {
                do {
                    try await client.deleteAccessApplication(id: existing)
                } catch let error as OpenTrafficError where error.isNotFound {}
                setAccessApplicationID(nil, for: definition.id)
            }
            return nil
        } catch {
            let message = Self.explainAccessError(error.localizedDescription)
            // Cloudflare refused the write, so the token can read Access but not edit it: say so in Settings.
            if message.hasPrefix("Your Cloudflare API token can't manage Access") {
                accessEditDenied = true
                cloudflareAccessPermission = false
            }
            return message
        }
    }

    private func setAccessApplicationID(_ value: String?, for id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].accessApplicationID = value
        saveDefinitions()
    }

    static func explainAccessError(_ message: String) -> String {
        if message.contains("HTTP 403") || message.localizedCaseInsensitiveContains("authentication error") {
            return "Your Cloudflare API token can't manage Access. Edit the token and add the permission Account → Access: Apps and Policies → Edit, then try again."
        }
        if message.localizedCaseInsensitiveContains("organization") || message.localizedCaseInsensitiveContains("zero trust") {
            return "Cloudflare Access needs a Zero Trust organization. Set one up (free) at one.dash.cloudflare.com, then try again."
        }
        return message
    }

    /// Read-only check run with each account refresh, so the UI can say up front whether Access will work.
    func refreshAccessPermission() async {
        guard isAPITokenUnlocked, let client = try? await client(for: accountID) else {
            cloudflareAccessPermission = nil
            return
        }
        let canRead = await client.canManageAccessApplications()
        cloudflareAccessPermission = accessEditDenied && canRead == true ? false : canRead
    }
}

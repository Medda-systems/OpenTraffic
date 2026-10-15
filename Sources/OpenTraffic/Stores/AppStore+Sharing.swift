import Foundation
import OpenTrafficCore

/// How long a share stays up before it stops itself.
enum ShareDuration: String, CaseIterable, Identifiable {
    case never
    case minutes15
    case hour1
    case hours4

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .minutes15: 15 * 60
        case .hour1: 60 * 60
        case .hours4: 4 * 60 * 60
        }
    }

    var title: String {
        switch self {
        case .never: "Until I stop it"
        case .minutes15: "15 minutes"
        case .hour1: "1 hour"
        case .hours4: "4 hours"
        }
    }
}

enum Countdown {
    /// "42 min", "1 h 5 min", "<1 min"
    static func text(until deadline: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, deadline.timeIntervalSince(now)) / 60)
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

extension AppStore {
    // MARK: Auto-stop

    func setAutoStop(_ id: UUID, after duration: ShareDuration) {
        autoStopDeadlines[id] = duration.interval.map { Date().addingTimeInterval($0) }
    }

    func enforceAutoStop(now: Date = Date()) {
        for (id, deadline) in autoStopDeadlines where deadline <= now {
            autoStopDeadlines[id] = nil
            guard isActive(id), let definition = definitions.first(where: { $0.id == id }) else { continue }
            stop(id)
            notice = AppNotice(.info, "Stopped “\(definition.name)” — its share time ran out.")
            TunnelNotifications.post(
                title: "\(definition.name) stopped",
                body: "Its share time ran out.",
                identifier: "autostop-\(id.uuidString)"
            )
        }
    }

    // MARK: Default share

    /// The provider a plain Share click uses, falling back to a temporary URL when it isn't ready.
    var effectiveDefaultShareKind: TunnelKind {
        switch defaultShareKind {
        case .tailscale where tailscaleBlocker == nil: .tailscale
        case .ngrok where ngrokBlocker == nil: .ngrok
        case .opentunnel where openTunnelBlocker == nil: .opentunnel
        default: .quick
        }
    }

    // MARK: Host header

    /// Makes the tunnel send the local service's own host as the Host header (or stops doing so).
    /// Custom domains change Cloudflare's ingress; Quick Tunnels and ngrok restart with the new setting.
    func setHostHeaderRewrite(_ enabled: Bool, for id: UUID) async {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        let definition = definitions[index]
        guard definition.supportsHostHeaderRewrite, definition.rewriteHostHeader != enabled else { return }
        if definition.kind.usesCloudflareAccount {
            do {
                guard let account = definition.accountID, let tunnelID = definition.cloudflareTunnelID,
                      let hostname = definition.hostname?.nilIfBlank else {
                    throw OpenTrafficError.api("This tunnel has no Cloudflare hostname to configure.")
                }
                let client = try await client(for: account)
                try await client.applyHostnameConfiguration(
                    tunnelID: tunnelID,
                    hostname: hostname,
                    service: definition.localURL,
                    hostHeader: enabled ? definition.originHostHeader.map { .set($0) } ?? .keep : .remove
                )
            } catch {
                notice = AppNotice(.error, "Couldn't update the Host header on Cloudflare: \(error.localizedDescription)")
                return
            }
        }
        // Look the tunnel up again: it may have moved or been removed while Cloudflare was updating.
        guard let current = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[current].rewriteHostHeader = enabled
        saveDefinitions()
        if !definition.kind.usesCloudflareAccount, isActive(id) {
            await restart(id)
        } else {
            await refreshHealth(for: id)
        }
        notice = AppNotice(.success, enabled
            ? "“\(definition.name)” now sends \(definition.originHostHeader ?? "the local host") as the Host header."
            : "“\(definition.name)” now sends the public hostname as the Host header.")
    }

    /// Stops a running tunnel and starts it again once it has fully stopped.
    func restart(_ id: UUID) async {
        stop(id, endingSession: false)
        for _ in 0..<50 where runtime(for: id).state == .stopping {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let definition = definitions.first(where: { $0.id == id }) {
            start(definition)
        }
    }

    // MARK: Saved paths

    func addSavedPath(_ path: String, to id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }),
              let trimmed = path.nilIfBlank else { return }
        let normalized = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard !definitions[index].savedPaths.contains(normalized) else { return }
        definitions[index].savedPaths.append(normalized)
        saveDefinitions()
    }

    func removeSavedPath(_ path: String, from id: UUID) {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
        definitions[index].savedPaths.removeAll { $0 == path }
        saveDefinitions()
    }

    func copyPublicURL(_ id: UUID, path: String) {
        guard let definition = definitions.first(where: { $0.id == id }),
              let base = publicURL(for: definition) else { return }
        Pasteboard.copy(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }
}

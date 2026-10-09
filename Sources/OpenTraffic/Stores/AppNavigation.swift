import Foundation

/// Transient feedback shown at the bottom of the main window.
struct AppNotice: Identifiable {
    enum Action {
        case openSettings
    }

    let id = UUID()
    let severity: Severity
    let message: String
    var actionTitle: String?
    var action: Action?

    init(_ severity: Severity, _ message: String, actionTitle: String? = nil, action: Action? = nil) {
        self.severity = severity
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

enum Severity: Sendable {
    case info
    case success
    case warning
    case error
}

/// The kinds of tunnel the New Tunnel flow can produce.
enum NewTunnelKind: String, CaseIterable, Identifiable, Sendable {
    case quick
    case opentunnel
    case tailscale
    case ngrok
    case customDomain
    case importExisting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "Temporary URL"
        case .tailscale: "Your Tailnet"
        case .ngrok: "ngrok"
        case .opentunnel: "OpenTunnel"
        case .customDomain: "Your Domain"
        case .importExisting: "Existing Tunnel"
        }
    }

    /// What sets it apart, in a few words, under its name in the list.
    var tagline: String {
        switch self {
        case .quick: "Random address, new each start"
        case .opentunnel: "Lasting address, encrypted"
        case .tailscale: "Private to your devices"
        case .ngrok: "Request inspector"
        case .customDomain: "A hostname you own"
        case .importExisting: "Import from Cloudflare"
        }
    }

    /// One sentence on when to choose it.
    var pitch: String {
        switch self {
        case .quick: "The quickest way to show someone what you're working on."
        case .opentunnel: "The link stays the same each time you start, and OpenTunnel's relay can't read the traffic."
        case .tailscale: "Share with your own devices and team without putting anything on the public internet."
        case .ngrok: "See every request, replay webhooks, and protect the link with a password or sign-in."
        case .customDomain: "A permanent address on your own domain, served from this Mac."
        case .importExisting: "Run a tunnel that's already in your Cloudflare account from this Mac."
        }
    }

    /// The same three facts for every option, so they're easy to compare.
    var audience: String {
        switch self {
        case .quick, .opentunnel: "Anyone with the link"
        case .tailscale: "Devices on your tailnet, or anyone with Funnel"
        case .ngrok: "Anyone, or only people who sign in"
        case .customDomain: "Anyone, or only people with an email code"
        case .importExisting: "As the tunnel is set up"
        }
    }

    var address: String {
        switch self {
        case .quick: "A random trycloudflare.com address"
        case .opentunnel: "name.<your-id>.opentunnel.xyz, the same every start"
        case .tailscale: "This Mac's ts.net name"
        case .ngrok: "Your ngrok domain"
        case .customDomain: "A hostname on your Cloudflare zone"
        case .importExisting: "Its existing hostname"
        }
    }

    var requirement: String {
        switch self {
        case .quick: "cloudflared"
        case .opentunnel: "The opentunnel command"
        case .tailscale: "The Tailscale app, signed in"
        case .ngrok: "An ngrok account and its CLI"
        case .customDomain, .importExisting: "A Cloudflare account and cloudflared"
        }
    }

    /// The list groups options by what they need.
    enum Group: String, CaseIterable, Identifiable {
        case noAccount = "No account needed"
        case account = "With your account"
        case existing = "Already set up"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .quick, .opentunnel: .noAccount
        case .tailscale, .ngrok, .customDomain: .account
        case .importExisting: .existing
        }
    }
}

/// Every sheet the main window can present. Only one is visible at a time.
enum PresentedSheet: Identifiable, Equatable {
    case newTunnel(NewTunnelKind)
    case edit(UUID)
    case renameDiscovered(UUID)
    case hostHeader(UUID)
    case protection(UUID)
    case onboarding

    var id: String {
        switch self {
        case .newTunnel(let kind): "new-\(kind.rawValue)"
        case .edit(let id): "edit-\(id.uuidString)"
        case .renameDiscovered(let id): "rename-\(id.uuidString)"
        case .hostHeader(let id): "host-\(id.uuidString)"
        case .protection(let id): "protection-\(id.uuidString)"
        case .onboarding: "onboarding"
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case requests
    case logs
    case feedback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .requests: "Requests"
        case .logs: "Logs"
        case .feedback: "Feedback"
        }
    }
}

enum DockVisibility: String, CaseIterable, Identifiable {
    case always
    case whileWindowOpen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whileWindowOpen: "Only while the window is open"
        }
    }
}

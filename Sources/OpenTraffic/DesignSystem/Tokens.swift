import AppKit
import SwiftUI
import OpenTrafficCore

/// Layout constants shared by every OpenTraffic surface.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 14
}

/// Brand colors. The icon is black and white, so the app follows the system accent color.
enum Brand {
    static let accent = Color.accentColor
    static let accentText = Color.accentColor
    /// Cloudflare's own orange, for marking Cloudflare as a provider.
    static let cloudflare = Color(nsColor: NSColor(srgbRed: 0xF3 / 255, green: 0x80 / 255, blue: 0x20 / 255, alpha: 1))
    /// Fill for content cards in the main window.
    static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.6)
    static let cardStroke = Color.primary.opacity(0.08)
}

/// The words OpenTraffic uses for its concepts. Views use these rather than ad-hoc strings
/// so the same action is never called "Pause" in one place and "Stop" in another.
enum Vocabulary {
    static let start = "Start"
    static let stop = "Stop"
    static let share = "Share"
    static let copyURL = "Copy Public URL"
    static let openInBrowser = "Open in Browser"
    static let edit = "Edit…"
    static let rename = "Rename…"
    static let remove = "Remove from OpenTraffic…"
    static let showDetails = "Show Details"
    static let showLogs = "Show Logs"
    static let newTunnel = "New Tunnel…"
    static let publicURL = "Public URL"
    static let localService = "Local service"
    static let recheck = "Recheck"
}

extension TunnelDisplayState {
    var symbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .checking: "circle.dotted.circle"
        case .starting, .stopping: "circle.dashed"
        case .attention: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .external: "terminal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .checking: .teal
        case .starting, .stopping: .blue
        case .attention: .red
        case .stopped: .secondary
        case .external: .indigo
        }
    }

    /// `tint` for text: system colors in dark mode, darker shades in light mode so labels stay
    /// readable (at least 4.5:1) on light backgrounds.
    var textTint: Color {
        switch self {
        case .online: .adaptive(light: 0x15803D, dark: .green)
        case .checking: .adaptive(light: 0x0F766E, dark: .teal)
        case .starting, .stopping: .adaptive(light: 0x1D4ED8, dark: .blue)
        case .attention: .adaptive(light: 0xB91C1C, dark: .red)
        case .stopped: .secondary
        case .external: .adaptive(light: 0x4338CA, dark: .indigo)
        }
    }
}

extension Color {
    /// `light` (an sRGB hex) in light mode, `dark` in dark mode.
    static func adaptive(light: UInt32, dark: Color) -> Color {
        let lightColor = NSColor(
            srgbRed: CGFloat((light >> 16) & 0xFF) / 255,
            green: CGFloat((light >> 8) & 0xFF) / 255,
            blue: CGFloat(light & 0xFF) / 255,
            alpha: 1
        )
        let darkColor = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    /// Readable text color for an HTTP status class (see `httpStatus`).
    static func httpStatusText(_ codeOrClass: String) -> Color {
        switch codeOrClass.first {
        case "2": .adaptive(light: 0x15803D, dark: .green)
        case "3": .adaptive(light: 0x1D4ED8, dark: .blue)
        case "4": .adaptive(light: 0xC2410C, dark: .orange)
        case "5": .adaptive(light: 0xB91C1C, dark: .red)
        default: .secondary
        }
    }
}

extension Severity {
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .blue
        case .success: .green
        case .warning: .yellow
        case .error: .red
        }
    }
}



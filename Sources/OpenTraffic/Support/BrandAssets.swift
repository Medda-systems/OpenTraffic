import AppKit
import OpenTrafficCore

@MainActor
enum BrandAssets {
    static let menuIcon: NSImage = loadSVG(named: "opentraffic-menu", isTemplate: true)

    private static var statusIcons: [String: NSImage] = [:]
    private static var providerLogos: [TunnelProvider: NSImage] = [:]
    private static var fittedLogos: [String: NSImage] = [:]

    /// The provider's mark as a template image, or nil when running outside the app bundle.
    static func providerLogo(_ provider: TunnelProvider) -> NSImage? {
        if let cached = providerLogos[provider] { return cached }
        guard let url = Bundle.main.url(forResource: "provider-\(provider.rawValue)", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = provider.title
        providerLogos[provider] = image
        return image
    }

    /// The provider's mark at an even visual weight for `style` (see `LogoFitting`). Providers
    /// without a bundled mark (OpenTunnel), or runs outside the app bundle, use their SF Symbol.
    static func logo(_ provider: TunnelProvider, style: LogoFitting.Style) -> NSImage {
        let key = "\(provider.rawValue)-\(style.canvas.width)x\(style.canvas.height)"
        if let cached = fittedLogos[key] { return cached }
        let source = providerLogo(provider)
            ?? NSImage(systemSymbolName: provider.fallbackSymbol, accessibilityDescription: provider.title)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
            ?? NSImage()
        source.isTemplate = true
        let fitted = LogoFitting.fitted(source, style: style)
        fitted.isTemplate = true
        fitted.accessibilityDescription = provider.title
        fittedLogos[key] = fitted
        return fitted
    }

    /// The status item glyph. Template images keep the system's menu bar tinting:
    /// dimmed when nothing is shared, solid while something is live, a badge for attention,
    /// and a brief dim "blink" when new requests arrive (like a network activity light).
    static func statusBarIcon(state: MenuBarIconState, pulse: Bool) -> NSImage {
        let blink = pulse && state == .live
        let key = "\(state)-\(blink)"
        if let cached = statusIcons[key] { return cached }

        let composed = NSImage(size: NSSize(width: 31, height: 16))
        composed.lockFocus()
        let logoOpacity: CGFloat = switch state {
        case .idle: 0.45
        case .live: blink ? 0.55 : 1
        case .attention: 1
        }
        menuIcon.draw(in: NSRect(x: 0, y: 0, width: 28, height: 16), from: .zero, operation: .sourceOver, fraction: logoOpacity)
        if state == .attention {
            // A gap around the badge keeps it apart from the glyph in a one-color template image.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 21.5, y: 7.5, width: 9.5, height: 9.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 23, y: 9, width: 7, height: 7)).fill()
        }
        composed.unlockFocus()
        composed.isTemplate = true
        composed.accessibilityDescription = "OpenTraffic"
        statusIcons[key] = composed
        return composed
    }

    private static func loadSVG(named name: String, isTemplate: Bool) -> NSImage {
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else {
            let fallback = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "OpenTraffic") ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "OpenTraffic"
        return image
    }
}

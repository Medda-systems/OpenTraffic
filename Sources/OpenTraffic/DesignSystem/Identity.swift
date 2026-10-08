import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import OpenTrafficCore

/// A tunnel's identity: its site's favicon (or a fallback symbol) with an optional status badge.
struct TunnelIcon: View {
    let originURL: String?
    var state: TunnelDisplayState?
    var fallbackSymbol = "globe"
    var size: CGFloat = 28

    @State private var favicon: NSImage?
    @Environment(\.animationsActive) private var animationsActive

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.16)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let state {
                Image(systemName: state.symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, state.tint)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                    .offset(x: size * 0.14, y: size * 0.14)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: animationsActive && (state == .starting || state == .stopping))
                    .animation(.snappy, value: state)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state?.label ?? "Site icon")
        .task(id: originURL) {
            guard let originURL else { favicon = nil; return }
            favicon = FaviconService.shared.cachedIcon(for: originURL)
            if favicon == nil { favicon = await FaviconService.shared.icon(for: originURL) }
        }
    }
}

// MARK: - Provider logos

/// A provider's mark at a given height. Cloudflare shows in its brand orange; ngrok and
/// Tailscale use monochrome marks that follow the text color, as their own brands do.
struct ProviderLogo: View {
    let provider: TunnelProvider
    var height: CGFloat = 14
    var tint: Color?

    /// Every provider gets the same slot, 1.6 times as wide as `height`, with its mark at an even
    /// visual weight inside (see `LogoFitting.Style.inline`).
    var body: some View {
        Image(nsImage: BrandAssets.logo(provider, style: .inline))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: height * 1.6, height: height)
            .foregroundStyle(tint ?? defaultTint)
            .accessibilityLabel(provider.title)
    }

    private var defaultTint: Color {
        provider == .cloudflare ? Brand.cloudflare : .primary
    }

}

extension TunnelProvider {
    /// The SF Symbol shown when the provider has no bundled mark (OpenTunnel) or outside the app bundle.
    var fallbackSymbol: String {
        switch self {
        case .cloudflare: "cloud.fill"
        case .ngrok: "arrow.left.arrow.right.circle"
        case .tailscale: "lock.shield"
        case .opentunnel: "network"
        }
    }
}

extension NewTunnelKind {
    var provider: TunnelProvider {
        switch self {
        case .quick, .customDomain, .importExisting: .cloudflare
        case .tailscale: .tailscale
        case .ngrok: .ngrok
        case .opentunnel: .opentunnel
        }
    }
}

// MARK: - QR codes

enum QRCode {
    /// A crisp QR code for the text, or nil if Core Image can't encode it.
    static func image(for text: String, pointSize: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (pointSize * 2) / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(representation)
        return image
    }
}

/// Shows a scannable QR code for a URL, for opening the tunnel on a phone.
struct QRCodeButton: View {
    let url: String?
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Show QR Code", systemImage: "qrcode")
                .foregroundStyle(.primary)
        }
        .labelStyle(.iconOnly)
        .tint(.primary)
        .disabled(url == nil)
        .help("Show a QR code to open this URL on your phone")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            if let url {
                QRCodePanel(url: url)
            }
        }
    }
}

private struct QRCodePanel: View {
    let url: String

    var body: some View {
        VStack(spacing: Spacing.m) {
            if let image = QRCode.image(for: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(Spacing.m)
                    .background(.white, in: RoundedRectangle(cornerRadius: Radius.medium))
                    .accessibilityLabel("QR code for \(url)")
            }
            Text("Scan to open on your phone")
                .font(.headline)
            Text(url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.l)
        .frame(width: 280)
    }
}

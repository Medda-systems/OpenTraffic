import SwiftUI
import OpenTrafficCore

struct SitePreviewView: View {
    let identity: String
    let originURL: String?
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 128, height: 80)
            } else {
                Image(systemName: supportedOriginURL == nil ? "rectangle.slash" : "safari")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
            }
            if errorMessage != nil, !isLoading {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                            .help(errorMessage ?? "Preview unavailable")
                        Spacer()
                    }
                }
                .padding(4)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityLabel("Refresh preview")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading || supportedOriginURL == nil)
                    .help(errorMessage ?? "Refresh site preview")
                    .padding(4)
                }
                Spacer()
            }
        }
        .frame(width: 128, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)))
        .task(id: cacheIdentity) {
            let requestIdentity = cacheIdentity
            image = await SitePreviewService.shared.cachedImage(identity: requestIdentity, variant: preferredVariant)
            if image == nil, supportedOriginURL != nil { await refresh() }
        }
        .accessibilityLabel(errorMessage ?? "Site preview")
    }

    private func refresh() async {
        guard let originURL = supportedOriginURL else {
            errorMessage = SitePreviewError.unsupportedOrigin.localizedDescription
            return
        }
        let requestIdentity = cacheIdentity
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let refreshed = try await SitePreviewService.shared.refresh(identity: requestIdentity, originURL: originURL)
            guard requestIdentity == cacheIdentity, !Task.isCancelled else { return }
            image = refreshed
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var supportedOriginURL: String? {
        guard let originURL,
              let url = URL(string: originURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return originURL
    }

    private var preferredVariant: SitePreviewVariant {
        .bestFit(pointSize: CGSize(width: 128, height: 80), displayScale: displayScale)
    }

    private var cacheIdentity: String {
        guard let originURL = supportedOriginURL else { return identity + "|unsupported" }
        return SitePreviewService.cacheIdentity(identity: identity, originURL: originURL)
    }
}

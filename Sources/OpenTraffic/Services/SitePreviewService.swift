import AppKit
import OpenTrafficCore
import WebKit

enum SitePreviewError: LocalizedError {
    case unsupportedOrigin
    case timedOut
    case navigationFailed(String)
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOrigin: "Preview requires an HTTP or HTTPS local origin."
        case .timedOut: "The site did not become ready before the preview timeout."
        case .navigationFailed(let message): "Preview unavailable: \(message)"
        case .snapshotFailed: "The page loaded, but macOS could not capture its preview."
        }
    }
}

@MainActor
final class SitePreviewService {
    static let shared = SitePreviewService()

    private let cache: SitePreviewCache
    private var captureActive = false
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    init(cache: SitePreviewCache = SitePreviewCache()) {
        self.cache = cache
    }

    func cachedImage(identity: String, variant: SitePreviewVariant) async -> NSImage? {
        guard let data = await cache.data(identity: identity, variant: variant) else { return nil }
        return NSImage(data: data)
    }

    func refresh(identity: String, originURL: String) async throws -> NSImage {
        guard let url = validatedOrigin(originURL) else { throw SitePreviewError.unsupportedOrigin }
        await acquireCaptureSlot()
        defer { releaseCaptureSlot() }
        try Task.checkCancellation()

        let sourcePNG = try await capture(url: url)

        let rendered = await Task.detached(priority: .utility) { () -> [SitePreviewVariant: Data] in
            var output: [SitePreviewVariant: Data] = [:]
            for variant in SitePreviewVariant.allCases {
                if let data = SitePreviewImageProcessor.pngData(from: sourcePNG, pixelSize: variant.pixelSize) {
                    output[variant] = data
                }
            }
            return output
        }.value
        guard let medium = rendered[.medium], let image = NSImage(data: medium) else {
            throw SitePreviewError.snapshotFailed
        }
        for (variant, data) in rendered {
            try await cache.store(data, identity: identity, variant: variant)
        }
        return image
    }

    func remove(identity: String) {
        Task { await cache.remove(identity: identity) }
    }

    nonisolated static func cacheIdentity(identity: String, originURL: String) -> String {
        let normalized = URL(string: originURL)?.standardized.absoluteString ?? originURL
        return "\(identity)|\(normalized)"
    }

    private func validatedOrigin(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    private func acquireCaptureSlot() async {
        guard captureActive else {
            captureActive = true
            return
        }
        await withCheckedContinuation { captureWaiters.append($0) }
    }

    private func releaseCaptureSlot() {
        if captureWaiters.isEmpty { captureActive = false }
        else { captureWaiters.removeFirst().resume() }
    }

    private func capture(url: URL) async throws -> Data {
        let coordinator = PreviewCaptureCoordinator(url: url)
        return try await withTaskCancellationHandler {
            try await coordinator.run()
        } onCancel: {
            Task { @MainActor in coordinator.cancel() }
        }
    }
}

@MainActor
private final class PreviewCaptureCoordinator: NSObject, WKNavigationDelegate {
    private let originHost: String
    private let initialRequest: URLRequest
    private let webView: WKWebView
    private let window: NSWindow
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(url: URL) {
        originHost = url.host?.lowercased() ?? ""
        initialRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1_440, height: 900),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
    }

    func run() async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(SitePreviewError.timedOut))
            }
            webView.load(initialRequest)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, self.continuation != nil else { return }
            _ = try? await webView.evaluateJavaScript("document.fonts ? document.fonts.ready : Promise.resolve()")
            guard self.continuation != nil else { return }
            self.takeSnapshot()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SitePreviewError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SitePreviewError.navigationFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == originHost else {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame == true {
                finish(.failure(SitePreviewError.navigationFailed("The page redirected outside its local origin.")))
            }
            return
        }
        guard navigationAction.targetFrame != nil else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            decisionHandler(.cancel)
            finish(.failure(SitePreviewError.navigationFailed("The origin returned HTTP \(response.statusCode).")))
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func takeSnapshot() {
        guard continuation != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 1_440
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            if let image,
               let tiff = image.tiffRepresentation,
               let representation = NSBitmapImageRep(data: tiff),
               let png = representation.representation(using: .png, properties: [:]) {
                self?.finish(.success(png))
            } else {
                self?.finish(.failure(error ?? SitePreviewError.snapshotFailed))
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.close()
        continuation.resume(with: result)
    }
}

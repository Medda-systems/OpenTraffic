import AppKit
import OpenTrafficCore

/// Fetches and caches favicons for local origins so each tunnel is recognizable at a glance.
/// Icons are only loaded from the origin's own host (or inline data: URLs), with small size caps.
@MainActor
final class FaviconService {
    static let shared = FaviconService()

    private var images: [String: NSImage] = [:]
    private var failures: [String: Date] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private static let retryAfterFailure: TimeInterval = 60
    private nonisolated static let maximumDocumentBytes = 256 * 1024
    private nonisolated static let maximumIconBytes = 512 * 1024

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func cachedIcon(for origin: String) -> NSImage? {
        images[Self.key(origin)]
    }

    func icon(for origin: String) async -> NSImage? {
        let key = Self.key(origin)
        if let image = images[key] { return image }
        if let failedAt = failures[key], Date().timeIntervalSince(failedAt) < Self.retryAfterFailure { return nil }
        if let task = inFlight[key] { return await task.value }
        guard let base = URL(string: key), ["http", "https"].contains(base.scheme ?? "") else { return nil }

        let session = session
        let task = Task<NSImage?, Never> {
            await Self.fetch(base: base, session: session)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            images[key] = image
            failures[key] = nil
        } else {
            failures[key] = Date()
        }
        return image
    }

    private nonisolated static func fetch(base: URL, session: URLSession) async -> NSImage? {
        var iconURL = FaviconLocator.iconURL(html: "", baseURL: base)
        if let (data, _) = await download(base, limit: maximumDocumentBytes, session: session) {
            iconURL = FaviconLocator.iconURL(html: String(decoding: data, as: UTF8.self), baseURL: base)
        }
        if iconURL.scheme == "data" {
            guard let data = try? Data(contentsOf: iconURL), data.count <= maximumIconBytes else { return nil }
            return validImage(data)
        }
        // Never follow an icon to another host; local pages shouldn't make OpenTraffic call the internet.
        guard iconURL.host?.lowercased() == base.host?.lowercased(),
              let (data, response) = await download(iconURL, limit: maximumIconBytes, session: session),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        return validImage(data)
    }

    /// Reads at most `limit` bytes (stopping early rather than buffering a huge response) and
    /// follows redirects only within the same host.
    private nonisolated static func download(_ url: URL, limit: Int, session: URLSession) async -> (Data, URLResponse)? {
        guard let (bytes, response) = try? await session.bytes(from: url, delegate: SameHostRedirects()) else { return nil }
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return (data, response)
    }

    private nonisolated static func validImage(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width >= 8, image.size.height >= 8 else { return nil }
        return image
    }

    /// Icons belong to an origin (scheme, host, port), not to a path.
    private static func key(_ origin: String) -> String {
        guard var components = URLComponents(string: origin) else { return origin }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        if components.host == "127.0.0.1" || components.host == "::1" { components.host = "localhost" }
        return components.string ?? origin
    }
}

/// Refuses redirects that leave the original host, so a local page can't point OpenTraffic elsewhere.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let origin = task.originalRequest?.url?.host?.lowercased()
        return request.url?.host?.lowercased() == origin ? request : nil
    }
}

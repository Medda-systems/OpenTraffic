import Foundation
import OpenTrafficCore

enum TunnelRowPresentation {
    static func compact(
        localURL: String?,
        statistics: TunnelStatistics?,
        fallbackStartedAt: Date? = nil,
        now: Date = Date()
    ) -> String {
        let endpoint = localEndpoint(localURL) ?? "origin —"
        let startedAt = statistics?.processStartedAt ?? fallbackStartedAt
        let uptime = startedAt.map { formatDuration(max(0, now.timeIntervalSince($0))) } ?? "—"
        let requests = statistics?.totalRequests.map { "\($0) req" } ?? "— req"
        return "\(endpoint) · \(uptime) · \(requests)"
    }

    static func localEndpoint(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), let host = url.host else { return nil }
        if let port = url.port {
            let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
            return loopback ? ":\(port)" : "\(host):\(port)"
        }
        return host
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds) / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if totalMinutes > 0 { return "\(totalMinutes)m" }
        return "<1m"
    }

    static func byteCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

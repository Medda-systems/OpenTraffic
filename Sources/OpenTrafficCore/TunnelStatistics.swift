import Foundation

public struct TunnelStatistics: Equatable, Sendable {
    public var totalRequests: Int64?
    public var requestErrors: Int64?
    public var responseByCode: [String: Int64]
    public var sentBytes: Int64?
    public var receivedBytes: Int64?
    public var processStartedAt: Date?

    public init(
        totalRequests: Int64? = nil,
        requestErrors: Int64? = nil,
        responseByCode: [String: Int64] = [:],
        sentBytes: Int64? = nil,
        receivedBytes: Int64? = nil,
        processStartedAt: Date? = nil
    ) {
        self.totalRequests = totalRequests
        self.requestErrors = requestErrors
        self.responseByCode = responseByCode
        self.sentBytes = sentBytes
        self.receivedBytes = receivedBytes
        self.processStartedAt = processStartedAt
    }

    public var transportBytes: Int64? {
        guard let sentBytes, let receivedBytes else { return nil }
        let (total, overflow) = sentBytes.addingReportingOverflow(receivedBytes)
        return overflow ? nil : total
    }
}

public enum TunnelStatisticsParser {
    public static func parse(_ text: String) -> TunnelStatistics {
        var statistics = TunnelStatistics()
        var sentSamples: [String: Double] = [:]
        var receivedSamples: [String: Double] = [:]

        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let value = Double(parts[1]), value.isFinite, value >= 0 else { continue }
            let sample = String(parts[0])
            let name = sample.prefix { $0 != "{" }
            let labels = parseLabels(in: sample)

            switch name {
            case "cloudflared_tunnel_total_requests":
                statistics.totalRequests = integer(value)
            case "cloudflared_tunnel_request_errors":
                statistics.requestErrors = integer(value)
            case "cloudflared_tunnel_response_by_code":
                if let code = labels["status_code"], let count = integer(value) {
                    statistics.responseByCode[code] = count
                }
            case "process_start_time_seconds":
                statistics.processStartedAt = Date(timeIntervalSince1970: value)
            case "quic_client_sent_bytes":
                sentSamples[sampleIdentity(name: String(name), labels: labels)] = value
            case "quic_client_receive_bytes":
                receivedSamples[sampleIdentity(name: String(name), labels: labels)] = value
            default:
                break
            }
        }
        statistics.sentBytes = sum(samples: sentSamples)
        statistics.receivedBytes = sum(samples: receivedSamples)
        return statistics
    }

    private static func integer(_ value: Double) -> Int64? {
        guard value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int64(value.rounded(.towardZero))
    }

    private static func sum(samples: [String: Double]) -> Int64? {
        guard !samples.isEmpty else { return nil }
        var total = 0.0
        for value in samples.values {
            total += value
            guard total.isFinite else { return nil }
        }
        return integer(total)
    }

    private static func sampleIdentity(name: String, labels: [String: String]) -> String {
        let stableLabels = labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(name){\(stableLabels)}"
    }

    private static func parseLabels(in sample: String) -> [String: String] {
        guard let open = sample.firstIndex(of: "{"), let close = sample.lastIndex(of: "}"), open < close else { return [:] }
        let contents = sample[sample.index(after: open)..<close]
        var labels: [String: String] = [:]
        for item in contents.split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            labels[String(pair[0])] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return labels
    }
}

public enum TunnelMetricsFetcher {
    public static func fetch(host: String = "127.0.0.1", port: UInt16) async -> TunnelStatistics? {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(urlHost):\(port)/metrics") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.75
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.75
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration, delegate: MetricsNoRedirectDelegate.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 2 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return TunnelStatisticsParser.parse(text)
    }
}

private final class MetricsNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = MetricsNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

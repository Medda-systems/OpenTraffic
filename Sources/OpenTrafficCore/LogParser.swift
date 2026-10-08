import Foundation

public struct CloudflaredLogParser: Sendable {
    public static let maximumPendingBytes = 256 * 1024
    private var pending = Data()
    private let secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    public mutating func append(_ data: Data, stream: String) -> [TunnelLogEntry] {
        pending.append(data)
        var entries: [TunnelLogEntry] = []

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if let text = String(data: line, encoding: .utf8)?.nilIfBlank {
                if line.count > Self.maximumPendingBytes {
                    let truncated = String(decoding: line.prefix(Self.maximumPendingBytes), as: UTF8.self)
                    entries.append(TunnelLogEntry(
                        level: "warning",
                        message: SecretRedactor.redact(truncated, secrets: secrets) + " … <line truncated>",
                        stream: stream
                    ))
                } else {
                    entries.append(Self.parseLine(text, stream: stream, secrets: secrets))
                }
            }
        }
        if pending.count > Self.maximumPendingBytes {
            let truncated = String(decoding: pending.prefix(Self.maximumPendingBytes), as: UTF8.self)
            pending.removeAll(keepingCapacity: true)
            entries.append(TunnelLogEntry(
                level: "warning",
                message: SecretRedactor.redact(truncated, secrets: secrets) + " … <line truncated>",
                stream: stream
            ))
        }
        return entries
    }

    public mutating func finish(stream: String) -> [TunnelLogEntry] {
        defer { pending.removeAll(keepingCapacity: false) }
        guard let text = String(data: pending, encoding: .utf8)?.nilIfBlank else { return [] }
        return [Self.parseLine(text, stream: stream, secrets: secrets)]
    }

    public static func parseLine(_ raw: String, stream: String, secrets: [String] = []) -> TunnelLogEntry {
        let scrubbed = SecretRedactor.redact(raw, secrets: secrets)
        guard
            let data = scrubbed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TunnelLogEntry(level: "info", message: scrubbed, stream: stream)
        }

        let message = (object["message"] as? String)
            ?? (object["msg"] as? String)
            ?? scrubbed
        // cloudflared uses level/time; ngrok uses lvl/t with four-letter levels.
        let level = normalizedLevel((object["level"] as? String) ?? (object["lvl"] as? String) ?? "info")
        let timestamp = parseDate(object["time"] as? String)
            ?? parseDate(object["timestamp"] as? String)
            ?? parseDate(object["t"] as? String)
            ?? Date()
        return TunnelLogEntry(
            timestamp: timestamp,
            level: level,
            message: SecretRedactor.redact(message, secrets: secrets),
            stream: stream,
            rawLine: scrubbed
        )
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        // ngrok writes offsets without a colon: 2026-10-03T22:57:40+0200
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: string)
    }

    static func normalizedLevel(_ level: String) -> String {
        switch level.lowercased() {
        case "eror", "err", "crit", "fatal": "error"
        case "dbug": "debug"
        default: level.lowercased()
        }
    }
}

public enum SecretRedactor {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "(?i)(authorization[\\\"' ]*[:=][\\\"' ]*(?:bearer\\s+)?)[^\\\"'\\s,}]+"),
        try! NSRegularExpression(pattern: "(?i)(tunnel[_-]?token[\\\"' ]*[:=][\\\"' ]*)[^\\\"'\\s,}]+"),
        try! NSRegularExpression(pattern: "(?i)(--token(?:=|\\s+))[^\\s]+"),
        try! NSRegularExpression(pattern: "(?i)(x-auth-key[\\\"' ]*[:=][\\\"' ]*)[^\\\"'\\s,}]+"),
        try! NSRegularExpression(pattern: "(?i)([\\\"']?token[\\\"']?\\s*[:=]\\s*)[^\\s,}\\]]+"),
        try! NSRegularExpression(pattern: "(?i)(token:)[^\\s\\]]+"),
    ]

    public static func redact(_ input: String, secrets: [String] = []) -> String {
        let scrubbedKnownValues = secrets.reduce(input) { value, secret in
            value.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return patterns.reduce(scrubbedKnownValues) { value, regex in
            let range = NSRange(value.startIndex..., in: value)
            return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1<redacted>")
        }
    }
}

public struct BoundedLogBuffer: Sendable {
    public let capacity: Int
    private(set) public var entries: [TunnelLogEntry] = []
    /// Error-level lines currently in the buffer, kept up to date as lines come and go.
    private(set) public var errorCount = 0

    public init(capacity: Int = 2_000) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(contentsOf newEntries: [TunnelLogEntry]) {
        entries.append(contentsOf: newEntries)
        errorCount += newEntries.count { $0.isError }
        if entries.count > capacity {
            let overflow = entries.count - capacity
            errorCount -= entries.prefix(overflow).count { $0.isError }
            entries.removeFirst(overflow)
        }
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        errorCount = 0
    }
}

extension TunnelLogEntry {
    public var isError: Bool {
        ["error", "fatal", "panic"].contains(level.lowercased())
    }
}

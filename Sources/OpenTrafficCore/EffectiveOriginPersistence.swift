import Foundation

public struct PersistedEffectiveOrigin: Codable, Equatable, Sendable {
    public let tunnelID: UUID
    public let url: String
    public let verifiedAt: Date

    public init(tunnelID: UUID, url: String, verifiedAt: Date) {
        self.tunnelID = tunnelID
        self.url = url
        self.verifiedAt = verifiedAt
    }
}

public struct EffectiveOriginPersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appending(path: "OpenTraffic", directoryHint: .isDirectory)
                .appending(path: "effective-origins.json")
        }
    }

    public func load() throws -> [PersistedEffectiveOrigin] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([PersistedEffectiveOrigin].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ values: [PersistedEffectiveOrigin]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
    }
}

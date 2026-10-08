import Foundation

public struct TunnelPersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appending(path: "OpenTraffic", directoryHint: .isDirectory)
                .appending(path: "tunnels.json")
        }
    }

    public func load() throws -> [TunnelDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([TunnelDefinition].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ definitions: [TunnelDefinition]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definitions).write(to: fileURL, options: .atomic)
    }
}

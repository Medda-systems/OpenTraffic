import Foundation

public struct DiscoveryPreference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public var alias: String?
    public var isHidden: Bool
    public var origin: String?
    public var executablePath: String

    public init(key: String, alias: String? = nil, isHidden: Bool = false, origin: String?, executablePath: String) {
        self.key = key
        self.alias = alias
        self.isHidden = isHidden
        self.origin = origin
        self.executablePath = executablePath
    }
}

public struct DiscoveryPreferencesState: Codable, Equatable, Sendable {
    public var entries: [DiscoveryPreference]

    public init(entries: [DiscoveryPreference] = []) {
        self.entries = entries
    }
}

public struct DiscoveryPreferencesPersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appending(path: "OpenTraffic", directoryHint: .isDirectory)
                .appending(path: "discovery-preferences.json")
        }
    }

    public func load() throws -> DiscoveryPreferencesState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return DiscoveryPreferencesState() }
        return try JSONDecoder().decode(DiscoveryPreferencesState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: DiscoveryPreferencesState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

public extension DiscoveredQuickTunnel {
    var preferenceKey: String {
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent
        let origin = localURL.flatMap(URL.init(string:))?.standardized.absoluteString ?? localURL ?? publicURL
        return "\(executable)|\(origin)"
    }
}

import Foundation

public final class CredentialProtectionRegistry: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appending(path: "OpenTraffic", directoryHint: .isDirectory)
                .appending(path: "credential-protection.json")
        }
    }

    public func isProtected(key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try load().contains(key)
    }

    public func setProtected(_ protected: Bool, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var keys = try load()
        if protected { keys.insert(key) }
        else { keys.remove(key) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(keys.sorted())
        try data.write(to: fileURL, options: .atomic)
    }

    private func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: fileURL)))
    }
}

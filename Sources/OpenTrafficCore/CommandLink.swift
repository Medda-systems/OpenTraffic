import Foundation

/// Keeps a command linked into a bin folder, as a symlink to a file inside an app bundle, so it follows
/// app updates. Only links to an app bundle's `Contents/Resources/<name>` count as its own: those it
/// replaces and removes; anything else at that name is left alone.
public struct CommandLink: Sendable {
    public let name: String
    public let target: String
    /// Where to link, in order of preference.
    public let directories: [String]

    public init(name: String, target: String, directories: [String]) {
        self.name = name
        self.target = target
        self.directories = directories
    }

    public enum Outcome: Equatable, Sendable {
        case installed(String)
        /// A file of that name that isn't one of these links is in the way.
        case blocked(String)
        case failed(String)
    }

    private var links: [String] { directories.map { "\($0)/\(name)" } }

    /// Where the command points at `target`.
    public var installedPath: String? {
        links.first { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) == target }
    }

    /// A link this made: to the command inside some app bundle (this one or an older copy).
    public func isOurs(_ link: String) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return false }
        return destination.hasSuffix(".app/Contents/Resources/\(name)")
    }

    /// Points an existing link of ours at `target`, or makes one in the first folder that can take it.
    @discardableResult
    public func install(creating creatable: Set<String> = []) -> Outcome {
        if let installedPath { return .installed(installedPath) }
        let fileManager = FileManager.default
        for link in links where isOurs(link) {
            if (try? fileManager.removeItem(atPath: link)) != nil,
               (try? fileManager.createSymbolicLink(atPath: link, withDestinationPath: target)) != nil {
                return .installed(link)
            }
        }
        var blocked: String?
        for directory in directories {
            if creatable.contains(directory) {
                try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            guard fileManager.isWritableFile(atPath: directory) else { continue }
            let link = "\(directory)/\(name)"
            // `attributesOfItem` doesn't follow links, so a broken link counts as there too.
            if (try? fileManager.attributesOfItem(atPath: link)) != nil {
                blocked = blocked ?? link
                continue
            }
            if (try? fileManager.createSymbolicLink(atPath: link, withDestinationPath: target)) != nil {
                return .installed(link)
            }
        }
        if let blocked { return .blocked("\(blocked) already exists and isn't OpenTraffic's, so it was left alone.") }
        return .failed("None of \(directories.joined(separator: ", ")) can take it.")
    }

    /// Removes the links this made.
    public func uninstall() {
        for link in links where isOurs(link) {
            try? FileManager.default.removeItem(atPath: link)
        }
    }
}

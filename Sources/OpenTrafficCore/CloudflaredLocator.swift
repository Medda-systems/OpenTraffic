import Foundation

/// Finds the command-line tool for a provider: a user-chosen path first, then the usual install locations.
public enum ExecutableLocator {
    public static func commonPaths(for provider: TunnelProvider) -> [String] {
        let name = provider.executableName
        var paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "~/.local/bin/\(name)"]
        if provider == .tailscale {
            // The Mac App Store and standalone Tailscale apps ship the CLI inside the bundle.
            paths.append("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        }
        return paths
    }

    public static func resolve(
        _ provider: TunnelProvider,
        customPath: String? = nil,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = [customPath?.nilIfBlank].compactMap { $0 } + commonPaths(for: provider)
        return candidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first(where: isExecutable)
            .map(URL.init(fileURLWithPath:))
    }
}

public enum CloudflaredLocator {
    public static var commonPaths: [String] { ExecutableLocator.commonPaths(for: .cloudflare) }

    public static func resolve(customPath: String?) -> URL? {
        ExecutableLocator.resolve(.cloudflare, customPath: customPath)
    }
}

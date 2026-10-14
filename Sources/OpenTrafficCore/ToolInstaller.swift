import CryptoKit
import Foundation
import Security

/// The command-line tools OpenTraffic can install by itself, from each maker's official release, into
/// its own folder. Nothing else on the Mac changes: no Homebrew, no administrator password, no PATH.
public enum ManagedTools {
    /// `~/Library/Application Support/OpenTraffic/Tools`.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenTraffic/Tools", directoryHint: .isDirectory)
    }

    public static func path(for provider: TunnelProvider) -> URL {
        directory.appending(path: provider.executableName)
    }

    /// All four. Tailscale is the exception in where it goes: it's a Mac app with a system extension, so
    /// its official installer package puts it in /Applications, after asking for the Mac's password.
    public static func canInstall(_ provider: TunnelProvider) -> Bool {
        true
    }

    /// The Tailscale app, where its installer puts it.
    public static let tailscaleApp = URL(fileURLWithPath: "/Applications/Tailscale.app")

    /// Set by tests and screenshots to pretend nothing is installed elsewhere on the Mac.
    public static var onlyManaged: Bool {
        ProcessInfo.processInfo.environment["OPENTRAFFIC_MANAGED_TOOLS_ONLY"] == "1"
    }

    private static var manifestURL: URL { directory.appending(path: "tools.json") }

    /// The version OpenTraffic installed for `provider`, if it installed one.
    public static func installedVersion(of provider: TunnelProvider) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path(for: provider).path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return manifest[provider.rawValue]
    }

    static func record(version: String, for provider: TunnelProvider) {
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        manifest[provider.rawValue] = version
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
    }
}

/// One downloadable build of a tool, as its maker publishes it.
public struct ToolRelease: Sendable, Equatable {
    public enum Archive: Sendable, Equatable { case tarGzip, zip, package }

    public let provider: TunnelProvider
    /// nil when the source doesn't say (ngrok); the installed tool reports it afterwards.
    public let version: String?
    public let url: URL
    public let size: Int64?
    /// Hex SHA-256 of the download, when the maker publishes one.
    public let sha256: String?
    public let archive: Archive
    /// Who publishes it, and the Developer ID team that must have signed the tool (nil: not signed with one).
    public let publisher: String
    public let teamID: String?

    /// "github.com", "ngrok.com", or "pkgs.tailscale.com", for saying where it comes from.
    public var host: String {
        provider == .ngrok ? "ngrok.com" : (url.host ?? "")
    }

    /// Installing it asks for the Mac's password (an installer package).
    public var needsPassword: Bool { archive == .package }
}

public enum ToolInstallError: LocalizedError, Equatable {
    case notInstallable
    case noBuild
    case download(String)
    case checksumMismatch
    case signature(String)
    case doesNotRun(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstallable: "OpenTraffic can't install this one for you."
        case .noBuild: "There's no build for this Mac in the latest release."
        case let .download(message): "The download didn't finish: \(message)"
        case .checksumMismatch: "The download doesn't match the checksum its maker published, so it wasn't installed."
        case let .signature(publisher): "The download isn't signed by \(publisher), so it wasn't installed."
        case let .doesNotRun(message): "The tool was downloaded but doesn't run on this Mac: \(message)"
        case .cancelled: "Installing was cancelled."
        }
    }
}

public enum ToolCatalog {
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The newest official build of `provider` for this Mac.
    public static func latestRelease(for provider: TunnelProvider, session: URLSession = .shared) async throws -> ToolRelease {
        switch provider {
        case .cloudflare, .opentunnel:
            let repository = provider == .cloudflare ? "cloudflare/cloudflared" : "anomalyco/opentunnel"
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ToolInstallError.download("GitHub answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            return try githubRelease(for: provider, json: data, architecture: architecture)
        case .ngrok:
            let file = architecture == "arm64" ? "arm64" : "amd64"
            let url = URL(string: "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-\(file).zip")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 20
            let size = try? await session.data(for: request).1.expectedContentLength
            return ToolRelease(provider: .ngrok, version: nil, url: url, size: size.flatMap { $0 > 0 ? $0 : nil }, sha256: nil,
                               archive: .zip, publisher: "ngrok, Inc.", teamID: "TEX8MHRDQ9")
        case .tailscale:
            // "latest" redirects to the versioned package, whose SHA-256 sits next to it.
            var request = URLRequest(url: URL(string: "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg")!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 20
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url else {
                throw ToolInstallError.download("Tailscale's download server answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            var checksumRequest = URLRequest(url: url.appendingPathExtension("sha256"))
            checksumRequest.timeoutInterval = 20
            let checksum = try? await session.data(for: checksumRequest).0
            return tailscaleRelease(packageURL: url, size: http.expectedContentLength, checksumFile: checksum)
        }
    }

    static func tailscaleRelease(packageURL url: URL, size: Int64, checksumFile: Data?) -> ToolRelease {
        let digest = checksumFile
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        return ToolRelease(
            provider: .tailscale,
            version: version(in: url.lastPathComponent),
            url: url,
            size: size > 0 ? size : nil,
            sha256: digest,
            archive: .package,
            publisher: "Tailscale Inc.",
            teamID: "W5364U7YZB"
        )
    }

    /// Picks this Mac's build out of a GitHub release (`/releases/latest`).
    static func githubRelease(for provider: TunnelProvider, json: Data, architecture: String) throws -> ToolRelease {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int64
                let digest: String?
                let browser_download_url: URL
            }
            let tag_name: String
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: json)
        let name = switch provider {
        case .cloudflare: "cloudflared-darwin-\(architecture == "arm64" ? "arm64" : "amd64").tgz"
        default: "opentunnel-darwin-\(architecture == "arm64" ? "arm64" : "x64").tar.gz"
        }
        guard let asset = release.assets.first(where: { $0.name == name }) else { throw ToolInstallError.noBuild }
        let digest = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return ToolRelease(
            provider: provider,
            version: version,
            url: asset.browser_download_url,
            size: asset.size,
            sha256: digest,
            archive: .tarGzip,
            publisher: provider == .cloudflare ? "Cloudflare, Inc." : "Anomaly",
            // cloudflared is signed with Cloudflare's Developer ID; OpenTunnel's builds aren't, so they're
            // checked against the checksum GitHub publishes for them instead.
            teamID: provider == .cloudflare ? "68WVV388M8" : nil
        )
    }

    /// The version number in a tool's `--version` output ("cloudflared version 2026.10.0 (built …)").
    public static func version(in output: String) -> String? {
        output.firstMatch(of: /\d+\.\d+(?:\.\d+)?/).map { String($0.output) }
    }
}

/// Downloads, checks, and installs one tool. Each step reports through `progress`.
public enum ToolInstaller {
    public enum Phase: Sendable, Equatable {
        case downloading(received: Int64, total: Int64?)
        case verifying
        case installing
    }

    public struct Installed: Sendable, Equatable {
        public let version: String
        public let path: URL
    }

    /// `installPackage` runs a checked installer package with administrator rights (the app asks for the
    /// Mac's password); only Tailscale needs it.
    public static func install(
        _ release: ToolRelease,
        session: URLSession = .shared,
        installPackage: (@Sendable (URL) async throws -> Void)? = nil,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws -> Installed {
        let provider = release.provider
        let work = FileManager.default.temporaryDirectory.appending(path: "opentraffic-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(.downloading(received: 0, total: release.size))
        // Under its own name: Installer only opens a package whose name ends in .pkg.
        let name = release.url.lastPathComponent.isEmpty ? "download" : release.url.lastPathComponent
        let archive = try await download(release.url, to: work.appending(path: name), expected: release.size, session: session, progress: progress)

        progress(.verifying)
        if let expected = release.sha256, try sha256(of: archive) != expected {
            throw ToolInstallError.checksumMismatch
        }
        if release.archive == .package {
            try verifyPackage(archive, teamID: release.teamID, publisher: release.publisher)
            guard let installPackage else { throw ToolInstallError.notInstallable }
            progress(.installing)
            try await installPackage(archive)
            let binary = ManagedTools.tailscaleApp.appending(path: "Contents/MacOS/Tailscale")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw ToolInstallError.doesNotRun("the installer finished, but Tailscale isn't in Applications.")
            }
            let info = NSDictionary(contentsOf: ManagedTools.tailscaleApp.appending(path: "Contents/Info.plist"))
            return Installed(version: info?["CFBundleShortVersionString"] as? String ?? release.version ?? "", path: binary)
        }
        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        switch release.archive {
        case .tarGzip: try run("/usr/bin/tar", ["-xzf", archive.path, "-C", unpacked.path])
        case .zip: try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        case .package: break // installed above
        }
        guard let binary = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == provider.executableName }) else {
            throw ToolInstallError.download("The archive doesn't contain \(provider.executableName).")
        }
        try verifySignature(of: binary, teamID: release.teamID, publisher: release.publisher)

        progress(.installing)
        try FileManager.default.createDirectory(at: ManagedTools.directory, withIntermediateDirectories: true)
        let destination = ManagedTools.path(for: provider)
        // Next to the destination first, so the swap is a rename and a running copy is never half-written.
        let staged = ManagedTools.directory.appending(path: ".\(provider.executableName)-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: binary, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        removexattr(staged.path, "com.apple.quarantine", 0)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }

        let output = try run(destination.path, provider == .ngrok ? ["version"] : ["--version"], timeout: 15)
        guard let version = ToolCatalog.version(in: output) ?? release.version else {
            throw ToolInstallError.doesNotRun(output.isEmpty ? "it printed nothing." : output)
        }
        ManagedTools.record(version: version, for: provider)
        return Installed(version: version, path: destination)
    }

    // MARK: Steps

    /// Runs one download in its own session, whose delegate reliably hears about every chunk written.
    private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let expected: Int64?
        let report: @Sendable (Phase) -> Void
        private var continuation: CheckedContinuation<URL, Error>?
        private var lastReport = Date.distantPast
        private var moved: URL?
        private var status: Int?

        init(destination: URL, expected: Int64?, report: @escaping @Sendable (Phase) -> Void) {
            self.destination = destination
            self.expected = expected
            self.report = report
        }

        func run(_ request: URLRequest) async throws -> URL {
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            // A few updates a second are plenty for a progress bar.
            guard Date().timeIntervalSince(lastReport) > 0.06 else { return }
            lastReport = Date()
            report(.downloading(received: totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns, so move it now.
            status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            if (try? FileManager.default.moveItem(at: location, to: destination)) != nil { moved = destination }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = self.continuation
            self.continuation = nil
            if let error {
                continuation?.resume(throwing: ToolInstallError.download(error.localizedDescription))
            } else if let status, !(200..<300).contains(status) {
                continuation?.resume(throwing: ToolInstallError.download("the server answered HTTP \(status)."))
            } else if let moved {
                continuation?.resume(returning: moved)
            } else {
                continuation?.resume(throwing: ToolInstallError.download("the file couldn't be saved."))
            }
        }
    }

    private static func download(_ url: URL, to destination: URL, expected: Int64?, session: URLSession,
                                 progress: @escaping @Sendable (Phase) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let file = try await Download(destination: destination, expected: expected, report: progress).run(request)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        progress(.downloading(received: size ?? expected ?? 0, total: size ?? expected))
        return file
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The code must have a valid signature, and with `teamID`, a Developer ID one from that team.
    static func verifySignature(of binary: URL, teamID: String?, publisher: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code else {
            throw ToolInstallError.signature(publisher)
        }
        var requirement: SecRequirement?
        if let teamID {
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw ToolInstallError.signature(publisher)
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw ToolInstallError.signature(publisher)
        }
    }

    /// An installer package must be signed with its maker's Developer ID Installer certificate and
    /// notarized by Apple.
    static func verifyPackage(_ package: URL, teamID: String?, publisher: String) throws {
        let signature = (try? run("/usr/sbin/pkgutil", ["--check-signature", package.path], timeout: 30)) ?? ""
        let assessment = (try? run("/usr/sbin/spctl", ["--assess", "--type", "install", "-v", package.path], timeout: 30)) ?? ""
        guard signature.contains("signed by a developer certificate issued by Apple for distribution"),
              teamID.map({ signature.contains("Developer ID Installer:") && signature.contains("(\($0))") }) ?? false,
              assessment.contains("accepted") else {
            throw ToolInstallError.signature(publisher)
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw ToolInstallError.doesNotRun("\(URL(fileURLWithPath: executable).lastPathComponent) didn't finish.")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ToolInstallError.doesNotRun(output.isEmpty ? "it exited with status \(process.terminationStatus)." : output)
        }
        return output
    }
}

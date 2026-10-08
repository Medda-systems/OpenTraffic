import CryptoKit
import Darwin
import Foundation

/// The local API's bearer token, kept in Application Support/OpenTraffic/api-token (mode 0600).
/// `opentraffic-mcp` reads the same file.
public enum APIToken {
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "OpenTraffic/api-token")
    }

    /// The saved token, or a new one if there is none yet.
    public static func loadOrCreate(at url: URL = defaultURL) throws -> String {
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            // Tighten a file someone loosened; the token is a password.
            if let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, mode & 0o077 != 0 {
                chmod(url.path, 0o600)
            }
            return token
        }
        return try regenerate(at: url)
    }

    /// Replaces the token; clients using the old one get 401 from then on.
    public static func regenerate(at url: URL = defaultURL) throws -> String {
        let token = makeToken()
        try write(token, to: url)
        return token
    }

    /// 32 random bytes, base64url without padding.
    static func makeToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Writes a new file that is 0600 from the start, then moves it into place.
    private static func write(_ token: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array((token + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let writeError = errno
        close(descriptor)
        guard written == bytes.count else {
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: writeError) ?? .EIO)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let renameError = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
        }
    }
}

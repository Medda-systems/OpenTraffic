import Foundation

/// The macOS sandbox (Seatbelt) profile the shared copy of an Electron app's main process runs in.
/// Viewers drive that process through the app's own IPC handlers, so it may only:
///   - read the project, the Electron binary and its session folder (not the rest of the home folder),
///   - write its session folder (a throwaway copy of the app's data), not even the project,
///   - reach the local services OpenTraffic allowed (the internet is fine),
///   - not use the keychain.
public enum ElectronSandbox {
    public struct Policy: Sendable, Equatable {
        public var homeDirectory: String
        /// Folders it may read inside the home folder.
        public var readable: [String]
        /// Its own folder: data, uploads, temporary files.
        public var session: String
        /// Local TCP ports it may connect to.
        public var allowedPorts: [Int]
        /// Unix sockets it may connect to, besides its session's own.
        public var allowedSockets: [String]
        /// Other folders it may not read: the shared temporary folders other apps use.
        public var privateFolders: [String]

        public init(homeDirectory: String, readable: [String], session: String, allowedPorts: [Int], allowedSockets: [String] = [],
                    privateFolders: [String] = [NSTemporaryDirectory(), "/private/tmp"]) {
            self.privateFolders = privateFolders
            self.homeDirectory = homeDirectory
            self.readable = readable
            self.session = session
            self.allowedPorts = allowedPorts
            self.allowedSockets = allowedSockets
        }
    }

    /// The user's real home folder, from the user database: NSHomeDirectory() follows
    /// CFFIXED_USER_HOME and the like, which must not move what the sandbox protects.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if !path.isEmpty { return path }
        }
        return NSHomeDirectory()
    }

    /// A string as a profile's literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A path as Seatbelt matches it: resolved (/private/var, not /var). resolvingSymlinksInPath drops
    /// /private, so realpath; paths that don't exist yet stay as given.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The folders above `paths`, which may be looked at (not listed or read): resolving a path needs it.
    static func parents(of paths: [String]) -> [String] {
        var parents = Set<String>()
        for path in paths {
            var parent = URL(fileURLWithPath: real(path)).deletingLastPathComponent()
            while parent.path != "/", !parent.path.isEmpty {
                parents.insert(parent.path)
                parent.deleteLastPathComponent()
            }
        }
        return parents.sorted()
    }

    public static func profile(_ policy: Policy) -> String {
        let session = real(policy.session)
        var lines = [
            "(version 1)",
            "(allow default)",
            "",
            "; Files: nothing in anyone's home folder or on other volumes but the project and the",
            "; Electron binary.",
            "(deny file-read* (subpath \"/Users\") (subpath \"/Volumes\") (subpath \(quoted(real(policy.homeDirectory)))))",
        ]
        let privateFolders = policy.privateFolders.map(real).filter { $0 != "/" && !$0.isEmpty }
        if !privateFolders.isEmpty {
            lines.append("(deny file-read* " + privateFolders.map { "(subpath \(quoted($0)))" }.joined(separator: " ") + ")")
        }
        // Their parent folders can be looked at (not listed or read): resolving paths needs it.
        for parent in parents(of: policy.readable + [policy.session]) { lines.append("(allow file-read-metadata (literal \(quoted(parent))))") }
        for folder in policy.readable { lines.append("(allow file-read* (subpath \(quoted(real(folder)))))") }
        lines += [
            "(allow file-read* (subpath \(quoted(session))))",
            "",
            "; Writes: only its own session folder.",
            "(deny file-write* (subpath \"/\"))",
            "(allow file-write* (subpath \(quoted(session))))",
            "(allow file-write* (subpath \"/dev\"))",
            "",
            "; No keychain.",
            "(deny mach-lookup (global-name \"com.apple.securityd\") (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.security.agent\") (global-name \"com.apple.secd\"))",
            "",
            "; Local services: only the allowed ones. The internet is fine. (Unix sockets first: a",
            "; later unix-socket rule would also cover TCP to localhost.)",
            "(deny network-outbound (remote unix-socket))",
            "(allow network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))",
            "(allow network-outbound (remote unix-socket (subpath \(quoted(session)))))",
        ]
        for socket in policy.allowedSockets {
            lines.append("(allow network-outbound (remote unix-socket (path-literal \(quoted(real(socket))))))")
        }
        lines.append("(deny network-outbound (remote ip \"localhost:*\"))")
        for port in Set(policy.allowedPorts).sorted() where (1...65_535).contains(port) {
            lines.append("(allow network-outbound (remote ip \"localhost:\(port)\"))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

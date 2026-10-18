import CryptoKit
import Foundation

/// The Electron a finished app's sandboxed copy runs on. Usually the app's own, in Node mode; apps
/// that turned Node mode off (the RunAsNode fuse, as Forge's template does) get a stock copy of
/// the very same Electron version from Electron's GitHub releases, checked against its published
/// SHA-256 sums and kept in OpenTraffic's tools folder.
public enum ElectronRuntime {
    /// Electron's fuse wire: this sentinel, a version byte, a length byte, then one byte per fuse
    /// ("1" on, "0" off, "r" removed). RunAsNode is the first.
    static let fuseSentinel = Data("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".utf8)

    public static func frameworkBinary(of bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Electron Framework")
    }

    /// The fuses, as their bytes, or nil when the wire can't be found.
    public static func fuses(inFramework binary: URL) -> [UInt8]? {
        guard let data = try? Data(contentsOf: binary.resolvingSymlinksInPath(), options: .alwaysMapped),
              let range = data.range(of: fuseSentinel) else { return nil }
        let start = range.upperBound
        guard data.count > start + 2 else { return nil }
        let length = Int(data[start + 1])
        guard data.count >= start + 2 + length else { return nil }
        return Array(data[(start + 2)..<(start + 2 + length)])
    }

    /// Whether ELECTRON_RUN_AS_NODE works with this app's own binary.
    public static func runsAsNode(_ bundle: URL) -> Bool {
        guard let fuses = fuses(inFramework: frameworkBinary(of: bundle)), let first = fuses.first else { return true }
        return first != UInt8(ascii: "0") && first != UInt8(ascii: "r")
    }

    /// The Electron version an app is built on.
    public static func version(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Resources/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return info["CFBundleVersion"] as? String
    }

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// Where stock Electrons are kept: next to OpenTraffic's other managed tools.
    public static func toolsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenTraffic/Tools/Electron", isDirectory: true)
    }

    static func stockBinary(version: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(version)-\(architecture)/Electron.app/Contents/MacOS/Electron")
    }

    /// The binary to run `bundle`'s sandboxed copy on: its own, or a stock Electron of the same
    /// version (downloaded the first time, about 100 MB).
    public static func binary(for bundle: URL, executable: URL, directory: URL = toolsDirectory(), session: URLSession = .shared) async throws -> URL {
        if runsAsNode(bundle) { return executable }
        guard let version = version(of: bundle), version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil else {
            throw OpenTrafficError.process("Couldn't tell which Electron \(bundle.lastPathComponent) is built on.")
        }
        let binary = stockBinary(version: version, in: directory)
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        try await download(version: version, into: directory, session: session)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw OpenTrafficError.process("Electron \(version) didn't unpack as expected.")
        }
        return binary
    }

    static func download(version: String, into directory: URL, session: URLSession) async throws {
        let name = "electron-v\(version)-darwin-\(architecture).zip"
        let base = URL(string: "https://github.com/electron/electron/releases/download/v\(version)/")!
        let (sums, sumsResponse) = try await session.data(from: base.appendingPathComponent("SHASUMS256.txt"))
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
                .first(where: { $0.count == 2 && $0[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name })?[0]
        else { throw OpenTrafficError.process("Couldn't find Electron \(version)'s checksums.") }

        let (zip, response) = try await session.download(from: base.appendingPathComponent(name))
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OpenTrafficError.process("Couldn't download Electron \(version).") }
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw OpenTrafficError.process("Electron \(version)'s download didn't match its checksum.") }

        let fm = FileManager.default
        let target = directory.appendingPathComponent("\(version)-\(architecture)")
        let staging = directory.appendingPathComponent(".unpacking-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw OpenTrafficError.process("Couldn't unpack Electron \(version).") }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
    }
}

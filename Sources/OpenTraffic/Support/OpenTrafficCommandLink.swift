import Foundation
import OpenTrafficCore

/// The `opentraffic` command on the PATH: a symlink to the script in the app bundle, so it follows
/// updates. A copy of OpenTraffic in Applications keeps it linked by itself (Settings → General turns
/// that off); a copy anywhere else (the disk image, Downloads, a development build) never links it.
enum OpenTrafficCommandLink {
    static let installsKey = "installsCommandLineTool"
    private static let localBin = NSString(string: "~/.local/bin").expandingTildeInPath

    /// Homebrew's and the traditional bin folder, which are on most shells' PATH, then ~/.local/bin.
    private static var link: CommandLink? {
        Bundle.main.url(forResource: "opentraffic", withExtension: nil).map {
            CommandLink(name: "opentraffic", target: $0.path, directories: ["/opt/homebrew/bin", "/usr/local/bin", localBin])
        }
    }

    /// In an Applications folder, where it stays put.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/")
    }

    /// Settings → General: keep the command linked (on unless turned off).
    static var installsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: installsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: installsKey) }
    }

    static var installedPath: String? { link?.installedPath }

    @discardableResult
    static func install() -> CommandLink.Outcome {
        link?.install(creating: [localBin]) ?? .failed("This copy of OpenTraffic doesn't include the opentraffic command.")
    }

    static func uninstall() {
        link?.uninstall()
    }

    /// At launch: links the command for a copy in Applications, unless that's turned off.
    static func installIfNeeded() {
        guard isInstalledCopy, installsAutomatically, installedPath == nil else { return }
        install()
    }
}

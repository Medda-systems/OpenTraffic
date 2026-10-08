import AppKit

/// OpenTraffic used to be called TunnelBar. Its saved shares, comments, API token, and records of
/// the Tailscale shares it made carry over the first time OpenTraffic runs. Keychain items kept
/// their service names (`com.tunnelbar.app`, `com.tunnelbar.share-password`), so they need nothing.
enum LegacyData {
    /// Earlier bundle IDs, newest first.
    static let bundleIDs = ["se.medda.tunnelbar", "com.tunnelbar.app"]

    /// Copies `Application Support/TunnelBar` to `Application Support/OpenTraffic` when there's no
    /// OpenTraffic folder yet. Copied rather than moved, so an older copy that's still running
    /// keeps working; the old folder can be deleted afterwards.
    static func migrate(fileManager: FileManager = .default) {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacy = support.appending(path: "TunnelBar", directoryHint: .isDirectory)
        let current = support.appending(path: "OpenTraffic", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: current.path) else { return }
        try? fileManager.copyItem(at: legacy, to: current)
        // OpenTraffic removes every Tailscale share on this record at launch. While TunnelBar is
        // still running they're its live shares, so they stay TunnelBar's to remove.
        if isLegacyAppRunning {
            try? fileManager.removeItem(at: current.appending(path: "tailscale-shares.json"))
        }
    }

    private static var isLegacyAppRunning: Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }
}

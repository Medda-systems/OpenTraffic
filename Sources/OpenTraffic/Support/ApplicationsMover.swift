import AppKit

/// Offers to move OpenTraffic into Applications when it's opened from the disk image or Downloads.
/// From there the `opentraffic` command, the MCP bridge path, and launch at login would point at a
/// copy that goes away.
@MainActor
enum ApplicationsMover {
    private static let declinedKey = "declinedMoveToApplications"

    static func offerIfNeeded() {
        let source = Bundle.main.bundleURL
        let path = source.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !path.hasPrefix("/Applications/"), !path.hasPrefix("\(home)/Applications/") else { return }
        // Development builds run from the repository; only offer for downloaded copies.
        guard path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") || path.hasPrefix("\(home)/Downloads/") else { return }
        guard !UserDefaults.standard.bool(forKey: declinedKey) else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move OpenTraffic to the Applications folder?"
        alert.informativeText = "OpenTraffic is running from \(path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") ? "the disk image" : "Downloads"). In Applications, the opentraffic command, coding-agent setup, and Launch at Login keep working after you eject or tidy up."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        guard response == .alertFirstButtonReturn else { return }

        let destination = URL(fileURLWithPath: "/Applications").appending(path: source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            // The person already approved this copy when they opened it; without the quarantine
            // flag macOS runs it in place instead of from a temporary read-only location.
            removexattr(destination.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            for case let item as URL in FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() {
                removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
        } catch {
            let failure = NSAlert()
            failure.messageText = "OpenTraffic couldn't move itself"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag OpenTraffic into the Applications folder in Finder instead."
            failure.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

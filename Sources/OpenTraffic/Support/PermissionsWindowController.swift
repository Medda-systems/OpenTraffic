import AppKit
import SwiftUI

/// The window that walks through the permissions Mac app sharing needs (PermissionsWizardView).
/// Opened by a Mac app share that is missing them, by Settings, by `opentraffic permissions` and
/// by the `opentraffic://permissions` link; one window, brought to the front when asked again.
@MainActor
final class PermissionsWindowController {
    static let shared = PermissionsWindowController()
    private var window: NSWindow?

    private init() {}

    var isShown: Bool { window?.isVisible == true }

    func show(store: AppStore) {
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow(store: AppStore) -> NSWindow {
        let view = PermissionsWizardView(store: store) { [weak self] in self?.close() }
            .tint(Brand.accent)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(PermissionsWizardView.size)
        window.title = "Permissions for Mac Apps"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }
}

/// Quits OpenTraffic and opens it again: macOS applies Screen Recording to an app only when it
/// starts. The new instance gets the same arguments and the variables that make a test copy its
/// own (its home folder and API socket), so an isolated copy stays isolated.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let environment = ProcessInfo.processInfo.environment
        var open = ["-n", "-a", Bundle.main.bundleURL.path]
        for key in ["CFFIXED_USER_HOME", "OPENTRAFFIC_SOCKET"] {
            if let value = environment[key] { open += ["--env", "\(key)=\(value)"] }
        }
        let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--background" }
        if !arguments.isEmpty { open += ["--args"] + arguments }
        // A shell outlives this process: it waits for it to exit (quitting stops the shares first),
        // then opens the app again.
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$@\"", "sh"] + open
        var own = environment
        own.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = own
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppStore.shared.notice = AppNotice(.error, "OpenTraffic couldn't reopen itself: \(error.localizedDescription). Quit and open it again.")
            return
        }
        NSApp.terminate(nil)
    }
}

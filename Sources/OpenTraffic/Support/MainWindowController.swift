import AppKit
import SwiftUI

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    private weak var mainWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// SwiftUI's openWindow action, registered at launch, so links and notification actions can
    /// reopen the main window after it was closed.
    private var opener: OpenWindowAction?

    func registerOpener(_ action: OpenWindowAction) {
        opener = action
    }

    private init() {}

    func register(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        // A newly registered window is about to be shown, so it gets a Dock icon.
        NSApp.setActivationPolicy(.regular)
        mainWindow = window
        window.isReleasedWhenClosed = false
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MainWindowController.shared.windowWillClose()
            }
        }
    }

    func show(openIfNeeded: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else if let opener {
            opener(id: "main")
        } else {
            openIfNeeded()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows or hides the Dock icon according to the user's preference and window state.
    func applyActivationPolicy() {
        let windowVisible = mainWindow?.isVisible ?? false
        let showDock = AppStore.shared.dockVisibility == .always || windowVisible
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    private func windowWillClose() {
        guard AppStore.shared.dockVisibility == .whileWindowOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { registerWindow(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { registerWindow(for: nsView) }
    }

    private func registerWindow(for view: NSView) {
        guard let window = view.window else { return }
        MainWindowController.shared.register(window)
    }
}

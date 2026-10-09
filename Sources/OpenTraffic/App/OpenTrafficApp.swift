import AppKit
import Darwin
import SwiftUI
import OpenTrafficCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignalSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        registerURLHandler()
    }

    /// opentraffic:// links from the CLI, Shortcuts, scripts, or other apps.
    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        // Answer the Apple event first; confirmation alerts run their own modal loop.
        DispatchQueue.main.async {
            AppStore.shared.handleAutomationURL(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI installs its own URL handling during launch; make sure OpenTraffic's wins.
        registerURLHandler()
        // Menu-bar-only users start without a Dock icon; the main window adds it when it opens.
        NSApp.setActivationPolicy(AppStore.shared.dockVisibility == .always ? .regular : .accessory)
        // A capture run works off-screen and must never take focus.
        if !DemoCapture.isActive { NSApp.activate(ignoringOtherApps: true) }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Quit from the run loop, not from inside this main-queue block: termination waits for
            // connectors to stop, and their callbacks need the main queue to be free.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
        }
        source.resume()
        terminationSignalSource = source
        ApplicationsMover.offerIfNeeded()
        Updates.start()
        #if DEBUG
        DebugSnapshots.runIfRequested(store: AppStore.shared)
        DemoCapture.start(store: AppStore.shared)
        #endif
        let store = AppStore.shared
        if store.globalHotKeysEnabled { GlobalHotKeys.shared.setEnabled(true) }
        if store.hasCompletedOnboarding, store.notifyWhenReady || store.notifyOnFailure {
            TunnelNotifications.requestAuthorizationIfNeeded()
        }
    }

    /// A menu bar app keeps running with no windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppStore.shared.saveCommentsNow()
        AppStore.shared.stopAll {
            Task { @MainActor in
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct OpenTrafficApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared

    var body: some Scene {
        Window("OpenTraffic", id: "main") {
            MainWindowView(store: store)
                .frame(minWidth: 860, minHeight: 560)
                .tint(Brand.accent)
                .pausesAnimationsWhenHidden()
        }
        .defaultSize(width: 1_040, height: 720)
        .commands {
            TunnelCommands(store: store)
        }

        // Capture runs (debug builds) stay out of the menu bar.
        MenuBarExtra(isInserted: .constant(!DemoCapture.isActive)) {
            MenuBarPopoverView(store: store)
                .tint(Brand.accent)
                .pausesAnimationsWhenHidden()
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .tint(Brand.accent)
        }
    }
}

/// Reads the store here rather than in the App body, so status polls only re-evaluate this small
/// view — and the icon itself only updates when its state or traffic blink actually changes.
private struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        MenuBarIcon(state: store.menuBarState, pulse: store.trafficPulse && store.menuBarState == .live)
            .equatable()
    }
}

private struct MenuBarIcon: View, Equatable {
    let state: MenuBarIconState
    let pulse: Bool

    var body: some View {
        Image(nsImage: BrandAssets.statusBarIcon(state: state, pulse: pulse))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 11)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .idle: "OpenTraffic, nothing shared"
        case .live: "OpenTraffic, sharing"
        case .attention: "OpenTraffic, attention needed"
        }
    }
}

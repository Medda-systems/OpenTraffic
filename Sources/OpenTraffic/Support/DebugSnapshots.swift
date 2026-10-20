#if DEBUG
import AppKit
import OpenTrafficCore
import SwiftUI

/// For checking layouts without showing windows: launching a debug build with
/// `OPENTRAFFIC_SNAPSHOTS=<folder>` renders views offscreen to PNGs there, then quits.
///
/// `OPENTRAFFIC_SNAPSHOTS_SHARE=<Mac app name>[:quick]` then shares that Mac app as its row's Share
/// menu does (OpenTunnel unless `:quick`), waits until it's live, and captures the popover and the
/// share's Live Collaboration card in floating panels (`*-panel-*.png`, also announced as
/// `SNAPSHOT_WINDOW <name> <n>`), plus `share-url.txt`. It keeps the share up for
/// `OPENTRAFFIC_SNAPSHOTS_HOLD` seconds (default 8, or until `<folder>/done` exists), then quits the
/// normal way, which stops the share and its app.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(store: AppStore) {
        guard let folder = ProcessInfo.processInfo.environment["OPENTRAFFIC_SNAPSHOTS"].flatMap(\.nilIfBlank) else { return }
        Task { @MainActor in
            // Let the first scan of local services finish so lists have content.
            try? await Task.sleep(for: .seconds(4))
            // The menu bar popover, with whatever is running (Electron apps under their own heading).
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                render(
                    MenuBarPopoverView(store: store),
                    size: NSSize(width: 380, height: 640),
                    appearance: appearance,
                    to: URL(fileURLWithPath: folder).appending(path: "popover-\(name).png")
                )
            }
            for scheme in [ColorScheme.dark, .light] {
                renderSwiftUI(
                    MenuBarPopoverView(store: store).frame(width: 380, height: 640)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                    to: URL(fileURLWithPath: folder).appending(path: "popover-swiftui-\(scheme == .dark ? "dark" : "light").png")
                )
            }
            // The Mac app permission guidance as the popover shows it, as if both permissions were off.
            let granted = store.missingMacAppPermissions
            store.missingMacAppPermissions = [.accessibility, .screenRecording]
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                render(
                    MacAppPermissionsMessage(store: store, waitingApp: "Orbit") {}
                        .padding(Spacing.s)
                        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.medium))
                        .padding(Spacing.s)
                        .frame(width: 360),
                    size: NSSize(width: 360, height: 200),
                    appearance: appearance,
                    to: URL(fileURLWithPath: folder).appending(path: "macapp-permissions-\(name).png")
                )
            }
            store.missingMacAppPermissions = granted
            if let request = ProcessInfo.processInfo.environment["OPENTRAFFIC_SNAPSHOTS_SHARE"].flatMap(\.nilIfBlank) {
                await shareMacApp(request, store: store, folder: URL(fileURLWithPath: folder))
                return
            }
            if ProcessInfo.processInfo.environment["OPENTRAFFIC_SNAPSHOTS_ONLY"] == "popover" {
                // Offscreen renders drop parts of a scrolling list: also show it for real, briefly, in a
                // floating panel on every Space, and print its window number for `screencapture -l`.
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640), styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.contentView = NSHostingView(rootView: MenuBarPopoverView(store: store))
                if let screen = NSScreen.main { panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 400, y: screen.visibleFrame.maxY - 10)) }
                panel.orderFrontRegardless()
                print("SNAPSHOT_WINDOW \(panel.windowNumber)")
                fflush(stdout)
                try? await Task.sleep(for: .seconds(6))
                exit(0)
            }
            for kind in NewTunnelKind.allCases {
                for scheme in [ColorScheme.dark, .light] {
                    renderSwiftUI(
                        KindSummary(kind: kind).padding(24).frame(width: 690, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                        to: URL(fileURLWithPath: folder).appending(path: "summary-\(kind.rawValue)-\(scheme == .dark ? "dark" : "light").png")
                    )
                }
                for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    render(
                        NewTunnelSheet(store: store, initialKind: kind),
                        size: NSSize(width: 960, height: 700),
                        appearance: appearance,
                        to: URL(fileURLWithPath: folder).appending(path: "new-tunnel-\(kind.rawValue)-\(name).png")
                    )
                }
            }
            exit(0)
        }
    }

    // MARK: A live Mac app share

    private static func shareMacApp(_ request: String, store: AppStore, folder: URL) async {
        let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
        let kind: TunnelKind = parts.count > 1 && parts[1] == "quick" ? .quick : .opentunnel
        let environment = ProcessInfo.processInfo.environment
        let hold = environment["OPENTRAFFIC_SNAPSHOTS_HOLD"].flatMap(Double.init) ?? 8
        func finish(_ problem: String? = nil) {
            if let problem {
                try? (problem + "\n").write(to: folder.appending(path: "share-error.txt"), atomically: true, encoding: .utf8)
                print("SNAPSHOT_SHARE_ERROR \(problem)")
                fflush(stdout)
            }
            // From the run loop, not from inside this main-actor task: quitting waits for main-actor work
            // (stopping the share and its app), which can't run while this task holds the main queue.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
        }

        var app: MacApp?
        for _ in 0..<20 {
            app = store.detectedMacApps.first { $0.name == parts[0] || $0.bundle.path == parts[0] }
            if app != nil { break }
            await store.scanLocalServices(showsProgress: false)
            try? await Task.sleep(for: .seconds(1))
        }
        guard let app else { return finish("No Mac app named \(parts[0]) was found.") }

        // The popover as it is before sharing, with the app under Mac Apps.
        let popover = panel(MenuBarPopoverView(store: store), size: NSSize(width: 380, height: 640), right: 400)
        try? await Task.sleep(for: .seconds(1.5))
        capture(popover, name: "popover-panel-before", folder: folder)
        store.share(app, kind: kind)
        if store.pendingMacAppShare != nil {
            try? await Task.sleep(for: .seconds(1))
            capture(popover, name: "popover-panel-permissions", folder: folder)
            return finish("Waiting for permissions: \(store.missingMacAppPermissions.map(\.rawValue).joined(separator: ", "))")
        }
        guard let definition = store.definitions.first(where: { $0.macApp == app.id && $0.kind == kind }) else {
            return finish(store.notice?.message ?? "The share wasn't created.")
        }
        let id = definition.id
        let started = Date()
        while Date().timeIntervalSince(started) < 180 {
            let runtime = store.runtime(for: id)
            if runtime.state == .failed || (runtime.state == .stopped && runtime.lastError != nil) {
                return finish(runtime.lastError ?? "The share failed.")
            }
            if runtime.state == .running, let url = runtime.publicURL, store.macAppStatus[id]?.state == .running {
                try? (url + "\n").write(to: folder.appending(path: "share-url.txt"), atomically: true, encoding: .utf8)
                print("SNAPSHOT_SHARE_URL \(url)")
                fflush(stdout)
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard store.runtime(for: id).publicURL != nil else { return finish("The share didn't go live within 3 minutes.") }

        // Live: the popover (the share under Live) and its card, with Restart App and Reset Data.
        let card = panel(MacAppCardSnapshot(store: store, id: id), size: NSSize(width: 680, height: 520), right: 1100)
        try? await Task.sleep(for: .seconds(1.5))
        capture(popover, name: "popover-panel-live", folder: folder)
        capture(card, name: "macapp-card-panel", folder: folder)
        let done = folder.appending(path: "done")
        let holding = Date()
        while Date().timeIntervalSince(holding) < hold, !FileManager.default.fileExists(atPath: done.path) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        capture(card, name: "macapp-card-panel-end", folder: folder)
        finish()
    }

    /// A floating panel on every Space, top right, announced for `screencapture -l`.
    private static func panel(_ view: some View, size: NSSize, right: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main { panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - right, y: screen.visibleFrame.maxY - 10)) }
        panel.orderFrontRegardless()
        return panel
    }

    private static func capture(_ window: NSWindow, name: String, folder: URL) {
        print("SNAPSHOT_WINDOW \(name) \(window.windowNumber)")
        fflush(stdout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", folder.appending(path: "\(name).png").path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func renderSwiftUI(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        // Captures AppKit-backed parts (lists, forms, controls); plain SwiftUI drawing comes out
        // blank, so `renderSwiftUI` covers that separately.
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
/// A share's Live Collaboration card on its own, as the share's page shows it.
private struct MacAppCardSnapshot: View {
    let store: AppStore
    let id: UUID

    var body: some View {
        ScrollView {
            if let tunnel = store.definitions.first(where: { $0.id == id }) {
                CollaborationCard(store: store, tunnel: tunnel)
                    .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif

#if DEBUG
import AppKit
import SwiftUI

/// For checking layouts without showing windows: launching a debug build with
/// `OPENTRAFFIC_SNAPSHOTS=<folder>` renders views offscreen to PNGs there, then quits.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(store: AppStore) {
        guard let folder = ProcessInfo.processInfo.environment["OPENTRAFFIC_SNAPSHOTS"].flatMap(\.nilIfBlank) else { return }
        Task { @MainActor in
            // Let the first scan of local services finish so lists have content.
            try? await Task.sleep(for: .seconds(4))
            // The menu bar popover, with whatever is running (Electron apps under Ready to Share).
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
#endif

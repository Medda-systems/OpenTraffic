import AppKit
import OpenTrafficCore
import SwiftUI

/// Debug builds only: tools for capturing the real app for the website, README, and demo video.
///
/// - `OPENTRAFFIC_DEMO_PORTS=5173,3001` lists only those ports under Ready to Share and hides
///   tunnels and agents running elsewhere, so a capture never shows anything personal.
/// - `OPENTRAFFIC_CAPTURE=<folder>` shows the real views in off-screen windows (no menu bar icon,
///   no activation), drawn behind the desktop wallpaper where nobody sees them but `screencapture`
///   can still capture them, writes their window numbers to `windows.json` for `screencapture -l`, and
///   applies `command.json` from the folder: `{"select": "Orbit", "tab": "feedback",
///   "appearance": "light", "newTunnel": "quick", "protection": "password"}`. Each applied command
///   bumps `ack.txt`. `"protection": "password"` adds a demo ngrok share with a password and shows its
///   Protection sheet; `"off"` removes both.
@MainActor
enum DemoCapture {
    static let folder: URL? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["OPENTRAFFIC_CAPTURE"].flatMap(\.nilIfBlank).map { URL(fileURLWithPath: $0) }
        #else
        nil
        #endif
    }()

    static var isActive: Bool { folder != nil }

    static let demoPorts: Set<Int>? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["OPENTRAFFIC_DEMO_PORTS"].map { Set($0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }) }
        #else
        nil
        #endif
    }()

    #if DEBUG
    /// Below the desktop picture: on screen as far as the window server knows, so it can be
    /// captured, but covered by the wallpaper and never in the way.
    private static let hiddenLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

    private static func hide(_ window: NSWindow) {
        window.level = hiddenLevel
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
    }

    /// Draws as the focused window would, though the capture app never takes focus.
    private final class ActiveLookingWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    private static var windows: [String: NSWindow] = [:]
    private static let protectedDemoID = UUID()
    private static var popoverHost: NSHostingView<AnyView>?
    private static var acknowledged = 0
    private static var activity: NSObjectProtocol?

    static func start(store: AppStore) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Nothing of the app is visible, so App Nap would otherwise slow its timers to a crawl.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Capturing the app")
        // SwiftUI opens the main window at launch; captures use their own copies instead. Hidden,
        // not closed: closing it would end the app.
        for window in NSApp.windows where !(window is NSPanel) { window.orderOut(nil) }
        makePopover(store: store)
        windows["main"] = makeWindow(
            AnyView(MainWindowView(store: store).frame(minWidth: 860, minHeight: 560).tint(Brand.accent)),
            size: NSSize(width: 1180, height: 760),
            titled: true
        )
        windows["newTunnel"] = makeWindow(
            AnyView(NewTunnelSheet(store: store, initialKind: .quick)),
            size: NSSize(width: 960, height: 700),
            titled: false
        )
        writeWindowNumbers()
        // Launched hidden (open -j) so nothing flashes on screen; the off-screen windows need it shown.
        NSApp.unhideWithoutActivation()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in poll(store: store) }
        }
    }

    private static func makePopover(store: AppStore) {
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 360, height: 640), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hide(panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        let host = NSHostingView(rootView: AnyView(MenuBarPopoverView(store: store).tint(Brand.accent)))
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
            host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        panel.contentView = material
        panel.orderFrontRegardless()
        popoverHost = host
        windows["popover"] = panel
        fitPopover()
    }

    /// The popover is as tall as its content, as in the menu bar.
    private static func fitPopover() {
        guard let panel = windows["popover"], let host = popoverHost else { return }
        let height = ceil(host.fittingSize.height)
        if abs(panel.frame.height - height) > 0.5 {
            panel.setFrame(NSRect(x: 40, y: 40, width: 360, height: height), display: true)
        }
    }

    private static func makeWindow(_ view: AnyView, size: NSSize, titled: Bool) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = .all
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.titled, .fullSizeContentView]
        let window = ActiveLookingWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hide(window)
        window.contentViewController = controller
        window.title = "OpenTraffic"
        if !titled {
            // Looks like a sheet: no title bar or buttons.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
        window.setContentSize(size)
        window.orderFrontRegardless()
        return window
    }

    private static func writeWindowNumbers() {
        guard let folder else { return }
        let numbers = windows.mapValues(\.windowNumber)
        if let data = try? JSONSerialization.data(withJSONObject: numbers, options: [.sortedKeys]) {
            try? data.write(to: folder.appending(path: "windows.json"))
        }
    }

    private static func poll(store: AppStore) {
        fitPopover()
        guard let folder else { return }
        let file = folder.appending(path: "command.json")
        guard let data = try? Data(contentsOf: file),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        try? FileManager.default.removeItem(at: file)
        if let name = command["select"] {
            store.selectedID = store.definitions.first { $0.name == name }?.id
        }
        if let tab = command["tab"].flatMap(DetailTab.init(rawValue:)) {
            store.detailTab = tab
        }
        if let appearance = command["appearance"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let kind = command["newTunnel"].flatMap(NewTunnelKind.init(rawValue:)), let old = windows["newTunnel"] {
            // A fresh sheet for the chosen option.
            windows["newTunnel"] = makeWindow(AnyView(NewTunnelSheet(store: store, initialKind: kind)), size: NSSize(width: 960, height: 700), titled: false)
            old.orderOut(nil)
            writeWindowNumbers()
        }
        if let protection = command["protection"] {
            windows.removeValue(forKey: "protection")?.orderOut(nil)
            store.definitions.removeAll { $0.id == protectedDemoID }
            if protection == "password" {
                let demo = TunnelDefinition(id: protectedDemoID, name: "Orbit", kind: .ngrok, localURL: "http://localhost:5175", protection: .password(username: "guest"))
                store.definitions.append(demo)
                windows["protection"] = makeWindow(AnyView(ProtectionSheet(store: store, tunnel: demo)), size: NSSize(width: 540, height: 520), titled: false)
            }
            writeWindowNumbers()
        }
        acknowledged += 1
        try? String(acknowledged).write(to: folder.appending(path: "ack.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}

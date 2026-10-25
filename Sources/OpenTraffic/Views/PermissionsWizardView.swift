import AppKit
import OpenTrafficCore
import SwiftUI
import UniformTypeIdentifiers

/// Walks through the permissions sharing a Mac app needs, one at a time: why each is needed, a
/// button that asks macOS and opens the right pane of System Settings, the app's icon to drag into
/// the list when OpenTraffic isn't in it, and Quit & Reopen for Screen Recording (macOS applies it
/// when the app starts). Each step checks itself off as soon as the switch is on.
struct PermissionsWizardView: View {
    @Bindable var store: AppStore
    var onClose: () -> Void

    /// Permissions whose pane was opened from here, so the next hint can show.
    @State private var opened: Set<MacAppSession.Permission>
    /// System Settings showed no window after Open System Settings (it can hang, or be left
    /// running where macOS no longer counts it as open, and then nothing opens).
    @State private var settingsDidNotOpen = false

    /// Off for renders of a made-up state (debug snapshots), which a live check would replace.
    private let checksLive: Bool

    init(store: AppStore, onClose: @escaping () -> Void, previewOpened: Set<MacAppSession.Permission>? = nil) {
        self.store = store
        self.onClose = onClose
        checksLive = previewOpened == nil
        _opened = State(initialValue: previewOpened ?? [])
    }

    private var missing: [MacAppSession.Permission] { store.missingMacAppPermissions }
    private var allOn: Bool { missing.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(allOn ? "OpenTraffic can share Mac apps" : "Let OpenTraffic share Mac apps")
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.xl)

            VStack(spacing: Spacing.m) {
                ForEach(Array(MacAppSession.Permission.allCases.enumerated()), id: \.element) { index, permission in
                    PermissionStepCard(
                        number: index + 1,
                        permission: permission,
                        isOn: !missing.contains(permission),
                        isCurrent: missing.first == permission,
                        wasOpened: opened.contains(permission)
                    ) {
                        // macOS's own prompt only the first time: it lists OpenTraffic in System
                        // Settings, and its button opens System Settings too, which would race the
                        // second opening.
                        let first = opened.insert(permission).inserted
                        store.requestMacAppPermission(permission, ask: first)
                        settingsDidNotOpen = false
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            settingsDidNotOpen = !Self.systemSettingsShowsAWindow()
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)

            if settingsDidNotOpen, !allOn {
                InlineMessage(
                    severity: .warning,
                    message: "It may be stuck. Quit it with Force Quit (Option-Command-Esc), then click Open System Settings again.",
                    title: "System Settings didn't open"
                ) {}
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.m)
            }

            Label("OpenTraffic only reads and captures the app you share, and only while you share it.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)

            Spacer(minLength: 0)
            Divider()
            HStack {
                if let pending = store.pendingMacAppShare {
                    Label(allOn ? "Sharing \(pending.app.name)…" : "\(pending.app.name) starts sharing once both are on.",
                          systemImage: allOn ? "checkmark.circle.fill" : "clock")
                        .font(.callout)
                        .foregroundStyle(allOn ? Color.green : Color.secondary)
                }
                Spacer()
                if allOn {
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(store.pendingMacAppShare == nil ? "Later" : "Cancel Share") {
                        store.cancelPendingMacAppShare()
                        onClose()
                    }
                }
            }
            .padding(Spacing.l)
        }
        // A fixed size that fits the tallest step: a window that follows its content's height
        // gets into a layout loop with the wrapping text (AppKit then ends the app).
        .frame(width: Self.size.width, height: Self.size.height)
        .task {
            // System Settings doesn't say when a switch changes: look every second while this is open.
            while checksLive, !Task.isCancelled {
                store.refreshMacAppPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static let size = CGSize(width: 580, height: 560)

    /// The name this OpenTraffic has in System Settings' lists (a test build's says which it is).
    static let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "OpenTraffic"

    /// Whether System Settings is running, as macOS counts apps, with a window on screen.
    static func systemSettingsShowsAWindow() -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
        guard !pids.isEmpty else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t).map(pids.contains) == true && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private var subtitle: String {
        if allOn { return "Both permissions are on. Share an app from the Mac Apps list in the menu bar." }
        return "Viewers see and use your app in their browser. macOS asks you to allow two things for that, once."
    }
}

/// One permission: its number (a check once it's on), what it's for, and while it's the current
/// step, how to turn it on.
private struct PermissionStepCard: View {
    let number: Int
    let permission: MacAppSession.Permission
    let isOn: Bool
    let isCurrent: Bool
    let wasOpened: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            badge
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(permission.title).font(.headline)
                    Spacer()
                    if isOn {
                        Text("On").font(.callout.weight(.medium)).foregroundStyle(.green)
                    }
                }
                if permission.settingsListName != permission.title {
                    Text("Called \(permission.settingsListName) in System Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent { instructions }
            }
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.35) : Color.clear)
        )
        .opacity(!isOn && !isCurrent ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(permission.title), \(isOn ? "on" : "off")")
    }

    private var badge: some View {
        ZStack {
            Circle().fill(isOn ? Color.green : isCurrent ? Color.accentColor : Color.secondary.opacity(0.35))
            if isOn {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var purpose: String {
        switch permission {
        case .accessibility:
            "Reads the shared app's buttons, fields and lists, so viewers can click and type in it and comments stick to the right control."
        case .screenRecording:
            "Captures the shared app's window, and only that window, so viewers see it."
        }
    }

    @ViewBuilder
    private var instructions: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Button(wasOpened ? "Open System Settings Again" : "Open System Settings", action: open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(wasOpened ? nil : .defaultAction)
                if permission == .screenRecording, wasOpened {
                    Button("Quit & Reopen") { AppStore.shared.relaunchForPermissions() }
                        .help("macOS turns Screen Recording on for an app when it starts")
                }
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if wasOpened {
                HStack(spacing: Spacing.s) {
                    AppDragTile()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .help("Shows this OpenTraffic in Finder, to drag it from there")
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    private var hint: String {
        let pane = "Privacy & Security > \(permission.settingsListName)"
        if !wasOpened { return "Opens \(pane). Switch on \(PermissionsWizardView.appName) there; macOS may ask for your password." }
        var text = "In \(pane), switch on \(PermissionsWizardView.appName). Not in the list? Drag the icon below into it (or drag it from Finder), or click + and choose it."
        if permission == .screenRecording {
            text += " Already on and this step still waits? macOS applies it after OpenTraffic reopens: click Quit & Reopen."
        }
        return text
    }
}

/// OpenTraffic's own icon and name, to drag into a System Settings privacy list (they take apps
/// dropped on them). Says where this copy is when it isn't the one in Applications.
private struct AppDragTile: View {
    private let bundle = Bundle.main.bundleURL

    var body: some View {
        HStack(spacing: Spacing.s) {
            // The app's own icon image: the Finder icon of the bundle comes through macOS's icon
            // treatment, which crops OpenTraffic's icon file at this size.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(PermissionsWizardView.appName).font(.callout.weight(.medium))
                Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: "hand.draw").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        // A link to the app, as Finder drags it: a provider of the file's contents hands the list a
        // copy of the bundle, which isn't the app that asks for the permission.
        .onDrag { NSItemProvider(object: bundle as NSURL) }
        .help("Drag into the list in System Settings")
        .accessibilityLabel("OpenTraffic app, drag into the list in System Settings")
    }

    private var location: String {
        let parent = bundle.deletingLastPathComponent().path
        if parent == "/Applications" { return "Drag me into the list" }
        return "This copy: \(bundle.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
    }
}

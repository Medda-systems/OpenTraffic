import AppKit
import Carbon.HIToolbox
import OpenTrafficCore

/// System-wide shortcuts registered with Carbon's hot-key API, which needs no Accessibility permission.
/// ⌃⌥⌘S shares the newest detected local server; ⌃⌥⌘C copies the URL of the most recently started tunnel.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    enum Action: UInt32 {
        case shareNewest = 1
        case copyLatestURL = 2

        var keyCode: Int {
            switch self {
            case .shareNewest: kVK_ANSI_S
            case .copyLatestURL: kVK_ANSI_C
            }
        }

        var display: String {
            switch self {
            case .shareNewest: "⌃⌥⌘S"
            case .copyLatestURL: "⌃⌥⌘C"
            }
        }
    }

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x5442_4152 // "TBAR"

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKeys.isEmpty, handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let raw = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKeys.shared.perform(raw) }
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        // If neither shortcut could be registered (taken by another app), don't keep the handler.
        defer { if hotKeys.isEmpty { unregister() } }
        for action in [Action.shareNewest, .copyLatestURL] {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let modifiers = UInt32(cmdKey | optionKey | controlKey)
            if RegisterEventHotKey(UInt32(action.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference {
                hotKeys.append(reference)
            }
        }
    }

    private func unregister() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func perform(_ raw: UInt32) {
        let store = AppStore.shared
        switch Action(rawValue: raw) {
        case .shareNewest:
            Task {
                await store.scanLocalServices()
                guard let service = store.shareableLocalServices.first else {
                    TunnelNotifications.post(title: "Nothing to share", body: "No unshared web server is running on this Mac.", identifier: "hotkey-share")
                    return
                }
                store.share(service, kind: store.effectiveDefaultShareKind)
            }
        case .copyLatestURL:
            let latest = store.definitions
                .filter { store.isActive($0.id) && store.publicURL(for: $0) != nil }
                .max { (store.runtime(for: $0.id).startedAt ?? .distantPast) < (store.runtime(for: $1.id).startedAt ?? .distantPast) }
            guard let latest, let url = store.publicURL(for: latest) else {
                TunnelNotifications.post(title: "No running tunnel", body: "Start a tunnel first.", identifier: "hotkey-copy")
                return
            }
            store.copyPublicURL(latest.id)
            TunnelNotifications.post(title: "Copied \(latest.name)", body: url, identifier: "hotkey-copy")
        case nil:
            break
        }
    }
}

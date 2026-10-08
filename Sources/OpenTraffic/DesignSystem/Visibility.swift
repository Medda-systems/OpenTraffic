import AppKit
import SwiftUI

private struct AnimationsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private struct WindowIsOpenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the hosting window is closed, hidden, or fully covered. Continuous animations
    /// (traffic packets, pulses) pause then, so a closed window or menu bar popover costs no CPU.
    var animationsActive: Bool {
        get { self[AnimationsActiveKey.self] }
        set { self[AnimationsActiveKey.self] = newValue }
    }

    /// False while the hosting window is closed (but not when minimized or merely covered).
    var windowIsOpen: Bool {
        get { self[WindowIsOpenKey.self] }
        set { self[WindowIsOpenKey.self] = newValue }
    }
}

extension View {
    /// Tracks whether this view's window is actually on screen and exposes it as `animationsActive`.
    func pausesAnimationsWhenHidden() -> some View {
        modifier(WindowVisibilityModifier())
    }
}

private struct WindowVisibilityModifier: ViewModifier {
    // Starts closed: SwiftUI can host a scene's views before (or without) putting them in a window,
    // and they shouldn't do work until a window actually shows them.
    @State private var visibility = WindowVisibility(onScreen: false, open: false)

    func body(content: Content) -> some View {
        content
            .environment(\.animationsActive, visibility.onScreen)
            .environment(\.windowIsOpen, visibility.open)
            .background(WindowVisibilityReader(visibility: $visibility))
    }
}

private struct WindowVisibility: Equatable {
    var onScreen: Bool
    var open: Bool
}

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visibility: WindowVisibility

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = { visibility in
            if self.visibility != visibility { self.visibility = visibility }
        }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {}

    final class ObservingView: NSView {
        var onChange: ((WindowVisibility) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange?(WindowVisibility(onScreen: false, open: false))
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { return }
            // Minimized windows count as open so they restore with their content in place.
            let open = !closing && (window.isVisible || window.isMiniaturized)
            let onScreen = open && !window.isMiniaturized && window.occlusionState.contains(.visible)
            onChange?(WindowVisibility(onScreen: onScreen, open: open))
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

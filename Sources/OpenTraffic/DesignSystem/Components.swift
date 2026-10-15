import Charts
import SwiftUI
import OpenTrafficCore

// MARK: Status

/// A small breathing dot that says "live right now".
struct LivePulse: View {
    var color: Color = .green
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var animationsActive

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background {
                if !reduceMotion && animationsActive {
                    PulseRing(color: color.opacity(0.5), filled: true, scale: 2.4, startOpacity: 0.8, duration: 1.6)
                }
            }
            .accessibilityLabel("Live")
    }
}

/// Capsule with symbol and label for headers.
struct StatusBadge: View {
    let state: TunnelDisplayState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.callout.weight(.medium))
            .foregroundStyle(state.textTint)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs + 1)
            .background(state.tint.opacity(0.12), in: Capsule())
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: state)
            .accessibilityElement(children: .combine)
    }
}

// MARK: Messages

/// An inline message with an optional set of actions, placed next to what it describes.
struct InlineMessage<Actions: View>: View {
    let severity: Severity
    let message: String
    var title: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: severity.symbol)
                .foregroundStyle(severity.tint)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let title {
                    Text(title).fontWeight(.semibold)
                }
                Text(message)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.s) { actions }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }
}

extension InlineMessage where Actions == EmptyView {
    init(severity: Severity, message: String, title: String? = nil) {
        self.init(severity: severity, message: message, title: title) { EmptyView() }
    }
}

/// Floating, auto-dismissing notice for the main window.
struct NoticeToast: View {
    let notice: AppNotice
    let onAction: (AppNotice.Action) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: notice.severity.symbol)
                .foregroundStyle(notice.severity.tint)
                .font(.title3)
            Text(notice.message)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let title = notice.actionTitle, let action = notice.action {
                Button(title) { onAction(action) }
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .task(id: notice.id) {
            // Errors stay until dismissed; everything else gets out of the way.
            guard notice.severity != .error else { return }
            try? await Task.sleep(for: .seconds(notice.action == nil ? 4 : 8))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Metrics

struct MetricTile: View {
    let title: String
    let value: String
    var caption: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Requests per polling interval as a compact area chart.
struct RequestSparkline: View {
    let history: RequestHistory?

    var body: some View {
        let points = history?.deltas ?? []
        if points.count < 2 {
            Text("Collecting traffic…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        } else {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.date), y: .value("Requests", point.count))
                    .foregroundStyle(.tint.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Requests", point.count))
                    .foregroundStyle(.tint)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 44)
            .accessibilityLabel("Requests over the last few minutes")
        }
    }
}

// MARK: Controls

/// Copies text and briefly confirms with a checkmark.
struct CopyButton: View {
    private let provide: () -> String?
    private let isAvailable: Bool
    private let label: String
    private let iconOnly: Bool
    private let concealed: Bool
    @State private var copied = false

    init(text: String?, label: String = "Copy", iconOnly: Bool = true) {
        self.provide = { text }
        self.isAvailable = text != nil
        self.label = label
        self.iconOnly = iconOnly
        self.concealed = false
    }

    /// Produces the text only when clicked, for values that are expensive or sensitive to read
    /// (long log exports, Keychain passwords). Concealed text is hidden from clipboard managers.
    init(label: String, iconOnly: Bool = true, concealed: Bool = false, isAvailable: Bool = true, text: @escaping () -> String?) {
        self.provide = text
        self.isAvailable = isAvailable
        self.label = label
        self.iconOnly = iconOnly
        self.concealed = concealed
    }

    var body: some View {
        Button {
            guard let text = provide() else { return }
            Pasteboard.copy(text, concealed: concealed)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: copied)
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
        }
        .disabled(!isAvailable)
        .help(copied ? "Copied" : label)
    }
}

/// Copies a share's link; a share with a password OpenTraffic checks also offers the link with the
/// password built in, from the button's menu.
struct CopyLinkMenu: View {
    let url: String?
    let linkWithPassword: () -> String?
    @State private var copied = false

    var body: some View {
        Menu {
            Button("Copy Link", systemImage: "link") { copy(url) }
            Button("Copy Link with Password", systemImage: "key") { copy(linkWithPassword(), concealed: true) }
        } label: {
            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
        } primaryAction: {
            copy(url)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(url == nil)
        .help(copied ? "Copied" : "Copy the link. The menu also has the link with the password built in.")
    }

    private func copy(_ text: String?, concealed: Bool = false) {
        guard let text else { return }
        Pasteboard.copy(text, concealed: concealed)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// Borderless icon button that shows a hover background, for dense rows.
struct RowIconButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Standard macOS sheet layout: title, scrolling content, and a bottom button bar
/// with the cancel and default actions at the trailing edge.
struct SheetScaffold<Content: View, Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var leadingFooter: Leading
    @ViewBuilder var trailingFooter: Trailing

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.s)

            content

            Divider()
            HStack(spacing: Spacing.s) {
                leadingFooter
                Spacer()
                trailingFooter
            }
            .padding(Spacing.l)
        }
    }
}

extension SheetScaffold where Leading == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailingFooter: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.leadingFooter = EmptyView()
        self.trailingFooter = trailingFooter()
    }
}

/// Hover highlight for list-like rows outside of a List.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

// MARK: Removal

extension View {
    /// Asks before removing a saved tunnel from OpenTraffic, saying what goes with it.
    func confirmsRemoval(of tunnel: Binding<TunnelDefinition?>, store: AppStore) -> some View {
        confirmationDialog(
            "Remove \(tunnel.wrappedValue?.name ?? "tunnel") from OpenTraffic?",
            isPresented: Binding(get: { tunnel.wrappedValue != nil }, set: { if !$0 { tunnel.wrappedValue = nil } }),
            presenting: tunnel.wrappedValue
        ) { definition in
            Button("Remove", role: .destructive) { store.remove(definition.id) }
        } message: { definition in
            Text(removalMessage(definition, store: store))
        }
    }
}

@MainActor
private func removalMessage(_ definition: TunnelDefinition, store: AppStore) -> String {
    var message = "This stops the tunnel and removes the saved entry."
    if definition.kind.usesCloudflareAccount { message += " Cloudflare resources are not deleted." }
    if !store.comments(for: definition.id).isEmpty { message += " Its collaboration comments are deleted too." }
    return message
}

// MARK: HTTP status

extension Color {
    /// The color for an HTTP status class, from a code (`404`) or a class label (`4xx`).
    static func httpStatus(_ codeOrClass: String) -> Color {
        switch codeOrClass.first {
        case "2": .green
        case "3": .blue
        case "4": .orange
        case "5": .red
        default: .secondary
        }
    }
}

import AppKit
import SwiftUI
import OpenTrafficCore

/// Header shared by managed and discovered tunnel details.
struct DetailHeader<Actions: View>: View {
    let previewIdentity: String
    let originURL: String?
    let title: String
    let state: TunnelDisplayState
    let caption: String
    var provider: TunnelProvider?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.l) {
            SitePreviewView(identity: previewIdentity, originURL: originURL)
            VStack(alignment: .leading, spacing: Spacing.s - 2) {
                HStack(spacing: Spacing.s) {
                    TunnelIcon(originURL: originURL, size: 22)
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                HStack(spacing: Spacing.s) {
                    StatusBadge(state: state)
                    if let provider {
                        ProviderLogo(provider: provider, height: 13, tint: .secondary)
                    }
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.m)
            actions.controlSize(.large)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
    }
}

/// Segmented Overview / Logs switcher placed in the window toolbar.
struct DetailTabPicker: ToolbarContent {
    @Binding var selection: DetailTab
    var tabs: [DetailTab] = [.overview, .logs]
    var logBadge: Int = 0
    var feedbackBadge: Int = 0

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(title(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(help)
        }
    }
}

extension DetailTabPicker {
    private func title(for tab: DetailTab) -> String {
        switch tab {
        case .logs where logBadge > 0: "\(tab.title) (\(logBadge))"
        case .feedback where feedbackBadge > 0: "\(tab.title) (\(feedbackBadge))"
        default: tab.title
        }
    }

    private var help: String {
        let shortcuts = tabs.map { tab -> String in
            switch tab {
            case .overview: "⌘1 Overview"
            case .logs: "⌘2 Logs"
            case .requests: "⌘3 Requests"
            case .feedback: "⌘4 Feedback"
            }
        }
        return "Switch views (\(shortcuts.joined(separator: ", ")))"
    }
}

/// The public URL as the hero of the overview: large monospaced address, copy, QR, and open.
struct PublicURLCard<Footer: View>: View {
    let url: String?
    var placeholder = "Available once the tunnel starts"
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(Vocabulary.publicURL)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.m) {
                if let url, let link = webURL {
                    Text(url)
                        .font(.title3.weight(.semibold).monospaced())
                        .foregroundStyle(Brand.accentText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(link) }
                        .help("Double-click to open")
                } else {
                    Text(placeholder)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                HStack(spacing: Spacing.xs) {
                    CopyButton(text: url, label: Vocabulary.copyURL)
                    QRCodeButton(url: url)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button(Vocabulary.openInBrowser, systemImage: "arrow.up.right") {
                    if let webURL { NSWorkspace.shared.open(webURL) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(webURL == nil)
                .help(Vocabulary.openInBrowser)
            }
            footer
        }
    }

    private var webURL: URL? {
        guard let url, let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return nil }
        return link
    }
}

extension PublicURLCard where Footer == EmptyView {
    init(url: String?, placeholder: String = "Available once the tunnel starts") {
        self.init(url: url, placeholder: placeholder) { EmptyView() }
    }
}

struct TrafficCard: View {
    let statistics: TunnelStatistics?
    let startedAt: Date?
    let history: RequestHistory?
    var emptyMessage = "Start the tunnel to see live traffic."

    var body: some View {
        Card(title: "Traffic") {
            if let statistics {
                HStack(spacing: Spacing.l) {
                    MetricTile(title: "Requests", value: statistics.totalRequests.map(Self.number) ?? "—")
                    MetricTile(
                        title: "Origin errors",
                        value: statistics.requestErrors.map(Self.number) ?? "—",
                        tint: (statistics.requestErrors ?? 0) > 0 ? .red : nil
                    )
                    MetricTile(title: "Uptime", value: uptime)
                    if statistics.transportBytes != nil {
                        MetricTile(title: "Transferred", value: TunnelRowPresentation.byteCount(statistics.transportBytes), caption: "QUIC, incl. overhead")
                    }
                }
                RequestSparkline(history: history)
                let classes = ResponseClassCount.summarize(statistics.responseByCode)
                if !classes.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Text("Responses").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        ForEach(classes) { item in
                            Text("\(item.label) \(Self.number(item.count))")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(Self.tint(for: item.label))
                                .padding(.horizontal, Spacing.s - 2)
                                .padding(.vertical, Spacing.xxs)
                                .background(Self.tint(for: item.label).opacity(0.12), in: Capsule())
                                .contentTransition(.numericText())
                        }
                    }
                }
            } else {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: statistics)
    }

    private var uptime: String {
        let started = statistics?.processStartedAt ?? startedAt
        return started.map { TunnelRowPresentation.formatDuration(Date().timeIntervalSince($0)) } ?? "—"
    }

    private static func number(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private static func tint(for label: String) -> Color {
        Color.httpStatus(label)
    }
}

/// Every health check as a row, behind a disclosure; the connection path is the summary.
struct HealthDetailsCard: View {
    let health: TunnelHealth?
    var provider: TunnelProvider = .cloudflare
    /// When the tunnel is stopped on purpose, only the connector check is meaningful.
    var collapsed = false
    let fixes: (TunnelHealthCheck) -> [HealthFix]
    let onRecheck: () -> Void
    @State private var expanded: Bool?

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if let health {
                        ForEach(Array(visibleChecks(health).enumerated()), id: \.element.id) { index, check in
                            if index > 0 { Divider() }
                            row(for: check).padding(.vertical, Spacing.s)
                        }
                        if collapsed {
                            Text("Local service, Cloudflare, DNS, and public site checks run once the tunnel starts.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, Spacing.xs)
                        }
                    } else {
                        HStack(spacing: Spacing.s) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, Spacing.s)
                .animation(.spring(duration: 0.4), value: health?.checks)
            } label: {
                HStack {
                    Text("Health Checks").font(.headline)
                    if let health, !collapsed {
                        summary(for: health)
                    }
                    Spacer()
                    if let updatedAt = health?.updatedAt {
                        Text("Checked \(updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Button(Vocabulary.recheck, systemImage: "arrow.clockwise", action: onRecheck)
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Recheck health (⌘R)")
                }
            }
        }
    }

    private func summary(for health: TunnelHealth) -> some View {
        let failed = health.checks.filter { $0.state == .failed }.count
        let checking = health.checks.contains { $0.state == .working }
        let (text, color): (String, Color) = if failed > 0 {
            ("\(failed) failing", .red)
        } else if checking {
            ("Checking…", .blue)
        } else {
            ("All passing", .green)
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .contentTransition(.opacity)
    }

    /// Open by default when something is failing, so problems are never hidden.
    private var isExpanded: Binding<Bool> {
        Binding {
            expanded ?? (collapsed || health?.checks.contains { $0.state == .failed } == true)
        } set: {
            expanded = $0
        }
    }

    private func visibleChecks(_ health: TunnelHealth) -> [TunnelHealthCheck] {
        collapsed ? health.checks.filter { $0.kind == .connector } : health.checks
    }

    private func row(for check: TunnelHealthCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            icon(for: check.state)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(check.kind.title(for: provider)).fontWeight(.medium)
                if let detail = check.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.s)
            ForEach(fixes(check)) { fix in
                if fix.isProminent {
                    Button(fix.title, action: fix.action).buttonStyle(.borderedProminent)
                } else {
                    Button(fix.title, action: fix.action)
                }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func icon(for state: HealthCheckState) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Passed")
        case .working:
            ProgressView().controlSize(.mini).accessibilityLabel("Checking")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary).accessibilityLabel("Not checked")
        }
    }
}

struct SetupProgressView: View {
    let steps: [SetupProgressStep]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s - 2) {
            ForEach(steps) { step in
                HStack(spacing: Spacing.s) {
                    stepIcon(for: step.state).frame(width: 16)
                    Text(step.title)
                    if case .failed(let message) = step.state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
        }
        .animation(.snappy, value: steps)
    }

    @ViewBuilder
    private func stepIcon(for state: SetupProgressState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .active: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

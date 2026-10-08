import SwiftUI
import OpenTrafficCore

/// Searchable, level-filterable log viewer shared by managed and discovered tunnels.
struct LogConsole: View {
    enum LevelFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case warnings = "Warnings"
        case errors = "Errors"

        var id: String { rawValue }

        func includes(_ level: String) -> Bool {
            switch self {
            case .all: true
            case .warnings: LogConsole.rank(level) >= 1
            case .errors: LogConsole.rank(level) >= 2
            }
        }
    }

    let entries: [TunnelLogEntry]
    var source: String?
    var onClear: (() -> Void)?
    var emptyTitle = "No log output yet"
    var emptyMessage = "Start the tunnel to stream cloudflared output here."

    @State private var searchText = ""
    @State private var filter = LevelFilter.all
    @State private var followTail = true
    @State private var expandedIDs = Set<UUID>()

    var body: some View {
        // Filter once per render; everything below works from this one pass.
        let visible = filtered
        VStack(spacing: 0) {
            controls(visible)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "text.alignleft")
                } description: {
                    Text(emptyMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                lines(visible)
            }
        }
    }

    private func controls(_ visible: [TunnelLogEntry]) -> some View {
        let counts = levelCounts
        return HStack(spacing: Spacing.s) {
            Picker("Level", selection: $filter) {
                ForEach(LevelFilter.allCases) { level in
                    Text(label(for: level, counts: counts)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            FilterField(text: $searchText)
                .frame(maxWidth: 260)

            Spacer()

            if let source {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source)
            }
            Toggle(isOn: $followTail) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Keep the newest line in view")
            CopyButton(label: "Copy Visible Lines", isAvailable: !visible.isEmpty) { Self.copyText(visible) }
                .tint(.primary)
            if let onClear {
                Button("Clear", systemImage: "trash", action: onClear)
                    .labelStyle(.iconOnly)
                    .tint(.primary)
                    .disabled(entries.isEmpty)
                    .help("Clear logs")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private func lines(_ visible: [TunnelLogEntry]) -> some View {
        ScrollViewReader { proxy in
            List(visible) { entry in
                LogRow(
                    entry: entry,
                    time: Self.time.string(from: entry.timestamp),
                    isExpanded: Binding(
                        get: { expandedIDs.contains(entry.id) },
                        set: { if $0 { expandedIDs.insert(entry.id) } else { expandedIDs.remove(entry.id) } }
                    )
                )
                .listRowBackground(Self.rank(entry.level) >= 2 ? Color.red.opacity(0.06) : Color.clear)
                .id(entry.id)
                .contextMenu {
                    Button("Copy Message") { Pasteboard.copy(entry.message) }
                    Button("Copy Raw Line") { Pasteboard.copy(entry.rawLine ?? entry.message) }
                }
            }
            .listStyle(.plain)
            .onChange(of: visible.last?.id) { scrollToEnd(proxy, visible) }
            .onChange(of: followTail) { scrollToEnd(proxy, visible) }
            .onAppear { scrollToEnd(proxy, visible) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ visible: [TunnelLogEntry]) {
        guard followTail, let last = visible.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    private var filtered: [TunnelLogEntry] {
        entries.filter { entry in
            // cloudflared draws ASCII tables; their empty border rows carry no information.
            !StructuredLog.displayMessage(entry.message).isEmpty
                && filter.includes(entry.level)
                && (searchText.isEmpty
                    || (entry.rawLine ?? entry.message).localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Warning-or-worse and error counts in one pass.
    private var levelCounts: (warnings: Int, errors: Int) {
        entries.reduce(into: (0, 0)) { counts, entry in
            let rank = Self.rank(entry.level)
            if rank >= 1 { counts.0 += 1 }
            if rank >= 2 { counts.1 += 1 }
        }
    }

    private func label(for level: LevelFilter, counts: (warnings: Int, errors: Int)) -> String {
        let count = switch level {
        case .all: 0
        case .warnings: counts.warnings
        case .errors: counts.errors
        }
        return count == 0 ? level.rawValue : "\(level.rawValue) \(count)"
    }

    private static func copyText(_ visible: [TunnelLogEntry]) -> String {
        visible
            .map { "\(Self.time.string(from: $0.timestamp)) [\($0.level)] \($0.rawLine ?? $0.message)" }
            .joined(separator: "\n")
    }

    nonisolated static func rank(_ level: String) -> Int {
        switch level.lowercased() {
        case "error", "fatal", "panic": 2
        case "warn", "warning": 1
        default: 0
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// One log line: level label, tidied message, structured fields as tags, raw JSON on demand.
private struct LogRow: View {
    let entry: TunnelLogEntry
    let time: String
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            LevelChip(level: entry.level)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(StructuredLog.displayMessage(entry.message))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let fields = StructuredLog.fields(fromRawLine: entry.rawLine)
                if !fields.isEmpty {
                    WrappingHStack(spacing: Spacing.xs) {
                        ForEach(fields) { field in
                            HStack(spacing: 3) {
                                Text(field.key).foregroundStyle(.secondary)
                                Text(field.value).foregroundStyle(field.key == "error" ? .red : .primary)
                            }
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                if isExpanded, let raw = entry.rawLine {
                    Text(raw)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.small))
                }
            }
            if entry.rawLine != nil {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(isExpanded ? "Hide raw JSON" : "Show raw JSON")
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide raw JSON" : "Show raw JSON")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LevelChip: View {
    let level: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(width: 38)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(level)
    }

    private var label: String {
        switch LogConsole.rank(level) {
        case 2: "ERROR"
        case 1: "WARN"
        default: level.lowercased() == "debug" ? "DEBUG" : "INFO"
        }
    }

    private var foreground: Color {
        switch LogConsole.rank(level) {
        case 2: .white
        case 1: .black
        default: .secondary
        }
    }

    private var background: Color {
        switch LogConsole.rank(level) {
        case 2: .red
        case 1: .yellow
        default: .primary.opacity(0.08)
        }
    }
}

/// Lays children out left to right, wrapping onto new lines when a row is full.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A compact search field with a clear button and an optional result count.
struct FilterField: View {
    @Binding var text: String
    var count: Int?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small))
    }
}

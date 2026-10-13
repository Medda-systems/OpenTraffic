import SwiftUI
import OpenTrafficCore

/// Requests captured by the tunnel's ngrok agent: list on the left, the selected request on the right.
struct RequestInspector: View {
    @Bindable var store: AppStore
    let tunnel: TunnelDefinition
    @State private var selectedID: String?
    @State private var filter = ""

    var body: some View {
        if requests.isEmpty {
            ContentUnavailableView {
                Label(isRunning ? "No Requests Yet" : "Not Capturing", systemImage: "arrow.left.arrow.right")
            } description: {
                Text(isRunning
                     ? "Requests to \(store.publicURL(for: tunnel) ?? "the public URL") appear here as they arrive."
                     : "Start the tunnel to capture requests. ngrok keeps them only while it runs.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Not an HSplitView: inside the window's split view it sized itself from its panes' ideal
            // widths rather than the space it was given, pushing the window's sidebar and this tab's
            // right edge out of the window at default sizes. Here the list gets a share of the actual width.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    list
                        .frame(width: Self.listWidth(available: proxy.size.width))
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// About two-fifths of the tab, within 240–340pt, leaving the rest to the selected request.
    private static func listWidth(available: CGFloat) -> CGFloat {
        min(340, max(240, (available * 0.4).rounded()))
    }

    private var requests: [NgrokRequest] { store.ngrokRequests[tunnel.id] ?? [] }
    private var isRunning: Bool { store.isActive(tunnel.id) }

    private var filtered: [NgrokRequest] {
        guard let query = filter.nilIfBlank else { return requests }
        return requests.filter {
            "\($0.method) \($0.uri) \($0.statusCode.map(String.init) ?? "")".localizedCaseInsensitiveContains(query)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            FilterField(text: $filter, count: filtered.count)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
            Divider()
            List(filtered, selection: $selectedID) { request in
                RequestRow(request: request)
                    .tag(request.id)
            }
            .listStyle(.inset)
            // In a split view's detail column, rows inserted without an animation keep the default
            // row height instead of being measured, so new requests drew squashed over their neighbors.
            .animation(.default, value: filtered.map(\.id))
        }
        .onAppear { if selectedID == nil { selectedID = requests.first?.id } }
    }

    @ViewBuilder
    private var detail: some View {
        if let request = requests.first(where: { $0.id == selectedID }) ?? requests.first {
            RequestDetail(request: request, publicURL: store.publicURL(for: tunnel), canReplay: isRunning) {
                try await store.replayNgrokRequest(request, for: tunnel.id)
            }
            .id(request.id)
        } else {
            ContentUnavailableView("Select a Request", systemImage: "sidebar.left")
        }
    }
}

private struct RequestRow: View {
    let request: NgrokRequest

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(request.method)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.uri)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Spacing.xs) {
                    if let start = request.start {
                        Text(start, style: .time)
                    }
                    if let duration = request.duration {
                        Text("· \(RequestFormat.duration(duration))")
                    }
                    if request.start == nil && request.duration == nil && !request.isReplay {
                        // Keeps every row two lines tall.
                        Text("—")
                    }
                    if request.isReplay {
                        Text("Replayed")
                            .foregroundStyle(.tint)
                            .fontWeight(.medium)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.xs)
            StatusCodePill(code: request.statusCode)
        }
        .padding(.vertical, 2)
    }
}

struct StatusCodePill: View {
    let code: Int?

    var body: some View {
        Text(code.map(String.init) ?? "—")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(code.map { Color.httpStatusText(String($0)) } ?? .secondary)
            .padding(.horizontal, Spacing.s - 2)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var tint: Color {
        code.map { Color.httpStatus(String($0)) } ?? .secondary
    }
}

private struct RequestDetail: View {
    let request: NgrokRequest
    let publicURL: String?
    let canReplay: Bool
    let replay: () async throws -> Void
    @State private var revealSecrets = false
    @State private var replayState: ReplayState = .idle

    private enum ReplayState: Equatable {
        case idle, replaying, done
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                Card(title: "Request", accessory: {
                    Toggle("Show secrets", isOn: $revealSecrets)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Show Authorization, Cookie, and API key header values")
                }, content: {
                    HeaderList(headers: request.request.headers, revealSecrets: revealSecrets)
                    BodyView(content: request.request.decodedBody)
                })
                if let response = request.response {
                    Card(title: "Response") {
                        HeaderList(headers: response.headers, revealSecrets: revealSecrets)
                        BodyView(content: response.decodedBody)
                    }
                }
            }
            .padding(Spacing.l)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(request.method).font(.headline.monospaced())
                Text(request.uri)
                    .font(.headline.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                StatusCodePill(code: request.statusCode)
            }
            HStack(spacing: Spacing.s) {
                if let start = request.start {
                    Text(start.formatted(date: .abbreviated, time: .standard))
                }
                if let duration = request.duration {
                    Text("· \(RequestFormat.duration(duration))")
                }
                if request.isReplay { Text("· Replayed") }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                Button {
                    replayState = .replaying
                    Task {
                        do {
                            try await replay()
                            replayState = .done
                        } catch {
                            replayState = .failed(error.localizedDescription)
                        }
                    }
                } label: {
                    Label(replayState == .done ? "Replayed" : "Replay", systemImage: replayState == .done ? "checkmark" : "arrow.clockwise")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canReplay || replayState == .replaying)
                .help(canReplay ? "Send this request to your local service again" : "Start the tunnel to replay")
                CopyButton(
                    text: publicURL.map { request.curlCommand(baseURL: $0) },
                    label: "Copy as cURL",
                    iconOnly: false
                )
                .help("Copy a curl command for this request (secrets are left out)")
                if case .failed(let message) = replayState {
                    InlineMessage(severity: .error, message: message)
                }
            }
            .controlSize(.small)
        }
    }
}

private struct HeaderList: View {
    let headers: [(name: String, values: [String])]
    let revealSecrets: Bool

    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary).font(.callout)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                ForEach(headers, id: \.name) { header in
                    GridRow {
                        Text(header.name)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(value(for: header))
                            .textSelection(.enabled)
                            .foregroundStyle(isHidden(header) ? .tertiary : .primary)
                    }
                    .font(.caption.monospaced())
                }
            }
        }
    }

    private func isHidden(_ header: (name: String, values: [String])) -> Bool {
        !revealSecrets && NgrokRequest.isSensitive(header.name)
    }

    private func value(for header: (name: String, values: [String])) -> String {
        isHidden(header) ? "•••••• (hidden)" : header.values.joined(separator: ", ")
    }
}

private struct BodyView: View {
    let content: NgrokRequest.DecodedBody
    private var data: Data { content.data }

    var body: some View {
        if !data.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Body · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.small))
            }
        }
    }

    /// Pretty-printed JSON when possible, UTF-8 text otherwise, capped so huge bodies stay responsive.
    private var text: String {
        // A content coding that couldn't be undone (brotli, say) would only show as noise.
        if let encoding = content.encoding {
            return "\(encoding)-compressed, \(data.count) bytes"
        }
        let limit = 64 * 1024
        let slice = data.prefix(limit)
        if let object = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        // Cutting at the limit can split a multi-byte character; drop up to 3 trailing bytes to recover.
        let decoded = (0...min(3, slice.count)).lazy.compactMap { String(data: slice.dropLast($0), encoding: .utf8) }.first
        guard let string = decoded else {
            return "Binary content (\(data.count) bytes)"
        }
        return data.count > limit ? string + "\n… truncated" : string
    }
}

enum RequestFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }
}

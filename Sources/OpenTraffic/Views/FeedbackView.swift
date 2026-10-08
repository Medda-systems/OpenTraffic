import SwiftUI
import OpenTrafficCore

/// Comments people pinned to the shared site, grouped by page.
struct FeedbackView: View {
    let store: AppStore
    let tunnel: TunnelDefinition
    @AppStorage("feedbackShowResolved") private var showResolved = true

    var body: some View {
        let comments = store.collabComments[tunnel.id] ?? []
        let visible = showResolved ? comments : comments.filter { !$0.resolved }
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Toggle("Show Resolved", isOn: $showResolved)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Copy as Markdown", systemImage: "doc.on.doc") { store.copyFeedback(for: tunnel.id, asIssue: false) }
                    .disabled(comments.isEmpty)
                Button("Copy as GitHub Issue", systemImage: "exclamationmark.bubble") { store.copyFeedback(for: tunnel.id, asIssue: true) }
                    .disabled(comments.isEmpty)
                Button("Clear Resolved", systemImage: "trash") {
                    Task { await store.clearResolvedComments(for: tunnel.id) }
                }
                .disabled(!comments.contains(where: \.resolved))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            Divider()
            let errors = store.collabErrors[tunnel.id] ?? []
            if visible.isEmpty && errors.isEmpty {
                ContentUnavailableView {
                    Label(comments.isEmpty ? "No comments yet" : "Everything's resolved", systemImage: "text.bubble")
                } description: {
                    Text(comments.isEmpty
                         ? "People in the session can click Comment in the page's OpenTraffic pill to pin a note to any element. Notes show up here and are kept after the share stops."
                         : "Turn on Show Resolved to see them.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !errors.isEmpty {
                        Section {
                            ForEach(Array(errors.enumerated()), id: \.offset) { _, group in
                                ErrorGroupRow(group: group)
                            }
                        } header: {
                            HStack {
                                Text("Browser errors")
                                Spacer()
                                Button("Clear") { store.clearErrors(for: tunnel.id) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                    }
                    ForEach(pages(visible), id: \.path) { page in
                        Section {
                            ForEach(page.comments) { comment in
                                CommentRow(store: store, tunnelID: tunnel.id, comment: comment)
                            }
                        } header: {
                            HStack(spacing: Spacing.s) {
                                Text(page.path).font(.callout.monospaced())
                                if let title = page.comments.compactMap(\.title).first {
                                    Text(title).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: tunnel.id) { store.loadComments(for: tunnel.id) }
    }

    private func pages(_ comments: [CollabComment]) -> [(path: String, comments: [CollabComment])] {
        var order: [String] = []
        var grouped: [String: [CollabComment]] = [:]
        for comment in comments.sorted(by: { $0.createdAt < $1.createdAt }) {
            if grouped[comment.path] == nil { order.append(comment.path) }
            grouped[comment.path, default: []].append(comment)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

private struct CommentRow: View {
    let store: AppStore
    let tunnelID: UUID
    let comment: CollabComment
    @State private var confirmingDelete = false
    @State private var replying = false
    @State private var reply = ""
    @State private var screenshot: LoadedScreenshot?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            InitialsAvatar(name: comment.author, color: comment.color, size: 26)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Text(comment.author).fontWeight(.semibold)
                    if let label = comment.label {
                        Text("on “\(label)”").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.s)
                    Text(comment.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(comment.text)
                    .textSelection(.enabled)
                    .strikethrough(comment.resolved, color: .secondary)
                    .foregroundStyle(comment.resolved ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let screenshot {
                    Button {
                        NSWorkspace.shared.open(screenshot.url)
                    } label: {
                        Image(nsImage: screenshot.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 360, maxHeight: 220, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                            .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help("Open the full picture")
                    .accessibilityLabel("Screenshot of the pinned element")
                }
                if let environment = comment.environment {
                    Text("\(environment.browser) · \(environment.os) · \(environment.viewport)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !comment.errors.isEmpty {
                    DisclosureGroup("\(comment.errors.count) browser error\(comment.errors.count == 1 ? "" : "s") before this comment") {
                        ForEach(Array(comment.errors.enumerated()), id: \.offset) { _, error in
                            Text(error.message).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                }
                ForEach(comment.replies) { reply in
                    ReplyRow(reply: reply)
                }
                if replying {
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        TextField("Reply", text: $reply, axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(send)
                        HStack {
                            Button("Cancel") { replying = false; reply = "" }
                            Button("Reply", action: send)
                                .buttonStyle(.borderedProminent)
                                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .controlSize(.small)
                    }
                }
                HStack(spacing: Spacing.m) {
                    Button(comment.resolved ? "Reopen" : "Resolve", systemImage: comment.resolved ? "arrow.uturn.backward" : "checkmark.circle") {
                        Task { await store.resolveComment(comment.id, resolved: !comment.resolved, for: tunnelID) }
                    }
                    if !replying {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") { replying = true }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .padding(.vertical, Spacing.xs)
        .opacity(comment.resolved ? 0.75 : 1)
        .task(id: comment.screenshot) { await loadScreenshot() }
        .confirmationDialog("Delete this comment?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await store.deleteComment(comment.id, for: tunnelID) } }
        } message: {
            Text("It disappears for everyone in the session.")
        }
    }

    /// Finds and decodes the screenshot once per attachment, reading the file off the main thread.
    private func loadScreenshot() async {
        guard let attachment = comment.screenshot else { screenshot = nil; return }
        let key = "\(tunnelID)/\(attachment)" as NSString
        if let cached = LoadedScreenshot.cache.object(forKey: key) { screenshot = cached; return }
        guard let url = store.screenshotURL(for: comment, in: tunnelID) else { screenshot = nil; return }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard !Task.isCancelled else { return }
        guard let data, let image = NSImage(data: data) else { screenshot = nil; return }
        let loaded = LoadedScreenshot(url: url, image: image)
        LoadedScreenshot.cache.setObject(loaded, forKey: key)
        screenshot = loaded
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        replying = false
        Task { await store.replyToComment(comment.id, text: text, for: tunnelID) }
    }
}

/// A comment's decoded screenshot, cached by share and attachment id so rows don't reload it.
@MainActor
private final class LoadedScreenshot {
    static let cache: NSCache<NSString, LoadedScreenshot> = {
        let cache = NSCache<NSString, LoadedScreenshot>()
        cache.countLimit = 100
        return cache
    }()

    let url: URL
    let image: NSImage

    init(url: URL, image: NSImage) {
        self.url = url
        self.image = image
    }
}

private struct ReplyRow: View {
    let reply: CollabReply

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            InitialsAvatar(name: reply.author, color: reply.color, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(reply.author).font(.callout.weight(.semibold))
                    if let agent = reply.agent {
                        Text(agent == reply.author ? "App" : agent)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(reply.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(reply.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, Spacing.s)
    }
}

private struct ErrorGroupRow: View {
    let group: CollabErrorGroup

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: group.kind == .network ? "network.slash" : "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            Text("×\(group.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts = [group.paths.joined(separator: ", ")]
        if let source = group.source { parts.append(source) }
        parts.append(group.lastAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

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
            if store.agentCommandIsSet {
                AgentBar(store: store, tunnel: tunnel)
                Divider()
            }
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
    @FocusState private var replyFocused: Bool
    @State private var screenshot: LoadedScreenshot?
    @State private var afterScreenshot: LoadedScreenshot?

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
                if !comment.edits.isEmpty {
                    SuggestedEditsView(edits: comment.edits)
                }
                if let context = comment.context, context.component != nil || context.source != nil {
                    Text([context.component, context.source].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(context.selector.map { "Where it comes from in the code\n\($0)" } ?? "Where it comes from in the code")
                }
                CommentStatus(store: store, tunnelID: tunnelID, comment: comment)
                if screenshot != nil || afterScreenshot != nil {
                    CommentPicture(before: screenshot, after: afterScreenshot)
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
                            .focused($replyFocused)
                            .onAppear { replyFocused = true }
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
                    if store.agentCommandIsSet, !comment.resolved, store.agentClaims.claim(share: tunnelID, comment: comment.id) == nil,
                       !store.isQueuedForAgent(comment.id, in: tunnelID) {
                        Button { store.sendToAgent(comment.id, for: tunnelID) } label: {
                            Label { Text("Send to \(store.agentClientName)") } icon: { AgentMark(name: store.agentClientName, size: 13) }
                        }
                        .help("Run the agent command for this comment")
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .padding(.vertical, Spacing.xs)
        .opacity(comment.resolved ? 0.75 : 1)
        .task(id: comment.screenshot) { screenshot = await load(after: false) }
        .task(id: comment.afterScreenshot) { afterScreenshot = await load(after: true) }
        .confirmationDialog("Delete this comment?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await store.deleteComment(comment.id, for: tunnelID) } }
        } message: {
            Text("It disappears for everyone in the session.")
        }
    }

    /// Finds and decodes a picture once per attachment, reading the file off the main thread.
    private func load(after: Bool) async -> LoadedScreenshot? {
        guard let attachment = after ? comment.afterScreenshot : comment.screenshot else { return nil }
        let key = "\(tunnelID)/\(attachment)" as NSString
        if let cached = LoadedScreenshot.cache.object(forKey: key) { return cached }
        guard let url = store.screenshotURL(for: comment, in: tunnelID, after: after) else { return nil }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return nil }
        let loaded = LoadedScreenshot(url: url, image: image)
        LoadedScreenshot.cache.setObject(loaded, forKey: key)
        return loaded
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        replying = false
        Task { await store.replyToComment(comment.id, text: text, for: tunnelID) }
    }
}

/// Who is working on a comment, or who fixed it and whether the commenter agreed.
private struct CommentStatus: View {
    let store: AppStore
    let tunnelID: UUID
    let comment: CollabComment

    var body: some View {
        if !comment.resolved, let claim = store.agentClaims.claim(share: tunnelID, comment: comment.id) {
            Label {
                Text("\(claim.agent) is working on this") + Text(claim.progress.map { " · \($0)" } ?? "").foregroundStyle(.secondary)
            } icon: {
                AgentMark(name: claim.agent, size: 12)
            }
            .font(.caption)
            .foregroundStyle(AgentMark.color(for: claim.agent))
        } else if !comment.resolved, store.isQueuedForAgent(comment.id, in: tunnelID) {
            let agent = store.agentRuns[tunnelID]?.client ?? store.agentClientName
            Label { Text("Waiting for \(agent)") } icon: { AgentMark(name: agent, size: 12) }
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if comment.resolved, let by = comment.resolvedBy {
            Label {
                Text(comment.resolvedByAuthor ? "Resolved by \(by), who wrote it" : "Resolved by \(by)")
                    + Text(comment.confirmed ? " · \(comment.author) confirmed the fix" : "")
            } icon: {
                if comment.resolvedByAgent, !comment.confirmed {
                    AgentMark(name: by, size: 12)
                } else {
                    Image(systemName: comment.confirmed ? "checkmark.seal.fill" : "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(comment.confirmed ? AnyShapeStyle(TunnelDisplayState.online.textTint) : AnyShapeStyle(.secondary))
        }
    }
}

/// The agent command for this share: what it's doing, where it works, and what it printed.
private struct AgentBar: View {
    let store: AppStore
    let tunnel: TunnelDefinition
    @State private var showingOutput = false

    var body: some View {
        let run = store.agentRuns[tunnel.id]
        HStack(spacing: Spacing.s) {
            if run?.state == .running {
                ProgressView().controlSize(.small)
            } else {
                AgentMark(name: run?.client ?? store.agentClientName, size: 15)
            }
            Text(status(run))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.s)
            Button(folderLabel) { store.chooseAgentDirectory(for: tunnel.id) }
                .help("The project folder the agent works in for this share. Click to change.")
                .lineLimit(1)
                .truncationMode(.middle)
            if let run, !run.output.isEmpty {
                Button("Output") { showingOutput = true }
                    .popover(isPresented: $showingOutput, arrowEdge: .bottom) { AgentOutput(run: run) }
            }
            if run?.state == .running {
                Button("Stop", role: .destructive) { store.stopAgentRun(for: tunnel.id) }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xs)
    }

    private var folderLabel: String {
        let path = tunnel.agentDirectory ?? store.detectedProjectDirectory(for: tunnel)?.path
        guard let path else { return "Choose Project Folder…" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func status(_ run: AgentRun?) -> String {
        let waiting = store.agentQueues[tunnel.id]?.count ?? 0
        let more = waiting > 0 ? " (\(waiting) more waiting)" : ""
        switch run?.state {
        case .running?: return "\(run!.client) is working on a comment\(more)…"
        case .finished?: return "\(run!.client) finished \(run!.startedAt.formatted(.relative(presentation: .named)))"
        case .failed(let reason)?: return reason
        case .stopped?: return "Stopped"
        case nil:
            return store.agentRunsAutomatically
                ? "\(store.agentClientName) handles new comments when no agent is watching"
                : "Send comments to \(store.agentClientName) below"
        }
    }
}

private struct AgentOutput: View {
    let run: AgentRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(run.output.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(width: 520, height: 320)
    }
}

/// A comment's picture: the fix once there's a picture of it, with "Hold to see before" for the comment's
/// own, as in the page overlay. Clicking it shows it larger right here, and again, smaller.
private struct CommentPicture: View {
    let before: LoadedScreenshot?
    let after: LoadedScreenshot?
    @State private var holding = false
    @State private var large = false

    var body: some View {
        let pair = before != nil && after != nil
        let showing = holding && pair ? before : after ?? before
        if let showing {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if pair {
                    HStack(spacing: Spacing.s) {
                        Text(holding ? "Before" : "After")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.s)
                        HoldToSeeBefore(holding: $holding)
                    }
                }
                Button {
                    withAnimation(.snappy(duration: 0.25)) { large.toggle() }
                } label: {
                    Image(nsImage: showing.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // Larger: up to twice the picture's own size, so a small element's picture stays sharp.
                        .frame(maxWidth: large ? max(360, showing.image.size.width * 2) : 360, maxHeight: large ? 600 : 220, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(.quaternary))
                }
                .buttonStyle(.plain)
                .help(large ? "Show it smaller" : "Show it larger")
                .accessibilityLabel(holding && pair ? "Picture of the element before the fix"
                    : pair ? "Picture of the element after the fix" : "Picture of the commented element")
                .accessibilityHint(large ? "Shows it smaller" : "Shows it larger")
            }
            .frame(maxWidth: large ? .infinity : 360, alignment: .leading)
        }
    }
}

/// Shows the picture from before the fix for as long as it's held.
private struct HoldToSeeBefore: View {
    @Binding var holding: Bool

    var body: some View {
        Text("Hold to see before")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(holding ? Color.white : Color.primary)
            .background(holding ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, pressing: { holding = $0 }, perform: {})
            .help("Shows the page as it was before the fix while you hold it")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Before the fix")
            .accessibilityValue(holding ? "Showing before" : "Showing after")
            .accessibilityAction { holding.toggle() }
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
            if let agent = reply.agent {
                AgentAvatar(name: agent, size: 18)
            } else {
                InitialsAvatar(name: reply.author, color: reply.color, size: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(reply.author).font(.callout.weight(.semibold))
                    if let agent = reply.agent {
                        // As in the page overlay.
                        Text(agent == reply.author ? "Agent" : "Agent · \(agent)")
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
        let time = group.lastAt.formatted(date: .omitted, time: .shortened)
        return group.location.isEmpty ? time : "\(group.location) · \(time)"
    }
}

/// Changes a commenter suggested by editing the page: old → new.
struct SuggestedEditsView: View {
    let edits: [CollabSuggestedEdit]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Suggested edit", systemImage: "pencil.line")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                (Text(edit.property.map { "\($0): " } ?? "").foregroundStyle(.secondary)
                    + Text(edit.old).strikethrough().foregroundStyle(.secondary)
                    + Text(edit.old.isEmpty ? "" : " → ")
                    + Text(edit.new).fontWeight(.semibold))
                    .font(edit.kind == .style ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

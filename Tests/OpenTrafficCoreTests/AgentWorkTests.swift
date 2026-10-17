import Foundation
import Testing
@testable import OpenTrafficCore

// Agents at work on comments, fixes the commenter hears about, and the agent command.

private func decode(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

private func messages(_ outgoing: [CollabRoom.Outgoing], for id: String, in room: CollabRoom) -> [[String: Any]] {
    outgoing.filter { room.includes($0.target, id) }.map { decode($0.text) }
}

/// A room with the host on /, a commenter (overlay "client-ada-1") and a bystander on /pricing, and one
/// comment by the commenter on /pricing. Returns the room and the comment's id.
private func roomWithComment() throws -> (CollabRoom, String) {
    var room = CollabRoom()
    let start = Date(timeIntervalSince1970: 1_000)
    _ = room.connect(isHost: true, id: "host")
    _ = room.connect(isHost: false, id: "ada")
    _ = room.connect(isHost: false, id: "sam")
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: "host", now: start)
    _ = room.receive(#"{"type":"hello","name":"Ada","path":"/pricing","client":"client-ada-1"}"#, from: "ada", now: start)
    _ = room.receive(#"{"type":"hello","name":"Sam","path":"/pricing","client":"client-sam-1"}"#, from: "sam", now: start)
    _ = room.receive(##"{"type":"comment","text":"Button is cut off","path":"/pricing","x":0.5,"y":120,"anchor":"#cta","rx":0.5,"ry":0.5}"##, from: "ada", now: start)
    let comment = try #require(room.comments.first)
    return (room, comment.id)
}

// MARK: Fixes

@Test func resolvingRecordsWhoAndTellsOnlyTheCommenterItsTheirs() throws {
    var (room, id) = try roomWithComment()
    let output = room.resolveComment(id, resolved: true, by: "Claude Code", agent: true, now: Date(timeIntervalSince1970: 2_000))

    let comment = try #require(room.comments.first)
    #expect(comment.resolvedBy == "Claude Code")
    #expect(comment.resolvedByAgent)
    #expect(!comment.resolvedByAuthor)
    #expect(comment.resolvedAt == Date(timeIntervalSince1970: 2_000))

    let forAda = try #require(messages(output, for: "ada", in: room).first { $0["type"] as? String == "comment" }?["comment"] as? [String: Any])
    #expect(forAda["mine"] as? Bool == true)
    #expect(forAda["resolvedBy"] as? String == "Claude Code")
    #expect(forAda["resolvedByAgent"] as? Bool == true)
    let forSam = try #require(messages(output, for: "sam", in: room).first { $0["type"] as? String == "comment" }?["comment"] as? [String: Any])
    #expect(forSam["mine"] == nil)
}

@Test func onlyTheCommenterConfirmsAndReopeningForgetsTheFix() throws {
    var (room, id) = try roomWithComment()
    _ = room.resolveComment(id, resolved: true, by: "Claude Code", agent: true)
    let later = Date().addingTimeInterval(10)

    #expect(room.receive(#"{"type":"confirm","id":"\#(id)"}"#, from: "sam", now: later).isEmpty)
    #expect(room.receive(#"{"type":"confirm","id":"\#(id)"}"#, from: "host", now: later).isEmpty)
    #expect(room.comments.first?.confirmed == false)
    #expect(!room.receive(#"{"type":"confirm","id":"\#(id)"}"#, from: "ada", now: later).isEmpty)
    #expect(room.comments.first?.confirmed == true)

    _ = room.receive(#"{"type":"resolve","id":"\#(id)","resolved":false}"#, from: "ada", now: later.addingTimeInterval(1))
    let reopened = try #require(room.comments.first)
    #expect(!reopened.resolved)
    #expect(!reopened.confirmed)
    #expect(reopened.resolvedBy == nil)
    #expect(reopened.resolvedAt == nil)
}

@Test func theCommenterResolvingTheirOwnCommentIsNoNews() throws {
    var (room, id) = try roomWithComment()
    let output = room.receive(#"{"type":"resolve","id":"\#(id)","resolved":true}"#, from: "ada", now: Date().addingTimeInterval(10))
    #expect(room.comments.first?.resolvedByAuthor == true)
    #expect(room.comments.first?.resolvedBy == "Ada")
    #expect(!output.contains { decode($0.text)["type"] as? String == "capture" })
}

@Test func theHostsPageIsAskedForAPictureOfTheFixOnThatPage() throws {
    var (room, id) = try roomWithComment()
    // The host is on another page: nothing to capture yet.
    let resolved = room.resolveComment(id, resolved: true, by: "Claude Code", agent: true)
    #expect(!resolved.contains { decode($0.text)["type"] as? String == "capture" })

    // Arriving on the page, the host's overlay is asked for it; visitors never are.
    let moved = room.receive(#"{"type":"path","path":"/pricing"}"#, from: "host")
    let capture = try #require(messages(moved, for: "host", in: room).first { $0["type"] as? String == "capture" })
    #expect(capture["id"] as? String == id)
    #expect(!messages(moved, for: "ada", in: room).contains { $0["type"] as? String == "capture" })
}

@Test func picturesOfTheFixComeFromTheHostOrTheCommenterAndOnlyOnce() throws {
    var (room, id) = try roomWithComment()
    room.registerAttachment("aaaaaaaaaaaaaaaaaaaaaa", from: "sam")
    room.registerAttachment("bbbbbbbbbbbbbbbbbbbbbb", from: "ada")
    room.registerAttachment("cccccccccccccccccccccc", from: "host")
    let later = Date().addingTimeInterval(10)

    // Not resolved yet.
    #expect(room.receive(#"{"type":"after","id":"\#(id)","screenshot":"bbbbbbbbbbbbbbbbbbbbbb"}"#, from: "ada", now: later).isEmpty)
    _ = room.resolveComment(id, resolved: true, by: "Claude Code", agent: true)
    // A bystander, or someone else's upload.
    #expect(room.receive(#"{"type":"after","id":"\#(id)","screenshot":"aaaaaaaaaaaaaaaaaaaaaa"}"#, from: "sam", now: later).isEmpty)
    #expect(room.receive(#"{"type":"after","id":"\#(id)","screenshot":"cccccccccccccccccccccc"}"#, from: "ada", now: later.addingTimeInterval(3)).isEmpty)
    #expect(!room.receive(#"{"type":"after","id":"\#(id)","screenshot":"bbbbbbbbbbbbbbbbbbbbbb"}"#, from: "ada", now: later.addingTimeInterval(6)).isEmpty)
    #expect(room.comments.first?.afterScreenshot == "bbbbbbbbbbbbbbbbbbbbbb")
    #expect(room.receive(#"{"type":"after","id":"\#(id)","screenshot":"cccccccccccccccccccccc"}"#, from: "host", now: later.addingTimeInterval(9)).isEmpty)

    // Reopening drops the picture.
    _ = room.resolveComment(id, resolved: false)
    #expect(room.comments.first?.afterScreenshot == nil)
    #expect(room.comments.first?.attachments == [])
}

// MARK: Agents in the session

@Test func anAgentAtWorkJoinsTheSessionAtTheCommentsElement() throws {
    var (room, id) = try roomWithComment()
    let since = Date()
    let output = room.setAgentWork([CollabAgentWork(agent: "Claude Code", commentID: id, progress: "Editing Pricing.tsx", since: since)])

    let agent = try #require(room.peers.first { $0.isAgent })
    #expect(agent.name == "Claude Code")
    #expect(agent.path == "/pricing")
    #expect(agent.color == "#D97757") // Claude's own colour
    let join = try #require(messages(output, for: "sam", in: room).first { $0["type"] as? String == "join" }?["peer"] as? [String: Any])
    #expect(join["isAgent"] as? Bool == true)
    #expect((join["at"] as? [String: Any])?["anchor"] as? String == "#cta")
    let comment = try #require(messages(output, for: "ada", in: room).first { $0["type"] as? String == "comment" }?["comment"] as? [String: Any])
    #expect((comment["claim"] as? [String: Any])?["agent"] as? String == "Claude Code")
    #expect((comment["claim"] as? [String: Any])?["progress"] as? String == "Editing Pricing.tsx")

    // Late joiners see the agent in their welcome.
    _ = room.connect(isHost: false, id: "lea")
    let welcome = try #require(messages(room.receive(#"{"type":"hello","path":"/pricing"}"#, from: "lea"), for: "lea", in: room).first)
    #expect((welcome["peers"] as? [[String: Any]])?.contains { $0["isAgent"] as? Bool == true } == true)

    // Same work again: nothing to say.
    #expect(room.setAgentWork([CollabAgentWork(agent: "Claude Code", commentID: id, progress: "Editing Pricing.tsx", since: since)]).isEmpty)
}

@Test func resolvingEndsTheWorkAndTheAgentLeaves() throws {
    var (room, id) = try roomWithComment()
    _ = room.setAgentWork([CollabAgentWork(agent: "Claude Code", commentID: id, since: Date())])
    let agentID = try #require(room.peers.first { $0.isAgent }?.id)

    let output = room.resolveComment(id, resolved: true, by: "Claude Code", agent: true)
    #expect(!room.peers.contains { $0.isAgent })
    #expect(messages(output, for: "sam", in: room).contains { $0["type"] as? String == "leave" && $0["id"] as? String == agentID })
    let comment = try #require(messages(output, for: "ada", in: room).first { $0["type"] as? String == "comment" }?["comment"] as? [String: Any])
    #expect(comment["claim"] == nil)
}

@Test func workOnUnknownOrResolvedCommentsIsIgnored() throws {
    var (room, id) = try roomWithComment()
    _ = room.resolveComment(id, resolved: true)
    #expect(room.setAgentWork([
        CollabAgentWork(agent: "Codex", commentID: id, since: Date()),
        CollabAgentWork(agent: "Codex", commentID: "nope", since: Date()),
    ]).isEmpty)
    #expect(!room.peers.contains { $0.isAgent })
}

// MARK: Claims

@Test func claimsAreExclusiveRenewableAndLapse() throws {
    var book = AgentClaimBook()
    let share = UUID()
    let start = Date(timeIntervalSince1970: 0)
    try book.claim(share: share, comment: "c1", agent: "Claude Code", now: start)
    #expect(throws: AgentClaimBook.ClaimError.claimed(by: "Claude Code")) {
        try book.claim(share: share, comment: "c1", agent: "Codex", now: start.addingTimeInterval(60))
    }
    // Renewing keeps the start, moves the deadline, and updates progress (blank progress keeps the old one).
    let renewed = try book.claim(share: share, comment: "c1", agent: "Claude Code", progress: "  Editing\nHeader.tsx ", now: start.addingTimeInterval(600))
    #expect(renewed.since == start)
    #expect(renewed.progress == "Editing Header.tsx")
    #expect(try book.claim(share: share, comment: "c1", agent: "Claude Code", progress: " ", now: start.addingTimeInterval(601)).progress == "Editing Header.tsx")
    #expect(book.expire(now: start.addingTimeInterval(600 + AgentClaimBook.lease - 1)).isEmpty)
    #expect(book.expire(now: start.addingTimeInterval(601 + AgentClaimBook.lease)).map(\.commentID) == ["c1"])
    #expect(book.claims(share: share).isEmpty)

    // An expired claim no longer blocks anyone.
    try book.claim(share: share, comment: "c2", agent: "Codex", now: start)
    #expect(try book.claim(share: share, comment: "c2", agent: "Cursor", now: start.addingTimeInterval(AgentClaimBook.lease + 1)).agent == "Cursor")
}

@Test func onlyTheClaimingAppReleases() throws {
    var book = AgentClaimBook()
    let share = UUID()
    try book.claim(share: share, comment: "c1", agent: "Claude Code")
    #expect(book.release(share: share, comment: "c1", agent: "Codex") == nil)
    #expect(book.claim(share: share, comment: "c1") != nil)
    #expect(book.release(share: share, comment: "c1", agent: "Claude Code")?.agent == "Claude Code")
    #expect(book.claim(share: share, comment: "c1") == nil)
}

@Test func apiCommentsSayWhereTheyStand() {
    let share = UUID()
    var comment = CollabComment(id: "c1", author: "Ada", color: "#f00", path: "/", text: "Fix", x: 0, y: 0, createdAt: Date())
    #expect(APIComment(comment, shareID: share).status == "open")
    let claim = AgentClaim(shareID: share, commentID: "c1", agent: "Codex", progress: "Looking", since: Date(), expires: .distantFuture)
    let working = APIComment(comment, shareID: share, claim: claim)
    #expect(working.status == "working")
    #expect(working.claimedBy == "Codex")
    #expect(working.progress == "Looking")

    comment.setResolved(true, by: "Codex", agent: true)
    let resolved = APIComment(comment, shareID: share, claim: claim)
    #expect(resolved.status == "resolved")
    #expect(resolved.claimedBy == nil)
    #expect(resolved.resolvedBy == "Codex")
    comment.confirmed = true
    #expect(APIComment(comment, shareID: share).status == "confirmed")
}

@Test func fixDetailsSurviveACodableRoundTripAndOldFilesStillLoad() throws {
    var comment = CollabComment(id: "c1", author: "Ada", color: "#f00", path: "/", text: "Fix", x: 0, y: 0, createdAt: Date(timeIntervalSince1970: 5))
    comment.setResolved(true, by: "Claude Code", agent: true, at: Date(timeIntervalSince1970: 9))
    comment.confirmed = true
    comment.afterScreenshot = "aaaaaaaaaaaaaaaaaaaaaa"
    let decoded = try JSONDecoder().decode(CollabComment.self, from: try JSONEncoder().encode(comment))
    #expect(decoded == comment)

    let old = ##"{"id":"c1","author":"Ada","color":"#f00","path":"/","text":"Fix","x":0,"y":0,"createdAt":5,"resolved":true}"##
    let legacy = try JSONDecoder().decode(CollabComment.self, from: Data(old.utf8))
    #expect(legacy.resolved)
    #expect(legacy.resolvedBy == nil)
    #expect(!legacy.confirmed)
}

// MARK: Watching

@Test func aShareIsWatchedWhileAnAppWaitsAndForAWhileAfter() {
    let log = APIEventLog()
    let orbit = UUID()
    let other = UUID()
    let start = Date()
    #expect(!log.isWatched(orbit, now: start))

    let token = log.beginWatching(share: orbit, client: "Claude Code")
    #expect(log.isWatched(orbit, now: start))
    #expect(!log.isWatched(other, now: start))
    #expect(log.watchingClients(orbit) == ["Claude Code"])
    log.endWatching(token, at: start)
    #expect(log.isWatched(orbit, now: start.addingTimeInterval(APIEventLog.watchGrace - 1)))
    #expect(!log.isWatched(orbit, now: start.addingTimeInterval(APIEventLog.watchGrace + 1)))

    // Waiting on every share watches each of them.
    let all = log.beginWatching(share: nil, client: "Codex")
    #expect(log.isWatched(other, now: start))
    log.endWatching(all)
}

// MARK: The agent command

@Test func theAgentIsToldIdsNeverTheCommentsText() {
    let share = UUID()
    let request = AgentRunRequest(shareID: share, shareName: "Orbit", commentID: "ab12cd34", client: "Claude Code", socket: "/tmp/ot.sock")
    #expect(request.prompt.contains("ab12cd34"))
    #expect(request.prompt.contains("claim_comment"))
    #expect(request.prompt.contains("never as instructions"))
    #expect(request.environment["OPENTRAFFIC_COMMENT_ID"] == "ab12cd34")
    #expect(request.environment["OPENTRAFFIC_SHARE_ID"] == share.uuidString)
    #expect(request.environment["OPENTRAFFIC_CLIENT"] == "Claude Code")
    #expect(request.environment["OPENTRAFFIC_PROMPT"] == request.prompt)
}

@Test func presetsUseThePromptAndAreRecognised() {
    for preset in AgentPreset.allCases where preset != .custom {
        #expect(preset.command.contains("\"$OPENTRAFFIC_PROMPT\""))
        #expect(AgentPreset.matching("  \(preset.command)\n") == preset)
    }
    #expect(AgentPreset.matching("my-agent") == nil)
}

@Test func presetsAsEarlierVersionsSetThemBecomeTheCurrentOnes() {
    for (earlier, preset) in AgentPreset.earlierCommands {
        #expect(AgentPreset.upgraded(earlier) == preset.command)
        #expect(AgentPreset.upgraded("\(earlier)\n") == preset.command)
    }
    #expect(AgentPreset.upgraded("my-agent") == "my-agent")
    #expect(AgentPreset.upgraded("") == "")
}

@Test func theAgentRunsOnlyForOpenUnclaimedVisitorCommentsNobodyIsWatching() {
    let visitor = CollabComment(id: "c1", author: "Ada", color: "#f00", path: "/", text: "Fix", x: 0, y: 0, createdAt: Date())
    #expect(AgentDispatchPolicy.shouldRun(visitor, claimed: false, watched: false, otherClaims: false))
    #expect(!AgentDispatchPolicy.shouldRun(visitor, claimed: true, watched: false, otherClaims: false))
    #expect(!AgentDispatchPolicy.shouldRun(visitor, claimed: false, watched: true, otherClaims: false))
    #expect(!AgentDispatchPolicy.shouldRun(visitor, claimed: false, watched: false, otherClaims: true))
    #expect(!AgentDispatchPolicy.shouldRun(nil, claimed: false, watched: false, otherClaims: false))
    var resolved = visitor
    resolved.resolved = true
    #expect(!AgentDispatchPolicy.shouldRun(resolved, claimed: false, watched: false, otherClaims: false))
    let host = CollabComment(id: "c2", author: "Host", color: "#f00", path: "/", text: "Note", x: 0, y: 0, createdAt: Date(), fromHost: true)
    #expect(!AgentDispatchPolicy.shouldRun(host, claimed: false, watched: false, otherClaims: false))
}

@Test func aProcessDirectoryIsWhereItRuns() throws {
    let here = try #require(ProcessDirectory.of(getpid()))
    #expect(here.standardizedFileURL.path == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
    #expect(ProcessDirectory.of(-1) == nil)
}

// MARK: Over the API

@Test func claimingOverMCPIsExclusiveAndShowsInFeedback() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let first = try await api.mcp(
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"claim_comment","arguments":{"share":"Orbit","comment_id":"c1","progress":"Looking"}}}"#,
        headers: ["X-OpenTraffic-Client": "Claude Code"]
    )
    let claimed = try #require(((try JSONSerialization.jsonObject(with: first.0) as? [String: Any])?["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
    #expect(claimed["status"] as? String == "working")
    #expect(claimed["claimedBy"] as? String == "Claude Code")

    let second = try await api.mcp(
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claim_comment","arguments":{"share":"Orbit","comment_id":"c1"}}}"#,
        headers: ["X-OpenTraffic-Client": "Codex"]
    )
    let refused = try #require((try JSONSerialization.jsonObject(with: second.0) as? [String: Any])?["result"] as? [String: Any])
    #expect(refused["isError"] as? Bool == true)

    let released = try await api.mcp(
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"release_comment","arguments":{"share":"Orbit","comment_id":"c1"}}}"#,
        headers: ["X-OpenTraffic-Client": "Claude Code"]
    )
    let open = try #require(((try JSONSerialization.jsonObject(with: released.0) as? [String: Any])?["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
    #expect(open["status"] as? String == "open")
}

@Test func claimingOverRESTAndAskingForThePictureOfTheFix() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let claimed = try await api.object("POST", "/v1/shares/Orbit/comments/c1/claim", json: #"{"progress":"Editing"}"#)
    #expect(claimed["status"] as? String == "working")
    #expect(claimed["progress"] as? String == "Editing")
    let released = try await api.object("DELETE", "/v1/shares/Orbit/comments/c1/claim")
    #expect(released["status"] as? String == "open")

    let (_, missing) = try await api.request("GET", "/v1/shares/Orbit/comments/c1/screenshot?which=after")
    #expect(missing.statusCode == 404)
    let (_, wrong) = try await api.request("GET", "/v1/shares/Orbit/comments/c1/screenshot?which=later")
    #expect(wrong.statusCode == 400)
    let (_, before) = try await api.request("GET", "/v1/shares/Orbit/comments/c1/screenshot?which=before")
    #expect(before.statusCode == 200)
}

@Test func waitingForFeedbackCountsAsWatching() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    #expect(!api.events.isWatched(FakeAPIBackend.orbitID))
    let waiting = Task { _ = try await api.callTool("wait_for_feedback", #"{"share":"Orbit","timeout_seconds":2}"#) }
    #expect(await eventually { api.events.isWatched(FakeAPIBackend.orbitID) })
    try await waiting.value
    // Still counts for a while after, as the app handles what it got.
    #expect(api.events.isWatched(FakeAPIBackend.orbitID))
}

// MARK: Running the agent command

extension ProcessSpawningTests {
/// What a run printed and how it ended.
private final class RunRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var ending: (status: Int32, signalled: Bool)?

    func print(_ chunk: String) { lock.withLock { text += chunk } }
    func end(_ status: Int32, _ signalled: Bool) { lock.withLock { ending = (status, signalled) } }
    var output: String { lock.withLock { text } }
    var ended: (status: Int32, signalled: Bool)? { lock.withLock { ending } }
}

private func run(_ command: String, in directory: URL = FileManager.default.temporaryDirectory, environment: [String: String] = [:]) throws -> (AgentProcess, RunRecord) {
    let record = RunRecord()
    let process = AgentProcess(command: command, directory: directory, environment: environment, path: "/usr/bin:/bin")
    try process.start(output: { record.print($0) }, exit: { record.end($0, $1) })
    return (process, record)
}

@Test func theAgentCommandRunsInTheProjectWithTheCommentsIds() async throws {
    let project = FileManager.default.temporaryDirectory.appending(path: "ot-agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let request = AgentRunRequest(shareID: UUID(), shareName: "Orbit", commentID: "ab12cd34", client: "Claude Code", socket: "/tmp/ot.sock")
    let (_, record) = try run(#"pwd; echo "$OPENTRAFFIC_COMMENT_ID $OPENTRAFFIC_CLIENT"; echo oops >&2; exit 3"#, in: project, environment: request.environment)

    #expect(await eventually { record.ended != nil })
    #expect(record.ended?.status == 3)
    #expect(record.ended?.signalled == false)
    let lines = record.output.split(separator: "\n").map(String.init)
    #expect(URL(fileURLWithPath: lines.first ?? "").resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path)
    #expect(lines.contains("ab12cd34 Claude Code"))
    #expect(lines.contains("oops"))
}

// Each preset needs a way to the comment that its own lockdown leaves open: the `opentraffic` command's
// feedback commands, or (Codex) a sandbox that lets out only OpenTraffic's socket.
@Test func presetsLeaveTheAgentAWayToOpenTraffic() async throws {
    let socket = "/Users/Ada Lovelace/Library/Application Support/OpenTraffic/opentraffic.sock"
    // Stand-ins for the agents that print what they were given. Codex's sandbox keeps the web out.
    let stubs = #"claude() { print -rl -- "$@"; }; codex() { [[ $1 == sandbox ]] && return 7; print -rl -- "$@"; }; opencode() { print -r -- "$OPENCODE_CONFIG_CONTENT"; }; "#
    func output(_ preset: AgentPreset) async throws -> [String] {
        let request = AgentRunRequest(shareID: UUID(), shareName: "Orbit", commentID: "ab12cd34", client: preset.clientName, socket: socket)
        let (_, record) = try run(stubs + preset.command, environment: request.environment)
        #expect(await eventually { record.ended != nil })
        #expect(record.ended?.status == 0)
        return record.output.split(separator: "\n").map(String.init)
    }

    let claude = try await output(.claudeCode)
    #expect(claude.firstIndex(of: "--permission-mode").map { claude[$0 + 1] } == "dontAsk")
    let allowed = try #require(claude.firstIndex(of: "--allowedTools").map { claude[$0 + 1].split(separator: ",").map(String.init) })
    #expect(allowed.filter { $0.hasPrefix("Bash") } == AgentPreset.feedbackCommands.map { "Bash(opentraffic \($0) *)" })
    #expect(allowed.contains("mcp__opentraffic"))
    #expect(claude.firstIndex(of: "--disallowedTools").map { claude[$0 + 1] } == "WebFetch,WebSearch,Read(./.env),Read(./.env.*)")

    let codex = try await output(.codex)
    #expect(codex.first == "exec")
    #expect(codex.contains("features.network_proxy=true"))
    #expect(codex.contains("allow_login_shell=false"))
    #expect(codex.contains(#"permissions.opentraffic.extends=":workspace""#))
    #expect(codex.contains(#"permissions.opentraffic.network.unix_sockets={"\#(socket)"="allow"}"#))
    #expect(codex.last == AgentRunRequest(shareID: UUID(), shareName: "Orbit", commentID: "ab12cd34", client: "Codex", socket: socket).prompt.split(separator: "\n").last.map(String.init))

    let opencode = try #require(JSONSerialization.jsonObject(with: Data((try await output(.opencode).first ?? "").utf8)) as? [String: Any])
    let permission = try #require(opencode["permission"] as? [String: Any])
    var bash = ["*": "deny"]
    for command in AgentPreset.feedbackCommands { bash["opentraffic \(command) *"] = "allow" }
    #expect(permission["bash"] as? [String: String] == bash)
    #expect(permission["webfetch"] as? String == "deny")
    #expect(permission["external_directory"] as? [String: String] == ["\(AgentPreset.screenshotFolder)/**": "allow"])
}

// Codex ignores settings it doesn't know: if its sandbox ever lets the web through, Codex isn't started.
@Test func codexDoesntStartWhenItsSandboxLetsTheWebThrough() async throws {
    let stub = #"codex() { [[ $1 == sandbox ]] && return 0; echo STARTED; }; "#
    let request = AgentRunRequest(shareID: UUID(), shareName: "Orbit", commentID: "ab12cd34", client: "Codex", socket: "/tmp/ot.sock")
    let (_, record) = try run(stub + AgentPreset.codex.command, environment: request.environment)
    #expect(await eventually { record.ended != nil })
    #expect(record.ended?.status == 1)
    #expect(!record.output.contains("STARTED"))
    #expect(record.output.contains("let the web through"))
}

@Test func theAgentIsToldTheOpentrafficCommandsItMayRun() throws {
    let request = AgentRunRequest(shareID: UUID(), shareName: "Orbit", commentID: "ab12cd34", client: "opencode", socket: "/x")
    let commands = request.prompt.matches(of: try Regex<(Substring, Substring)>(#"`opentraffic (\w+) "#)).map { String($0.1) }
    #expect(Set(commands) == Set(AgentPreset.feedbackCommands))
    #expect(request.prompt.contains("-o \(AgentPreset.screenshotFolder)/`"))
}

@Test func stoppingTheAgentStopsWhatItStarted() async throws {
    let marker = "ot-agent-sleep-\(UUID().uuidString.prefix(8))"
    // A child the shell can't replace itself with, as an agent CLI with helpers would be.
    let (process, record) = try run("sh -c 'exec -a \(marker) sleep 60' & wait")
    #expect(await eventually { process.isRunning })
    try await Task.sleep(for: .milliseconds(300))
    process.stop()
    #expect(await eventually { record.ended != nil })
    let leftover = Process()
    leftover.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    leftover.arguments = ["-f", marker]
    leftover.standardOutput = FileHandle.nullDevice
    try leftover.run()
    leftover.waitUntilExit()
    #expect(leftover.terminationStatus == 1) // nothing matched
}

@Test func stoppingASingleCommandEndsItBySignal() async throws {
    let (process, record) = try run("sleep 60")
    #expect(await eventually { process.isRunning })
    process.stop()
    #expect(await eventually { record.ended != nil })
    #expect(record.ended?.signalled == true)
}
}

@Test func agentsAreKnownByTheNameTheyGoBy() {
    #expect(AgentBrand(agentName: "Claude Code") == .claude)
    #expect(AgentBrand(agentName: "codex") == .codex)
    #expect(AgentBrand(agentName: "cursor-agent") == .cursor)
    #expect(AgentBrand(agentName: "opencode") == .opencode) // not Codex
    #expect(AgentBrand(agentName: "my-agent.py") == nil)
    #expect(AgentBrand.claude.color == "#D97757")
    #expect(AgentBrand.codex.color == "#3941FF")
    #expect(AgentBrand.cursor.color == nil)

    var room = CollabRoom()
    _ = room.connect(isHost: false, id: "ada")
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: "ada")
    _ = room.receive(#"{"type":"comment","text":"Fix","path":"/","x":0.5,"y":10}"#, from: "ada")
    let id = room.comments[0].id
    _ = room.setAgentWork([CollabAgentWork(agent: "opencode", commentID: id, since: Date())])
    #expect(room.peers.first { $0.isAgent }?.color == CollabRoom.agentColor)
}

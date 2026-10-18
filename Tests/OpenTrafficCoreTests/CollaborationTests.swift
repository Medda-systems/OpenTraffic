import Foundation
import Testing
@testable import OpenTrafficCore

// MARK: HTML injection

private func inject(_ chunks: [String], snippet: String = "<S>") -> String {
    var injector = HTMLInjector(headEnd: snippet)
    var output: [UInt8] = []
    for chunk in chunks { output += injector.feed(Array(chunk.utf8)) }
    output += injector.finish()
    return String(decoding: output, as: UTF8.self)
}

@Test func injectsBeforeHeadCloseCaseInsensitively() {
    #expect(inject(["<html><HEAD><title>x</title></HeAd><body>hi</body></html>"]) == "<html><HEAD><title>x</title><S></HeAd><body>hi</body></html>")
}

@Test func findsAMarkerSplitAcrossChunks() {
    #expect(inject(["<html><head><title>x</title></he", "ad><body>", "hi</body>"]) == "<html><head><title>x</title><S></head><body>hi</body>")
}

@Test func injectsBeforeBodyWithoutHeadAndAtTheEndWithoutEither() {
    #expect(inject(["<p>no head</p><body class=a>x</body>"]) == "<p>no head</p><S><body class=a>x</body>")
    #expect(inject(["just ", "text"]) == "just text<S>")
    #expect(inject([]) == "<S>")
}

@Test func streamsEverythingAfterTheInsertionPoint() {
    var injector = HTMLInjector(headEnd: "<S>")
    #expect(injector.feed(Array("<head>".utf8)).isEmpty)
    #expect(String(decoding: injector.feed(Array("</head><body>".utf8)), as: UTF8.self) == "<head><S></head><body>")
    #expect(String(decoding: injector.feed(Array("more".utf8)), as: UTF8.self) == "more")
    #expect(injector.finish().isEmpty)
}

@Test func injectedOutputGrowsByExactlyTheSnippet() {
    let page = "<html><head></head><body>\(String(repeating: "x", count: 5000))</body></html>"
    #expect(inject([page], snippet: CollabProxy.scriptTag).utf8.count == page.utf8.count + CollabProxy.scriptTag.utf8.count)
}

// MARK: Room

private func decode(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

private func messages(_ outgoing: [CollabRoom.Outgoing], for id: String, in room: CollabRoom) -> [[String: Any]] {
    outgoing.filter { room.includes($0.target, id) }.map { decode($0.text) }
}

@Test func helloWelcomesAndAnnouncesPeers() throws {
    var room = CollabRoom()
    let host = room.connect(isHost: true, id: "host")!
    let guest = room.connect(isHost: false, id: "guest")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: host)
    let output = room.receive(#"{"type":"hello","name":"Ada","path":"/docs"}"#, from: guest)

    let welcome = try #require(messages(output, for: guest, in: room).first)
    #expect(welcome["type"] as? String == "welcome")
    #expect((welcome["you"] as? [String: Any])?["name"] as? String == "Ada")
    #expect((welcome["peers"] as? [[String: Any]])?.first?["isHost"] as? Bool == true)
    let join = try #require(messages(output, for: host, in: room).first)
    #expect(join["type"] as? String == "join")
    #expect(room.peers.map(\.name) == ["Host", "Ada"])
}

@Test func messagesBeforeHelloAndUnknownTypesAreIgnored() throws {
    var room = CollabRoom()
    let id = room.connect(isHost: false)!
    #expect(room.receive(#"{"type":"cursor","x":0.5,"y":10}"#, from: id).isEmpty)
    #expect(room.peers.isEmpty)
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: id)
    #expect(room.receive(#"{"type":"explode"}"#, from: id).isEmpty)
    #expect(room.receive("not json", from: id).isEmpty)
}

@Test func cursorsOnlyReachPeersOnTheSamePage() throws {
    var room = CollabRoom()
    let a = room.connect(isHost: false, id: "a")!
    let b = room.connect(isHost: false, id: "b")!
    let c = room.connect(isHost: false, id: "c")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: a)
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: b)
    _ = room.receive(#"{"type":"hello","path":"/other"}"#, from: c)
    let output = room.receive(##"{"type":"cursor","x":2,"y":40,"anchor":"#main","rx":0.25,"ry":-1}"##, from: a)
    let toB = messages(output, for: b, in: room)
    #expect(toB.count == 1)
    #expect(toB.first?["x"] as? Double == 1) // clamped
    #expect(toB.first?["ry"] as? Double == 0)
    #expect(messages(output, for: c, in: room).isEmpty)
    #expect(messages(output, for: a, in: room).isEmpty)
}

@Test func onlyTheHostLeadsAndLeadingEndsWhenTheHostLeaves() throws {
    var room = CollabRoom()
    let host = room.connect(isHost: true, id: "host")!
    let guest = room.connect(isHost: false, id: "guest")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: host)
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: guest)

    #expect(room.receive(#"{"type":"lead","on":true}"#, from: guest).isEmpty)
    #expect(room.receive(#"{"type":"scroll","ratio":0.5}"#, from: host).isEmpty) // not leading yet
    let started = messages(room.receive(#"{"type":"lead","on":true}"#, from: host), for: guest, in: room)
    #expect(started.first?["on"] as? Bool == true)
    let navigated = messages(room.receive(#"{"type":"path","path":"/pricing?plan=pro"}"#, from: host), for: guest, in: room)
    // Followers get the page, not its query string: that can carry tokens.
    #expect(navigated.contains { $0["type"] as? String == "lead" && $0["path"] as? String == "/pricing" })
    let scrolled = messages(room.receive(#"{"type":"scroll","ratio":0.4}"#, from: host), for: guest, in: room)
    #expect(scrolled.first?["ratio"] as? Double == 0.4)

    let left = messages(room.disconnect(host), for: guest, in: room)
    #expect(left.contains { $0["type"] as? String == "leave" })
    #expect(left.contains { $0["type"] as? String == "lead" && $0["on"] as? Bool == false })
    #expect(!room.leading)
}

@Test func welcomeCarriesTheLeadPositionForLateJoiners() throws {
    var room = CollabRoom()
    let host = room.connect(isHost: true, id: "host")!
    _ = room.receive(#"{"type":"hello","path":"/a"}"#, from: host)
    _ = room.receive(#"{"type":"lead","on":true}"#, from: host)
    _ = room.receive(#"{"type":"scroll","ratio":0.75}"#, from: host)
    let late = room.connect(isHost: false, id: "late")!
    let welcome = try #require(messages(room.receive(#"{"type":"hello","path":"/"}"#, from: late), for: late, in: room).first)
    #expect(welcome["leading"] as? Bool == true)
    #expect(welcome["path"] as? String == "/a")
    #expect(welcome["ratio"] as? Double == 0.75)
}

@Test func pathsMustStayOnTheSite() {
    #expect(CollabRoom.validPath("/") == "/")
    #expect(CollabRoom.validPath("/docs?q=1") == "/docs")
    #expect(CollabRoom.validPath("/reset#token=abc") == "/reset")
    #expect(CollabRoom.validPath("/.//evil.example") == nil)
    #expect(CollabRoom.validPath("/a/%2E%2E/b") == nil)
    #expect(CollabRoom.validPath("/a//b") == nil)
    #expect(CollabRoom.validPath("//evil.example") == nil)
    #expect(CollabRoom.validPath("/\\evil.example") == nil)
    #expect(CollabRoom.validPath("/a\\b") == nil)
    #expect(CollabRoom.validPath("https://evil.example") == nil)
    #expect(CollabRoom.validPath("/a\nb") == nil)
    #expect(CollabRoom.validPath("/" + String(repeating: "a", count: 600)) == nil)
}

@Test func namesAreCleanedAndLimited() {
    #expect(CollabRoom.sanitizedName("  Ada\u{202E}  ") == "Ada")
    #expect(CollabRoom.sanitizedName("\u{200B}\n") == nil)
    #expect(CollabRoom.sanitizedName(String(repeating: "x", count: 50))?.count == 32)
    #expect(CollabRoom.sanitizedName(42) == nil)
}

@Test func floodsAndOversizedFramesAreDropped() throws {
    var room = CollabRoom()
    let a = room.connect(isHost: false, id: "a")!
    let b = room.connect(isHost: false, id: "b")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: a)
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: b)
    let now = Date()
    var delivered = 0
    for _ in 0..<100 {
        delivered += room.receive(#"{"type":"cursor","x":0.5,"y":1}"#, from: a, now: now).count
    }
    #expect(delivered == CollabRoom.maximumMessagesPerSecond - 1) // the hello counted too
    let big = #"{"type":"rename","name":""# + String(repeating: "x", count: 5000) + #""}"#
    #expect(room.receive(big, from: b, now: now.addingTimeInterval(2)).isEmpty)
}

@Test func roomStopsAcceptingWhenFullButKeepsAPlaceForTheHost() {
    var room = CollabRoom()
    for _ in 0..<(CollabRoom.maximumPeers - 1) {
        let id = room.connect(isHost: false)
        #expect(id != nil)
    }
    #expect(room.connect(isHost: false) == nil)
    #expect(room.connect(isHost: true) != nil)
}

// MARK: Comments and pointing

private let aliceClient = "client-alice-123456"

private func roomWithHostAndTwoGuests() -> (CollabRoom, host: String, alice: String, bob: String) {
    var room = CollabRoom(hostName: "Sam")
    let host = room.connect(isHost: true, id: "host")!
    let alice = room.connect(isHost: false, id: "alice")!
    let bob = room.connect(isHost: false, id: "bob")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: host)
    _ = room.receive(#"{"type":"hello","name":"Alice","path":"/","client":"\#(aliceClient)"}"#, from: alice)
    _ = room.receive(#"{"type":"hello","name":"Bob","path":"/pricing","client":"client-bob-1234567"}"#, from: bob)
    return (room, host, alice, bob)
}

@Test func hostNameComesFromSettings() {
    var room = CollabRoom(hostName: "  Sam ")
    let host = room.connect(isHost: true, id: "h")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: host)
    #expect(room.peers.first?.name == "Sam")
    var unnamed = CollabRoom(hostName: "")
    let other = unnamed.connect(isHost: true, id: "h")!
    _ = unnamed.receive(#"{"type":"hello","path":"/"}"#, from: other)
    #expect(unnamed.peers.first?.name == "Host")
}

@Test func commentsReachEveryoneAndOnlyAuthorOrHostMayDelete() throws {
    var (room, host, alice, bob) = roomWithHostAndTwoGuests()
    let now = Date()
    let output = room.receive(##"{"type":"comment","text":" Make this bigger\nplease ","path":"/","x":0.5,"y":200,"anchor":"#cta","rx":0.5,"ry":0.5,"label":"  Start\n free ","title":"Home"}"##, from: alice, now: now)
    let comment = try #require(room.comments.first)
    #expect(comment.text == "Make this bigger\nplease")
    #expect(comment.label == "Start free")
    #expect(comment.author == "Alice")

    func canDelete(_ id: String) -> Bool? {
        messages(output, for: id, in: room).first.flatMap { ($0["comment"] as? [String: Any])?["canDelete"] as? Bool }
    }
    #expect(canDelete(alice) == true)
    #expect(canDelete(host) == true)
    #expect(canDelete(bob) == false) // other page, still told; can't delete

    // Too soon for another comment.
    #expect(room.receive(#"{"type":"comment","text":"again","path":"/","x":0,"y":0}"#, from: alice, now: now.addingTimeInterval(1)).isEmpty)

    // Bob can resolve but not delete.
    _ = room.receive(#"{"type":"resolve","id":"\#(comment.id)","resolved":true}"#, from: bob)
    #expect(room.comments.first?.resolved == true)
    #expect(room.receive(#"{"type":"delete","id":"\#(comment.id)"}"#, from: bob).isEmpty)
    #expect(room.comments.count == 1)

    // Alice reloads (new connection, same client id) and deletes her comment.
    _ = room.disconnect(alice)
    let again = room.connect(isHost: false, id: "alice2")!
    let welcome = messages(room.receive(#"{"type":"hello","path":"/","client":"\#(aliceClient)"}"#, from: again), for: again, in: room).first
    #expect(((welcome?["comments"] as? [[String: Any]])?.first?["canDelete"] as? Bool) == true)
    let deleted = room.receive(#"{"type":"delete","id":"\#(comment.id)"}"#, from: again)
    #expect(room.comments.isEmpty)
    #expect(messages(deleted, for: host, in: room).first?["type"] as? String == "comment-delete")
}

@Test func commentsAreValidated() {
    var (room, _, alice, _) = roomWithHostAndTwoGuests()
    #expect(room.receive(#"{"type":"comment","text":"   ","path":"/","x":0,"y":0}"#, from: alice).isEmpty)
    let long = String(repeating: "x", count: 1001)
    #expect(room.receive(#"{"type":"comment","text":"\#(long)","path":"/","x":0,"y":0}"#, from: alice).isEmpty)
    #expect(room.receive(#"{"type":"comment","text":"hi","path":"//evil","x":0,"y":0}"#, from: alice).isEmpty)
    #expect(room.comments.isEmpty)
}

@Test func pointsReachEveryoneOnThePageIncludingTheSender() {
    var (room, host, alice, bob) = roomWithHostAndTwoGuests()
    let now = Date()
    let output = room.receive(##"{"type":"point","x":0.2,"y":50,"anchor":"#cta","rx":0.1,"ry":0.9}"##, from: alice, now: now)
    #expect(messages(output, for: alice, in: room).first?["name"] as? String == "Alice")
    #expect(messages(output, for: host, in: room).first?["type"] as? String == "point")
    #expect(messages(output, for: bob, in: room).isEmpty) // on /pricing
    #expect(room.receive(#"{"type":"point","x":0.2,"y":50}"#, from: alice, now: now.addingTimeInterval(0.1)).isEmpty)
}

@Test func fullRoomsDropResolvedCommentsFirst() {
    let old = Date(timeIntervalSince1970: 0)
    var seeded = (0..<CollabRoom.maximumComments).map {
        CollabComment(id: "c\($0)", author: "A", color: "#000000", path: "/", text: "t", x: 0, y: 0, createdAt: old)
    }
    seeded[10].resolved = true
    var room = CollabRoom(comments: seeded)
    let guest = room.connect(isHost: false, id: "g")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: guest)
    _ = room.receive(#"{"type":"comment","text":"new","path":"/","x":0,"y":0}"#, from: guest)
    #expect(room.comments.count == CollabRoom.maximumComments)
    #expect(!room.comments.contains { $0.id == "c10" })
    #expect(room.comments.contains { $0.id == "c0" })

    // With nothing resolved left to drop, new comments are refused rather than pushing out open ones.
    _ = room.receive(#"{"type":"comment","text":"another","path":"/","x":0,"y":0}"#, from: guest, now: Date().addingTimeInterval(10))
    #expect(room.comments.count == CollabRoom.maximumComments)
    #expect(room.comments.contains { $0.id == "c0" })
    #expect(!room.comments.contains { $0.text == "another" })
}

@Test func errorsAndUploadTokensOnlyReachTheirOwners() throws {
    var room = CollabRoom(hostName: "Sam")
    room.capturesErrors = true
    let host = room.connect(isHost: true, id: "host")!
    let alice = room.connect(isHost: false, id: "alice")!
    let hostWelcome = messages(room.receive(#"{"type":"hello","path":"/"}"#, from: host), for: host, in: room).first
    let aliceWelcome = messages(room.receive(#"{"type":"hello","path":"/"}"#, from: alice), for: alice, in: room).first
    let token = try #require(aliceWelcome?["uploadToken"] as? String)
    #expect(token != hostWelcome?["uploadToken"] as? String)
    #expect(room.connection(forUploadToken: token) == alice)
    #expect(room.connection(forUploadToken: "guess") == nil)

    let output = room.receive(#"{"type":"comment","text":"Broken","path":"/","x":0,"y":0,"errors":[{"kind":"network","message":"GET /api?key=secret → 500","path":"/","at":1}]}"#, from: alice)
    let forHost = try #require(messages(output, for: host, in: room).first?["comment"] as? [String: Any])
    let forAlice = try #require(messages(output, for: alice, in: room).first?["comment"] as? [String: Any])
    #expect((forHost["errors"] as? [[String: Any]])?.first?["message"] as? String == "GET /api → 500")
    #expect(forAlice["errors"] == nil)
}

@Test func repliesAndRenamesAreLimited() {
    var room = CollabRoom()
    let alice = room.connect(isHost: false, id: "alice")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: alice)
    _ = room.receive(#"{"type":"comment","text":"x","path":"/","x":0,"y":0}"#, from: alice)
    let id = room.comments[0].id
    for index in 0..<(CollabRoom.maximumRepliesPerComment + 5) {
        _ = room.addReply(to: id, text: "r\(index)", author: "Host", color: "#000000", fromHost: true, agent: nil)
    }
    #expect(room.comments[0].replies.count == CollabRoom.maximumRepliesPerComment)

    let now = Date()
    #expect(!room.receive(#"{"type":"rename","name":"Al"}"#, from: alice, now: now).isEmpty)
    #expect(room.receive(#"{"type":"rename","name":"Ali"}"#, from: alice, now: now.addingTimeInterval(0.2)).isEmpty)
}

@Test func feedbackExportsAsAChecklistGroupedByPage() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let comments = [
        CollabComment(id: "1", author: "Alice", color: "#000000", path: "/", text: "Bigger button", x: 0, y: 0, label: "Start free", title: "Home · Orbit", createdAt: date),
        CollabComment(id: "2", author: "Bob", color: "#000000", path: "/pricing", text: "Typo\nhere", x: 0, y: 0, createdAt: date, resolved: true),
    ]
    let markdown = FeedbackExport.markdown(comments, shareName: "Orbit", date: date)
    #expect(markdown.contains("### `/` — Home · Orbit"))
    #expect(markdown.contains("- [ ] **Alice** on “Start free”: Bigger button"))
    #expect(markdown.contains("- [x] **Bob**: Typo\n  here"))
    let issue = FeedbackExport.githubIssue(comments, shareName: "Orbit", date: date)
    #expect(issue.title.hasPrefix("Feedback from Orbit session"))
    #expect(issue.body.hasPrefix("1 open of 2 comments"))
}

@Test func commentsSurviveACodableRoundTrip() throws {
    let comment = CollabComment(id: "1", author: "A", color: "#123456", path: "/", text: "t", x: 0.5, y: 10, anchor: "#a", rx: 0.1, ry: 0.2, createdAt: Date(timeIntervalSince1970: 100), authorClient: "client-xyz-12345")
    let decoded = try JSONDecoder().decode(CollabComment.self, from: JSONEncoder().encode(comment))
    #expect(decoded == comment)
}

// MARK: Phase 3 — injection points, policies, rewriting

private func injectBoth(_ chunks: [String]) -> String {
    var injector = HTMLInjector(headStart: "<B>", headEnd: "<O>")
    var output: [UInt8] = []
    for chunk in chunks { output += injector.feed(Array(chunk.utf8)) }
    output += injector.finish()
    return String(decoding: output, as: UTF8.self)
}

@Test func bridgeGoesFirstInHeadAndOverlayLast() {
    #expect(injectBoth(["<html><head lang=x><script src=app.js></script></head><body>"]) == "<html><head lang=x><B><script src=app.js></script><O></head><body>")
    #expect(injectBoth(["<html><he", "ad><title>t</title></HEAD>"]) == "<html><head><B><title>t</title><O></HEAD>")
    // <header> is not <head>.
    #expect(injectBoth(["<body><header>x</header>"]) == "<B><O><body><header>x</header>")
    #expect(injectBoth(["plain"]) == "plain<B><O>")
    let injector = HTMLInjector(headStart: "<B>", headEnd: "<O>")
    #expect(injector.addedLength == 6)
}

@Test func policiesAreLeftAloneWhenOpenTrafficScriptsAlreadyLoad() {
    let openKollab = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'sha256-abc='; connect-src 'self' ws://localhost:7880"
    let result = ContentSecurityPolicyAdjuster.adjust(openKollab, origin: "https://x.trycloudflare.com", nonce: "n1")
    // 'self' plus a hash still allows same-origin external scripts; connect-src already has 'self'.
    #expect(result.header == openKollab)
    #expect(!result.needsNonce)
    #expect(ContentSecurityPolicyAdjuster.loopbackPorts(in: openKollab) == [7880])
}

@Test func strictPoliciesGetANonceOrAPathSource() {
    let strict = ContentSecurityPolicyAdjuster.adjust("script-src 'nonce-abc' 'strict-dynamic'; object-src 'none'", origin: "https://x.dev", nonce: "n1")
    #expect(strict.header == "script-src 'nonce-abc' 'strict-dynamic' 'nonce-n1'; object-src 'none'")
    #expect(strict.needsNonce)

    let cdnOnly = ContentSecurityPolicyAdjuster.adjust("default-src https://cdn.example.com", origin: "https://x.dev", nonce: "n1")
    #expect(cdnOnly.header == "default-src https://cdn.example.com; script-src https://cdn.example.com https://x.dev/__opentraffic/bridge.js https://x.dev/__opentraffic/electron/preload.js https://x.dev/__opentraffic/collab.js; connect-src https://cdn.example.com https://x.dev/__opentraffic/ wss://x.dev/__opentraffic/")
    #expect(!cdnOnly.needsNonce)
}

@Test func redirectsToLocalServicesStayOnTheShare() {
    let rewriter = LoopbackURLRewriter(appPort: 5173, bridgedPorts: [7880])
    #expect(rewriter.location("http://localhost:5173/login?next=%2F#top") == "/login?next=%2F#top")
    #expect(rewriter.location("http://127.0.0.1:7880/rtc") == "/__opentraffic/port/7880/rtc")
    #expect(rewriter.location("http://localhost:9999/x") == nil)
    #expect(rewriter.location("https://github.com/login/oauth") == nil)
    #expect(rewriter.location("/dashboard") == nil)
    #expect(rewriter.location("/dashboard", bridgedFrom: 7880) == "/__opentraffic/port/7880/dashboard")
    #expect(rewriter.location("//evil.example/x", bridgedFrom: 7880) == nil)
    #expect(rewriter.location("http://localhost:5173//evil.example/x") == "/evil.example/x")
}

@Test func localhostCookieDomainsAreDropped() {
    #expect(LoopbackURLRewriter.setCookie("sid=1; Path=/; Domain=localhost; HttpOnly") == "sid=1; Path=/; HttpOnly")
    #expect(LoopbackURLRewriter.setCookie("sid=1; domain=.127.0.0.1") == "sid=1")
    #expect(LoopbackURLRewriter.setCookie("sid=1; Domain=example.com") == "sid=1; Domain=example.com")
}

@Test func repliesThreadsAndErrorsFollowTheRules() throws {
    var room = CollabRoom(hostName: "Sam")
    room.capturesErrors = true
    let alice = room.connect(isHost: false, id: "alice")!
    _ = room.receive(#"{"type":"hello","name":"Alice","path":"/"}"#, from: alice)
    let now = Date()
    room.registerAttachment("shot-1", from: alice)
    _ = room.receive(##"{"type":"comment","text":"Broken","path":"/","x":0,"y":0,"screenshot":"shot-1","env":{"browser":"Chrome 141","os":"macOS","viewport":"1280x800","dpr":2,"language":"en"},"errors":[{"kind":"network","message":"GET /api → 500","path":"/","at":1}]}"##, from: alice, now: now)
    let comment = try #require(room.comments.first)
    #expect(comment.screenshot == "shot-1")
    #expect(comment.environment?.viewport == "1280x800")
    #expect(comment.errors.first?.kind == .network)

    _ = room.receive(#"{"type":"reply","id":"\#(comment.id)","text":"Me too"}"#, from: alice, now: now)
    #expect(room.receive(#"{"type":"reply","id":"\#(comment.id)","text":"again"}"#, from: alice, now: now.addingTimeInterval(0.5)).isEmpty)
    let agentReply = room.addReply(to: comment.id, text: "Fixed in a1b2c3", author: "Sam", color: room.hostColor, fromHost: true, agent: "Claude Code")
    #expect(agentReply.comment?.replies.map(\.text) == ["Me too", "Fixed in a1b2c3"])
    #expect(agentReply.comment?.replies.last?.agent == "Claude Code")

    _ = room.receive(#"{"type":"errors","items":[{"kind":"error","message":"TypeError: x is undefined","source":"/app.js","line":12,"path":"/"}]}"#, from: alice, now: now)
    #expect(room.takeReportedErrors().first?.message == "TypeError: x is undefined")
    #expect(room.takeReportedErrors().isEmpty)
}

@Test func screenshotsMustBeUploadedByTheCommenter() {
    var room = CollabRoom()
    let alice = room.connect(isHost: false, id: "alice")!
    let bob = room.connect(isHost: false, id: "bob")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: alice)
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: bob)
    room.registerAttachment("shot-bob", from: bob)
    _ = room.receive(#"{"type":"comment","text":"x","path":"/","x":0,"y":0,"screenshot":"shot-bob"}"#, from: alice)
    #expect(room.comments.first?.screenshot == nil)
    #expect(room.isConnected(alice))
    #expect(!room.isConnected("nobody"))
}

@Test func errorsAreIgnoredUnlessTheShareCollectsThem() {
    var room = CollabRoom()
    let alice = room.connect(isHost: false, id: "alice")!
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: alice)
    _ = room.receive(#"{"type":"errors","items":[{"kind":"error","message":"x","path":"/"}]}"#, from: alice)
    #expect(room.takeReportedErrors().isEmpty)
}

@Test func errorGroupsCountRepeats() {
    var groups: [CollabErrorGroup] = []
    let at = Date()
    let item = CollabErrorItem(kind: .error, message: "boom", source: "/a.js", path: "/", at: at)
    let added = CollabErrorGroup.merge([item, item, CollabErrorItem(kind: .error, message: "boom", source: "/a.js", path: "/b", at: at)], into: &groups)
    #expect(added.count == 1)
    #expect(groups.first?.count == 3)
    #expect(groups.first?.paths == ["/", "/b"])
    #expect(groups.first?.location == "/, /b · /a.js")
}

@Test func errorGroupsNameEachPlaceOnce() {
    let at = Date()
    // An inline script's source is the page it's on.
    let inline = CollabErrorGroup(message: "boom", kind: .error, source: "/", count: 1, firstAt: at, lastAt: at, paths: ["/"])
    #expect(inline.location == "/")
    let unknown = CollabErrorGroup(message: "boom", kind: .network, source: nil, count: 1, firstAt: at, lastAt: at, paths: ["/cart"])
    #expect(unknown.location == "/cart")
}

// MARK: Event log

private let sampleShare = APIShareRef(id: UUID(), name: "Orbit", publicURL: nil)

@Test func eventLogWaitWakesOnAppendTimesOutAndHonoursCancellation() async {
    let log = APIEventLog()
    let cursor = log.cursor

    let started = Date()
    let empty = await log.wait(since: cursor, timeout: 0.2)
    #expect(empty.events.isEmpty)
    #expect(Date().timeIntervalSince(started) < 2)

    async let woken = log.wait(since: cursor, timeout: 10)
    try? await Task.sleep(for: .milliseconds(100))
    log.append(.commentCreated, share: sampleShare)
    let result = await woken
    #expect(result.events.map(\.type) == [.commentCreated])
    #expect(result.next == cursor + 1)

    let waiter = Task { await log.wait(since: log.cursor, timeout: 30) }
    try? await Task.sleep(for: .milliseconds(50))
    let cancelledAt = Date()
    waiter.cancel()
    _ = await waiter.value
    #expect(Date().timeIntervalSince(cancelledAt) < 2)

    // Many short waits racing their own timers must all return.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<200 { group.addTask { _ = await log.wait(since: log.cursor, timeout: 0.001) } }
    }
}

import Foundation
import Testing
@testable import OpenTrafficCore

// Element context, suggested edits, areas, drawing, devices, and roles in the hub.

private func decode(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

private func messages(_ outgoing: [CollabRoom.Outgoing], for id: String, in room: CollabRoom) -> [[String: Any]] {
    outgoing.filter { room.includes($0.target, id) }.map { decode($0.text) }
}

private func encode(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// A host and a guest ("ada", browser "ada-browser") on "/".
private func session(env: [String: Any]? = nil) -> CollabRoom {
    var room = CollabRoom()
    _ = room.connect(isHost: true, id: "host")
    _ = room.connect(isHost: false, id: "ada")
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: "host")
    var hello: [String: Any] = ["type": "hello", "path": "/", "name": "Ada", "client": "ada-browser"]
    if let env { hello["env"] = env }
    _ = room.receive(encode(hello), from: "ada")
    return room
}

private var phone: [String: Any] { ["browser": "Safari 19", "os": "iOS", "viewport": "390x844", "dpr": 3, "language": "en"] }

@Test func commentsKeepContextEditsAndAreaAndOnlyTheHostSeesTheContext() throws {
    var room = session()
    let comment: [String: Any] = [
        "type": "comment", "text": "Hard to read", "path": "/", "x": 0.4, "y": 300,
        "context": [
            "selector": "#hero a.btn.ghost", "component": "HeroActions", "source": "src/components/Hero.tsx:42?t=1",
            "styles": ["color": "rgb(242, 242, 243)", "background-color": "transparent", "position": "absolute", "font-size": "12px; color: red"],
        ],
        "edits": [
            ["kind": "text", "old": "Take the tour", "new": "Take a tour"],
            ["kind": "style", "property": "background-color", "old": "transparent", "new": "#f5f5f7"],
            ["kind": "style", "property": "behavior", "old": "", "new": "url(x.htc)"],
            ["kind": "style", "property": "color", "old": "", "new": "red;} body { display:none"],
            ["kind": "style", "property": "color", "old": "red", "new": "red"],
        ],
        "area": ["width": 120.4, "height": 80],
    ]
    let output = room.receive(encode(comment), from: "ada")
    let stored = try #require(room.comments.first)
    #expect(stored.context?.selector == "#hero a.btn.ghost")
    #expect(stored.context?.source == "src/components/Hero.tsx:42")
    #expect(stored.context?.styles == ["color": "rgb(242, 242, 243)", "background-color": "transparent"])
    #expect(stored.edits == [
        CollabSuggestedEdit(kind: .text, old: "Take the tour", new: "Take a tour"),
        CollabSuggestedEdit(kind: .style, property: "background-color", old: "transparent", new: "#f5f5f7"),
    ])
    #expect(stored.area == CollabArea(width: 120, height: 80))

    let toHost = try #require(messages(output, for: "host", in: room).first?["comment"] as? [String: Any])
    let toAda = try #require(messages(output, for: "ada", in: room).first?["comment"] as? [String: Any])
    #expect(toHost["context"] != nil)
    #expect(toAda["context"] == nil)
    #expect((toAda["edits"] as? [Any])?.count == 2)
    #expect((toAda["area"] as? [String: Any])?["width"] as? Double == 120)

    let api = APIComment(stored, shareID: UUID())
    #expect(api.context?.component == "HeroActions")
    #expect(api.edits?.count == 2)
    let markdown = FeedbackExport.markdown([stored], shareName: "Orbit")
    #expect(markdown.contains("Suggested: “Take the tour” → “Take a tour”"))
    #expect(markdown.contains("Source: `src/components/Hero.tsx:42` (HeroActions)"))
}

@Test func editsAndAreasAreCheckedAndCapped() {
    #expect(CollabRoom.suggestedEdits((0..<10).map { ["kind": "text", "old": "a", "new": "b\($0)"] }).count == 6)
    #expect(CollabRoom.suggestedEdits([["kind": "text", "old": "same", "new": "same"]]).isEmpty)
    #expect(CollabRoom.suggestedEdits([["kind": "style", "property": "color", "new": "url(\"x\")"]]).isEmpty)
    #expect(CollabRoom.suggestedEdits([["kind": "style", "property": "color", "new": "red /* x */"]]).isEmpty)
    #expect(CollabRoom.area(["width": 2, "height": 40]) == nil)
    #expect(CollabRoom.area(["width": 40, "height": 40_000]) == nil)
    #expect(CollabRoom.elementContext(["styles": ["position": "fixed"]]) == nil)
}

@Test func peopleCarryTheirDeviceAndItUpdates() throws {
    var room = session(env: phone)
    let ada = try #require(room.peers.first { $0.id == "ada" })
    #expect(ada.device?.viewport == "390x844")
    #expect(ada.client == "ada-browser")

    let start = Date()
    let resized = room.receive(encode(["type": "env", "env": phone.merging(["viewport": "844x390"]) { $1 }]), from: "ada", now: start)
    let update = try #require(messages(resized, for: "host", in: room).first)
    #expect((update["peer"] as? [String: Any]).flatMap { $0["device"] as? [String: Any] }?["viewport"] as? String == "844x390")
    // Once a second at most.
    #expect(room.receive(encode(["type": "env", "env": phone]), from: "ada", now: start.addingTimeInterval(0.3)).isEmpty)
}

@Test func drawingReachesThePageAndNothingElse() throws {
    var room = session()
    _ = room.connect(isHost: false, id: "bob")
    _ = room.receive(#"{"type":"hello","path":"/pricing"}"#, from: "bob")
    let start = Date()
    let ink = room.receive(#"{"type":"ink","stroke":3,"points":[[0.5,100],[0.51,104.6]]}"#, from: "ada", now: start)
    let toHost = try #require(messages(ink, for: "host", in: room).first)
    #expect(toHost["type"] as? String == "ink")
    #expect(toHost["stroke"] as? Int == 3)
    #expect((toHost["points"] as? [[Double]])?.last == [0.51, 105])
    #expect(messages(ink, for: "bob", in: room).isEmpty)
    #expect(messages(ink, for: "ada", in: room).isEmpty)
    #expect(ink.allSatisfy { $0.isEphemeral })

    let later = start.addingTimeInterval(1)
    #expect(room.receive(encode(["type": "ink", "points": Array(repeating: [0.5, 1], count: 65)]), from: "ada", now: later).isEmpty)
    #expect(room.receive(#"{"type":"ink","points":[[2,1]]}"#, from: "ada", now: later.addingTimeInterval(1)).count == 1) // x clamped
    #expect(room.receive(#"{"type":"ink","points":[[0.5,"x"]]}"#, from: "ada", now: later.addingTimeInterval(2)).isEmpty)
    // Up to 25 batches a second.
    #expect(room.receive(#"{"type":"ink","points":[[0.5,1]]}"#, from: "ada", now: later.addingTimeInterval(3)).count == 1)
    #expect(room.receive(#"{"type":"ink","points":[[0.5,1]]}"#, from: "ada", now: later.addingTimeInterval(3.01)).isEmpty)
}

@Test func viewersCanLookPointAndDrawButNotComment() throws {
    var room = session()
    let changed = room.setRoles(["ada-browser": .viewer], default: .commenter)
    // Ada hears about it too, so her overlay hides what she can't do.
    let update = try #require(messages(changed, for: "ada", in: room).first)
    #expect((update["peer"] as? [String: Any])?["role"] as? String == "viewer")

    let start = Date()
    #expect(room.receive(#"{"type":"comment","text":"hi","path":"/","x":0.5,"y":10}"#, from: "ada", now: start).isEmpty)
    #expect(room.comments.isEmpty)
    #expect(!room.receive(#"{"type":"point","x":0.5,"y":10}"#, from: "ada", now: start).isEmpty)
    #expect(!room.receive(#"{"type":"ink","points":[[0.5,10]]}"#, from: "ada", now: start.addingTimeInterval(1)).isEmpty)

    // The host comments; Ada can't reply to it or resolve it.
    _ = room.receive(#"{"type":"comment","text":"Look","path":"/","x":0.5,"y":10}"#, from: "host", now: start)
    let id = try #require(room.comments.first?.id)
    #expect(room.receive(encode(["type": "reply", "id": id, "text": "ok"]), from: "ada", now: start.addingTimeInterval(3)).isEmpty)
    #expect(room.receive(encode(["type": "resolve", "id": id, "resolved": true]), from: "ada", now: start.addingTimeInterval(3)).isEmpty)

    // Back to commenting: allowed again.
    _ = room.setRoles([:], default: .commenter)
    #expect(!room.receive(#"{"type":"comment","text":"hi","path":"/","x":0.5,"y":10}"#, from: "ada", now: start.addingTimeInterval(5)).isEmpty)
}

@Test func newPeopleGetTheDefaultRoleAndTheHostIsNeverLimited() throws {
    var room = CollabRoom()
    _ = room.setRoles(["known-browser": .trusted], default: .viewer)
    _ = room.connect(isHost: true, id: "host")
    _ = room.connect(isHost: false, id: "a")
    _ = room.connect(isHost: false, id: "b")
    _ = room.receive(#"{"type":"hello","path":"/"}"#, from: "host")
    _ = room.receive(#"{"type":"hello","path":"/","client":"known-browser"}"#, from: "a")
    _ = room.receive(#"{"type":"hello","path":"/","client":"stranger-browser"}"#, from: "b")
    #expect(room.peers.first { $0.id == "a" }?.role == .trusted)
    #expect(room.peers.first { $0.id == "b" }?.role == .viewer)
    #expect(room.peers.first { $0.id == "host" }?.role == .trusted)
    #expect(!room.receive(#"{"type":"comment","text":"hi","path":"/","x":0.5,"y":10}"#, from: "host").isEmpty)
}

@Test func sharesRememberRolesByBrowser() throws {
    var definition = TunnelDefinition(name: "Orbit", kind: .quick, localURL: "http://127.0.0.1:5173")
    #expect(definition.collabRole(forClient: "x") == .commenter)
    definition.collabMembers["ada-browser"] = CollabMember(role: .trusted, name: "Ada")
    definition.collabDefaultRole = .viewer
    let decoded = try JSONDecoder().decode(TunnelDefinition.self, from: JSONEncoder().encode(definition))
    #expect(decoded.collabRole(forClient: "ada-browser") == .trusted)
    #expect(decoded.collabRole(forClient: "someone") == .viewer)
    #expect(decoded.collabRole(forClient: nil) == .viewer)
}

@Test func watchingSomeoneBringsTheirPointerFromAnyPage() throws {
    var room = session()
    _ = room.receive(#"{"type":"path","path":"/pricing"}"#, from: "ada")
    let moved = #"{"type":"cursor","x":0.5,"y":120}"#
    // Different pages: the host doesn't get Ada's pointer…
    #expect(messages(room.receive(moved, from: "ada"), for: "host", in: room).isEmpty)
    // …until they look at her window.
    _ = room.receive(#"{"type":"watch","id":"ada"}"#, from: "host")
    #expect(messages(room.receive(moved, from: "ada"), for: "host", in: room).first?["type"] as? String == "cursor")
    #expect(messages(room.receive(#"{"type":"cursor-hide"}"#, from: "ada"), for: "host", in: room).first?["type"] as? String == "cursor-hide")
    // Same page: once, not twice.
    _ = room.receive(#"{"type":"path","path":"/pricing"}"#, from: "host")
    #expect(messages(room.receive(moved, from: "ada"), for: "host", in: room).count == 1)
    _ = room.receive(#"{"type":"path","path":"/"}"#, from: "host")
    _ = room.receive(#"{"type":"watch","id":null}"#, from: "host")
    #expect(messages(room.receive(moved, from: "ada"), for: "host", in: room).isEmpty)
    // Nobody can watch themselves or someone who isn't there.
    _ = room.receive(#"{"type":"watch","id":"nobody"}"#, from: "host")
    #expect(messages(room.receive(moved, from: "ada"), for: "host", in: room).isEmpty)
}

@Test func aDeviceViewIsTheSamePersonNotAnotherOne() throws {
    var room = session()
    _ = room.connect(isHost: false, id: "ada-view")
    let joined = room.receive(#"{"type":"hello","path":"/","name":"Ada","client":"ada-browser","inView":true}"#, from: "ada-view")
    #expect(room.peers.map(\.id) == ["host", "ada"])
    // Overlays still hear about it (its pointer is Ada's pointer), marked so they don't list it.
    let join = try #require(messages(joined, for: "host", in: room).first { $0["type"] as? String == "join" })
    #expect((join["peer"] as? [String: Any])?["inView"] as? Bool == true)
    // Same browser: same role and colour.
    #expect(room.peers.first { $0.id == "ada" }?.role == .commenter)
    #expect((join["peer"] as? [String: Any])?["color"] as? String == room.peers.first { $0.id == "ada" }?.color)
}

@Test func theHostCanShowFollowersAPhoneOrTheirWindow() throws {
    var room = session()
    func lastLead(_ output: [CollabRoom.Outgoing]) -> [String: Any]? {
        messages(output, for: "ada", in: room).last { $0["type"] as? String == "lead" }
    }
    let phone = lastLead(room.receive(#"{"type":"lead","on":true,"view":{"kind":"phone","w":390,"h":844}}"#, from: "host"))
    #expect((phone?["view"] as? [String: Any])?["w"] as? Int == 390)
    // Re-asserting after a reload without "view" keeps it; scrolling carries it too.
    _ = room.receive(#"{"type":"lead","on":true}"#, from: "host")
    let scrolled = lastLead(room.receive(#"{"type":"scroll","ratio":0.5}"#, from: "host"))
    #expect((scrolled?["view"] as? [String: Any])?["kind"] as? String == "phone")
    // Someone joining now gets it in their welcome.
    _ = room.connect(isHost: false, id: "bob")
    let welcome = try #require(messages(room.receive(#"{"type":"hello","path":"/"}"#, from: "bob"), for: "bob", in: room).first)
    #expect((welcome["view"] as? [String: Any])?["h"] as? Int == 844)
    // Back to everyone's own window; nonsense is refused, as is a visitor trying.
    #expect(lastLead(room.receive(#"{"type":"lead","on":true,"view":null}"#, from: "host"))?["view"] is NSNull)
    #expect(lastLead(room.receive(#"{"type":"lead","on":true,"view":{"kind":"tv","w":10,"h":10}}"#, from: "host"))?["view"] is NSNull)
    #expect(room.receive(#"{"type":"lead","on":true,"view":{"kind":"phone","w":390,"h":844}}"#, from: "ada").isEmpty)
    // Stopping leading forgets it.
    _ = room.receive(#"{"type":"lead","on":true,"view":{"kind":"window","w":1440,"h":900}}"#, from: "host")
    _ = room.receive(#"{"type":"lead","on":false}"#, from: "host")
    #expect(lastLead(room.receive(#"{"type":"lead","on":true}"#, from: "host"))?["view"] is NSNull)
}

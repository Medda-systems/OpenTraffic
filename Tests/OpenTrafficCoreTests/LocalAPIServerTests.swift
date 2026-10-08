import Foundation
import Testing
@testable import OpenTrafficCore

// The local REST API against a fake backend, over real HTTP.

private func errorCode(_ data: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
}

// MARK: Security

@Test func apiRejectsMissingAndWrongTokens() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let (missing, missingResponse) = try await api.request("GET", "/v1/shares", token: nil)
    #expect(missingResponse.statusCode == 401)
    #expect(errorCode(missing) == "unauthorized")
    #expect(missingResponse.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")

    let (_, wrong) = try await api.request("GET", "/v1/shares", token: "nope")
    #expect(wrong.statusCode == 401)
    let (_, prefix) = try await api.request("GET", "/v1/shares", token: String(APIHarness.token.dropLast()))
    #expect(prefix.statusCode == 401)
    let (_, longer) = try await api.request("GET", "/v1/shares", token: APIHarness.token + "x")
    #expect(longer.statusCode == 401)

    let (_, ok) = try await api.request("GET", "/v1/shares")
    #expect(ok.statusCode == 200)
}

@Test func apiRejectsRequestsFromWebPages() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let (data, response) = try await api.request("GET", "/v1/shares", headers: ["Origin": "http://127.0.0.1:\(api.port)"])
    #expect(response.statusCode == 403)
    #expect(errorCode(data) == "forbidden")
    let (_, preflight) = try await api.request("OPTIONS", "/mcp", token: nil, headers: ["Origin": "https://evil.example"])
    #expect(preflight.statusCode == 403)
}

@Test func apiChecksTheHostHeader() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    func get(host: String) async throws -> String {
        try await rawHTTP(port: api.port, "GET /v1/shares HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(APIHarness.token)\r\nConnection: close\r\n\r\n")
    }
    #expect(try await get(host: "127.0.0.1:\(api.port)").hasPrefix("HTTP/1.1 200"))
    #expect(try await get(host: "LOCALHOST:\(api.port)").hasPrefix("HTTP/1.1 200"))
    #expect(try await get(host: "evil.example:\(api.port)").hasPrefix("HTTP/1.1 403"))
    #expect(try await get(host: "127.0.0.1").hasPrefix("HTTP/1.1 403"))
    #expect(try await get(host: "127.0.0.1:1").hasPrefix("HTTP/1.1 403"))
    let noHost = try await rawHTTP(port: api.port, "GET /v1/shares HTTP/1.1\r\nAuthorization: Bearer \(APIHarness.token)\r\nConnection: close\r\n\r\n")
    #expect(noHost.hasPrefix("HTTP/1.1 403"))
}

@Test func apiTokenCanBeReplacedWhileRunning() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    api.server.setToken("fresh-token")
    let (_, old) = try await api.request("GET", "/v1/shares")
    #expect(old.statusCode == 401)
    let (_, new) = try await api.request("GET", "/v1/shares", token: "fresh-token")
    #expect(new.statusCode == 200)
}

@Test func apiLimitsBodySize() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let response = try await rawHTTP(
        port: api.port,
        "POST /v1/shares HTTP/1.1\r\nHost: 127.0.0.1:\(api.port)\r\nAuthorization: Bearer \(APIHarness.token)\r\nContent-Length: 70000\r\n\r\n{"
    )
    #expect(response.hasPrefix("HTTP/1.1 413"))
    #expect(response.contains("too_large"))
}

@Test func clientNamesAreSanitized() {
    #expect(LocalAPIServer.clientName(nil) == "API client")
    #expect(LocalAPIServer.clientName("  ") == "API client")
    #expect(LocalAPIServer.clientName("Claude Code") == "Claude Code")
    #expect(LocalAPIServer.clientName("Bad\u{0}\u{7}Name\u{202E}") == "BadName")
    #expect(LocalAPIServer.clientName(String(repeating: "a", count: 100)).count == 40)
    #expect(LocalAPIServer.matchesToken("Bearer abc", token: "abc"))
    #expect(LocalAPIServer.matchesToken("bearer abc", token: "abc"))
    #expect(!LocalAPIServer.matchesToken("Bearer abd", token: "abc"))
    #expect(!LocalAPIServer.matchesToken("Bearer ", token: ""))
    #expect(!LocalAPIServer.matchesToken("Basic abc", token: "abc"))
}

// MARK: Routes

@Test func listsAndCreatesShares() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let list = try await api.object("GET", "/v1/shares")
    let shares = try #require(list["shares"] as? [[String: Any]])
    #expect(shares.count == 1)
    #expect(shares[0]["name"] as? String == "Orbit")
    #expect(shares[0]["id"] as? String == FakeAPIBackend.orbitID.uuidString)
    #expect((shares[0]["people"] as? [[String: Any]])?.first?["isHost"] as? Bool == false)

    let (data, response) = try await api.request("POST", "/v1/shares", json: #"{"port":3000,"name":"Docs","collaboration":true}"#,
                                                 headers: ["X-OpenTraffic-Client": "Claude Code"])
    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let created = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(created["name"] as? String == "Docs")
    #expect(created["collaboration"] as? Bool == true)
    #expect(api.backend.clients == ["Claude Code"])

    let (_, unnamed) = try await api.request("POST", "/v1/shares", json: #"{"port":3001}"#)
    #expect(unnamed.statusCode == 200)
    #expect(api.backend.clients.last == "API client")
}

@Test func shareRequestsAreValidated() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    for body in [#"{}"#, #"{"port":0}"#, #"{"port":"80"}"#, #"{"port":80,"provider":"ftp"}"#, "not json", "[1]"] {
        let (data, response) = try await api.request("POST", "/v1/shares", json: body)
        #expect(response.statusCode == 400, "\(body)")
        #expect(errorCode(data) == "bad_request")
    }
    // Aliases the app maps (cloudflare, temporary, tailnet) pass, in any case.
    for provider in ["quick", "Cloudflare", "temporary", "TAILSCALE", "tailnet", "ngrok"] {
        let (_, response) = try await api.request("POST", "/v1/shares", json: #"{"port":80,"provider":"\#(provider)"}"#)
        #expect(response.statusCode == 200, "\(provider)")
    }
    api.backend.declineNewShares()
    let (data, declined) = try await api.request("POST", "/v1/shares", json: #"{"port":80}"#)
    #expect(declined.statusCode == 403)
    #expect(errorCode(data) == "denied")
}

@Test func startsAndStopsSharesByIdOrName() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let started = try await api.object("POST", "/v1/shares/orbit/start")
    #expect(started["state"] as? String == "running")
    let stopped = try await api.object("POST", "/v1/shares/\(FakeAPIBackend.orbitID.uuidString.lowercased())/stop")
    #expect(stopped["state"] as? String == "stopped")
    #expect(stopped["publicURL"] == nil)

    let (data, missing) = try await api.request("POST", "/v1/shares/nope/start")
    #expect(missing.statusCode == 404)
    #expect(errorCode(data) == "not_found")
    let (_, wrongMethod) = try await api.request("GET", "/v1/shares/orbit/start")
    #expect(wrongMethod.statusCode == 405)
    let (_, unknown) = try await api.request("GET", "/v1/nothing")
    #expect(unknown.statusCode == 404)
}

@Test func shareNamesArePercentDecodedPathSegments() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    // "a/b" encoded stays one segment, so it's looked up (and not found) as a name rather than routed.
    let (data, response) = try await api.request("POST", "/v1/shares/a%2Fb/start")
    #expect(response.statusCode == 404)
    #expect(String(decoding: data, as: UTF8.self).contains("No share named a/b"))
    let (_, spaced) = try await api.request("POST", "/v1/shares/%4Frbit/start")
    #expect(spaced.statusCode == 200)
}

@Test func readsCommentsWithStatusFilter() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let open = try #require(try await api.object("GET", "/v1/shares/Orbit/comments")["comments"] as? [[String: Any]])
    #expect(open.map { $0["id"] as? String } == ["c1"])
    let comment = open[0]
    #expect(comment["shareId"] as? String == FakeAPIBackend.orbitID.uuidString)
    #expect(comment["hasScreenshot"] as? Bool == true)
    #expect(comment["createdAt"] as? String == "2025-10-09T08:53:20.250Z")
    #expect((comment["environment"] as? [String: Any])?["browser"] as? String == "Safari 19")
    #expect(comment["canDelete"] == nil)
    #expect(comment["authorClient"] == nil)

    let resolved = try #require(try await api.object("GET", "/v1/shares/Orbit/comments?status=resolved")["comments"] as? [[String: Any]])
    #expect(resolved.map { $0["id"] as? String } == ["c2"])
    let all = try #require(try await api.object("GET", "/v1/shares/Orbit/comments?status=all")["comments"] as? [[String: Any]])
    #expect(all.count == 2)
    let (_, bad) = try await api.request("GET", "/v1/shares/Orbit/comments?status=maybe")
    #expect(bad.statusCode == 400)
}

@Test func resolvesAndRepliesToComments() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let resolved = try await api.object("PATCH", "/v1/shares/Orbit/comments/c1", json: #"{"resolved":true}"#)
    #expect(resolved["resolved"] as? Bool == true)
    let (_, missingField) = try await api.request("PATCH", "/v1/shares/Orbit/comments/c1", json: "{}")
    #expect(missingField.statusCode == 400)
    let (_, missingComment) = try await api.request("PATCH", "/v1/shares/Orbit/comments/zzz", json: #"{"resolved":false}"#)
    #expect(missingComment.statusCode == 404)

    let (data, response) = try await api.request("POST", "/v1/shares/Orbit/comments/c1/replies", json: #"{"text":"  Fixed the padding  "}"#,
                                                 headers: ["X-OpenTraffic-Client": "Codex"])
    #expect(response.statusCode == 200)
    let replied = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let reply = try #require((replied["replies"] as? [[String: Any]])?.first)
    #expect(reply["text"] as? String == "Fixed the padding")
    #expect(reply["agent"] as? String == "Codex")

    for body in [#"{"text":"   "}"#, #"{"text":"\#(String(repeating: "x", count: 1001))"}"#, #"{"words":"hi"}"#] {
        let (_, rejected) = try await api.request("POST", "/v1/shares/Orbit/comments/c1/replies", json: body)
        #expect(rejected.statusCode == 400)
    }
}

@Test func servesScreenshotsAsRawBytes() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let (data, response) = try await api.request("GET", "/v1/shares/Orbit/comments/c1/screenshot")
    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
    #expect(data == FakeAPIBackend.screenshot)
    let (_, none) = try await api.request("GET", "/v1/shares/Orbit/comments/c2/screenshot")
    #expect(none.statusCode == 404)
}

@Test func returnsErrorsAndLogs() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let errors = try #require(try await api.object("GET", "/v1/shares/Orbit/errors")["errors"] as? [[String: Any]])
    #expect(errors.first?["count"] as? Int == 3)
    #expect(errors.first?["kind"] as? String == "error")

    let lines = try #require(try await api.object("GET", "/v1/shares/Orbit/logs?lines=3")["lines"] as? [String])
    #expect(lines == ["line 498", "line 499", "line 500"])
    let defaults = try #require(try await api.object("GET", "/v1/shares/Orbit/logs")["lines"] as? [String])
    #expect(defaults.count == 200)
    let (_, bad) = try await api.request("GET", "/v1/shares/Orbit/logs?lines=lots")
    #expect(bad.statusCode == 400)
}

// MARK: Events

@Test func eventsLongPollWakesOnAppendWithoutBlockingOtherRequests() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    api.events.append(.shareStarted, share: api.backend.shareRef)
    let first = try await api.object("GET", "/v1/events")
    #expect((first["events"] as? [[String: Any]])?.first?["type"] as? String == "share.started")
    let next = try #require(first["next"] as? Int)

    let poll = Task { try await api.request("GET", "/v1/events?since=\(next)&wait=20").0 }
    // Other requests are answered while the poll is open.
    let started = Date()
    _ = try await api.object("GET", "/v1/shares")
    #expect(Date().timeIntervalSince(started) < 2)

    try await Task.sleep(for: .milliseconds(200))
    api.events.append(.commentCreated, share: api.backend.shareRef, comment: api.backend.comment("c1"))
    let woken = try #require(try JSONSerialization.jsonObject(with: try await poll.value) as? [String: Any])
    let events = try #require(woken["events"] as? [[String: Any]])
    #expect(events.count == 1)
    #expect(events[0]["type"] as? String == "comment.created")
    #expect(events[0]["seq"] as? Int == next)
    #expect((events[0]["comment"] as? [String: Any])?["id"] as? String == "c1")
    #expect((events[0]["share"] as? [String: Any])?["name"] as? String == "Orbit")
    #expect(woken["next"] as? Int == next + 1)
}

@Test func eventsLongPollTimesOut() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let cursor = api.events.cursor
    let started = Date()
    let result = try await api.object("GET", "/v1/events?since=\(cursor)&wait=1")
    #expect(Date().timeIntervalSince(started) >= 0.9)
    #expect((result["events"] as? [Any])?.isEmpty == true)
    #expect(result["next"] as? Int == cursor)
    let (_, bad) = try await api.request("GET", "/v1/events?since=soon")
    #expect(bad.statusCode == 400)
}

@Test func connectionsAreKeptAlive() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let request = "GET /v1/shares HTTP/1.1\r\nHost: 127.0.0.1:\(api.port)\r\nAuthorization: Bearer \(APIHarness.token)\r\n"
    let response = try await rawHTTP(port: api.port, request + "\r\n" + request + "Connection: close\r\n\r\n")
    #expect(response.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
}

@Test func stoppingTheServerEndsOpenLongPolls() async throws {
    let api = try await APIHarness.start()
    let poll = Task { try? await api.request("GET", "/v1/events?since=\(api.events.cursor)&wait=30") }
    try await Task.sleep(for: .milliseconds(200))
    let started = Date()
    await api.stop()
    _ = await poll.value
    #expect(Date().timeIntervalSince(started) < 5)
}

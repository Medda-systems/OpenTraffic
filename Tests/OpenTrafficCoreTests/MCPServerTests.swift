import Foundation
import Testing
@testable import OpenTrafficCore

// MCP over Streamable HTTP at /mcp, against a fake backend.

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func errorCode(_ data: Data) throws -> Int? {
    (try json(data)["error"] as? [String: Any])?["code"] as? Int
}

/// The text block of a tool result, parsed as JSON.
private func text(_ result: [String: Any]) throws -> [String: Any] {
    let content = try #require(result["content"] as? [[String: Any]])
    #expect(content.first?["type"] as? String == "text")
    let text = try #require(content.first?["text"] as? String)
    return try json(Data(text.utf8))
}

@Test func mcpInitializeNegotiatesTheProtocolVersion() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let older = try await api.mcpResult("initialize", params: #"{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#)
    #expect(older["protocolVersion"] as? String == "2025-03-26")
    #expect((older["capabilities"] as? [String: Any])?["tools"] is [String: Any])
    #expect((older["serverInfo"] as? [String: Any])?["name"] as? String == "opentraffic")
    #expect(older["instructions"] is String)

    let unknown = try await api.mcpResult("initialize", params: #"{"protocolVersion":"2024-11-05"}"#)
    #expect(unknown["protocolVersion"] as? String == "2025-06-18")
    let current = try await api.mcpResult("initialize", params: #"{"protocolVersion":"2025-06-18"}"#)
    #expect(current["protocolVersion"] as? String == "2025-06-18")
    #expect(try await api.mcpResult("ping").isEmpty)
}

@Test func mcpNotificationsGet202AndOtherMethodsAre405() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let (data, response) = try await api.mcp(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    #expect(response.statusCode == 202)
    #expect(data.isEmpty)
    let (_, clientResponse) = try await api.mcp(#"{"jsonrpc":"2.0","id":7,"result":{}}"#)
    #expect(clientResponse.statusCode == 202)
    let (_, get) = try await api.request("GET", "/mcp")
    #expect(get.statusCode == 405)
    let (_, unauthenticated) = try await api.request("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, token: nil)
    #expect(unauthenticated.statusCode == 401)
}

@Test func mcpAnswersMalformedMessagesWithJSONRPCErrors() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let (parse, parseResponse) = try await api.mcp("{nope")
    #expect(parseResponse.statusCode == 400)
    #expect(try errorCode(parse) == -32700)
    let (invalid, _) = try await api.mcp(#"{"id":1,"method":"ping"}"#)
    #expect(try errorCode(invalid) == -32600)
    let (unknown, _) = try await api.mcp(#"{"jsonrpc":"2.0","id":"x","method":"resources/list"}"#)
    #expect(try errorCode(unknown) == -32601)
    #expect(try json(unknown)["id"] as? String == "x")
    let (tool, _) = try await api.mcp(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#)
    #expect(try errorCode(tool) == -32602)

    let (batch, _) = try await api.mcp(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
    let replies = try #require(try JSONSerialization.jsonObject(with: batch) as? [[String: Any]])
    #expect(replies.count == 1)
}

@Test func mcpListsEveryToolWithASchema() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let tools = try #require(try await api.mcpResult("tools/list")["tools"] as? [[String: Any]])
    let names = Set(tools.compactMap { $0["name"] as? String })
    #expect(names == [
        "list_shares", "share", "start_share", "stop_share", "get_feedback", "resolve_comment", "reply_to_comment",
        "get_screenshot", "get_errors", "get_logs", "wait_for_feedback", "claim_comment", "release_comment", "restart_mac_app",
    ])
    for tool in tools {
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["properties"] is [String: Any])
        #expect((tool["description"] as? String)?.isEmpty == false)
    }
    let reply = try #require(tools.first { $0["name"] as? String == "reply_to_comment" }?["inputSchema"] as? [String: Any])
    #expect(reply["required"] as? [String] == ["share", "comment_id", "text"])
}

@Test func mcpToolsReturnStructuredContentAndText() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let listed = try await api.callTool("list_shares")
    let structured = try #require(listed["structuredContent"] as? [String: Any])
    #expect((structured["shares"] as? [[String: Any]])?.first?["name"] as? String == "Orbit")
    #expect((try text(listed)["shares"] as? [[String: Any]])?.count == 1)
    #expect(listed["isError"] == nil)

    let feedback = try #require(try await api.callTool("get_feedback", #"{"share":"orbit"}"#)["structuredContent"] as? [String: Any])
    #expect((feedback["comments"] as? [[String: Any]])?.map { $0["id"] as? String } == ["c1"])

    let shared = try await api.mcp(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"share","arguments":{"port":5174}}}"#,
                                   headers: ["X-OpenTraffic-Client": "Cursor"])
    let share = try #require((try json(shared.0)["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
    #expect(share["collaboration"] as? Bool == true)
    #expect(api.backend.clients == ["Cursor"])

    let replied = try #require(try await api.callTool("reply_to_comment", #"{"share":"Orbit","comment_id":"c1","text":"Done"}"#)["structuredContent"] as? [String: Any])
    #expect((replied["replies"] as? [[String: Any]])?.first?["text"] as? String == "Done")
    let resolved = try #require(try await api.callTool("resolve_comment", #"{"share":"Orbit","comment_id":"c1"}"#)["structuredContent"] as? [String: Any])
    #expect(resolved["resolved"] as? Bool == true)

    let errors = try #require(try await api.callTool("get_errors", #"{"share":"Orbit"}"#)["structuredContent"] as? [String: Any])
    #expect((errors["errors"] as? [Any])?.count == 1)
    let logs = try #require(try await api.callTool("get_logs", #"{"share":"Orbit","lines":2}"#)["structuredContent"] as? [String: Any])
    #expect(logs["lines"] as? [String] == ["line 499", "line 500"])
    let stopped = try #require(try await api.callTool("stop_share", #"{"share":"Orbit"}"#)["structuredContent"] as? [String: Any])
    #expect(stopped["state"] as? String == "stopped")
}

@Test func mcpToolFailuresAreErrorResults() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let missingShare = try await api.callTool("get_feedback", #"{"share":"nope"}"#)
    #expect(missingShare["isError"] as? Bool == true)
    let content = try #require(missingShare["content"] as? [[String: Any]])
    #expect(content.first?["text"] as? String == "No share named nope")

    let missingArgument = try await api.callTool("start_share")
    #expect(missingArgument["isError"] as? Bool == true)
    #expect((missingArgument["content"] as? [[String: Any]])?.first?["text"] as? String == "Missing share")
    let wrongType = try await api.callTool("share", #"{"port":"80"}"#)
    #expect(wrongType["isError"] as? Bool == true)

    api.backend.declineNewShares()
    let declined = try await api.callTool("share", #"{"port":80}"#)
    #expect(declined["isError"] as? Bool == true)
    #expect((declined["content"] as? [[String: Any]])?.first?["text"] as? String == "The user declined")
}

@Test func mcpScreenshotIsAnImageBlock() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let result = try await api.callTool("get_screenshot", #"{"share":"Orbit","comment_id":"c1"}"#)
    let block = try #require((result["content"] as? [[String: Any]])?.first)
    #expect(block["type"] as? String == "image")
    #expect(block["mimeType"] as? String == "image/png")
    #expect((block["data"] as? String).flatMap { Data(base64Encoded: $0) } == FakeAPIBackend.screenshot)

    let none = try await api.callTool("get_screenshot", #"{"share":"Orbit","comment_id":"c2"}"#)
    #expect(none["isError"] as? Bool == true)
}

@Test func mcpWaitForFeedbackReturnsCommentEventsForTheShare() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let other = APIShareRef(id: UUID(), name: "Other", publicURL: nil)
    let cursor = api.events.cursor

    let waiting = Task {
        try await api.mcp(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_for_feedback","arguments":{"share":"Orbit","timeout_seconds":20}}}"#).0
    }
    try await Task.sleep(for: .milliseconds(300))
    // Neither of these is feedback on Orbit, so the call keeps waiting.
    api.events.append(.sessionJoined, share: api.backend.shareRef, peer: APIPerson(name: "Ada", path: "/", isHost: false))
    api.events.append(.commentCreated, share: other)
    try await Task.sleep(for: .milliseconds(200))
    api.events.append(.commentDeleted, share: api.backend.shareRef, commentId: "c2")

    let result = try #require((try json(try await waiting.value)["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
    let events = try #require(result["events"] as? [[String: Any]])
    #expect(events.map { $0["type"] as? String } == ["comment.deleted"])
    #expect(events.first?["commentId"] as? String == "c2")
    #expect(result["cursor"] as? Int == cursor + 3)

    // Passing the cursor back picks up exactly what came after.
    api.events.append(.commentUpdated, share: api.backend.shareRef, comment: api.backend.comment("c1"))
    let next = try #require(try await api.callTool("wait_for_feedback", #"{"since":\#(cursor + 3),"timeout_seconds":5}"#)["structuredContent"] as? [String: Any])
    #expect((next["events"] as? [[String: Any]])?.map { $0["type"] as? String } == ["comment.updated"])
    #expect(next["cursor"] as? Int == cursor + 4)
}

@Test func mcpWaitForFeedbackTimesOutEmpty() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }
    let started = Date()
    let result = try #require(try await api.callTool("wait_for_feedback", #"{"timeout_seconds":0.5}"#)["structuredContent"] as? [String: Any])
    #expect(Date().timeIntervalSince(started) >= 0.4)
    #expect((result["events"] as? [Any])?.isEmpty == true)
    #expect(result["cursor"] as? Int == api.events.cursor)

    let unknown = try await api.callTool("wait_for_feedback", #"{"share":"nope","timeout_seconds":1}"#)
    #expect(unknown["isError"] as? Bool == true)
}

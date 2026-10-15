import Foundation
import Security
import Testing
@testable import OpenTrafficCore
@testable import OpenTrafficSocket

private func temporarySocket() -> String {
    // Short, because a socket path is limited to about 100 bytes.
    "/tmp/ot-test-\(UUID().uuidString.prefix(8)).sock"
}

@Test func trustedCallersAreServedWithoutATokenAndRunAsTrusted() async throws {
    let backend = FakeAPIBackend()
    let path = temporarySocket()
    let server = LocalAPIServer(trustedSocketPath: path, backend: backend, events: APIEventLog(), isTrustedCaller: { _ in true })
    _ = try await server.start()
    defer { Task { await server.stop() } }

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)

    let body = try JSONSerialization.data(withJSONObject: ["port": 5173, "name": "Orbit Two"])
    let response = try await Task.detached { try AppSocket.send("POST", "/v1/shares", body: body, client: "opentraffic command", socketPath: path) }.value
    #expect(response.status == 200)
    #expect(backend.clients == ["opentraffic command"])
    #expect(backend.trust == [true])
}

@Test func otherCallersAreTurnedAway() async throws {
    let backend = FakeAPIBackend()
    let path = temporarySocket()
    let server = LocalAPIServer(trustedSocketPath: path, backend: backend, events: APIEventLog(), isTrustedCaller: { _ in false })
    _ = try await server.start()
    defer { Task { await server.stop() } }

    await #expect(throws: AppSocket.Failure.self) {
        try await Task.detached { try AppSocket.send("GET", "/v1/shares", client: "someone else", socketPath: path) }.value
    }
    #expect(backend.clients.isEmpty)
}

@Test func theHTTPAPIIsNotTrusted() async throws {
    let harness = try await APIHarness.start()
    defer { Task { await harness.stop() } }
    _ = try await harness.request("POST", "/v1/shares", json: #"{"port":5173}"#)
    #expect(harness.backend.trust == [false])
}

@Test func signatureCheckWantsTheAppsOwnTools() throws {
    var me: SecCode?
    #expect(SecCodeCopySelf([], &me) == errSecSuccess)
    let ownPath = Bundle.main.executableURL!.resolvingSymlinksInPath().path
    // An ad hoc build trusts only the binaries inside its own bundle.
    #expect(!TrustedCallerVerifier(requirement: nil, toolPaths: ["/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-cli"]).isTrusted(me!))
    // A signed one wants its team's signature and the tools' identifiers, which the test runner hasn't got.
    #expect(!TrustedCallerVerifier(requirement: #"anchor apple generic and certificate leaf[subject.OU] = "5TR7SD7S8J" and identifier "se.medda.opentraffic.cli""#, toolPaths: []).isTrusted(me!))
    _ = ownPath
}

@Test func readsResponsesFromTheSocket() throws {
    let raw = Data("HTTP/1.1 201 Created\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}extra".utf8)
    let response = try AppSocket.parse(raw)
    #expect(response.status == 201)
    #expect(response.body == Data("{}".utf8))
    #expect(throws: AppSocket.Failure.self) { try AppSocket.parse(Data("garbage".utf8)) }
}

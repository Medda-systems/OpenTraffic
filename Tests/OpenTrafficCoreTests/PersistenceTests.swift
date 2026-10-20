import Foundation
import Testing
@testable import OpenTrafficCore

@Test func persistsAccountAssociationWithoutRuntimeState() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = TunnelPersistence(fileURL: directory.appending(path: "tunnels.json"))
    let definition = TunnelDefinition(
        name: "Development",
        kind: .remote,
        localURL: "http://localhost:3000",
        hostname: "dev.example.com",
        cloudflareTunnelID: "tunnel-id",
        accountID: "account-id"
    )
    try persistence.save([definition])
    #expect(try persistence.load() == [definition])
}

@Test func aMacAppShareKeepsItsAppAndDataChoice() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "tunnels.json")
    let persistence = TunnelPersistence(fileURL: file)
    let definition = TunnelDefinition(
        name: "Orbit",
        kind: .opentunnel,
        localURL: "http://127.0.0.1/",
        collaboration: true,
        openTunnelRoute: "orbit",
        agentDirectory: "/Users/me/code/orbit",
        macApp: "/Users/me/code/orbit/dist/Orbit.app",
        macAppData: .empty
    )
    try persistence.save([definition])
    let loaded = try persistence.load()
    #expect(loaded == [definition])
    #expect(loaded.first?.macApp == "/Users/me/code/orbit/dist/Orbit.app")
    #expect(loaded.first?.macAppData == .empty)
    let json = try String(contentsOf: file, encoding: .utf8)
    #expect(json.contains(#""macApp""#) && json.contains(#""macAppData""#))

    // Shares saved before Mac apps (or by a newer version with a data choice this one doesn't
    // know) still load; a blank app is no app.
    let older = #"{"id":"\#(UUID().uuidString)","name":"Shop","kind":"quick","localURL":"http://localhost:3000"}"#
    let plain = try JSONDecoder().decode(TunnelDefinition.self, from: Data(older.utf8))
    #expect(plain.macApp == nil && plain.macAppData == nil)
    let odd = #"{"id":"\#(UUID().uuidString)","name":"Orbit","kind":"quick","localURL":"http://127.0.0.1/","macApp":"","macAppData":"snapshot"}"#
    let tolerated = try JSONDecoder().decode(TunnelDefinition.self, from: Data(odd.utf8))
    #expect(tolerated.macApp == nil && tolerated.macAppData == nil)
}

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

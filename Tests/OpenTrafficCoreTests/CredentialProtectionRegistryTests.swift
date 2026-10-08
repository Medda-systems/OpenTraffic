import Foundation
import Testing
@testable import OpenTrafficCore

@Test func protectionRegistryPersistsAuthoritativeSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "protection.json")
    let registry = CredentialProtectionRegistry(fileURL: file)
    #expect(try !registry.isProtected(key: "account"))
    try registry.setProtected(true, key: "account")
    #expect(try CredentialProtectionRegistry(fileURL: file).isProtected(key: "account"))
    try registry.setProtected(false, key: "account")
    #expect(try !registry.isProtected(key: "account"))
}

@Test func corruptProtectionRegistryFailsClosed() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "protection.json")
    try Data("not-json".utf8).write(to: file)
    let registry = CredentialProtectionRegistry(fileURL: file)
    #expect(throws: (any Error).self) { try registry.isProtected(key: "account") }
}

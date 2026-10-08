import Foundation
import Testing
@testable import OpenTrafficCore

@MainActor
@Test func capturesFinalFastExitLogBeforeTermination() async throws {
    let executable = try makeScript("#!/bin/sh\necho '{\"level\":\"info\",\"message\":\"final-fast\",\"connIndex\":2}' >&2\nexit 7\n")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    let supervisor = ProcessSupervisor()
    let id = UUID()
    var entries: [TunnelLogEntry] = []
    var status: Int32?
    supervisor.onLogs = { _, _, newEntries in entries.append(contentsOf: newEntries) }
    supervisor.onTermination = { _, _, value in status = value }
    try supervisor.startQuick(id: id, generation: 1, executable: executable, localURL: "http://localhost:3000")

    for _ in 0..<100 where status == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(status == 7)
    #expect(entries.contains { $0.message == "final-fast" && $0.rawLine?.contains("connIndex") == true })
}

@MainActor
@Test func stopTerminatesAppOwnedProcess() async throws {
    let executable = try makeScript("#!/bin/sh\ntrap 'echo terminated >&2; exit 0' TERM\nwhile true; do sleep 1; done\n")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    let supervisor = ProcessSupervisor()
    let id = UUID()
    var status: Int32?
    supervisor.onTermination = { _, _, value in status = value }
    try supervisor.startQuick(id: id, generation: 1, executable: executable, localURL: "http://localhost:3000")
    try await Task.sleep(for: .milliseconds(100))
    supervisor.stop(id: id)

    for _ in 0..<150 where status == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(status == 0 || status == 15)
    #expect(!supervisor.isRunning(id: id))
}

private func makeScript(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "fake-cloudflared")
    try Data(contents.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}

import Foundation
import Testing
@testable import OpenTrafficCore

// Pages in a session catch up when the project's files change: which changes count, and that they arrive.

@Test func changesToThePagesFilesCountButNotToolingOrHiddenFiles() {
    let root = "/Users/ada/site"
    #expect(ProjectWatcher.matters("/Users/ada/site/index.html", under: root))
    #expect(ProjectWatcher.matters("/Users/ada/site/src/components/Hero.tsx", under: root))
    #expect(ProjectWatcher.matters("/Users/ada/site/dist/app.css", under: root))
    #expect(!ProjectWatcher.matters("/Users/ada/site/.git/index", under: root))
    #expect(!ProjectWatcher.matters("/Users/ada/site/node_modules/react/index.js", under: root))
    #expect(!ProjectWatcher.matters("/Users/ada/site/.DS_Store", under: root))
    #expect(!ProjectWatcher.matters("/Users/ada/site/.index.html.swp", under: root))
    #expect(!ProjectWatcher.matters("/Users/ada/site/index.html~", under: root))
    #expect(!ProjectWatcher.matters("/Users/ada/other/index.html", under: root))
    // FSEvents names /tmp as /private/tmp.
    #expect(ProjectWatcher.matters("/private/tmp/site/index.html", under: "/tmp/site"))
}

extension ProcessSpawningTests {
@Test func aChangedFileIsReportedOnceItsQuietAndToolingIsnt() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ot-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let count = Counter()
    let watcher = ProjectWatcher(directory: folder, delay: 0.2) { count.add() }
    #expect(watcher.start())
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))

    try "x".write(to: folder.appending(path: ".git/index"), atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(800))
    #expect(count.value == 0)

    // A burst of saves is one change.
    for n in 0..<3 { try "<h1>\(n)</h1>".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8) }
    #expect(await eventually { count.value >= 1 })
    try await Task.sleep(for: .milliseconds(500))
    #expect(count.value == 1)
}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

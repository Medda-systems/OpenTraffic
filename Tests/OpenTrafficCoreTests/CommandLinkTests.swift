import Foundation
import Testing
@testable import OpenTrafficCore

/// Two bin folders and an app bundle's command in a temporary folder.
private func scratch() throws -> (root: URL, first: String, second: String, target: String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "commandlink-\(UUID().uuidString)")
    let first = root.appending(path: "homebrew/bin").path
    let second = root.appending(path: "local/bin").path
    let target = root.appending(path: "Applications/OpenTraffic.app/Contents/Resources/opentraffic").path
    for directory in [first, second, (target as NSString).deletingLastPathComponent] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    FileManager.default.createFile(atPath: target, contents: Data("#!/bin/sh\n".utf8))
    return (root, first, second, target)
}

@Test func linksIntoTheFirstFolderAndFindsItAgain() throws {
    let s = try scratch()
    defer { try? FileManager.default.removeItem(at: s.root) }
    let link = CommandLink(name: "opentraffic", target: s.target, directories: [s.first, s.second])
    #expect(link.install() == .installed("\(s.first)/opentraffic"))
    #expect(link.installedPath == "\(s.first)/opentraffic")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(s.first)/opentraffic") == s.target)
    // Already there: nothing changes.
    #expect(link.install() == .installed("\(s.first)/opentraffic"))
}

@Test func updatesAnOlderLinkWhereverItIs() throws {
    let s = try scratch()
    defer { try? FileManager.default.removeItem(at: s.root) }
    // A link to a copy that has since moved, in the second folder.
    try FileManager.default.createSymbolicLink(atPath: "\(s.second)/opentraffic", withDestinationPath: "/Volumes/OpenTraffic/OpenTraffic.app/Contents/Resources/opentraffic")
    let link = CommandLink(name: "opentraffic", target: s.target, directories: [s.first, s.second])
    #expect(link.install() == .installed("\(s.second)/opentraffic"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(s.second)/opentraffic") == s.target)
    #expect(!FileManager.default.fileExists(atPath: "\(s.first)/opentraffic"))
}

@Test func leavesSomeoneElsesCommandAlone() throws {
    let s = try scratch()
    defer { try? FileManager.default.removeItem(at: s.root) }
    FileManager.default.createFile(atPath: "\(s.first)/opentraffic", contents: Data("mine".utf8))
    try FileManager.default.createSymbolicLink(atPath: "\(s.second)/opentraffic", withDestinationPath: "/usr/local/lib/other-tool")
    let link = CommandLink(name: "opentraffic", target: s.target, directories: [s.first, s.second])
    guard case .blocked = link.install() else { Issue.record("Expected to be blocked"); return }
    #expect(try String(contentsOfFile: "\(s.first)/opentraffic", encoding: .utf8) == "mine")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(s.second)/opentraffic") == "/usr/local/lib/other-tool")
    // Removing only takes away links of ours.
    link.uninstall()
    #expect(FileManager.default.fileExists(atPath: "\(s.first)/opentraffic"))
}

@Test func usesTheNextFolderWhenTheFirstIsTaken() throws {
    let s = try scratch()
    defer { try? FileManager.default.removeItem(at: s.root) }
    FileManager.default.createFile(atPath: "\(s.first)/opentraffic", contents: Data("mine".utf8))
    let link = CommandLink(name: "opentraffic", target: s.target, directories: [s.first, s.second])
    #expect(link.install() == .installed("\(s.second)/opentraffic"))
    link.uninstall()
    #expect(link.installedPath == nil)
    #expect(FileManager.default.fileExists(atPath: "\(s.first)/opentraffic"))
}

@Test func createsAFolderItMayCreate() throws {
    let s = try scratch()
    defer { try? FileManager.default.removeItem(at: s.root) }
    let missing = s.root.appending(path: "home/.local/bin").path
    let link = CommandLink(name: "opentraffic", target: s.target, directories: [missing])
    #expect(link.install(creating: [missing]) == .installed("\(missing)/opentraffic"))
}

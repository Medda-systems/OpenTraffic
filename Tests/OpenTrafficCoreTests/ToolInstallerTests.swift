import Foundation
import Testing
@testable import OpenTrafficCore

private let cloudflaredRelease = Data(#"""
{"tag_name":"2026.10.0","assets":[
 {"name":"cloudflared-darwin-amd64.tgz","size":21741581,"digest":"sha256:903845B81828c8cb3c5d13d816a2de71c06a3da5785469df8eb0e1b736d92f9f","browser_download_url":"https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-darwin-amd64.tgz"},
 {"name":"cloudflared-darwin-arm64.tgz","size":19809074,"digest":"sha256:a2f79ff7b9420aa537d74af239f376da170bbabeb529aec416002adac6a72e70","browser_download_url":"https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-darwin-arm64.tgz"},
 {"name":"cloudflared-linux-arm64","size":1,"digest":null,"browser_download_url":"https://example.com/x"}]}
"""#.utf8)

private let openTunnelRelease = Data(#"""
{"tag_name":"v0.5.1","assets":[
 {"name":"opentunnel-darwin-arm64.tar.gz","size":2747579,"digest":"sha256:04f690092d45a46b35446f15adabb957adca62943241517a9c2cf99744943eba","browser_download_url":"https://github.com/anomalyco/opentunnel/releases/download/v0.5.1/opentunnel-darwin-arm64.tar.gz"},
 {"name":"opentunnel-darwin-x64.tar.gz","size":2946787,"browser_download_url":"https://github.com/anomalyco/opentunnel/releases/download/v0.5.1/opentunnel-darwin-x64.tar.gz"}]}
"""#.utf8)

@Test func picksCloudflaredForThisMacsArchitecture() throws {
    let arm = try ToolCatalog.githubRelease(for: .cloudflare, json: cloudflaredRelease, architecture: "arm64")
    #expect(arm.version == "2026.10.0")
    #expect(arm.url.lastPathComponent == "cloudflared-darwin-arm64.tgz")
    #expect(arm.size == 19_809_074)
    #expect(arm.sha256 == "a2f79ff7b9420aa537d74af239f376da170bbabeb529aec416002adac6a72e70")
    #expect(arm.teamID == "68WVV388M8")
    #expect(arm.host == "github.com")
    let intel = try ToolCatalog.githubRelease(for: .cloudflare, json: cloudflaredRelease, architecture: "x86_64")
    #expect(intel.url.lastPathComponent == "cloudflared-darwin-amd64.tgz")
    // Digests are compared in lowercase.
    #expect(intel.sha256 == "903845b81828c8cb3c5d13d816a2de71c06a3da5785469df8eb0e1b736d92f9f")
}

@Test func openTunnelIsCheckedByChecksumNotTeam() throws {
    let arm = try ToolCatalog.githubRelease(for: .opentunnel, json: openTunnelRelease, architecture: "arm64")
    #expect(arm.version == "0.5.1")
    #expect(arm.teamID == nil)
    #expect(arm.sha256 != nil)
    let intel = try ToolCatalog.githubRelease(for: .opentunnel, json: openTunnelRelease, architecture: "x86_64")
    #expect(intel.url.lastPathComponent == "opentunnel-darwin-x64.tar.gz")
    #expect(intel.sha256 == nil)
}

@Test func aReleaseWithoutThisMacsBuildIsRefused() {
    let json = Data(#"{"tag_name":"1.0","assets":[]}"#.utf8)
    #expect(throws: ToolInstallError.noBuild) { try ToolCatalog.githubRelease(for: .cloudflare, json: json, architecture: "arm64") }
}

@Test func readsVersionsFromToolOutput() {
    #expect(ToolCatalog.version(in: "cloudflared version 2026.10.0 (built 2026-10-05-1738 UTC)") == "2026.10.0")
    #expect(ToolCatalog.version(in: "opentunnel 0.5.1") == "0.5.1")
    #expect(ToolCatalog.version(in: "ngrok version 3.24.0") == "3.24.0")
    #expect(ToolCatalog.version(in: "no version here") == nil)
}

@Test func hashesFiles() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "tool-hash-\(UUID().uuidString)")
    try Data("opentraffic".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try ToolInstaller.sha256(of: file) == "3a1de4b266b1672004d77adf709973701f6c96ee2594cba04b2bfbb201a8b453")
}

@Test func checksSignaturesAndTeams() throws {
    // Apple's own tools have a valid signature, but not a Developer ID from someone else's team.
    try ToolInstaller.verifySignature(of: URL(fileURLWithPath: "/bin/ls"), teamID: nil, publisher: "Apple")
    #expect(throws: ToolInstallError.signature("Cloudflare, Inc.")) {
        try ToolInstaller.verifySignature(of: URL(fileURLWithPath: "/bin/ls"), teamID: "68WVV388M8", publisher: "Cloudflare, Inc.")
    }
}

@Test func onlyTailscaleIsLeftToTheAppStore() {
    #expect(ManagedTools.canInstall(.cloudflare))
    #expect(ManagedTools.canInstall(.opentunnel))
    #expect(ManagedTools.canInstall(.ngrok))
    #expect(!ManagedTools.canInstall(.tailscale))
    #expect(ExecutableLocator.commonPaths(for: .cloudflare).last == ManagedTools.path(for: .cloudflare).path)
}

/// Installs the real tools from the internet. Run with OPENTRAFFIC_NETWORK_TESTS=1 and CFFIXED_USER_HOME
/// set to a scratch folder, so they land there instead of in your Application Support.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENTRAFFIC_NETWORK_TESTS"] == "1"), arguments: [TunnelProvider.cloudflare, .opentunnel, .ngrok])
func installsTheRealTool(_ provider: TunnelProvider) async throws {
    let release = try await ToolCatalog.latestRelease(for: provider)
    let phases = PhaseLog()
    let installed = try await ToolInstaller.install(release) { phases.append($0) }
    #expect(installed.path == ManagedTools.path(for: provider))
    #expect(FileManager.default.isExecutableFile(atPath: installed.path.path))
    #expect(ManagedTools.installedVersion(of: provider) == installed.version)
    #expect(phases.values.contains(.verifying) && phases.values.contains(.installing))
    let updates = phases.values.filter { if case .downloading = $0 { true } else { false } }.count
    print("installed \(provider.executableName) \(installed.version) from \(release.url.absoluteString), \(updates) progress updates")
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [ToolInstaller.Phase] = []
    func append(_ phase: ToolInstaller.Phase) { lock.withLock { phases.append(phase) } }
    var values: [ToolInstaller.Phase] { lock.withLock { phases } }
}

/// A fake "opentunnel" (an unsigned shell script) packed like a real release, served from disk.
private func fakeRelease(sha256: (URL) throws -> String?) throws -> (ToolRelease, URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "fake-tool-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = folder.appending(path: "opentunnel")
    try Data("#!/bin/sh\necho opentunnel 9.9.9\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let archive = folder.appending(path: "opentunnel.tar.gz")
    try ToolInstaller.run("/usr/bin/tar", ["-czf", archive.path, "-C", folder.path, "opentunnel"])
    let release = ToolRelease(provider: .opentunnel, version: "9.9.9", url: archive, size: nil, sha256: try sha256(archive),
                              archive: .tarGzip, publisher: "Anomaly", teamID: nil)
    return (release, folder)
}

@Test func refusesADownloadThatDoesNotMatchItsChecksum() async throws {
    let (release, folder) = try fakeRelease { _ in String(repeating: "0", count: 64) }
    defer { try? FileManager.default.removeItem(at: folder) }
    await #expect(throws: ToolInstallError.checksumMismatch) { try await ToolInstaller.install(release) { _ in } }
}

@Test func refusesAnUnsignedToolEvenWithTheRightChecksum() async throws {
    let (release, folder) = try fakeRelease { try ToolInstaller.sha256(of: $0) }
    defer { try? FileManager.default.removeItem(at: folder) }
    await #expect(throws: ToolInstallError.signature("Anomaly")) { try await ToolInstaller.install(release) { _ in } }
    #expect(ManagedTools.installedVersion(of: .opentunnel) != "9.9.9")
}

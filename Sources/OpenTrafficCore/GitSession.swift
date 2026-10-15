import Foundation
import os

/// A collaborative share's branch: while the share runs, the project works on its own branch (fixes
/// from feedback land there, one commit each), and when it stops the branch is merged back into the
/// one it started from, if that can be done cleanly.
public struct GitBranchSession: Codable, Hashable, Sendable {
    /// The repository's top folder.
    public let root: String
    /// The branch the session started from, and merges back into.
    public let original: String
    public let branch: String
    public let startedAt: Date

    public init(root: String, original: String, branch: String, startedAt: Date) {
        self.root = root
        self.original = original
        self.branch = branch
        self.startedAt = startedAt
    }
}

/// Changed files and their contents (git object ids; "-" for deleted), so later changes can be told
/// apart from what was already there.
public struct GitSnapshot: Equatable, Sendable {
    public var files: [String: String]

    public init(files: [String: String] = [:]) {
        self.files = files
    }

    /// Paths changed in `now` that weren't already changed this way here.
    public func changes(to now: GitSnapshot) -> [String] {
        now.files.filter { files[$0.key] != $0.value }.map(\.key).sorted()
    }
}

public enum GitSessionError: Error, Equatable, LocalizedError {
    case notARepository
    case detachedHead
    case operationInProgress
    /// git isn't installed (neither Homebrew's nor Apple's Command Line Tools).
    case gitMissing
    /// git doesn't know who's committing.
    case noIdentity
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository: "The project folder isn't in a git repository."
        case .detachedHead: "The repository isn't on a branch (detached HEAD)."
        case .operationInProgress: "The repository is in the middle of a merge, rebase, or similar."
        case .gitMissing: "git isn't installed on this Mac."
        case .noIdentity: "git doesn't know your name yet. In Terminal, run git config --global user.name \"Your Name\" and git config --global user.email you@example.com."
        case .failed(let message): message
        }
    }
}

/// How ending a session went.
public enum GitSessionEnd: Equatable, Sendable {
    /// Merged into the original branch (which is checked out again), with how many commits.
    case merged(commits: Int)
    /// Left as it is; the reason says why and what to do.
    case kept(reason: String)
}

/// Git operations on one repository, run with `/usr/bin/git`. Calls are serialized per instance.
public final class GitRepository: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let git: String
    /// Added to git's environment (tests point it at their own configuration).
    private let environment: [String: String]

    public init(root: URL, git: String = GitRepository.defaultGit, environment: [String: String] = [:]) {
        self.root = root
        self.git = git
        self.environment = environment
    }

    /// Homebrew's git when there is one, else Apple's.
    public static let defaultGit: String = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    /// Whether git can run. Apple's /usr/bin/git is only a stub without the Command Line Tools (or Xcode),
    /// and running it opens macOS's "install developer tools" dialog, so it's checked without running it.
    public static var isGitInstalled: Bool {
        guard defaultGit == "/usr/bin/git" else { return true }
        guard let developer = ToolOutput.run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !developer.isEmpty else { return false }
        return FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/git")
    }

    /// Opens Apple's installer for the Command Line Tools, which include git.
    public static func installCommandLineTools() {
        _ = ToolOutput.run("/usr/bin/xcode-select", ["--install"])
    }

    /// The repository containing `directory`, or nil.
    public static func containing(_ directory: URL, git: String = GitRepository.defaultGit, environment: [String: String] = [:]) -> GitRepository? {
        let probe = GitRepository(root: directory, git: git, environment: environment)
        guard let top = try? probe.run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else { return nil }
        return GitRepository(root: URL(fileURLWithPath: top, isDirectory: true), git: git, environment: environment)
    }

    /// What's ignored in a repository OpenTraffic sets up, when the project has no .gitignore.
    public static let defaultIgnore = """
    # Written by OpenTraffic when it set up git here. Edit freely.
    node_modules/
    .pnp.*
    dist/
    build/
    out/
    .next/
    .nuxt/
    .svelte-kit/
    .output/
    .vercel/
    .turbo/
    .cache/
    .parcel-cache/
    coverage/
    *.log
    .DS_Store
    .env
    .env.*
    !.env.example
    !.env.sample

    """

    /// Sets up git in `directory`: a repository whose first branch is main, a .gitignore when there isn't
    /// one, and a first commit of what's there, leaving out .env files (secrets) and files over
    /// `maximumFileBytes`, which stay as untracked files. Local only: no remote.
    public static func initialize(
        _ directory: URL, git: String = GitRepository.defaultGit, environment: [String: String] = [:],
        maximumFileBytes: Int = 10 * 1024 * 1024
    ) throws -> GitRepository {
        let repository = GitRepository(root: directory, git: git, environment: environment)
        // Without a name, the first commit would fail after the repository exists.
        guard let name = try? repository.run(["config", "user.name"]), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let email = try? repository.run(["config", "user.email"]), !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitSessionError.noIdentity
        }
        try repository.run(["init", "--quiet", "--initial-branch=main"])
        let ignore = directory.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try defaultIgnore.write(to: ignore, atomically: true, encoding: .utf8)
        }
        try repository.run(["add", "-A"])
        let staged = try repository.run(["diff", "--cached", "--name-only", "-z"]).split(separator: "\0").map(String.init)
        let leftOut = staged.filter { path in
            if isSecretFile(path) { return true }
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appending(path: path).path)[.size] as? Int) ?? 0
            return size > maximumFileBytes
        }
        for batch in stride(from: 0, to: leftOut.count, by: 200) {
            try repository.run(["rm", "--cached", "--quiet", "--"] + leftOut[batch..<min(batch + 200, leftOut.count)])
        }
        try repository.run(["commit", "--quiet", "--allow-empty", "-m", "Before OpenTraffic", "-m", "The project as it was when OpenTraffic set up git for it."])
        return repository
    }

    /// `.env` and `.env.*` files, which usually hold secrets (examples and samples excepted).
    static func isSecretFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard name == ".env" || name.hasPrefix(".env.") else { return false }
        return ![".env.example", ".env.sample", ".env.template"].contains(name)
    }

    // MARK: Sessions

    /// Creates the session's branch from the current one and switches to it. Uncommitted changes stay
    /// as they are, uncommitted. Returns the session and what was already changed.
    public func startSession(name: String, now: Date = Date()) throws -> (session: GitBranchSession, baseline: GitSnapshot) {
        try lock.withLock {
            guard !operationInProgress else { throw GitSessionError.operationInProgress }
            guard let original = try? run(["symbolic-ref", "--short", "-q", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
                  !original.isEmpty else { throw GitSessionError.detachedHead }
            let branch = try freeBranchName(Self.branchName(for: name, at: now))
            _ = try run(["switch", "-c", branch])
            return (GitBranchSession(root: root.path, original: original, branch: branch, startedAt: now), try snapshot())
        }
    }

    /// Whether the session's branch is still checked out.
    public func isOn(_ session: GitBranchSession) -> Bool {
        lock.withLock { currentBranch == session.branch }
    }

    /// Changed files right now.
    public func currentSnapshot() throws -> GitSnapshot {
        try lock.withLock { try snapshot() }
    }

    /// Commits what changed since `since` (and only that) on the session's branch. Returns the commit,
    /// or nil when nothing changed. Other uncommitted changes, staged or not, are left alone.
    @discardableResult
    public func commitChanges(since: GitSnapshot, in session: GitBranchSession, subject: String, body: String) throws -> String? {
        try lock.withLock {
            guard currentBranch == session.branch else { return nil }
            // .env files hold secrets: never committed for a fix, whatever .gitignore says.
            let paths = since.changes(to: try snapshot()).filter { !Self.isSecretFile($0) }
            guard !paths.isEmpty else { return nil }
            _ = try run(["add", "-A", "--"] + paths)
            _ = try run(["commit", "--quiet", "-m", subject, "-m", body, "--"] + paths)
            return try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Merges the session's branch back into the original one, when that's clean: a fast-forward
    /// (the usual case, which leaves the working folder exactly as it is), or a merge without
    /// conflicts when nothing is uncommitted. Otherwise the branch stays checked out.
    public func endSession(_ session: GitBranchSession) throws -> GitSessionEnd {
        try lock.withLock {
            guard currentBranch == session.branch else {
                return .kept(reason: "\(session.branch) isn't checked out any more, so OpenTraffic left both branches alone.")
            }
            guard !operationInProgress else {
                return .kept(reason: "The repository is in the middle of a merge or rebase; \(session.branch) is still checked out.")
            }
            let branchHead = try revision(session.branch)
            guard let originalHead = try? revision("refs/heads/\(session.original)") else {
                return .kept(reason: "\(session.original) no longer exists; \(session.branch) is still checked out.")
            }
            let commits = Int(try run(["rev-list", "--count", "\(originalHead)..\(branchHead)"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            // Only fixes that look like ordinary page changes merge by themselves.
            if commits > 0, let reason = try reviewChanges(from: originalHead, to: branchHead) {
                return .kept(reason: "\(session.branch) is still checked out for you to look at before merging into \(session.original): \(reason).")
            }
            if (try? run(["merge-base", "--is-ancestor", originalHead, branchHead])) != nil {
                // Fast-forward without touching the working folder: both names point at the same commit.
                _ = try run(["update-ref", "-m", "OpenTraffic: merge \(session.branch)", "refs/heads/\(session.original)", branchHead, originalHead])
                _ = try run(["symbolic-ref", "HEAD", "refs/heads/\(session.original)"])
                _ = try? run(["branch", "-d", session.branch])
                return .merged(commits: commits)
            }
            // The original branch moved on meanwhile: a real merge, only from a clean working folder.
            guard try run(["status", "--porcelain", "--untracked-files=no"]).isEmpty else {
                return .kept(reason: "\(session.original) changed since the share started and there are uncommitted changes, so \(session.branch) wasn't merged. Merge it yourself.")
            }
            _ = try run(["switch", "--quiet", session.original])
            do {
                _ = try run(["merge", "--no-edit", "--quiet", session.branch])
            } catch {
                _ = try? run(["merge", "--abort"])
                _ = try? run(["switch", "--quiet", session.branch])
                return .kept(reason: "Merging \(session.branch) into \(session.original) would conflict, so it's still checked out. Merge it yourself.")
            }
            _ = try? run(["branch", "-d", session.branch])
            return .merged(commits: commits)
        }
    }

    /// What `MergeGuard` makes of the changes between two commits, or nil when they may merge.
    private func reviewChanges(from base: String, to head: String) throws -> String? {
        let paths = try run(["diff", "--name-only", "-z", "\(base)..\(head)"]).split(separator: "\0").map(String.init)
        let added = try run(["diff", "--unified=0", "--no-color", "--no-ext-diff", "\(base)..\(head)"])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .map { String($0.dropFirst()) }
        return MergeGuard.review(paths: paths, addedLines: added)
    }

    // MARK: Helpers

    /// `opentraffic/<share>-<yyyyMMdd-HHmm>`.
    public static func branchName(for name: String, at date: Date) -> String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || (result.last.map { $0 != "-" } ?? false) { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "opentraffic/\(slug.isEmpty ? "share" : String(slug.prefix(30)))-\(formatter.string(from: date))"
    }

    private func freeBranchName(_ base: String) throws -> String {
        for suffix in [""] + (2...20).map({ "-\($0)" }) {
            let name = base + suffix
            if (try? revision("refs/heads/\(name)")) == nil { return name }
        }
        throw GitSessionError.failed("Couldn't find a free branch name like \(base).")
    }

    private var currentBranch: String? {
        (try? run(["symbolic-ref", "--short", "-q", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var operationInProgress: Bool {
        guard let gitDir = try? run(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"]
            .contains { FileManager.default.fileExists(atPath: gitDir + "/" + $0) }
    }

    private func revision(_ name: String) throws -> String {
        try run(["rev-parse", "--verify", "--quiet", name]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every changed or new (not ignored) file, relative to the root, with its contents' object id.
    private func snapshot() throws -> GitSnapshot {
        let status = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        var paths: [String] = []
        var entries = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            // Renames and copies are followed by the old path.
            if code.contains("R") || code.contains("C"), let old = entries.popFirst() { paths.append(old) }
        }
        var files: [String: String] = [:]
        var existing: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory) {
                files[path] = "-"
            } else if !isDirectory.boolValue {
                existing.append(path)
            } // A changed submodule: not ours to commit.
        }
        if !existing.isEmpty {
            let ids = try run(["hash-object", "--"] + existing).split(separator: "\n").map(String.init)
            for (path, id) in zip(existing, ids) { files[path] = id }
        }
        return GitSnapshot(files: files)
    }

    /// Runs git in the repository; its output, or `.failed` with what it said.
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment.merge(self.environment) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw GitSessionError.failed("Couldn't run git: \(error.localizedDescription)") }
        // Read both to the end before waiting, so a full pipe can't stall git.
        let errorData = OSAllocatedUnfairLock(initialState: Data())
        let readErrors = DispatchSemaphore(value: 0)
        Thread {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
            readErrors.signal()
        }.start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        readErrors.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("not a git repository") { throw GitSessionError.notARepository }
            throw GitSessionError.failed(message.isEmpty ? "git \(arguments.first ?? "") failed." : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

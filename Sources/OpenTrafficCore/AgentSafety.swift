import Darwin
import Foundation

// Keeping agents OpenTraffic starts safe from what visitors write. Anyone with a share's link can comment,
// and an agent reads the comment, so a comment can try to talk the agent into something (prompt
// injection). None of this changes what anyone sees in normal use; each piece only acts when something
// looks wrong. See specs/collab-plan.md, 3.7.

// MARK: One comment only

/// What a run of the agent command may touch: the one comment it was started for. Every request from the
/// run's processes (the agent, its MCP bridge, an `opentraffic` command it runs) is held to it, so a
/// talked-into agent can't publish other local servers, start or stop shares, or read other feedback.
public struct AgentRunScope: Equatable, Sendable {
    public let shareID: UUID
    public let commentID: String

    public init(shareID: UUID, commentID: String) {
        self.shareID = shareID
        self.commentID = commentID
    }

    /// MCP tools a run may call; each only on its comment.
    public static let tools: Set<String> = [
        "get_feedback", "get_screenshot", "claim_comment", "release_comment", "reply_to_comment", "resolve_comment",
    ]

    /// For a process OpenTraffic's runs left behind: no share, no comment, so every request is refused.
    public static let nothing = AgentRunScope(shareID: UUID(uuid: UUID_NULL), commentID: "")

    static let refusal = "This agent was started by OpenTraffic for one comment, and may only read, claim, reply to, and resolve that comment."

    static func refused(_ extra: String? = nil) -> OpenTrafficAPIError {
        OpenTrafficAPIError.denied(extra.map { "\(refusal) \($0)" } ?? refusal)
    }
}

/// Processes and their parents, for telling whether a caller belongs to a run of the agent command.
public enum ProcessAncestry {
    /// The parent of `pid`, or nil when it's gone.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// Whether `pid` is one of `roots`, or was started (directly or not) by one of them.
    public static func descends(_ pid: pid_t, from roots: Set<pid_t>) -> Bool {
        guard !roots.isEmpty else { return false }
        var current: pid_t? = pid
        var steps = 0
        while let process = current, process > 1, steps < 64 {
            if roots.contains(process) { return true }
            current = parent(of: process)
            steps += 1
        }
        return false
    }

    /// The app macOS holds responsible for `pid`: the one that started its chain of processes. Unlike the
    /// parent, it stays when a process lets go of what it started (a child whose parent exits goes to
    /// launchd). Nil if macOS can't tell.
    public static func responsibleProcess(of pid: pid_t) -> pid_t? {
        guard let responsible = responsibility, pid > 0 else { return nil }
        let result = responsible(pid)
        return result > 0 ? result : nil
    }

    /// Whether `pid` was started, however indirectly, by this app (`app`), when this app was opened as an
    /// app (from the Finder, Dock or `open`), so that it's responsible for itself. Started from a terminal,
    /// the terminal is responsible for the app and everything typed in it alike, so nothing can be told.
    public static func startedByApp(_ pid: pid_t, app: pid_t = getpid()) -> Bool {
        guard pid != app, responsibleProcess(of: app) == app else { return false }
        return responsibleProcess(of: pid) == app
    }

    /// `responsibility_get_pid_responsible_for_pid`, which macOS has but doesn't declare in its headers.
    private static let responsibility: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The process on the other end of a loopback TCP connection that came from `port`, if it can be told.
    public static func ownerOfLocalTCPPort(_ port: Int) -> pid_t? {
        guard (1...65_535).contains(port),
              let output = ToolOutput.run("/usr/sbin/lsof", ["-nP", "-iTCP@127.0.0.1:\(port)", "-sTCP:ESTABLISHED", "-Fp"], timeout: 2) else { return nil }
        let own = getpid()
        return output.split(separator: "\n").compactMap { line -> pid_t? in
            guard line.hasPrefix("p") else { return nil }
            return pid_t(line.dropFirst())
        }.first { $0 != own }
    }
}

// MARK: Secrets in replies

/// Blanks out secrets in text an agent wants to show visitors (a reply, its progress): the values of the
/// project's `.env` files, and anything shaped like a key, token, or private key.
public struct ReplyRedactor: Sendable {
    public static let placeholder = "[hidden]"

    /// Exact values to hide, longest first.
    private let values: [String]

    private static let patterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        #"\b(?:sk|pk|rk)-(?:[a-z]+-)?[A-Za-z0-9_\-]{16,}"#,           // OpenAI, Anthropic, Stripe-style keys
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"#,             // GitHub tokens
        #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#,
        #"\bglpat-[A-Za-z0-9_\-]{16,}\b"#,                            // GitLab
        #"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b"#,                       // Slack
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,                            // AWS access key ids
        #"\bAIza[0-9A-Za-z_\-]{30,}\b"#,                              // Google API keys
        #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, // JWTs
        #"\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+:[^\s@/]{4,}@"#,      // passwords in URLs
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public init(values: [String] = []) {
        self.values = Array(Set(values.filter { $0.count >= 8 })).sorted { $0.count > $1.count }
    }

    /// The text with secrets replaced, and whether anything was.
    public func redact(_ text: String) -> (text: String, redacted: Bool) {
        var result = text
        for value in values where result.contains(value) {
            result = result.replacingOccurrences(of: value, with: Self.placeholder)
        }
        for pattern in Self.patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: Self.placeholder)
        }
        return (result, result != text)
    }

    /// The values in a project's `.env` files (`.env`, `.env.local`, …; not examples), which are usually secrets.
    public static func environmentValues(in directories: [URL]) -> [String] {
        var values: [String] = []
        for directory in Set(directories.map(\.standardizedFileURL)) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where GitRepository.isSecretFile(name) {
                guard let text = try? String(contentsOf: directory.appending(path: name), encoding: .utf8) else { continue }
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
                    var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                        value = String(value.dropFirst().dropLast())
                    }
                    values.append(value)
                }
            }
        }
        return values
    }
}

// MARK: Run budget

/// How many runs of the agent command new comments may start by themselves, so nobody can burn through the
/// host's subscription or API credits by posting comment after comment. Past it, comments wait for the
/// host's Send to …; nothing else changes. People the host trusted by name aren't counted: the host
/// already decided their comments may run the agent.
public struct AgentRunBudget: Sendable {
    public static let perShare = 30
    public static let perVisitor = 10
    public static let window: TimeInterval = 60 * 60

    private var runs: [(share: UUID, visitor: String, at: Date)] = []

    public init() {}

    public func allows(share: UUID, visitor: String, now: Date = Date()) -> Bool {
        let recent = runs.filter { now.timeIntervalSince($0.at) < Self.window }
        return recent.filter { $0.share == share }.count < Self.perShare
            && recent.filter { $0.share == share && $0.visitor == visitor }.count < Self.perVisitor
    }

    public mutating func record(share: UUID, visitor: String, at date: Date = Date()) {
        runs.removeAll { date.timeIntervalSince($0.at) >= Self.window }
        runs.append((share, visitor, date))
    }
}

// MARK: Comments that wait for the host

/// Why a visitor's comment waits for the host's Send to … instead of starting the agent by itself.
public enum AgentHold: String, Equatable, Sendable {
    /// The host hasn't made them trusted.
    case notTrusted
    /// It reads more like instructions for an agent than feedback.
    case readsLikeOrders
    /// The agent already ran by itself as often as it may this hour.
    case budgetSpent
    /// A Mac app share whose project folder OpenTraffic doesn't know: the agent would have nowhere to work.
    case noProjectFolder

    /// Says why, after "Waiting for you: ".
    public func reason(agent: String) -> String {
        switch self {
        case .notTrusted: "only people you trust start \(agent) by themselves"
        case .readsLikeOrders: "it reads more like instructions than feedback"
        case .budgetSpent: "\(agent) already ran by itself as often as it may this hour"
        case .noProjectFolder: "OpenTraffic doesn't know which project the app is built from; choose its project folder in the Feedback tab"
        }
    }
}

extension AgentDispatchPolicy {
    /// Whether `comment` waits for the host, and why: nil when it may start the agent by itself. People
    /// trusted by name skip the budget; people trusted only because everyone is (New people can) don't.
    public static func hold(_ comment: CollabComment, on share: TunnelDefinition, siteHost: String?, budget: AgentRunBudget, now: Date = Date()) -> AgentHold? {
        guard !comment.fromHost else { return nil }
        guard share.collabRole(forClient: comment.authorClient) == .trusted else { return .notTrusted }
        if looksSuspicious(comment, siteHost: siteHost) { return .readsLikeOrders }
        if countsAgainstBudget(comment, on: share),
           !budget.allows(share: share.id, visitor: comment.authorClient ?? comment.author, now: now) {
            return .budgetSpent
        }
        return nil
    }

    /// Whether a run for `comment` uses up the budget: everyone's but the host's and those trusted by name.
    public static func countsAgainstBudget(_ comment: CollabComment, on share: TunnelDefinition) -> Bool {
        !comment.fromHost && comment.authorClient.flatMap { share.collabMembers[$0]?.role } != .trusted
    }
}

// MARK: Comments that read like orders

extension AgentDispatchPolicy {
    /// Whether a comment reads more like instructions for an agent than feedback about a page: commands,
    /// talk of instructions or secrets, links elsewhere, encoded blobs, or a wall of text. Such comments
    /// aren't run by themselves; they wait for the host's Send to …. `siteHost` is the share's own host.
    public static func looksSuspicious(_ comment: CollabComment, siteHost: String?) -> Bool {
        let text = [comment.text, comment.label ?? "", comment.title ?? ""].joined(separator: "\n")
        if comment.text.count > 600 { return true }
        let lower = text.lowercased()
        for pattern in suspiciousPatterns where lower.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        // Links anywhere but the site itself.
        let links = text.matches(of: /(?i)\b(?:https?|ftp|file|data|javascript):[^\s"'<>]+/).map { String($0.output) }
        let host = siteHost?.lowercased()
        for link in links {
            guard let url = URL(string: link), let linkHost = url.host?.lowercased(), linkHost == host else { return true }
        }
        return false
    }

    // Shapes of attempts, not topics: "the password field is misaligned" is feedback; "reply with the
    // password" isn't.
    private static let suspiciousPatterns = [
        #"\b(?:ignore|disregard|forget|override)\b[^.\n]{0,30}\b(?:instructions?|rules|prompt|guidelines|above|previous)\b"#,
        #"\b(?:system prompt|developer message|you are now|new instructions|jailbreak|as an ai)\b"#,
        #"\b(?:curl|wget|sudo|chmod|chown|rm -rf|powershell|osascript|base64 -d|sh -c|bash -c|zsh -c|npm (?:i|install|run)|npx|pip install|brew install)\b"#,
        #"(?:\||&&|;)\s*(?:sh|bash|zsh|python3?|node|perl|ruby)\b|\b(?:eval|exec)\s*\("#,
        #"(?:^|[\s/~])(?:\.env\b|\.ssh\b|id_rsa|id_ed25519|\.aws\b|\.npmrc|\.netrc|/etc/passwd|keychain)"#,
        #"\b(?:reveal|send|show|print|give|share|post|reply with|tell me|paste|upload|leak|email)\b[^.\n]{0,40}\b(?:api[ _-]?keys?|secrets?|passwords?|tokens?|credentials?|private keys?|env(?:ironment)? (?:file|variables?))\b"#,
        #"\b(?:mcp|tool call|list_shares|start_share|stop_share|wait_for_feedback|get_logs)\b"#,
        #"[A-Za-z0-9+/]{48,}={0,2}"#,
    ]
}

// MARK: Careful auto-merge

/// Whether a share's branch may be merged by itself when the share stops: only if its fixes look like
/// ordinary page changes. Anything touching build scripts, dependencies, CI, server code, or adding
/// network calls, code execution, or secrets access is kept on its branch for the host to look at.
public enum MergeGuard {
    public static let maximumAddedLines = 400

    /// Why the change needs the host's eyes, or nil when it may be merged.
    public static func review(paths: [String], addedLines: [String]) -> String? {
        if let path = paths.first(where: isSensitive) {
            return "it changes \(path), which can run code or change what gets installed"
        }
        if addedLines.count > maximumAddedLines {
            return "it adds \(addedLines.count) lines, more than a fix for a comment usually needs"
        }
        let code = addedLines.joined(separator: "\n")
        for (pattern, what) in riskyCode where code.range(of: pattern, options: .regularExpression) != nil {
            return "it adds \(what)"
        }
        return nil
    }

    static func isSensitive(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let sensitiveNames: Set<String> = [
            "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "deno.json",
            "requirements.txt", "pyproject.toml", "poetry.lock", "gemfile", "gemfile.lock", "go.mod", "go.sum",
            "cargo.toml", "cargo.lock", "composer.json", "dockerfile", "docker-compose.yml", "compose.yaml",
            "makefile", "procfile", ".npmrc", ".yarnrc", ".yarnrc.yml", ".nvmrc", ".tool-versions", "vercel.json",
            "netlify.toml", "wrangler.toml", "wrangler.jsonc", "firebase.json", ".htaccess",
        ]
        if sensitiveNames.contains(name) || name.hasPrefix(".env") || name.hasPrefix("dockerfile") { return true }
        // Build tooling runs as code on the machine that builds the site.
        if name.range(of: #"^(vite|next|nuxt|svelte|astro|remix|webpack|rollup|esbuild|babel|postcss|tailwind|turbo|tsup|vitest|jest|playwright|eslint)\.config\.[a-z]+$"#, options: .regularExpression) != nil {
            return true
        }
        let extensionName = (name as NSString).pathExtension
        if ["sh", "bash", "zsh", "ps1", "bat", "cmd", "command", "py", "rb", "pl", "php", "go", "rs", "java", "swift", "c", "cc", "cpp", "sql"].contains(extensionName) {
            return true
        }
        let parts = lower.split(separator: "/").map(String.init)
        let sensitiveFolders: Set<String> = [".github", ".gitlab", ".circleci", ".husky", ".git", ".vscode", "scripts", "bin", "server", "api", "functions", "middleware", "migrations", "supabase", "prisma", "infra", "terraform", ".cargo"]
        if parts.dropLast().contains(where: sensitiveFolders.contains) { return true }
        if name.hasPrefix("middleware.") || name.hasPrefix("instrumentation.") || name.hasSuffix(".server.ts") || name.hasSuffix(".server.js") { return true }
        return false
    }

    private static let riskyCode: [(String, String)] = [
        (#"\b(?:fetch|axios|XMLHttpRequest|sendBeacon|EventSource|WebSocket)\s*\(|new\s+(?:XMLHttpRequest|WebSocket|EventSource)\b|navigator\.sendBeacon"#, "a network request"),
        (#"\beval\s*\(|new\s+Function\s*\(|setTimeout\s*\(\s*["'`]|setInterval\s*\(\s*["'`]"#, "code that runs text as code"),
        (#"\b(?:child_process|execSync|spawnSync|require\s*\(\s*["'](?:fs|child_process|net|http|https|os)["']\))"#, "code that runs programs or reads files"),
        (#"process\.env|import\.meta\.env|Deno\.env|os\.environ"#, "access to environment variables, where secrets live"),
        (#"document\.cookie|localStorage|sessionStorage|indexedDB"#, "access to visitors' cookies or stored data"),
        (#"<script\b[^>]*\bsrc\s*=\s*["']?(?:https?:)?//|<iframe\b|<form\b[^>]*\baction\s*=\s*["']?(?:https?:)?//|\bimport\s*\(\s*["'](?:https?:)?//"#, "content loaded from another site"),
        (#"\batob\s*\(|\b(?:fromCharCode|unescape)\s*\(|[A-Za-z0-9+/]{120,}={0,2}"#, "encoded content"),
        (#"(?:https?:)?//(?!localhost|127\.0\.0\.1|(?:www\.)?w3\.org/|schema\.org/)[a-z0-9.-]+\.[a-z]{2,}"#, "a link to another site"),
    ]
}

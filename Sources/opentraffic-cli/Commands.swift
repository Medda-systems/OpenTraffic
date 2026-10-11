import Foundation

/// Every command: what the app's windows do, from a terminal.
enum Commands {
    static let all: [CommandSpec] = [
        // Shares
        CommandSpec(name: "list", aliases: ["ls"], group: "Shares", usage: "list", summary: "Your shares, with their state and public URL (the default)"),
        CommandSpec(name: "status", aliases: ["info"], group: "Shares", usage: "status <share>", summary: "One share in detail: URL, health, who's there, protection",
                    arguments: 1...1),
        CommandSpec(
            name: "share", group: "Shares",
            usage: "share <port|host:port|url> [--via quick|opentunnel|tailscale|ngrok|domain] [--name NAME] [--collab]",
            summary: "Share a local server; prints the public URL once it's live",
            details: """
            Ways to share (--via):
              quick        A temporary trycloudflare.com URL, new each start (the default). No account.
              opentunnel   A lasting address on opentunnel.xyz, encrypted end to end. No account.
              tailscale    Your tailnet only; add --funnel to make it public on the internet.
              ngrok        Your ngrok domain; --hostname for a reserved domain, --password to protect it.
              domain       A hostname in your Cloudflare account: --hostname app.example.com.

            Options:
              --name NAME      What to call it (default: the page title or localhost:PORT)
              --collab         Live collaboration: cursors, comments, follow mode (quick, opentunnel)
              --hostname HOST  domain: the hostname to serve. ngrok: a domain reserved in your account
              --replace-dns    domain: take over a hostname that already has a DNS record
              --funnel         tailscale: public on the internet through Funnel
              --password       ngrok: protect it with a generated password (--user NAME, default guest)
              --save           Save it without starting it
              --copy           Copy the public URL to the clipboard

            Sharing an existing share's address starts that share. OpenTraffic asks before anything goes
            public, unless you allow apps to share without asking in Settings → Integrations.
            """,
            flags: ["collab", "replace-dns", "funnel", "password", "save", "copy"], options: ["via", "name", "hostname", "user"], arguments: 1...1
        ),
        CommandSpec(name: "start", group: "Shares", usage: "start <share>", summary: "Start a saved share; prints its public URL", flags: ["copy"], arguments: 1...1),
        CommandSpec(name: "stop", group: "Shares", usage: "stop <share> | stop --all", summary: "Stop a share, or every running one", flags: ["all"], arguments: 0...1),
        CommandSpec(name: "restart", group: "Shares", usage: "restart <share>", summary: "Restart a share", arguments: 1...1),
        CommandSpec(name: "remove", aliases: ["rm", "delete"], group: "Shares", usage: "remove <share> [--yes]", summary: "Remove a share, with its settings and comments", flags: ["yes"], arguments: 1...1),
        CommandSpec(name: "rename", group: "Shares", usage: "rename <share> <new name>", summary: "Rename a share", arguments: 2...2),
        CommandSpec(
            name: "set", group: "Shares", usage: "set <share> [options]", summary: "Change a share's settings",
            details: """
            Options:
              --url PORT|URL         The local server (stop the share first)
              --collab on|off        Live collaboration
              --errors on|off        Collect visitors' browser errors (collaboration)
              --autostart on|off     Start whenever its local server is running
              --project NAME         Put it in a project (--no-project to take it out)
              --host-header on|off   Send the local server's own host in the Host header (Vite, Next.js)
              --stop-after DURATION  Stop by itself: never, 15m, 1h, or 4h
            """,
            flags: ["no-project"], options: ["url", "collab", "errors", "autostart", "project", "host-header", "stop-after"], arguments: 1...1
        ),
        CommandSpec(
            name: "protect", group: "Shares", usage: "protect <share> password|google|github|email|off [email ...] [--user NAME]",
            summary: "Choose who can open a share",
            details: """
              password [--user NAME]   A generated password (ngrok); prints it
              google [email ...]       Sign in with Google (ngrok); only these emails, if given
              github [email ...]       Sign in with GitHub (ngrok); only these emails, if given
              email email ...          One-time codes by email (custom domains, Cloudflare Access)
              off                      Anyone with the link
            """,
            options: ["user"], arguments: 2...50
        ),
        CommandSpec(name: "password", group: "Shares", usage: "password <share> [--new]", summary: "Show a protected share's username and password, or make a new one", flags: ["new"], arguments: 1...1),
        // Links
        CommandSpec(name: "url", group: "Links", usage: "url <share> [path]", summary: "Print the public URL", arguments: 1...2),
        CommandSpec(name: "copy", group: "Links", usage: "copy <share> [path]", summary: "Copy the public URL to the clipboard", arguments: 1...2),
        CommandSpec(name: "open", group: "Links", usage: "open <share> [path]", summary: "Open the public URL in your browser", arguments: 1...2),
        CommandSpec(name: "qr", group: "Links", usage: "qr <share> [path]", summary: "Show a QR code for the public URL", arguments: 1...2),
        // Feedback
        CommandSpec(name: "comments", group: "Feedback", usage: "comments <share> [--resolved | --all]", summary: "Comments visitors pinned to the page", flags: ["resolved", "all"], arguments: 1...1),
        CommandSpec(name: "reply", group: "Feedback", usage: "reply <share> <comment> <text>", summary: "Reply to a comment", arguments: 3...200),
        CommandSpec(name: "resolve", group: "Feedback", usage: "resolve <share> <comment> [--reopen]", summary: "Resolve a comment (or reopen it)", flags: ["reopen"], arguments: 2...2),
        CommandSpec(name: "delete-comment", group: "Feedback", usage: "delete-comment <share> <comment> [--yes]", summary: "Delete a comment", flags: ["yes"], arguments: 2...2),
        CommandSpec(name: "screenshot", group: "Feedback", usage: "screenshot <share> <comment> [-o FILE]", summary: "Save the picture of what a comment points at", options: ["output"], arguments: 2...2),
        CommandSpec(name: "errors", group: "Feedback", usage: "errors <share>", summary: "Browser errors visitors ran into", arguments: 1...1),
        CommandSpec(name: "logs", group: "Feedback", usage: "logs <share> [-n LINES] [-f]", summary: "The share's log; -f keeps following it", flags: ["follow"], options: ["lines"], arguments: 1...1),
        CommandSpec(name: "watch", group: "Feedback", usage: "watch [share]", summary: "Follow what happens: shares starting, people joining, comments", arguments: 0...1),
        // This Mac
        CommandSpec(name: "services", group: "This Mac", usage: "services", summary: "Web servers running on this Mac, with how long they've been up"),
        CommandSpec(name: "projects", group: "This Mac", usage: "projects", summary: "Projects: shares that start and stop together"),
        CommandSpec(name: "project", group: "This Mac", usage: "project start|stop <name>", summary: "Start or stop every share in a project", arguments: 2...2),
        CommandSpec(name: "domains", group: "This Mac", usage: "domains", summary: "Domains in your Cloudflare account, for --via domain"),
        // OpenTraffic
        CommandSpec(name: "doctor", group: "OpenTraffic", usage: "doctor", summary: "Check OpenTraffic, its API, and each way of sharing"),
        CommandSpec(name: "setup", group: "OpenTraffic", usage: "setup", summary: "Turn on OpenTraffic's local API for this command (asks in OpenTraffic once)"),
        CommandSpec(name: "show", group: "OpenTraffic", usage: "show [share]", summary: "Open OpenTraffic's window", arguments: 0...1),
        CommandSpec(name: "help", group: "OpenTraffic", usage: "help [command]", summary: "Help for every command, or one", arguments: 0...1),
        CommandSpec(name: "version", group: "OpenTraffic", usage: "version", summary: "This command's version"),
    ]

    static func spec(named name: String) -> CommandSpec? {
        all.first { $0.name == name || $0.aliases.contains(name) }
    }

    static func run(_ invocation: Invocation, location: AppLocation = AppLocation(), style: Style = .current) async throws {
        let client = Client(location: location)
        let style = invocation.flag("no-color") ? Style(color: false) : style
        let context = Context(invocation: invocation, client: client, style: style)
        try await context.run()
    }
}

/// One run of one command.
struct Context {
    let invocation: Invocation
    let client: Client
    let style: Style

    var args: [String] { invocation.arguments }
    var json: Bool { invocation.json }

    func say(_ text: String = "") { print(text) }

    /// The share's API path.
    func sharePath(_ name: String, _ rest: String = "") -> String { "/v1/shares/\(name.pathEncoded)\(rest)" }

    func run() async throws {
        switch invocation.command {
        case "list": try await list()
        case "status": try await status()
        case "share": try await share()
        case "start": try await start()
        case "stop": try await stop()
        case "restart": try await restart()
        case "remove": try await remove()
        case "rename": try await update(["name": args[1]], done: "Renamed to “\(args[1])”.")
        case "set": try await set()
        case "protect": try await protect()
        case "password": try await password()
        case "url", "copy", "open", "qr": try await link()
        case "comments": try await comments()
        case "reply": try await reply()
        case "resolve": try await resolve()
        case "delete-comment": try await deleteComment()
        case "screenshot": try await screenshot()
        case "errors": try await errors()
        case "logs": try await logs()
        case "watch": try await watch()
        case "services": try await services()
        case "projects": try await projects()
        case "project": try await project()
        case "domains": try await domains()
        case "doctor": try await doctor()
        case "setup": try await setup()
        case "show": try show()
        case "help": try help()
        case "version": say(Self.version)
        default: throw CLIError.usage("Unknown command “\(invocation.command)”.")
        }
    }

    static var version: String {
        let app = AppLocation().appURL.flatMap { Bundle(url: $0) }
        return "opentraffic \(app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")"
    }

    // MARK: Shares

    func list() async throws {
        let (body, raw) = try await client.get("/v1/shares", as: SharesBody.self)
        if json { return say(JSON.pretty(raw)) }
        guard !body.shares.isEmpty else {
            say("No shares yet. Share a dev server with `opentraffic share 3000`, or see what's running with `opentraffic services`.")
            return
        }
        var table = Table(header: ["NAME", "STATE", "VIA", "PUBLIC URL", "LOCAL", ""])
        for share in body.shares {
            var extra: [String] = []
            if !share.people.isEmpty { extra.append(Format.plural(share.people.count, "person", "people")) }
            if share.openComments > 0 { extra.append(Format.plural(share.openComments, "comment")) }
            table.rows.append([
                style.bold(share.name), Format.state(share.state, style: style), Format.via(share),
                share.publicURL.map { share.state == "running" ? style.cyan($0) : style.dim($0) } ?? style.dim("—"),
                Format.local(share.localURL), style.dim(extra.joined(separator: " · ")),
            ])
        }
        say(table.render(style: style))
    }

    func status() async throws {
        let (share, raw) = try await client.get(sharePath(args[0]), as: Share.self)
        if json { return say(JSON.pretty(raw)) }
        describe(share)
    }

    func describe(_ share: Share) {
        say("\(style.bold(share.name))  \(Format.state(share.state, style: style))")
        var rows: [(String, String)] = []
        rows.append(("Public URL", share.publicURL.map { style.cyan($0) } ?? style.dim("none yet")))
        rows.append(("Local", share.localURL))
        rows.append(("Via", Format.via(share) + (share.hostname.map { " (\($0))" } ?? "")))
        rows.append(("Who can open", Format.audience(share)))
        if share.collaboration {
            let people = share.people.isEmpty ? "nobody here now" : share.people.map(\.name).joined(separator: ", ")
            rows.append(("Collaboration", "on · \(people)"))
        }
        if share.comments > 0 { rows.append(("Comments", "\(share.openComments) open of \(share.comments)")) }
        if let project = share.project { rows.append(("Project", project)) }
        if share.autoStart == true { rows.append(("Starts", "whenever \(Format.local(share.localURL)) is running")) }
        if let stopsAt = share.stopsAt { rows.append(("Stops", Format.until(stopsAt))) }
        if share.rewriteHostHeader == true { rows.append(("Host header", "the local server's own")) }
        if let checks = share.health, !checks.isEmpty {
            let path = checks.filter { $0.state != "skipped" }.map { check -> String in
                let mark = switch check.state {
                case "ok": style.green("✓")
                case "failed": style.red("✕")
                case "working": style.yellow("…")
                default: style.dim("–")
                }
                return "\(mark) \(check.title)"
            }
            rows.append(("Health", path.joined(separator: "  ")))
            for check in checks where check.state == "failed" {
                if let detail = check.detail { rows.append(("", style.red("\(check.title): \(detail)"))) }
            }
        }
        if let error = share.lastError { rows.append(("Last error", style.red(error))) }
        let width = rows.map(\.0.count).max() ?? 0
        for (label, value) in rows {
            say("  \(style.dim(label.padding(toLength: width, withPad: " ", startingAt: 0)))  \(value)")
        }
    }

    /// After a share starts: its URL, or why it isn't live yet.
    func announce(_ share: Share, raw: Data, extra: String? = nil) throws {
        if json { return say(JSON.pretty(raw)) }
        if invocation.flag("copy"), let url = share.publicURL { Shell.run("/usr/bin/pbcopy", [], input: url) }
        switch share.state {
        case "running" where share.publicURL != nil:
            say("\(style.bold(share.name)) is live at \(style.cyan(share.publicURL!))\(invocation.flag("copy") ? style.dim(" (copied)") : "")")
            say(style.dim("  \(Format.via(share)) · \(Format.audience(share))\(share.collaboration ? " · live collaboration" : "")"))
        case "failed":
            throw CLIError.failed("“\(share.name)” failed to start: \(share.lastError ?? "see `opentraffic logs \(share.name)`").")
        case "stopped":
            say("Saved \(style.bold(share.name)). Start it with `opentraffic start \"\(share.name)\"`.")
        default:
            say("\(style.bold(share.name)) is \(share.state)… follow it with `opentraffic status \"\(share.name)\"`.")
        }
        if let extra { say(extra) }
    }

    func share() async throws {
        let target = args[0]
        let via = invocation.options["via"]?.lowercased()
        let password = invocation.flag("password")
        if password, via != "ngrok" {
            throw CLIError.usage("--password protects ngrok shares: add --via ngrok. (Custom domains use `opentraffic protect <share> email …`.)")
        }
        if via == "domain", invocation.options["hostname"] == nil {
            throw CLIError.usage("Sharing on your domain needs --hostname, like --hostname app.example.com. See `opentraffic domains`.")
        }
        var body: [String: Any?] = [
            "provider": via,
            "name": invocation.options["name"],
            "hostname": invocation.options["hostname"],
            "collaboration": invocation.flag("collab") ? true : nil,
            "replaceDNS": invocation.flag("replace-dns") ? true : nil,
            "funnel": invocation.flag("funnel") ? true : nil,
            "start": invocation.flag("save") || password ? false : nil,
        ]
        if let port = Int(target) { body["port"] = port } else { body["url"] = target }
        let (created, createdRaw) = try await client.call("POST", "/v1/shares", body: body, as: Share.self)
        guard password else { return try announce(created, raw: createdRaw) }
        let (protection, _) = try await client.call("PUT", sharePath(created.id, "/protection"), body: ["mode": "password", "username": invocation.options["user"]], as: Protection.self)
        let credentials = "  Username \(style.bold(protection.username ?? "guest"))   Password \(style.bold(protection.password ?? "—"))"
        if invocation.flag("save") {
            let (saved, raw) = try await client.get(sharePath(created.id), as: Share.self)
            return try announce(saved, raw: raw, extra: credentials)
        }
        let (started, raw) = try await client.call("POST", sharePath(created.id, "/start"), as: Share.self)
        try announce(started, raw: raw, extra: credentials)
    }

    func start() async throws {
        let (share, raw) = try await client.call("POST", sharePath(args[0], "/start"), as: Share.self)
        try announce(share, raw: raw)
    }

    func stop() async throws {
        if invocation.flag("all") {
            guard args.isEmpty else { throw CLIError.usage("Usage: opentraffic stop <share> | stop --all") }
            let (body, _) = try await client.get("/v1/shares", as: SharesBody.self)
            let running = body.shares.filter { ["running", "starting"].contains($0.state) }
            for share in running {
                try await client.request("POST", sharePath(share.id, "/stop"))
                if !json { say("Stopped \(style.bold(share.name)).") }
            }
            if json { say(JSON.pretty(JSON.encode(["stopped": running.map(\.name)]))) }
            else if running.isEmpty { say("Nothing was running.") }
            return
        }
        guard let name = args.first else { throw CLIError.usage("Usage: opentraffic stop <share> | stop --all") }
        let (share, raw) = try await client.call("POST", sharePath(name, "/stop"), as: Share.self)
        if json { return say(JSON.pretty(raw)) }
        say("Stopped \(style.bold(share.name)).")
    }

    func restart() async throws {
        let (share, raw) = try await client.call("POST", sharePath(args[0], "/restart"), as: Share.self)
        try announce(share, raw: raw)
    }

    func remove() async throws {
        let (share, _) = try await client.get(sharePath(args[0]), as: Share.self)
        try confirm("Remove “\(share.name)”? Its settings and comments are deleted\(share.kind == "remote" ? "; the tunnel and DNS record stay in your Cloudflare account" : "").")
        try await client.request("DELETE", sharePath(share.id))
        if json { return say(JSON.pretty(JSON.encode(["removed": share.name]))) }
        say("Removed \(style.bold(share.name)).")
    }

    /// Asks on a terminal; elsewhere --yes is required.
    func confirm(_ question: String) throws {
        guard !invocation.flag("yes") else { return }
        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIError.usage("\(question) Pass --yes to go ahead without asking.")
        }
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine()?.lowercased(), ["y", "yes"].contains(answer) else {
            throw CLIError.failed("Cancelled.")
        }
    }

    func update(_ changes: [String: Any?], done: String) async throws {
        let (share, raw) = try await client.call("PATCH", sharePath(args[0]), body: changes, as: Share.self)
        if json { return say(JSON.pretty(raw)) }
        say(done)
        describe(share)
    }

    func set() async throws {
        let options = invocation.options
        var changes: [String: Any?] = [:]
        if let url = options["url"] { changes["url"] = url }
        if let value = options["collab"] { changes["collaboration"] = try parseSwitch(value, option: "collab") }
        if let value = options["errors"] { changes["captureErrors"] = try parseSwitch(value, option: "errors") }
        if let value = options["autostart"] { changes["autoStart"] = try parseSwitch(value, option: "autostart") }
        if let value = options["host-header"] { changes["rewriteHostHeader"] = try parseSwitch(value, option: "host-header") }
        if let value = options["stop-after"] { changes["autoStop"] = value }
        if let project = options["project"] { changes["project"] = project }
        if invocation.flag("no-project") { changes["project"] = "" }
        guard !changes.isEmpty else {
            throw CLIError.usage("Nothing to change. Run `opentraffic help set` for the options.")
        }
        try await update(changes, done: "Updated.")
    }

    func protect() async throws {
        let mode = args[1].lowercased()
        let emails = Array(args.dropFirst(2))
        guard ["password", "google", "github", "email", "off", "none"].contains(mode) else {
            throw CLIError.usage("Usage: opentraffic protect <share> password|google|github|email|off [email ...]")
        }
        if mode == "password" || mode == "off" || mode == "none", !emails.isEmpty {
            throw CLIError.usage("\(mode) doesn't take email addresses.")
        }
        let (protection, raw) = try await client.call(
            "PUT", sharePath(args[0], "/protection"),
            body: ["mode": mode, "username": invocation.options["user"], "emails": emails.isEmpty ? nil : emails],
            as: Protection.self
        )
        if json { return say(JSON.pretty(raw)) }
        sayProtection(protection)
    }

    func sayProtection(_ protection: Protection) {
        switch protection.mode {
        case "password":
            say("Password protected.")
            say("  Username \(style.bold(protection.username ?? "guest"))   Password \(style.bold(protection.password ?? "—"))")
        case "google", "github", "email":
            let how = ["google": "Google sign-in", "github": "GitHub sign-in", "email": "Email codes"][protection.mode] ?? protection.mode
            say("\(how)\(protection.emails.isEmpty ? " (anyone with an account)" : " for \(protection.emails.joined(separator: ", "))").")
        default:
            say("Anyone with the link can open it.")
        }
    }

    func password() async throws {
        let (protection, raw) = invocation.flag("new")
            ? try await client.call("POST", sharePath(args[0], "/password"), as: Protection.self)
            : try await client.get(sharePath(args[0], "/protection"), as: Protection.self)
        if json { return say(JSON.pretty(raw)) }
        guard protection.mode == "password" else {
            throw CLIError.failed("“\(args[0])” isn't password protected. Protect it with `opentraffic protect \"\(args[0])\" password`.")
        }
        sayProtection(protection)
    }

    // MARK: Links

    func link() async throws {
        let (share, _) = try await client.get(sharePath(args[0]), as: Share.self)
        guard var url = share.publicURL else {
            throw CLIError.failed("“\(share.name)” has no public URL yet. Start it with `opentraffic start \"\(share.name)\"`.")
        }
        if let path = args[safe: 1] {
            url = url.hasSuffix("/") ? String(url.dropLast()) : url
            url += path.hasPrefix("/") ? path : "/\(path)"
        }
        if share.state != "running", !json {
            FileHandle.standardError.write(Data("Note: “\(share.name)” is \(share.state), so the link won't open until it's started.\n".utf8))
        }
        switch invocation.command {
        case "copy":
            Shell.run("/usr/bin/pbcopy", [], input: url)
            json ? say(JSON.pretty(JSON.encode(["url": url, "copied": true]))) : say("\(url) \(style.dim("(copied)"))")
        case "open":
            Shell.run("/usr/bin/open", [url])
            json ? say(JSON.pretty(JSON.encode(["url": url, "opened": true]))) : say("Opened \(url)")
        case "qr":
            guard let lines = QRCode.lines(for: url) else { throw CLIError.failed("Couldn't make a QR code.") }
            // White and black set explicitly, so it scans in light and dark terminals alike.
            say(lines.map { style.color ? "\u{1B}[97;40m\($0)\u{1B}[0m" : $0 }.joined(separator: "\n"))
            say(url)
        default:
            json ? say(JSON.pretty(JSON.encode(["url": url]))) : say(url)
        }
    }

    // MARK: Feedback

    func comments() async throws {
        let status = invocation.flag("all") ? "all" : invocation.flag("resolved") ? "resolved" : "open"
        let (body, raw) = try await client.get(sharePath(args[0], "/comments?status=\(status)"), as: CommentsBody.self)
        if json { return say(JSON.pretty(raw)) }
        guard !body.comments.isEmpty else {
            say(status == "open" ? "No open comments. (`--all` includes resolved ones.)" : "No comments.")
            return
        }
        for comment in body.comments {
            var meta = Format.ago(comment.createdAt)
            if let environment = comment.environment { meta += " · \(environment.browser), \(environment.os), \(environment.viewport)" }
            if comment.hasScreenshot { meta += " · picture" }
            if comment.resolved { meta += " · resolved" }
            let target = comment.label.map { " on “\($0)”" } ?? ""
            say("\(style.yellow(comment.id))  \(style.bold(comment.author))\(target) \(style.dim("at \(comment.path) · \(meta)"))")
            say("  \(comment.text)")
            for reply in comment.replies {
                let badge = reply.agent.map { _ in style.dim(" (agent)") } ?? ""
                say("  \(style.dim("↳")) \(style.bold(reply.author))\(badge): \(reply.text)")
            }
            say()
        }
        say(style.dim("Reply with `opentraffic reply \"\(args[0])\" <id> <text>`, resolve with `opentraffic resolve \"\(args[0])\" <id>`."))
    }

    func reply() async throws {
        let text = args.dropFirst(2).joined(separator: " ")
        let (comment, raw) = try await client.call("POST", sharePath(args[0], "/comments/\(args[1].pathEncoded)/replies"), body: ["text": text], as: Comment.self)
        if json { return say(JSON.pretty(raw)) }
        say("Replied to \(comment.author)'s comment.")
    }

    func resolve() async throws {
        let reopen = invocation.flag("reopen")
        let (comment, raw) = try await client.call("PATCH", sharePath(args[0], "/comments/\(args[1].pathEncoded)"), body: ["resolved": !reopen], as: Comment.self)
        if json { return say(JSON.pretty(raw)) }
        say(reopen ? "Reopened \(comment.author)'s comment." : "Resolved \(comment.author)'s comment.")
    }

    func deleteComment() async throws {
        try confirm("Delete comment \(args[1]) on “\(args[0])”?")
        try await client.request("DELETE", sharePath(args[0], "/comments/\(args[1].pathEncoded)"))
        if json { return say(JSON.pretty(JSON.encode(["deleted": args[1]]))) }
        say("Deleted the comment.")
    }

    func screenshot() async throws {
        let response = try await client.request("GET", sharePath(args[0], "/comments/\(args[1].pathEncoded)/screenshot"))
        let data = response.body
        let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : (data.count > 12 && data[8..<12] == Data("WEBP".utf8)) ? "webp" : "jpg"
        let path = invocation.options["output"] ?? "\(args[0].replacingOccurrences(of: "/", with: "-"))-\(args[1]).\(ext)"
        do {
            try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            throw CLIError.failed("Couldn't save \(path): \(error.localizedDescription)")
        }
        json ? say(JSON.pretty(JSON.encode(["file": path]))) : say("Saved \(path)")
    }

    func errors() async throws {
        let (body, raw) = try await client.get(sharePath(args[0], "/errors"), as: ErrorsBody.self)
        if json { return say(JSON.pretty(raw)) }
        guard !body.errors.isEmpty else {
            say("No browser errors. (They're collected when live collaboration and `--errors on` are on.)")
            return
        }
        for error in body.errors {
            say("\(style.red(error.kind))  \(error.message)")
            say(style.dim("  \(Format.plural(error.count, "time")), last \(Format.ago(error.lastAt)) · \(error.paths.joined(separator: ", "))\(error.source.map { " · \($0)" } ?? "")"))
        }
    }

    func logs() async throws {
        let count = Int(invocation.options["lines"] ?? "200") ?? 200
        let (body, raw) = try await client.get(sharePath(args[0], "/logs?lines=\(max(1, count))"), as: LogsBody.self)
        if json, !invocation.flag("follow") { return say(JSON.pretty(raw)) }
        if body.lines.isEmpty, !invocation.flag("follow") {
            return say(style.dim("No log lines. (OpenTunnel and Tailscale shares log in their own apps.)"))
        }
        body.lines.forEach { say($0) }
        guard invocation.flag("follow") else { return }
        var seen = body.lines
        while true {
            try await Task.sleep(for: .seconds(1))
            let (next, _) = try await client.get(sharePath(args[0], "/logs?lines=500"), as: LogsBody.self)
            // Print what follows the last line already printed.
            let fresh: ArraySlice<String>
            if let last = seen.last, let index = next.lines.lastIndex(of: last) {
                fresh = next.lines[(index + 1)...]
            } else {
                fresh = next.lines[...]
            }
            fresh.forEach { say($0) }
            if !fresh.isEmpty { seen = next.lines }
        }
    }

    func watch() async throws {
        let filter = args.first?.lowercased()
        var (body, _) = try await client.get("/v1/events?since=0", as: EventsBody.self)
        var cursor = body.next
        if !json { say(style.dim("Watching\(args.first.map { " “\($0)”" } ?? " OpenTraffic")… (Ctrl-C to stop)")) }
        while true {
            (body, _) = try await client.get("/v1/events?since=\(cursor)&wait=30", as: EventsBody.self)
            cursor = body.next
            for event in body.events where filter == nil || event.share.name.lowercased() == filter {
                if json {
                    let object: [String: Any?] = ["type": event.type, "share": event.share.name, "at": event.at.formatted(.iso8601), "person": event.peer?.name, "comment": event.comment?.text, "error": event.error?.message]
                    say(String(decoding: JSON.encode(object), as: UTF8.self))
                    continue
                }
                let name = style.bold(event.share.name)
                let line: String = switch event.type {
                case "share.started": "\(style.green("▶")) \(name) is live\(event.share.publicURL.map { " at \(style.cyan($0))" } ?? "")"
                case "share.stopped": "\(style.dim("■")) \(name) stopped"
                case "session.joined": "\(style.green("+")) \(event.peer?.name ?? "Someone") joined \(name)"
                case "session.left": "\(style.dim("−")) \(event.peer?.name ?? "Someone") left \(name)"
                case "comment.created": "\(style.yellow("●")) \(event.comment?.author ?? "Someone") commented on \(name): \(event.comment?.text ?? "")"
                case "comment.updated": "\(style.yellow("●")) A comment on \(name) changed\(event.comment?.resolved == true ? " (resolved)" : "")"
                case "comment.deleted": "\(style.dim("●")) A comment on \(name) was deleted"
                case "error.reported": "\(style.red("!")) \(name): \(event.error?.message ?? "a browser error")"
                default: "\(event.type) \(name)"
                }
                say("\(style.dim(Format.time(event.at)))  \(line)")
            }
        }
    }

    // MARK: This Mac

    func services() async throws {
        let (body, raw) = try await client.get("/v1/services", as: ServicesBody.self)
        if json { return say(JSON.pretty(raw)) }
        guard !body.services.isEmpty else {
            say("No web servers found on this Mac. Start a dev server and run this again.")
            return
        }
        var table = Table(header: ["PORT", "NAME", "PROCESS", "UP", "SHARED AS"])
        for service in body.services.sorted(by: { $0.port < $1.port }) {
            table.rows.append([
                style.bold(String(service.port)), service.title ?? style.dim("—"), service.process ?? style.dim("—"),
                service.upSince.map { Format.age(since: $0) } ?? style.dim("—"),
                service.sharedAs.map { style.cyan($0) } ?? style.dim("not shared"),
            ])
        }
        say(table.render(style: style))
        if body.services.contains(where: { $0.sharedAs == nil }), let port = body.services.first(where: { $0.sharedAs == nil })?.port {
            say(style.dim("\nShare one with `opentraffic share \(port)`."))
        }
    }

    func projects() async throws {
        let (body, raw) = try await client.get("/v1/projects", as: ProjectsBody.self)
        if json { return say(JSON.pretty(raw)) }
        guard !body.projects.isEmpty else {
            say("No projects. Put shares in one with `opentraffic set <share> --project NAME`.")
            return
        }
        var table = Table(header: ["PROJECT", "RUNNING", "SHARES"])
        for project in body.projects {
            table.rows.append([style.bold(project.name), "\(project.running) of \(project.shares.count)", project.shares.joined(separator: ", ")])
        }
        say(table.render(style: style))
    }

    func project() async throws {
        let action = args[0].lowercased()
        guard ["start", "stop"].contains(action) else { throw CLIError.usage("Usage: opentraffic project start|stop <name>") }
        let (project, raw) = try await client.call("POST", "/v1/projects/\(args[1].pathEncoded)/\(action)", as: Project.self)
        if json { return say(JSON.pretty(raw)) }
        say(action == "start"
            ? "Started \(style.bold(project.name)): \(project.running) of \(project.shares.count) running."
            : "Stopped \(style.bold(project.name)).")
    }

    func domains() async throws {
        let (body, raw) = try await client.get("/v1/zones", as: ZonesBody.self)
        if json { return say(JSON.pretty(raw)) }
        guard !body.zones.isEmpty else { return say("Your Cloudflare account has no domains.") }
        body.zones.forEach { say($0.name) }
        say(style.dim("\nShare on one with `opentraffic share 3000 --via domain --hostname app.\(body.zones[0].name)`."))
    }

    // MARK: OpenTraffic

    func doctor() async throws {
        let location = client.location
        func line(_ ok: Bool?, _ text: String) {
            let mark = ok == true ? style.green("✓") : ok == false ? style.red("✕") : style.yellow("!")
            say("\(mark) \(text)")
        }
        do {
            try await client.ensureReachable()
        } catch let error as CLIError {
            line(false, error.message)
            throw CLIError.unavailable("OpenTraffic isn't ready for the opentraffic command.")
        }
        let response = try await client.request("GET", "/v1/status", accept: [501])
        guard response.status != 501, let status = try? client.decode(AppStatus.self, from: response.body) else {
            line(true, "OpenTraffic answers on 127.0.0.1:\(location.port)")
            line(nil, "This version of OpenTraffic doesn't report more. Update it for the full check.")
            return
        }
        if json { return say(JSON.pretty(response.body)) }
        line(true, "OpenTraffic \(status.version) is running · API on 127.0.0.1:\(location.port) · \(Format.plural(status.shares, "share")), \(status.running) running")
        line(status.publishesWithoutAsking ? true : nil, status.publishesWithoutAsking
            ? "Apps may share without asking"
            : "OpenTraffic asks before anything goes public. For unattended use, allow it in Settings → Integrations.")
        let titles = ["quick": "Temporary URL (Cloudflare)", "opentunnel": "OpenTunnel", "tailscale": "Tailscale", "ngrok": "ngrok", "domain": "Your domain (Cloudflare)"]
        for provider in status.providers {
            let title = titles[provider.name] ?? provider.name
            line(provider.ready, provider.ready ? "\(title) is ready" : "\(title): \(provider.detail ?? "not ready")")
        }
    }

    func setup() async throws {
        if !json, !(await client.answers()) { say("Turning on OpenTraffic's local API… confirm in OpenTraffic if it asks.") }
        guard try await client.setUp() else {
            throw CLIError.unavailable("OpenTraffic's local API didn't come on. Turn on Settings → Integrations → “Allow apps on this Mac to use OpenTraffic”, then run `opentraffic doctor`.")
        }
        if json { return say(JSON.pretty(JSON.encode(["ready": true]))) }
        say("\(style.green("✓")) Ready. Try `opentraffic services` or `opentraffic share 3000`.")
    }

    func show() throws {
        let link = args.first.map { "opentraffic://show?name=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? $0)" } ?? "opentraffic://show"
        try client.openLink(link)
    }

    func help() throws {
        if let name = args.first {
            guard let spec = Commands.spec(named: name) else { throw CLIError.usage("Unknown command “\(name)”.") }
            say("\(style.bold("opentraffic \(spec.usage)"))\n\n\(spec.summary).")
            if !spec.details.isEmpty { say("\n\(spec.details)") }
            if !spec.aliases.isEmpty { say("\nAlso: \(spec.aliases.joined(separator: ", "))") }
            say(style.dim("\nAdd --json to any command for machine-readable output."))
            return
        }
        say("""
        \(style.bold("opentraffic")) — share localhost from the terminal, with everything OpenTraffic's windows can do.
        It uses OpenTraffic's local API and starts the app in the background if it isn't running.

        """)
        let groups = Commands.all.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        let width = Commands.all.map { $0.usage.split(separator: " ").prefix(2).joined(separator: " ").count }.max() ?? 0
        for group in groups {
            say(style.bold(group))
            for spec in Commands.all where spec.group == group {
                let short = spec.usage.split(separator: " ").prefix(2).joined(separator: " ")
                say("  \(short.padding(toLength: width, withPad: " ", startingAt: 0))  \(spec.summary)")
            }
            say()
        }
        say("""
        Examples
          opentraffic share 5173 --collab                     A public URL with live collaboration
          opentraffic share 3000 --via domain --hostname app.example.com
          opentraffic share 8080 --via ngrok --password        Password protected
          opentraffic comments Orbit && opentraffic reply Orbit 015ec043 "Fixed"

        `opentraffic help <command>` for its options; --json for scripts. First time: `opentraffic setup`.
        """)
    }
}

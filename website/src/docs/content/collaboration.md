## Start a session

Turn on **Live collaboration** for a temporary share (in New Tunnel, the share's detail view, or `opentraffic share 5173 --collab`) and everyone who opens the link sees each other: a presence pill with names, live cursors anchored to page elements, and — after **Open as Host** — a **Lead** switch that brings everyone to the page and scroll position you're on.

People can also pin **comments** to any element (the Comment button in the pill) and **point** at things for everyone (the Point button, or ⌥-click). A coding agent working on a comment appears in the session too, its cursor on the element; when the comment is resolved, its author is told and can [confirm the fix or reopen it](/docs/feedback#when-its-fixed). Comments appear in the share's **Feedback** tab (⌘4), where you can resolve or delete them for everyone and copy them as Markdown or as a GitHub issue; they're kept between sessions. OpenTraffic can notify you when someone joins or comments, and shows your name from Settings → General → Live Collaboration to the people you share with.

OpenTraffic runs a small proxy on 127.0.0.1 between cloudflared and your dev server. It forwards everything unchanged, with two exceptions:
- HTML pages get two script tags, `/__opentraffic/bridge.js` and `/__opentraffic/collab.js`.
- OpenTraffic answers `/__opentraffic/*` itself.

Hot-reload WebSockets are relayed byte for byte. The hub lives in OpenTraffic, with no account or outside service.

What visitors share:
- Everyone sees each other's chosen names and cursors, and which page (path only, never the query string) they're on.
- Cursor and presence messages do not send page content or form-field values. Explicit comments and element screenshots carry the selected feedback described below.
- When someone pins a comment, it carries a short label of the element, the page title, a picture of the element (with text fields blanked), their browser and window size, and, if you turned on error collection, the browser errors they hit.

Live collaboration works with Quick Tunnel and OpenTunnel shares of `http://` addresses. Other providers and HTTPS local origins are not currently supported for collaboration.



## Work on a branch

Turn on **Work on a branch** in a share's Live Collaboration card (or `opentraffic share 5173 --branch`, `opentraffic set Orbit --branch on`) and, while the share runs, its project is on a branch of its own:

- **When the share starts,** OpenTraffic finds the project from the folder your dev server runs in (or the one you chose in the Feedback tab), and switches its git repository to a new branch, `opentraffic/<share>-<date>`, made from the branch you're on. Your files don't change, so the dev server keeps serving, and uncommitted changes stay uncommitted.
- **When a comment is resolved** by an agent or by you, what changed for it is committed there, with the comment as the message. For a claimed comment, that's the files that changed since the agent claimed it. Changes you'd already made aren't included unless the agent changed the same file, but files you edit while an agent works on a comment go into its commit.
- **When the share stops,** the branch is merged back into the one it came from, if that's clean. Usually that's a fast-forward that leaves your working folder exactly as it is. If that branch moved on meanwhile, OpenTraffic merges only when nothing is uncommitted and nothing conflicts. Otherwise the branch stays checked out, OpenTraffic says why, and the next start carries on with it. A restart keeps the same branch.

It needs the project on a branch (not a detached HEAD), with no merge or rebase in progress. Commits use your git name and run your hooks, and `.env` files are never committed.

**No git yet?** Turning the switch on checks the project first. If it isn't in a git repository, OpenTraffic offers to **Set Up Git**: it creates a local repository there (no remote, nothing leaves your Mac), adds a `.gitignore` if there isn't one, and commits the project as it is, leaving out dependencies, build output, `.env` files, and files over 10 MB. **Continue Without** leaves the switch off. If git itself isn't installed, it offers Apple's Command Line Tools, which include it. From the command line, `--branch` on such a project fails and says what to do. If a project loses its repository later, the switch turns itself off when the share starts, and says so.

## Multi-service apps

See [Localhost bridge](/docs/localhost-bridge) when your frontend calls another local API or WebSocket server.

## Feedback workflow

See [Comments & feedback](/docs/feedback) to resolve threads or connect an agent.

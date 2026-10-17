# Live collaboration on shares

Share a local site and everyone who opens the link sees each other: who's here, where their
cursor is, and — when the host leads — the same page and scroll position. No accounts, no
third-party service: OpenTraffic itself is the hub.

## Phases

| Phase | Scope |
| --- | --- |
| 1 ✅ | Collaboration proxy for **Quick Tunnels** with an `http://` origin. Presence, live cursors, follow-the-host (URL + scroll), host link, OpenTraffic shows who's connected. |
| **2 (this)** | Pinned comments on elements, Feedback tab in OpenTraffic (copy as Markdown / GitHub issue), pointer highlight ("look here"), join/comment notifications, host name, copy invite link. |
| 3 | ngrok, Tailscale and custom-domain tunnels; `https://` origins; per-share "Collaboration" in automation links and the CLI. |

## How it works

```
visitor ─▶ Cloudflare ─▶ cloudflared ─▶ OpenTraffic collab proxy (127.0.0.1:<random>) ─▶ your dev server
host browser ───────────────────────────▶ (same proxy, via the host link)
```

* The proxy forwards every request unchanged, with two exceptions:
  1. `/__opentraffic/*` is OpenTraffic's own namespace (overlay script, WebSocket hub, host join link).
  2. HTML responses get one `<script src="/__opentraffic/collab.js" defer>` tag, inserted before
     `</head>` (or `<body`, or at the end). The response streams: only the bytes up to the
     insertion point are buffered. A known `Content-Length` grows by the tag's length.
* `Accept-Encoding` is removed from upstream requests so HTML arrives uncompressed (Cloudflare
  compresses at the edge anyway). If upstream still sends `Content-Encoding`, nothing is injected.
* WebSocket upgrades other than the hub (Vite/Next hot reload) become raw byte relays.
* The overlay lives in a closed Shadow DOM, so the site's CSS can't touch it and vice versa.
  It never reads or sends form contents or page text.
* `https://` origins and other tunnel kinds keep working without collaboration in phase 1.

### Host

OpenTraffic opens `http://127.0.0.1:<port>/__opentraffic/host?token=<random>` in the browser. The proxy
sets an `HttpOnly; SameSite=Strict` cookie `__opentraffic_host=<token>` for that origin and redirects
to `/`. The hub treats WebSocket clients presenting the token as the host. The cookie only exists
on the local origin, so it never travels through the tunnel.

### Turning it on

`TunnelDefinition.collaboration` (default off). Quick Tunnels get a URL per start, so toggling
while running asks to restart ("the temporary URL will change"). The Quick pane in New Tunnel
has a "Live collaboration" toggle so it can be on from the first start.

## Wire protocol (`/__opentraffic/ws`, JSON text frames)

Every message is an object with a `type`. Unknown types and fields are ignored. Frames over
4 KB are dropped; a client sending more than 60 messages per second has the excess dropped.

### Client → hub

| type | fields | notes |
| --- | --- | --- |
| `hello` | `name?: string`, `path: string` | First message. Name ≤ 32 chars after trimming control characters; empty → generated name. |
| `rename` | `name: string` | |
| `path` | `path: string` | `location.pathname` only (query strings and fragments can hold tokens), must start with `/`, no `//`, backslashes, or dot segments, ≤ 512 chars. |
| `cursor` | `anchor?: string`, `rx?: number`, `ry?: number`, `x: number`, `y: number` | `anchor` = CSS selector of the element under the pointer (≤ 256 chars), `rx/ry` = position within it (0…1). `x` = pageX / document width (0…1), `y` = pageY in CSS px — fallback when the anchor can't be resolved. |
| `cursor-hide` | | Pointer left the window. |
| `scroll` | `ratio: number` | 0…1 of the scrollable height. Only meaningful from the host while leading. |
| `lead` | `on: boolean` | Host only: start/stop leading. |

### Hub → client

| type | fields |
| --- | --- |
| `welcome` | `you: Peer`, `peers: [Peer]`, `leading: boolean` |
| `join` | `peer: Peer` |
| `leave` | `id: string` |
| `update` | `peer: Peer` (name/path changed) |
| `cursor` | `id`, plus the client's cursor fields |
| `cursor-hide` | `id` |
| `lead` | `on: boolean`, `path?: string`, `ratio?: number` (sent when leading starts, and on each host `path` / `scroll` while leading) |

`Peer = { id: string, name: string, color: string (#rrggbb), path: string, isHost: boolean }`.
Colors come from a fixed palette, assigned in join order.

### Overlay behaviour

* Presence pill bottom-right: colored initials of everyone here, "N here", the visitor's own name
  (click to rename, stored in `localStorage`), and — while the host leads — a "Following host"
  toggle. The host sees a "Lead" toggle instead.
* Cursors of peers on the same `path`, drawn with their name, pointer-events off.
* Following: on `lead` with a different `path`, navigate with `location.assign(path)` (paths only,
  never URLs); apply `ratio` with smooth scroll. A visitor who scrolls or navigates themselves
  stops following until they turn it back on.
* SPA navigation is detected by wrapping `history.pushState/replaceState` and listening to
  `popstate`.
* Reconnects with backoff; the pill shows "Reconnecting…".
* Respects `prefers-reduced-motion` (no cursor easing).

## Security

* The proxy listens on 127.0.0.1 only. The WebSocket requires `Origin` to match the request's
  `Host`, so other sites can't connect a visitor's browser to the hub.
* Names are rendered with `textContent`; all inputs are length-limited and validated.
* At most 50 connected peers per share.
* Visitors can see each other's chosen names, cursor positions, and which path they're on —
  the share's detail view says so next to the toggle. Combine with a password (section 3.8) for
  private sessions.
* Content-Security-Policy is adjusted only as far as OpenTraffic's own scripts and connections need
  (section 3.2): the two exact script URLs, or a nonce under `'strict-dynamic'`.
* Followers and the people list only ever see a page's path, never its query string or fragment,
  which can hold tokens.

## OpenTraffic UI (phase 1)

* Detail view: "Collaboration" card — toggle, "Open as Host", list of who's connected
  (name, page), privacy note.
* Rows and the menu bar card show a people count while anyone is connected.
* The effective local origin keeps showing the dev server, not the proxy.

## Phase 2 additions

### Protocol

Client → hub (in addition to phase 1):

| type | fields | notes |
| --- | --- | --- |
| `hello` | + `client?: string` | A random id the overlay keeps in `localStorage` (`__opentraffic_collab_client`, ≤ 64 chars `[A-Za-z0-9_-]`). Lets authors delete their own comments after a reload. Never shown to others. |
| `comment` | `text: string`, `path: string`, `x`, `y`, `anchor?`, `rx?`, `ry?`, `label?: string`, `title?: string` | Pin a comment. Same position fields as `cursor`. `text` 1–1000 chars. `label` ≤ 80 chars describes the element (see below); `title` ≤ 200 is `document.title`. At most one comment per 2 s per person. |
| `resolve` | `id: string`, `resolved: boolean` | Anyone may resolve or reopen. |
| `delete` | `id: string` | Only the comment's author (same `client`) or the host. |
| `point` | `x`, `y`, `anchor?`, `rx?`, `ry?` | "Look here": a pulse everyone on the same page sees. At most 2 per second per person. |

Hub → client:

| type | fields |
| --- | --- |
| `welcome` | + `comments: [Comment]` (every comment on every page, oldest first) |
| `comment` | `comment: Comment` — new or changed (resolved); replace by `id` |
| `comment-delete` | `id: string` |
| `point` | `id` (peer), `name`, `color`, plus the position fields — only to peers on the same path, including the sender |

`Comment = { id, author, color, path, text, x, y, anchor?, rx?, ry?, label?, title?, createdAt (ms since epoch), resolved, canDelete }`.
`canDelete` is computed per recipient (author or host), so it can differ between copies of the same comment.
At most 500 comments per share; older resolved ones are dropped first when full.

**Element label.** From the element under the pin: `aria-label`, else `alt`, else `title`, else its visible text
collapsed to one line, cut to 80 chars. For `input`, `textarea`, `select` and `[contenteditable]` the label is
the element kind only (for example "text field") — typed values are never read. The label and title are the
only page-derived text ever sent, and only when someone deliberately pins a comment.

### Overlay

* Pill: **Comment** and **Point** buttons, a comment count, and a "Show resolved" toggle in the people list menu.
* Comment mode: crosshair, the element under the pointer is outlined, a click opens a small composer next to it
  (⌘/Ctrl+Enter posts, Esc cancels). While in comment or point mode, page clicks are captured so links don't fire.
* Point: the Point button arms a single point; ⌥/Alt+click anywhere points without arming.
* Pins: numbered markers in the author's color on the current page (unresolved by default). A pin opens a bubble
  with author, relative time, element label, text, **Resolve/Reopen**, and **Delete** when `canDelete`.
* Point pulses: two expanding rings in the pointer's color with their name, ~1.5 s, reduced-motion → a static
  ring that fades.

### OpenTraffic

* **Feedback** tab on shares with collaboration: comments grouped by page, each with author, time, element label
  and text; resolve/reopen and delete (synced live to everyone when the share is running); **Copy as Markdown**,
  **Copy as GitHub Issue** (title + checklist body), **Clear Resolved**.
* Comments persist per share in `Application Support/OpenTraffic/feedback/<tunnel-id>.json` and are restored into
  the hub when the share starts again.
* Notifications (Settings → General, on by default): someone joins (grouped, at most one per 15 s per share) and
  new comments.
* Settings → General: **Your name in shared sessions** (empty → "Host").
* Collaboration card: **Copy Invite Link**.

## Phase 3: share anything, integrations, richer feedback

### 3.1 Localhost bridge (apps made of several local services)

Pages often call other local services by absolute URL (`ws://localhost:7880`, `http://127.0.0.1:3001/api`).
Through a tunnel those point at the *visitor's* machine, and browsers block public sites from reaching local
addresses. The bridge sends those calls through the same tunnel instead.

* `/__opentraffic/bridge.js` is inserted as the **first** element inside `<head>` (a plain, non-deferred script,
  so it runs before the app's scripts). The collaboration overlay tag stays where it is.
* It is served with its configuration inline at the top: `window.__opentrafficBridge = {"appPort":5173,"ports":[7880,3001]}`.
* When the page is **not** on a loopback host, it patches `fetch`, `XMLHttpRequest.prototype.open`, `WebSocket`,
  `EventSource` and `navigator.sendBeacon`. A URL whose host is `localhost`, `127.0.0.1`, `[::1]` or `0.0.0.0` is rewritten:
  * port == `appPort` → same origin, same path (`ws://localhost:5173/x` → `wss://<page host>/x`);
  * port in `ports` → `<page origin>/__opentraffic/port/<port>/x` (ws/wss follows the page scheme);
  * any other loopback port → left alone, and reported once per port with
    `fetch("/__opentraffic/bridge/want?port=<port>", {method: "POST", keepalive: true})` so the host can allow it.
  The patched constructors keep `instanceof`, static constants (`WebSocket.OPEN`…) and `name`.
* The proxy forwards `/__opentraffic/port/<port>/…` to `<upstream host>:<port>` **only for allowed ports**, with the
  prefix removed, `Host: localhost:<port>`, and `Origin` (if present) set to `http://localhost:<appPort>` so the
  local service sees what it would see without the tunnel. WebSocket upgrades there are raw relays like hot reload.
* Allowed ports are per share (`TunnelDefinition.bridgedPorts`). The proxy collects candidates (bridge reports, and
  loopback ports named in the app's `connect-src`), and OpenTraffic offers them in the collaboration card:
  "This app also uses localhost:7880 — Allow". Nothing is forwarded until the host allows it.

### 3.2 Proxy fixes

* **Content-Security-Policy**: only adjusted so OpenTraffic's own `/__opentraffic/` resources load. For the effective
  script directive (`script-src-elem` › `script-src` › `default-src`): nothing if absent, or if it has `'self'`
  without `'strict-dynamic'`; if it has `'strict-dynamic'` or any nonce/hash, add `'nonce-<random per response>'`
  and put that nonce on OpenTraffic's two script tags; otherwise add `<scheme>://<host>/__opentraffic/`. Same for the
  effective connect directive (`connect-src` › `default-src`): add `<scheme>://<host>/__opentraffic/` and
  `<ws scheme>://<host>/__opentraffic/` unless it has `'self'`. `-Report-Only` headers and `<meta>` policies are left
  alone.
* **Redirects**: a `Location` pointing at `localhost`/`127.0.0.1` on the app port becomes a same-origin path; on an
  allowed bridged port it becomes `/__opentraffic/port/<port>/…`.
* **Cookies**: `Domain=localhost` / `Domain=127.0.0.1` is removed from `Set-Cookie` so cookies stick to the tunnel host.
* Known limit: sign-in providers (GitHub, Google…) redirect to the callback URL the app registered, usually
  `localhost`; the provider must also allow the tunnel URL. WebRTC media (UDP) can't go through the tunnel.

### 3.3 Richer comments

Protocol additions (client → hub):

| type | fields | notes |
| --- | --- | --- |
| `comment` | + `screenshot?: string`, `env?: Env`, `errors?: [ErrorItem]` | `screenshot` is an id from the upload endpoint. `errors` (≤ 10) only when the share collects errors. |
| `reply` | `id: string` (comment), `text: string` | 1–1000 chars, at most one reply per second per person. |
| `errors` | `items: [ErrorItem]` (≤ 10) | Only when the share collects errors. At most one message per 5 s per person. |

`Env = { browser: string ≤ 60, os: string ≤ 60, viewport: string "1280x800", dpr: number, language: string ≤ 20 }`.
`ErrorItem = { kind: "error"|"rejection"|"console"|"network", message: string ≤ 300, source?: string ≤ 200, line?: int, path: string, at: ms }`.
For `network`, `message` is `"<METHOD> <path without query> → <status or 'failed'>"`; only status ≥ 500 or failures.

Hub → client: `welcome` gains `features: { errors: boolean }`. `Comment` gains `replies: [Reply]`,
`screenshot?: string`, `env?: Env`, `errors?: [ErrorItem]`.
`Reply = { id, author, color, text, createdAt, fromHost: boolean, agent?: string }` (`agent` names the app that
wrote it through OpenTraffic's API, e.g. "Claude Code").

**Screenshots**: on posting a comment, the overlay renders the pinned element (or its nearest ancestor that is at
least 320×200, at most 1600×1200 CSS px) into a canvas (SVG `foreignObject` with computed styles inlined;
cross-origin images may come out blank — best effort, skipped silently on failure or after 1.5 s) and uploads a
WebP/JPEG ≤ 600 KB: `POST /__opentraffic/upload` with headers `Content-Type: image/webp|image/jpeg|image/png` and
`X-OpenTraffic-Upload-Token: <welcome.uploadToken>` → `{"id":"<attachment id>"}`. The token is sent only to that
connection in its `welcome` (peer ids are public, so they can't authorize anything). The proxy checks that the bytes
really are that image type, accepts at most 10 uploads per minute per connection and 50 MB per share, stores
attachments with the share's comments, deletes them with their comment, and serves them back at
`GET /__opentraffic/attachments/<id>` (ids are 22 random URL-safe chars). Only the host's copy of a comment includes
its `errors`; error messages and sources have query strings removed.

**Errors** (per share, off by default, "Collect browser errors" in OpenTraffic): the overlay records uncaught errors,
unhandled rejections, the first string argument of `console.error`, and failed/5xx `fetch`/XHR calls, keeps the
last 20, attaches those from the last 2 minutes to each comment, and sends new ones in `errors` messages. The pill
shows "Errors shared with host" while this is on.

### 3.4 Local API, MCP and webhooks

OpenTraffic runs an API on `127.0.0.1:47777` (configurable) when **Settings → Integrations → Allow apps on this Mac**
is on (off by default).

* **Auth**: `Authorization: Bearer <token>`. The token lives in `~/Library/Application Support/OpenTraffic/api-token`
  (mode 0600) and can be regenerated. Requests must carry `Host: 127.0.0.1:<port>` or `localhost:<port>` and **no
  `Origin` header** (blocks web pages and DNS rebinding). Clients name themselves with `X-OpenTraffic-Client: <name>`.
* Anything that publishes a site (`share`, `start`) shows OpenTraffic's confirmation unless the client is allowed in
  Settings; reading feedback, resolving, replying and stopping don't ask.
* Shares are referred to by id or by name (case-insensitive).

REST (JSON):

| Method | Path | Body / query | Returns |
| --- | --- | --- | --- |
| GET | `/v1/shares` | | `{shares: [Share]}` |
| POST | `/v1/shares` | `{port?, url?, provider?: "quick"|"tailscale"|"ngrok", name?, collaboration?}` | `Share` (waits ≤ 30 s for the URL) |
| POST | `/v1/shares/{ref}/start`, `/stop` | | `Share` |
| GET | `/v1/shares/{ref}/comments` | `?status=open|resolved|all` | `{comments: [Comment]}` |
| PATCH | `/v1/shares/{ref}/comments/{id}` | `{resolved}` | `Comment` |
| POST | `/v1/shares/{ref}/comments/{id}/replies` | `{text}` | `Comment` |
| GET | `/v1/shares/{ref}/comments/{id}/screenshot` | | image bytes |
| GET | `/v1/shares/{ref}/errors` | | `{errors: [ErrorGroup]}` |
| GET | `/v1/shares/{ref}/logs` | `?lines=200` | `{lines: [String]}` |
| GET | `/v1/events` | `?since=<seq>&wait=<s ≤ 60>` | `{events: [Event], next: <seq>}` (long poll) |
| POST | `/mcp` | MCP JSON-RPC | MCP (Streamable HTTP, JSON responses only) |

Errors: `{error: {code, message}}` with 400/401/403/404/409/500.

`Share = { id, name, provider, kind, state, localURL, publicURL?, collaboration, people: [{name, path, isHost}], openComments, comments }`.
API comments are the hub's `Comment` without `canDelete`, plus `shareId`. `ErrorGroup = { message, kind, source?, count, firstAt, lastAt, paths: [String] }`.
`Event = { seq, id, type, at, share: {id, name, publicURL?}, comment?, peer?: {name}, error? }`, types:
`share.started`, `share.stopped`, `session.joined`, `session.left`, `comment.created`, `comment.updated`,
`comment.deleted`, `error.reported`.

**MCP** (protocol `2025-06-18`, also accepts `2025-03-26`): `initialize`, `ping`, `tools/list`, `tools/call`. Tools:
`list_shares`, `share` (port|url, provider, name, collaboration), `start_share`, `stop_share`, `get_feedback`
(share, status), `resolve_comment`, `reply_to_comment`, `get_screenshot` (returns an MCP image content block),
`get_errors`, `get_logs`, `wait_for_feedback` (share?, since?, timeout_seconds ≤ 300 → new/changed comments and a
cursor). Results carry `structuredContent` plus a JSON text block.
`opentraffic-mcp` (bundled in the app at `Contents/MacOS/opentraffic-mcp`) is a stdio ↔ HTTP bridge: it reads the token
file and relays newline-delimited JSON-RPC between stdin/stdout and `POST /mcp`, so any MCP client can use it.

**Webhooks** (Settings → Integrations): URL, events (empty = all), secret. Each event is POSTed as JSON with
`X-OpenTraffic-Event`, `X-OpenTraffic-Delivery: <event id>`, and `X-OpenTraffic-Signature: sha256=<hex HMAC-SHA256 of the
body with the secret>`; retried after 1, 5 and 25 s on errors or non-2xx.

### 3.5 Agents at work, and fixes the commenter hears about

OpenTraffic never runs a model. Agents (a subscription CLI like Claude Code or Codex, or a script with an API key)
work through the MCP server, the `opentraffic` command or REST, and OpenTraffic shows that work in the session.

**Claims (the app).** `claim_comment` / `POST …/comments/{id}/claim {progress?}` gives the calling client (its
`X-OpenTraffic-Client` / `OPENTRAFFIC_CLIENT` name) a 15-minute lease on an open comment; claiming again renews it and
updates `progress` (≤ 120 chars, one line). Another client's unexpired claim is a 409. Resolving, deleting, or
resolving from the page ends it; `release_comment` / `DELETE …/claim` gives it up; an expired lease is dropped by the
app's 5-second poll. Claims live in the app (`AgentClaimBook`), not on disk, and are pushed to the hub as
`CollabAgentWork`. Events: `comment.claimed`, `comment.released`. API comments gain `status`
(`open`/`working`/`resolved`/`confirmed`), `claimedBy`, `progress`, `resolvedBy`, `resolvedAt`, `hasAfterScreenshot`.

**Agents in the session (hub).** Each agent with work is a peer with `isAgent: true`, colour `#BF5AF2`, `path` of its
newest claimed comment, and `at: {x, y, anchor?, rx?, ry?}` — that comment's position. It joins, moves (`update`) and
leaves like anyone. The overlay draws its cursor at `at` (no idle timeout), beside the pin, tagged
"✦ <name> · working". Comments being worked on carry `claim: {agent, progress?}`; their pins pulse.

**Who resolved it (hub).** Comments record `resolvedBy` (person, host, or client name), `resolvedByAgent`,
`resolvedByAuthor` (the commenter themselves), `resolvedAt`, `confirmed`, and `afterScreenshot`; reopening clears
them all. Each person's copy says `mine: true` when their overlay (`client`) wrote it.

| Client → hub | Fields | Rules |
| --- | --- | --- |
| `confirm` | `id` | Only the comment's author, only while resolved. Sets `confirmed`. |
| `after` | `id`, `screenshot` (upload id) | A picture of the fix: from the host's connection, or the author's; the upload must be this connection's; only for a comment resolved by someone else that has none yet. One per 2 s. |

| Hub → client | Fields |
| --- | --- |
| `capture` | `id` — sent only to the host's overlay, when a comment on its page is resolved by someone else, and again for each such comment without a picture when the host's page arrives there (also those from the last day, after a restart). |

**Overlay.** When one of `mine` becomes resolved by someone else (or was while they were away, once per browser:
`localStorage["__opentraffic_collab_fixes_seen"]`), it shows "✓ <resolvedBy> fixed your comment" with **Take a look**
(goes to the page, scrolls to the element, opens it, and pictures the fix if nobody has) and **Later**. The bubble
says who's working on it or who fixed it, shows **Before**/**After**, and asks the author **Looks good** / **Reopen**.
On `capture` the host's overlay waits 1.5 s for hot reload, then pictures the element like a comment screenshot.
A visitor's overlay only pictures a fix after they click **Take a look**.

**Starting an agent (app).** Settings → Integrations → *Agent for comments* holds a command (presets for Claude Code,
Codex, Cursor, opencode, or custom) and *Run it by itself* (off by default). OpenTraffic runs `/bin/zsh -c <command>`
in the share's `agentDirectory` (else the local server's working directory, found from its pid, then remembered),
with the user's login-shell PATH behind the app's own `Contents/Resources` (so `opentraffic` is this copy's), and
`OPENTRAFFIC_PROMPT`, `OPENTRAFFIC_SHARE`, `OPENTRAFFIC_SHARE_ID`, `OPENTRAFFIC_COMMENT_ID`, `OPENTRAFFIC_CLIENT`,
`OPENTRAFFIC_SOCKET` — ids only, never visitor text. The agent reaches the comment with the `opentraffic` command
(the prompt lists the commands) or the MCP tools where the user set them up; a run that exits 0 without claiming,
replying to, releasing, or resolving its comment is shown as failed (it never reached OpenTraffic). Triggers: **Send to …** in the Feedback
tab, or by itself 5 s after a visitor's comment when it's still open and unclaimed, no client is in
`wait_for_feedback` for the share (or was in the last 90 s), and no client holds another of its comments. One run per
share at a time (the rest queue), 20-minute limit, **Stop** ends the command and what it started. A run that exits
while its client still holds the comment releases it.

### 3.6 Work on a branch

A per-share switch (`TunnelDefinition.workOnBranch`, off by default; `branch` in the API, `--branch` in the CLI).
`GitRepository` (Core) runs `git -C <root>`; calls on one repository are serialized.

* **Start** (when the share's collaboration starts): the project folder is `agentDirectory` (else the local server's
  working directory, from its pid); its repository's root is found with `rev-parse --show-toplevel`. Refused on a
  detached HEAD or during a merge/rebase/cherry-pick. `git switch -c opentraffic/<slug>-<yyyyMMdd-HHmm>` (`-2`… if
  taken) from the current branch: the working folder, including uncommitted changes, is untouched. The session
  (`root`, `original`, `branch`, `startedAt`) is saved on the share, so a restart or crash carries on with it while
  that branch is still checked out. The baseline is a snapshot of every changed file (`status --porcelain -z
  --untracked-files=all` + `hash-object`).
* **Fix commits**: on claim, the app snapshots the changes. When the comment is resolved by an app, the host, or after
  a claim, it commits the paths whose contents differ from that snapshot (else from the baseline, which moves to
  after each commit): `git add -A -- <paths>`, `git commit -m "Fix: <comment>" -m "<who, where, share, id>" --
  <paths>`, so other staged or unstaged changes stay as they are. Hooks run; a failure is shown, not retried.
* **End** (a real stop, removing the share, turning the switch or collaboration off, quitting; not a restart): if the
  branch is still checked out and the original is an ancestor, fast-forward without touching files (`update-ref` the
  original to the branch's head, `symbolic-ref HEAD` to the original, `branch -d`). If the original moved on, merge
  only from a clean tracked tree (`switch`, `merge --no-edit`; on conflict `merge --abort` and switch back).
  Otherwise keep the branch checked out, and the session, with a notice and notification saying why.

**Setting up git.** Turning the switch on in the app checks first (`BranchReadiness`): no folder yet → on, decided at
start; git not installed (no Homebrew git, and `xcode-select -p` has no git, checked without running Apple's stub,
which would open macOS's installer) → offer `xcode-select --install`; no repository → **Set Up Git** / **Continue
Without**. Set up = refuse without `user.name`/`user.email` (before creating anything); `git init
--initial-branch=main`; write `GitRepository.defaultIgnore` when there's no `.gitignore`; `add -A`, then `rm --cached`
`.env`/`.env.*` (not `.example`/`.sample`/`.template`) and files over 10 MB; commit "Before OpenTraffic". Local only.
`.env` files are also never part of a fix commit. The API and CLI refuse `branch: true` with a 409 saying what to do.
At start, a project that isn't (or no longer is) in a repository, or missing git, turns the switch off with one notice.

### 3.7 Agents and visitors' words (prompt injection)

Anyone with the link writes text an agent reads: the comment, replies, names, element labels, page titles,
reported errors, and the screenshot (all visitor-controlled, since visitors control their browser). Defences,
none visible in normal use (`Sources/OpenTrafficCore/AgentSafety.swift`):

1. **Run scope.** The private socket gives the caller's pid (audit token); the HTTP API, only while runs are
   active, the pid owning the connection's port (`lsof`). A caller descending from a running agent command's
   process (`ProcessAncestry`), or remembered from an earlier request of one, is held to `AgentRunScope`: MCP
   lists and accepts only get_feedback (filtered to its comment), get_screenshot, claim/release/reply/resolve
   on its comment; REST likewise; everything else is 403. After its run, such a process may do nothing. Neither may
   a process macOS holds this app responsible for (`responsibility_get_pid_responsible_for_pid`, which survives
   reparenting) that isn't in a run's tree: a run let go of it (double fork, `setsid`) to get out of its scope.
   Only when the app is responsible for itself (opened as an app, not from a terminal).
2. **Presets** without web, the shell only for `opentraffic`'s comment commands (`AgentPreset.feedbackCommands`):
   Claude Code `--permission-mode dontAsk` with `Read,Edit,Write,Glob,Grep,mcp__opentraffic,Bash(opentraffic
   <command> *)` and `.env` reads denied; Codex in a permissions profile extending `:workspace` whose network goes
   through Codex's proxy with nothing allowed but OpenTraffic's socket (`features.network_proxy`,
   `permissions.<p>.network.unix_sockets`), no login shell (it would reset PATH), and the same sandbox tried on the
   web first — Codex ignores settings it doesn't know, so it isn't started if the web gets through; Cursor without
   `--force` (its allowlist); opencode `OPENCODE_CONFIG_CONTENT` denying bash but the comment commands, webfetch,
   and reads outside the project but `/tmp/opentraffic` (screenshots).
3. **ReplyRedactor** on API replies and claim progress: `.env*` values (≥ 8 characters, not examples) of the
   project folder and branch root, and key/token/private-key/URL-password patterns → `[hidden]`; the host gets a
   notice.
4. **AgentRunBudget**: automatic runs ≤ 10 per share and ≤ 3 per visitor (overlay client id) per hour.
5. **Spotlighting**: MCP results with visitor text carry it between `<visitor-content id="…">` markers with a
   random id per call; screenshots come with a note that their text is untrusted; the run prompt says so.
6. **MergeGuard**: a branch merges by itself only when no changed path is sensitive (manifests, lockfiles,
   build/tool configs, CI, scripts and server-side languages, server/api/functions folders, `.env*`), it adds
   ≤ 400 lines, and no added line makes requests, evaluates code, runs programs, reads env vars or visitors'
   cookies/storage, loads content or links from other sites, or holds encoded blobs.
7. **Invisible characters**: everything visitors send is NFKC-normalised and loses control, format (incl.
   tags, bidi, zero-width), private-use and unassigned code points, variation selectors except U+FE0F, and
   blank fillers.
8. **looksSuspicious**: comments (and labels/titles) shaped like instructions — overriding instructions,
   commands, requests to disclose secrets, tool names, links off the site, base64, > 600 characters — don't
   start the agent by themselves; they wait for Send to ….

### 3.8 A password in front of the share

Quick Tunnels and OpenTunnel can't be configured to ask for a password (OpenTunnel's server only relays
encrypted bytes), but all their traffic passes through `CollabProxy` on the Mac, so the proxy asks
(`ShareAccess`). A protected Quick share runs through the proxy even without collaboration (forward
only); a protected OpenTunnel share likewise.

* Every request is checked before anything else, including the hub socket, the overlay script, bridged
  ports and other upgrades. Exempt: `/__opentraffic/host` (its token is checked as before) and
  `/__opentraffic/sign-in`. The host cookie lets the host through; the `Host` header proves nothing
  (OpenTunnel visitors can set it).
* Signed in = cookie `__opentraffic_access` = HMAC-SHA256(password, "opentraffic-access:" + share id),
  `HttpOnly; Secure; SameSite=Lax`, 30 days; or basic auth with the password (any username). Page
  navigations without it get the branded sign-in page (401) in place; anything else a 401 with
  `WWW-Authenticate: Basic`.
* Invite links carry `ot_invite` = HMAC(password, "opentraffic-invite:" + share id); a valid one sets the
  cookie and 303s to the same URL without it. Both values come from the password, so a new password
  signs everyone out and stops old links, applied live with `setAccess` (no restart).
* The sign-in POST returns a small page that stores the visitor's name for the overlay
  (`__opentraffic_collab_name`) and continues to a same-site `next`. Five wrong tries a minute per
  CF-Connecting-IP (or per share when the tunnel doesn't say) → 429. Comparisons are constant-time.
* The page is built from the website's shadcn components (`website/src/sign-in`), rendered to static
  HTML with its Tailwind CSS and the Geist font inlined by `npm run sign-in` into
  `Sources/OpenTrafficCore/SignInTemplate.swift`; the proxy only fills in the share's name, `next`, the
  error, and whether to ask for a name. No script runs on it.
* The app never sees OpenTraffic's cookie or basic auth with the share's password. OpenTraffic's pages
  send a CSP that loads nothing from elsewhere and forbids framing.

### 3.9 Element context, suggested edits, areas, drawing, devices, and roles

* **Context** (`CollabElementContext`): with each comment the overlay sends a readable selector (tag, id,
  non-generated classes, under the nearest ancestor with an id), the computed values of a fixed list of
  styles, and on development builds the component and source file: React's fiber (`_debugSource` when it
  exists, with its line; React 19's `_debugStack`, file only, since the dev server's transform shifts
  lines), Vue's `__vueParentComponent`/`__vue__` `__file`, Svelte's `__svelte_meta`, Angular's
  `ng.getOwningComponent`. Paths are cut to `src/…` (or their last three segments). Only the host's page
  and the API get it.
* **Suggested edits** (`CollabSuggestedEdit`, at most six): new text for an element whose text is a single
  text node (changed in place through `nodeValue`, so frameworks keep their node), or new values for an
  allow-listed set of style properties. The hub drops values that could leave the declaration (`;{}<>\"'`
  backslash, backtick, comments). Previews are local and undone on post, cancel, or close.
* **Areas** (`CollabArea`): dragging in comment mode pins the comment to the smallest element containing
  the box's corners, at the box's top-left; the size is in CSS pixels.
* **Drawing**: `ink` messages (≤ 64 `[x, y]` points, ≤ 25 a second) go to everyone else on the path,
  ephemeral; never stored.
* **Devices**: `hello` carries the overlay's environment; `env` updates it (≤ 1 a second). Peers carry
  `device` (browser, system, viewport). "View at their size" frames their path in a same-origin iframe of
  their viewport (the overlay doesn't run in frames), scaled into a phone, tablet, or browser-window frame
  on a stage over the page. `watch` (`{id}` or `{id: null}`) asks the hub for that person's `cursor` and
  `cursor-hide` from any path, so the stage can show their pointer and follow them; a reload is a new
  connection, so the stage re-attaches to the same name and device within 15 s.
* **Device views you can work in**: the stage's iframe gets `__opentrafficStage` (scale, screen and device
  rects, armed, followsLead, leadView, following); the overlay starts inside it only then (same origin,
  `frameElement` set by us) and says `hello {inView: true}`. The hub keeps in-view connections out of
  `peers` (the app, API) and fix captures, gives them the person's colour, and still sends them to
  overlays (their pointer), which don't list them. The framed overlay has no pill (the stage's pill tools
  call its `arm`), uses an in-memory session, and puts its comment box and bubbles in a shadow root on the
  stage's page, beside the device.
* **Phone / Desktop and leading**: `lead {on, view}` with `view = {kind: phone|window, w, h}` or null;
  left out keeps it. `lead` messages and the welcome carry it. Only the connection that turned leading on
  (`leadConnection`) moves followers with `path`/`scroll` (any other host page while it's reloading,
  never a device view unless it's the one), so the host's phone leads while it's open. Followers open
  the host's phone or window as a stage whose overlay follows; a window the size of theirs is skipped.
* **Roles** (`CollabRole`: trusted, commenter, viewer), kept per share by overlay client id
  (`collabMembers`) with a default (`collabDefaultRole`), pushed to the hub with `setRoles`. Viewers can't
  comment, reply, resolve, confirm, or delete; the hub refuses those messages. Automatic agent runs only
  start for comments by trusted people (or the host). Roles follow a browser, not a verified identity.

### Planned: following anyone (groups instead of one leader)

Today only the host leads and every visitor follows them. Planned: anyone can be followed. You follow a
person (from the people list), not "the lead"; whoever is being followed sees who follows them and can
stop being followed. Each follower picks one person, so two leaders never pull the same visitor.
Following someone who follows someone else follows the person at the front, so there are no loops.
The host keeps one override, **Everyone follow me**, for demos. The shared viewport (Phone, Desktop, or
Match my window) belongs to whoever is being followed and reaches only their own followers.

## Stdio bridge

`opentraffic-mcp` speaks MCP over stdio and relays each message to OpenTraffic over a private connection that only
OpenTraffic's own signed tools can use. Like the `opentraffic` command, it's part of the app: it needs no token,
works with the local API off, and doesn't ask before sharing. If OpenTraffic isn't running, the bridge starts it in
the background. Environment:

| Variable | Default | |
| --- | --- | --- |
| `OPENTRAFFIC_CLIENT` | `MCP client` | The name OpenTraffic shows for the app (on replies and in the activity log). |

### Tools

| Tool | Does |
| --- | --- |
| `list_shares` | Shares with state, URLs, people in the session, comment counts; for a Mac app share, how its app runs, who may control it, and whether its rebuild failed (`macApp.build`). |
| `list_mac_apps` | The Mac apps to share, as `opentraffic services` lists them: the ones you're building (with `projectDirectory`), then the installed apps that are running (`installed`: TextEdit, App Store apps, other developers' apps). |
| `share` | Publishes a local `port` or `url` (`provider`: `quick`, `tailscale`, `ngrok`, `opentunnel`; `name`; `collaboration`, default on), or a Mac app (`mac_app`: its .app path or name, one you're building or an installed one; `mac_app_data`: `copy` or `empty`; see [Mac apps](/docs/mac-apps)). |
| `start_share`, `stop_share` | By id or name. |
| `restart_mac_app` | Starts a shared Mac app again from its latest build on the same URL, after rebuilding it to show a fix (`reset_data`: over from its starting data). |
| `control_mac_app` | For a Mac app share set to ask to control: `allow` a viewer who asks, `deny` a request, or `take_back` control. `list_shares` shows who asks (`macApp.control.requests`) and who has control. |
| `get_feedback` | Comments (`status`: `open`, `resolved`, `all`). Each says whether it's `open`, `working` (and who's on it), `resolved`, or `confirmed`, and carries `context` (selector, styles, component, source file), suggested `edits` to apply as given, and `area` for a comment on a region. |
| `claim_comment`, `release_comment` | Say you're working on a comment (with optional `progress`), or stop. The session sees the app at the element; other apps' claims are refused. A claim lapses after 15 minutes unless claimed again. |
| `resolve_comment`, `reply_to_comment` | Replies and fixes show the app's name; the commenter is told it's fixed and can confirm or reopen it. |
| `get_screenshot` | The pinned element, as an image; `which: after` for the picture of it once fixed. |
| `get_errors`, `get_logs` | Browser errors visitors hit; the tunnel's log. |
| `wait_for_feedback` | Waits (up to `timeout_seconds`, default 60, max 300) for new, changed or deleted comments; returns them and a `cursor` to pass as `since` next time. |

`wait_for_feedback` holds the call open while it waits. If your client gives up on tool calls sooner, pass a
smaller `timeout_seconds`.

## Tool arguments

| Tool | Required arguments | Optional arguments |
| --- | --- | --- |
| `list_shares` | None | None |
| `list_mac_apps` | None | None |
| `share` | `port`, `url`, or `mac_app` | `provider`, `name`, `collaboration` (default true), `mac_app_data` (`copy` or `empty`; default `copy`) |
| `start_share` / `stop_share` | `share` | None |
| `restart_mac_app` | `share` | `reset_data` (default false) |
| `control_mac_app` | `share`, `action` (`allow`, `deny`, `take_back`) | `viewer`: a request's number or name (default: the oldest request) |
| `get_feedback` | `share` | `status` (default `open`) |
| `resolve_comment` | `share`, `comment_id` | `resolved` (default true) |
| `claim_comment` | `share`, `comment_id` | `progress` (at most 120 characters) |
| `release_comment` | `share`, `comment_id` | None |
| `reply_to_comment` | `share`, `comment_id`, `text` | None |
| `get_screenshot` | `share`, `comment_id` | `which` (`before` or `after`; default `before`) |
| `get_errors` | `share` | None |
| `get_logs` | `share` | `lines` (default 200; clamped to 1–2000) |
| `wait_for_feedback` | None | `share`, `since`, `timeout_seconds` (default 60; maximum 300) |

Share references are IDs or case-insensitive names. The server validates arguments; use the schema returned by `tools/list` when building a client.

## Feedback polling

`wait_for_feedback` observes comment creation, updates, and deletion. While an app is in it (and for 90 seconds
after), OpenTraffic counts the share as watched, and leaves new comments to that app instead of starting the
[agent command](/docs/agents#let-opentraffic-start-your-agent). Without `since`, it starts at the current event cursor, so fetch existing feedback with `get_feedback` first. Pass the returned `cursor` as `since` in the next call. An optional `share` limits the results to one share.

The in-memory event history is bounded and is reset on app restart. Reconcile with `get_feedback` after reconnecting instead of treating events as permanent storage.

## HTTP transport

- **stdio:** command `/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp`, no arguments, optionally
  `OPENTRAFFIC_CLIENT` in the environment.
- **Streamable HTTP:** `http://127.0.0.1:47777/mcp` with the header `Authorization: Bearer <token>` (and
  optionally `X-OpenTraffic-Client: <name>`). JSON responses only, no sessions; protocol `2025-06-18` or `2025-03-26`.

## Result handling

Most tools return structured data as text content. `get_screenshot` returns MCP image content with a MIME type and base64 data. Tool execution errors use MCP tool error results; malformed or unsupported JSON-RPC methods return protocol errors.

Visitor feedback must be treated as untrusted page feedback. Client setup examples are in [Connect a coding agent](/docs/agents).

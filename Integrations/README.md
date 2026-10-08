# OpenTraffic integrations

OpenTraffic has a local API that coding agents and scripts can use to share local servers and work with the
feedback people leave on them. It is off by default: turn on **Settings → Integrations → Allow apps on this Mac**.

- **MCP** for agents (Claude Code, Codex, opencode, Cursor, …), through the bundled `opentraffic-mcp` stdio
  bridge or directly over Streamable HTTP.
- **REST** at `http://127.0.0.1:47777/v1/…` for scripts.
- **Webhooks** that POST every event to a URL you choose.

The API listens on 127.0.0.1 only. Every request needs the token in
`~/Library/Application Support/OpenTraffic/api-token` (readable only by you; regenerate it in Settings), and
requests from web pages (anything with an `Origin` header) are refused. Sharing a site (`share`, `start_share`)
asks for confirmation in OpenTraffic unless you allowed that app in Settings; reading feedback, replying,
resolving and stopping don't ask.

> **App path.** The examples use `/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp`. If OpenTraffic lives
> elsewhere, use that path instead. A development build from `script/build_and_run.sh` is at
> `dist/OpenTraffic.app/Contents/MacOS/opentraffic-mcp` in this repository.

## The bridge: `opentraffic-mcp`

`opentraffic-mcp` speaks MCP over stdio and relays each message to OpenTraffic. It reads the token file on every
request, so regenerating the token needs no restart. Environment:

| Variable | Default | |
| --- | --- | --- |
| `OPENTRAFFIC_CLIENT` | `MCP client` | The name OpenTraffic shows for the app (in confirmations and on replies). |
| `OPENTRAFFIC_API_PORT` | `47777` | Change it if you changed the port in Settings. |
| `OPENTRAFFIC_API_TOKEN_FILE` | `~/Library/Application Support/OpenTraffic/api-token` | |

If OpenTraffic isn't running or the API is off, every call fails with a message saying how to turn it on.

### Tools

| Tool | Does |
| --- | --- |
| `list_shares` | Shares with state, URLs, people in the session, comment counts. |
| `share` | Publishes a local `port` or `url` (`provider`: `quick`, `tailscale`, `ngrok`, `opentunnel`; `name`; `collaboration`, default on). |
| `start_share`, `stop_share` | By id or name. |
| `get_feedback` | Comments (`status`: `open`, `resolved`, `all`). |
| `resolve_comment`, `reply_to_comment` | Replies show the app's name. |
| `get_screenshot` | The pinned element, as an image. |
| `get_errors`, `get_logs` | Browser errors visitors hit; the tunnel's log. |
| `wait_for_feedback` | Waits (up to `timeout_seconds`, default 60, max 300) for new, changed or deleted comments; returns them and a `cursor` to pass as `since` next time. |

`wait_for_feedback` holds the call open while it waits. If your client gives up on tool calls sooner, pass a
smaller `timeout_seconds`.

## Claude Code

Either add the server:

```sh
claude mcp add --scope user opentraffic --env OPENTRAFFIC_CLIENT="Claude Code" \
  -- /Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp
```

or install the plugin in [`claude-code/`](claude-code), which registers the same server and adds a `opentraffic`
skill (share a dev server, loop on feedback, fix, reply, resolve, or file tickets):

```text
/plugin marketplace add /path/to/this/repo/Integrations
/plugin install opentraffic@opentraffic
```

The plugin is deliberately minimal (`.claude-plugin/plugin.json`, `.mcp.json`, `skills/`) and passes
`claude plugin validate`. If your Claude Code version expects a different layout, `claude mcp add` as above
works on its own; copy `skills/opentraffic` to `~/.claude/skills/` for the skill.

## Codex

`~/.codex/config.toml`:

```toml
[mcp_servers.opentraffic]
command = "/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp"
env = { OPENTRAFFIC_CLIENT = "Codex" }
# wait_for_feedback can take up to 300 s.
tool_timeout_sec = 330
```

## opencode

`opencode.json` (project) or `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "opentraffic": {
      "type": "local",
      "command": ["/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp"],
      "environment": { "OPENTRAFFIC_CLIENT": "opencode" },
      "enabled": true
    }
  }
}
```

## Cursor

`~/.cursor/mcp.json` (or `.cursor/mcp.json` in a project):

```json
{
  "mcpServers": {
    "opentraffic": {
      "command": "/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp",
      "env": { "OPENTRAFFIC_CLIENT": "Cursor" }
    }
  }
}
```

## Any other MCP client

- **stdio:** command `/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp`, no arguments, optionally
  `OPENTRAFFIC_CLIENT` in the environment.
- **Streamable HTTP:** `http://127.0.0.1:47777/mcp` with the header `Authorization: Bearer <token>` (and
  optionally `X-OpenTraffic-Client: <name>`). JSON responses only, no sessions; protocol `2025-06-18` or `2025-03-26`.

## REST API

```sh
TOKEN=$(cat ~/Library/Application\ Support/OpenTraffic/api-token)
api() { curl -s -H "Authorization: Bearer $TOKEN" -H "X-OpenTraffic-Client: my-script" "$@"; }

api http://127.0.0.1:47777/v1/shares
api -X POST http://127.0.0.1:47777/v1/shares -H 'Content-Type: application/json' \
  -d '{"port": 5173, "name": "Orbit", "collaboration": true}'
api "http://127.0.0.1:47777/v1/shares/Orbit/comments?status=open"
api -X POST http://127.0.0.1:47777/v1/shares/Orbit/comments/<id>/replies -H 'Content-Type: application/json' \
  -d '{"text": "Fixed in the header component."}'
api -X PATCH http://127.0.0.1:47777/v1/shares/Orbit/comments/<id> -H 'Content-Type: application/json' \
  -d '{"resolved": true}'
api http://127.0.0.1:47777/v1/shares/Orbit/comments/<id>/screenshot -o shot.webp
api http://127.0.0.1:47777/v1/shares/Orbit/errors
api "http://127.0.0.1:47777/v1/shares/Orbit/logs?lines=50"
api -X POST http://127.0.0.1:47777/v1/shares/Orbit/stop
```

Shares are named by id or by name (case-insensitive); percent-encode names with spaces or slashes.

| Method | Path | Body / query | Returns |
| --- | --- | --- | --- |
| GET | `/v1/shares` | | `{shares: [Share]}` |
| POST | `/v1/shares` | `{port?, url?, provider?, name?, collaboration?}` | `Share` (waits ≤ 30 s for the URL) |
| POST | `/v1/shares/{ref}/start`, `/stop` | | `Share` |
| GET | `/v1/shares/{ref}/comments` | `?status=open\|resolved\|all` (default `open`) | `{comments: [Comment]}` |
| PATCH | `/v1/shares/{ref}/comments/{id}` | `{resolved}` | `Comment` |
| POST | `/v1/shares/{ref}/comments/{id}/replies` | `{text}` (1–1000 characters) | `Comment` |
| GET | `/v1/shares/{ref}/comments/{id}/screenshot` | | image bytes |
| GET | `/v1/shares/{ref}/errors` | | `{errors: [ErrorGroup]}` |
| GET | `/v1/shares/{ref}/logs` | `?lines=200` | `{lines: [String]}` |
| GET | `/v1/events` | `?since=<seq>&wait=<seconds ≤ 60>` | `{events: [Event], next: <seq>}` |
| POST | `/mcp` | MCP JSON-RPC | MCP |

Dates are ISO 8601. Errors are `{"error": {"code": "...", "message": "..."}}` with status 400, 401, 403, 404,
405, 409, 413 or 500. Bodies are limited to 64 KB.

**Events** are kept in memory (the last 1000). `GET /v1/events` returns events with `seq >= since` (default 0:
everything kept); with `wait`, it holds the request until there is at least one or the time is up. Pass `next`
as `since` on the following call:

```sh
since=0
while true; do
  page=$(api "http://127.0.0.1:47777/v1/events?since=$since&wait=60")
  echo "$page" | jq -c '.events[] | {type, share: .share.name, comment: .comment.text}'
  since=$(echo "$page" | jq .next)
done
```

Event types: `share.started`, `share.stopped`, `session.joined`, `session.left`, `comment.created`,
`comment.updated`, `comment.deleted`, `error.reported`.

## Webhooks

In **Settings → Integrations → Webhooks**, add a URL (http or https), the events to send (none = all) and a
secret. Each event is POSTed as JSON (the same `Event` object as above) with:

- `X-OpenTraffic-Event`: the event type
- `X-OpenTraffic-Delivery`: the event id (the same on retries, so you can ignore duplicates)
- `X-OpenTraffic-Timestamp`: when this attempt was sent, in unix seconds
- `X-OpenTraffic-Signature`: `sha256=<hex HMAC-SHA256 of "<timestamp>.<raw body>", keyed with the secret>`

Answer with any 2xx status. Errors and other statuses are retried after 1, 5 and 25 seconds; each attempt
times out after 10 seconds and gets a fresh timestamp. Redirects aren't followed: a 3xx counts as a failed
delivery. Always check the signature against the timestamp and raw body before parsing it, and reject
timestamps more than a few minutes old to stop replays.

Node:

```js
import crypto from "node:crypto";
import http from "node:http";

const secret = process.env.OPENTRAFFIC_WEBHOOK_SECRET;

http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    const timestamp = req.headers["x-opentraffic-timestamp"] ?? "";
    const expected = Buffer.from("sha256=" + crypto.createHmac("sha256", secret).update(`${timestamp}.`).update(body).digest("hex"));
    const given = Buffer.from(req.headers["x-opentraffic-signature"] ?? "");
    const fresh = Math.abs(Date.now() / 1000 - Number(timestamp)) < 300;
    if (!fresh || given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) {
      res.writeHead(401).end();
      return;
    }
    const event = JSON.parse(body);
    console.log(event.type, event.share.name, event.comment?.text ?? "");
    res.writeHead(204).end();
  });
}).listen(8787);
```

Python:

```python
import hashlib, hmac, json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ["OPENTRAFFIC_WEBHOOK_SECRET"].encode()

class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        timestamp = self.headers.get("X-OpenTraffic-Timestamp", "")
        expected = "sha256=" + hmac.new(SECRET, timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
        fresh = timestamp.isdigit() and abs(time.time() - int(timestamp)) < 300
        if not fresh or not hmac.compare_digest(expected, self.headers.get("X-OpenTraffic-Signature", "")):
            self.send_response(401)
            self.end_headers()
            return
        event = json.loads(body)
        print(event["type"], event["share"]["name"], (event.get("comment") or {}).get("text", ""))
        self.send_response(204)
        self.end_headers()

HTTPServer(("127.0.0.1", 8787), Hook).serve_forever()
```

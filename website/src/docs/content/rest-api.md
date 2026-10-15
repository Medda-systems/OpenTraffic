## Authentication

This API is for your own apps and scripts. The `opentraffic` [command](/docs/cli) and the [MCP bridge](/docs/mcp) don't use it: they're part of OpenTraffic and need no token.

Enable the local API in Settings → Integrations. The default base URL is `http://127.0.0.1:47777`. Every request requires `Authorization: Bearer <token>`. Read the token from `~/Library/Application Support/OpenTraffic/api-token`, a file readable only by your user.

Send `X-OpenTraffic-Client` to identify your integration. Requests containing an `Origin` header are rejected: this API is for local applications and scripts, not browser JavaScript. Do not expose or tunnel the API port.

Creating or starting a share can prompt for approval. Sharing an origin on another device always asks, even when publishing without confirmation is enabled. Stopping, reading feedback, replying, and resolving do not ask for publication approval.

## Request examples and endpoints

```sh
TOKEN=$(cat ~/Library/Application\ Support/OpenTraffic/api-token)
api() { curl -s -H "Authorization: Bearer $TOKEN" -H "X-OpenTraffic-Client: my-script" "$@"; }

api http://127.0.0.1:47777/v1/shares
api -X POST http://127.0.0.1:47777/v1/shares -H 'Content-Type: application/json' \
  -d '{"port": 5173, "name": "Orbit", "collaboration": true}'
api "http://127.0.0.1:47777/v1/shares/Orbit/comments?status=open"
COMMENT_ID="replace-with-an-id-from-the-comments-response"
api -X POST "http://127.0.0.1:47777/v1/shares/Orbit/comments/$COMMENT_ID/replies" -H 'Content-Type: application/json' \
  -d '{"text": "Fixed in the header component."}'
api -X PATCH "http://127.0.0.1:47777/v1/shares/Orbit/comments/$COMMENT_ID" -H 'Content-Type: application/json' \
  -d '{"resolved": true}'
api "http://127.0.0.1:47777/v1/shares/Orbit/comments/$COMMENT_ID/screenshot" -o shot.webp
api http://127.0.0.1:47777/v1/shares/Orbit/errors
api "http://127.0.0.1:47777/v1/shares/Orbit/logs?lines=50"
api -X POST http://127.0.0.1:47777/v1/shares/Orbit/stop
```

Shares are named by id or by name (case-insensitive); percent-encode names with spaces or slashes.

| Method | Path | Body / query | Returns |
| --- | --- | --- | --- |
| GET | `/v1/status` | | `{version, shares, running, providers: [{name, ready, detail, warning?}], publishesWithoutAsking}` |
| GET | `/v1/services` | | `{services: [{port, url, title, process, statusCode, upSince, sharedAs}]}` |
| GET | `/v1/shares` | | `{shares: [Share]}` |
| POST | `/v1/shares` | see below | `Share` (waits ≤ 30 s for the URL) |
| GET | `/v1/shares/{ref}` | | `Share` |
| PATCH | `/v1/shares/{ref}` | `{name?, url?, collaboration?, captureErrors?, autoStart?, project?, rewriteHostHeader?, autoStop?}` | `Share` |
| DELETE | `/v1/shares/{ref}` | | `{deleted: true}` |
| POST | `/v1/shares/{ref}/start`, `/stop`, `/restart` | | `Share` (`/stop` waits ≤ 10 s until it has stopped) |
| GET, PUT | `/v1/shares/{ref}/protection` | PUT: `{mode, username?, emails?}` | `{mode, username, password, emails}` |
| POST | `/v1/shares/{ref}/password` | | a new password: `{mode, username, password, emails}` |
| GET | `/v1/shares/{ref}/comments` | `?status=open\|resolved\|all` (default `open`) | `{comments: [Comment]}` |
| PATCH | `/v1/shares/{ref}/comments/{id}` | `{resolved}` | `Comment` |
| DELETE | `/v1/shares/{ref}/comments/{id}` | | `{deleted: true}` |
| POST | `/v1/shares/{ref}/comments/{id}/replies` | `{text}` (1–1000 characters) | `Comment` |
| GET | `/v1/shares/{ref}/comments/{id}/screenshot` | | image bytes |
| GET | `/v1/shares/{ref}/errors` | | `{errors: [ErrorGroup]}` |
| GET | `/v1/shares/{ref}/logs` | `?lines=200` | `{lines: [String]}` |
| GET | `/v1/events` | `?since=<seq>&wait=<seconds ≤ 60>` | `{events: [Event], next: <seq>}` |
| GET | `/v1/projects` | | `{projects: [{name, shares, running}]}` |
| POST | `/v1/projects/{name}/start`, `/stop` | | `{name, shares, running}` |
| GET | `/v1/zones` | | `{zones: [{id, name}]}`: domains in the connected Cloudflare account |
| GET | `/v1/tools` | | `{tools: [{name, provider, installed, path, version, installable}]}`: the tools OpenTraffic shares through |
| POST | `/v1/tools/{name}/install` | | `{name, provider, installed, path, version, installable}`: installs `cloudflared`, `opentunnel`, `ngrok`, or `tailscale` from its maker's official release (Tailscale asks for the Mac's password in OpenTraffic; 502 `install_failed` if a download fails its checks or installing is cancelled) |
| POST | `/mcp` | MCP JSON-RPC | MCP |

Dates are ISO 8601. Errors are `{"error": {"code": "...", "message": "..."}}` with status 400, 401, 403, 404,
405, 409, 413, 500 or 502. Bodies are limited to 64 KB.



## Create a share

| Field | Type | Meaning |
| --- | --- | --- |
| `port` | integer | Local port, 1–65535. Use this when you are not supplying `url`. |
| `url` | string | HTTP or HTTPS local service URL. Provider and collaboration restrictions still apply. |
| `provider` | string | `quick`, `opentunnel`, `tailscale`, `ngrok`, or `domain`; defaults to `quick`. |
| `name` | string | Optional display name; must not belong to another share. |
| `collaboration` | boolean | Enable collaboration where supported; defaults to false in REST (true in the MCP `share` tool). |
| `hostname` | string | `domain`: the hostname to serve, in your Cloudflare account (required). `ngrok`: a domain reserved in your ngrok account. |
| `replaceDNS` | boolean | `domain`: take over a hostname that already has a DNS record. An existing CNAME is pointed at the new tunnel and A/AAAA records are replaced; other records are never removed. |
| `funnel` | boolean | `tailscale`: public on the internet through Funnel instead of tailnet only. |
| `start` | boolean | `false` saves the share without starting it. |

A share for a way of sharing that isn't set up yet (including `funnel` when Funnel isn't allowed for this Mac) is refused with 409 (`not_ready`) and the reason, before anything is asked or created; `GET /v1/status` lists what's ready, and a `warning` when a way that's ready is likely to fail anyway (for example, a network whose DNS filter blocks temporary Cloudflare tunnels). A `domain` hostname that already has a DNS record is refused with 409 (`dns_record_exists`) unless `replaceDNS` is set. Creating a custom-domain share always asks for confirmation, because it creates a tunnel and a DNS record in your Cloudflare account.

A create request waits up to 30 seconds for a URL. The returned share may still be starting and `publicURL` may be absent; use `GET /v1/shares` to check progress rather than creating a duplicate.

## Share response

A `Share` contains `id`, `name`, `provider`, `kind`, `state`, `localURL`, optional `publicURL`, `collaboration`, `people`, `openComments`, and `comments`. It also has what the share's detail view shows: `hostname`, `lastError` (when failed), `protection` (`none`, `password`, `google`, `github`, or `email`), `project`, `autoStart`, `captureErrors`, `rewriteHostHeader`, `funnel` (Tailscale), `stopsAt`, and `health`, the connection path's latest checks (`kind`, `title`, `state` of `ok`, `working`, `failed`, or `skipped`, and `detail`). Each person has a name, path, and `isHost` flag. State is one of `stopped`, `starting`, `running`, `stopping`, or `failed`.

## Comment response

A `Comment` contains `shareId`, `id`, `author`, `path`, `text`, `createdAt`, `resolved`, `replies`, `hasScreenshot`, and `errors`. Optional context includes `title`, `label`, `anchor`, and `environment`. Fetch screenshot bytes from the screenshot endpoint only when `hasScreenshot` is true. Swift’s optional fields can be omitted from JSON.

## Limits and errors

| Status | How to handle it |
| --- | --- |
| 400 | Correct the request, provider, URL, or parameter. |
| 401 | Check the bearer token; it may have been regenerated. |
| 403 | Check local API restrictions or denied publication approval. |
| 404 | Refresh the share or comment reference. |
| 405 | Use the endpoint’s supported method. |
| 409 | Resolve the conflicting app or share state before retrying. |
| 413 | Reduce the request body below 64 KB. |
| 500 | Inspect OpenTraffic and retry only when appropriate. |
| 502 | The connector failed to start; inspect its logs before retrying. |

Replies must contain 1–1000 characters. Log requests default to 200 lines and are clamped to 1–2000. For event polling and webhook delivery, see [Events](/docs/events) and [Webhooks](/docs/webhooks).

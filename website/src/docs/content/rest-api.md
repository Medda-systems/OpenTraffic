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
| GET | `/v1/services` | | `{services: [{port, url, title, process, statusCode, upSince, sharedAs}], apps: [{kind: "macapp", name, bundle, bundleIdentifier, projectDirectory, running, builtAt, sharedAs, device?}]}`: web servers, and the Mac apps being built on this Mac (`device`, like `iPhone 17 Simulator`, for an iPhone app in a booted Simulator, which can't be shared yet) |
| GET | `/v1/shares` | | `{shares: [Share]}` |
| POST | `/v1/shares` | see below | `Share` (waits ≤ 30 s for the URL) |
| GET | `/v1/shares/{ref}` | | `Share` |
| PATCH | `/v1/shares/{ref}` | `{name?, url?, collaboration?, captureErrors?, branch?, autoStart?, project?, rewriteHostHeader?, autoStop?, macAppControl?, macAppAppearance?, macAppWindowSize?}` | `Share`; the `macApp…` fields are a Mac app share's viewer options: `everyone`, `watchOnly` or `askToControl`; `viewer`, `mac`, `light` or `dark`; `fitViewer` or `app` |
| DELETE | `/v1/shares/{ref}` | | `{deleted: true}` |
| POST | `/v1/shares/{ref}/start`, `/stop`, `/restart` | | `Share` (`/stop` waits ≤ 10 s until it has stopped) |
| POST | `/v1/shares/{ref}/restart-app`, `/reset-data` | | `Share`, once the Mac app is back: `/restart-app` starts a Mac app share's app again from its latest build on the same address, `/reset-data` starts it over from the data it started with (409 when the share isn't running, 502 `restart_failed` with the reason when the app doesn't come back) |
| GET, PUT | `/v1/shares/{ref}/protection` | PUT: `{mode, username?, emails?}` | `{mode, username, password, emails, link}`; `link` (temporary and OpenTunnel shares, once they have an address) has the password built in, and `username` is null there since any works |
| POST | `/v1/shares/{ref}/password` | | a new password: `{mode, username, password, emails}` |
| GET | `/v1/shares/{ref}/comments` | `?status=open\|resolved\|all` (default `open`) | `{comments: [Comment]}` |
| PATCH | `/v1/shares/{ref}/comments/{id}` | `{resolved}` | `Comment` |
| DELETE | `/v1/shares/{ref}/comments/{id}` | | `{deleted: true}` |
| POST | `/v1/shares/{ref}/comments/{id}/replies` | `{text}` (1–1000 characters) | `Comment` |
| POST | `/v1/shares/{ref}/comments/{id}/claim` | optional `{progress}` (at most 120 characters) | `Comment`; 409 when another app has it or it's resolved |
| DELETE | `/v1/shares/{ref}/comments/{id}/claim` | | `Comment` |
| GET | `/v1/shares/{ref}/comments/{id}/screenshot` | `?which=before\|after` (default `before`) | image bytes |
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
| `branch` | boolean | With `collaboration`: [work on a branch](/docs/collaboration#work-on-a-branch) while it runs. |
| `hostname` | string | `domain`: the hostname to serve, in your Cloudflare account (required). `ngrok`: a domain reserved in your ngrok account. |
| `replaceDNS` | boolean | `domain`: take over a hostname that already has a DNS record. An existing CNAME is pointed at the new tunnel and A/AAAA records are replaced; other records are never removed. |
| `funnel` | boolean | `tailscale`: public on the internet through Funnel instead of tailnet only. |
| `start` | boolean | `false` saves the share without starting it. |
| `macApp` | string | A Mac app you're building, instead of `port` or `url`: its full .app path, or its name as `GET /v1/services` lists it. Shared with `quick` or `opentunnel`, always with live collaboration; sharing an app that's already shared that way returns that share. A `url` that is an .app path shares a running Electron app of yours, or else the Mac app. See [Mac apps](/docs/mac-apps). |
| `macAppData` | string | With `macApp`: `copy` (default) starts its isolated copy with a copy of the app's data, `empty` with none. |

A share for a way of sharing that isn't set up yet (including `funnel` when Funnel isn't allowed for this Mac) is refused with 409 (`not_ready`) and the reason, before anything is asked or created; `GET /v1/status` lists what's ready, and a `warning` when a way that's ready is likely to fail anyway (for example, a network whose DNS filter blocks temporary Cloudflare tunnels). A `domain` hostname that already has a DNS record is refused with 409 (`dns_record_exists`) unless `replaceDNS` is set. Creating a custom-domain share always asks for confirmation, because it creates a tunnel and a DNS record in your Cloudflare account. A Mac app share (created, started, or restarted) is refused with 409 (`missing_permissions`) while OpenTraffic doesn't have Accessibility and Screen Recording, and with 409 while another share runs the same app.

A create request waits up to 30 seconds for a URL. The returned share may still be starting and `publicURL` may be absent; use `GET /v1/shares` to check progress rather than creating a duplicate.

## Share response

A `Share` contains `id`, `name`, `provider`, `kind`, `state`, `localURL`, optional `publicURL`, `collaboration`, `people`, `openComments`, and `comments`. It also has what the share's detail view shows: `hostname`, `lastError` (when failed), `protection` (`none`, `password`, `google`, `github`, or `email`), `project`, `autoStart`, `captureErrors`, `rewriteHostHeader`, `funnel` (Tailscale), `stopsAt`, `branch` (and, while it's on one, `branchName` and the `baseBranch` it merges into), `macApp` for a Mac app share (`path`, `name`, `data` of `copy` or `empty`, and while it runs `state` of `starting`, `running`, `restarting`, `crashed`, `failed`, or `stopped`, `viewers`, `warning`, and `error`), and `health`, the connection path's latest checks (`kind`, `title`, `state` of `ok`, `working`, `failed`, or `skipped`, and `detail`). Each person has a name, path, and `isHost` flag, plus `role` (`trusted`, `commenter`, or `viewer`) and `device` (`browser`, `os`, `viewport`, `dpr`, `language`) when known; coding agents at work on a comment also appear, with `isAgent: true`. State is one of `stopped`, `starting`, `running`, `stopping`, or `failed`.

## Comment response

A `Comment` contains `shareId`, `id`, `author`, `path`, `text`, `createdAt`, `resolved`, `replies`, `hasScreenshot`, and `errors`. Optional context includes `title`, `label`, `anchor`, and `environment`; `context` (`selector`, `styles`, and on development builds `component` and `source`), `edits` (each `kind` `text` or `style`, with `property` for styles, `old`, and `new`: exact changes the commenter suggested), and `area` (`width` and `height` in CSS pixels, for a comment on a region). `status` is `open`, `working` (an app claimed it: `claimedBy`, and its latest `progress`), `resolved` (`resolvedBy`, `resolvedAt`), or `confirmed` (the commenter agreed with the fix). Fetch screenshot bytes from the screenshot endpoint only when `hasScreenshot` is true, and the picture of the fix with `which=after` only when `hasAfterScreenshot` is true.

A claim says an app is working on a comment: other apps' claims are refused, and everyone in the session sees the app at the comment's element. Claim again to update `progress`; that also renews the claim, which otherwise lapses after 15 minutes. Resolving ends it. The `X-OpenTraffic-Client` header names the app, on claims, replies, and fixes. Swift’s optional fields can be omitted from JSON.

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

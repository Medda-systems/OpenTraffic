## Authentication

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
405, 409, 413, 500 or 502. Bodies are limited to 64 KB.



## Create a share

| Field | Type | Meaning |
| --- | --- | --- |
| `port` | integer | Local port, 1–65535. Use this when you are not supplying `url`. |
| `url` | string | HTTP or HTTPS local service URL. Provider and collaboration restrictions still apply. |
| `provider` | string | `quick`, `tailscale`, `ngrok`, or `opentunnel`; defaults to `quick`. |
| `name` | string | Optional display name. |
| `collaboration` | boolean | Enable collaboration where supported; defaults to false in REST (true in the MCP `share` tool). |

A create request waits up to 30 seconds for a URL. The returned share may still be starting and `publicURL` may be absent; use `GET /v1/shares` to check progress rather than creating a duplicate.

## Share response

A `Share` contains `id`, `name`, `provider`, `kind`, `state`, `localURL`, optional `publicURL`, `collaboration`, `people`, `openComments`, and `comments`. Each person has a name, path, and `isHost` flag. State is one of `stopped`, `starting`, `running`, `stopping`, or `failed`.

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

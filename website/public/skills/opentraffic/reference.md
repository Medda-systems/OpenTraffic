# opentraffic command reference

Every command takes `--json`. Exit status: `0` worked, `1` failed or refused, `2` wrong usage, `3` OpenTraffic not reachable or not set up. Shares are named by name (case-insensitive) or id.

## Shares

| Command | Does |
| --- | --- |
| `opentraffic list` (or just `opentraffic`) | Every share: state, way of sharing, public URL, people, open comments. |
| `opentraffic status <share>` | One share in detail, including `health` for each hop and `lastError`. |
| `opentraffic share <port\|host:port\|url> [options]` | Share a local server and wait until it's live. |
| `opentraffic start <share>` / `stop <share>` / `stop --all` / `restart <share>` | Start, stop, restart. |
| `opentraffic remove <share> --yes` | Remove a share with its settings and comments. |
| `opentraffic rename <share> <new name>` | Rename. |
| `opentraffic set <share> [options]` | `--url PORT\|URL` (stop it first), `--collab on\|off`, `--errors on\|off`, `--autostart on\|off`, `--project NAME`, `--no-project`, `--host-header on\|off`, `--stop-after never\|15m\|1h\|4h`. |
| `opentraffic protect <share> password [--user NAME]` | Password protection (ngrok shares); prints the password. |
| `opentraffic protect <share> google\|github [email ...]` | Sign-in (ngrok shares), optionally limited to these emails. |
| `opentraffic protect <share> email <email ...>` | Email codes (custom domains, Cloudflare Access). |
| `opentraffic protect <share> off` | Anyone with the link. |
| `opentraffic password <share> [--new]` | Show, or replace, the password. |

`share` options:

| Option | Meaning |
| --- | --- |
| `--via quick` | Temporary trycloudflare.com URL, new each start (default). |
| `--via opentunnel` | Lasting opentunnel.xyz address, end-to-end encrypted. |
| `--via tailscale [--funnel]` | Tailnet only; `--funnel` makes it public. |
| `--via ngrok [--hostname DOMAIN] [--password [--user NAME]]` | The user's ngrok domain or a reserved one. |
| `--via domain --hostname HOST [--replace-dns]` | A hostname in the user's Cloudflare account (`opentraffic domains` lists them). |
| `--name NAME` | Display name. |
| `--collab` | Live collaboration (cursors, comments, follow mode). |
| `--save` | Save without starting. |
| `--copy` | Copy the URL to the clipboard. |

## Links

| Command | Does |
| --- | --- |
| `opentraffic url <share> [path]` | Print the public URL. |
| `opentraffic copy <share> [path]` | Copy it. |
| `opentraffic open <share> [path]` | Open it in the browser. |
| `opentraffic qr <share> [path]` | QR code in the terminal. |

## Feedback

| Command | Does |
| --- | --- |
| `opentraffic comments <share> [--resolved\|--all]` | Comments with element, path, browser, picture, replies. |
| `opentraffic reply <share> <comment> <text>` | Reply (1–1000 characters). |
| `opentraffic resolve <share> <comment> [--reopen]` | Resolve or reopen. |
| `opentraffic delete-comment <share> <comment> --yes` | Delete. |
| `opentraffic screenshot <share> <comment> [-o FILE]` | Save the picture of the commented element (WebP, PNG, or JPEG). |
| `opentraffic errors <share>` | Browser errors visitors hit. |
| `opentraffic logs <share> [-n LINES] [-f]` | The share's log. |
| `opentraffic watch [share]` | Stream events: `share.started`, `share.stopped`, `session.joined`, `session.left`, `comment.created`, `comment.updated`, `comment.deleted`, `error.reported`. |

## This Mac and the app

| Command | Does |
| --- | --- |
| `opentraffic services` | Web servers running on this Mac, with uptime and the share publishing each. |
| `opentraffic projects` / `project start\|stop <name>` | Shares grouped to start and stop together. |
| `opentraffic domains` | Domains in the connected Cloudflare account. |
| `opentraffic doctor` | Whether OpenTraffic, its API, and each way of sharing are ready. |
| `opentraffic setup` | Turn on the local API (the user confirms in OpenTraffic). |
| `opentraffic install <cloudflared\|opentunnel\|ngrok>` | Install a tool to share with, from its maker's official release. |
| `opentraffic show [share]` | Open OpenTraffic's window. |
| `opentraffic help [command]` | Help. |

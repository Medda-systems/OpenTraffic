## Install and set up

The `opentraffic` command comes with the app. The [installer](/docs/installation) links it into your PATH, and OpenTraffic itself keeps it linked whenever it runs from Applications, whichever way you installed it, in the first of `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin` that can take it. The link points into the app, so updates update the command too. An `opentraffic` that isn't OpenTraffic's is never replaced, and removing OpenTraffic with Homebrew removes the link. **Settings → General → Install the opentraffic command** turns it off (and removes the link).

Then run, once:

```sh
opentraffic setup
```

This turns on OpenTraffic's local API, which the command uses; OpenTraffic asks you to confirm. Check everything with `opentraffic doctor`.

The command talks to OpenTraffic over its local API. If OpenTraffic isn't running, the command starts it in the background: in the menu bar, without opening its window or taking focus. Shares still run in the app, so the menu bar and the app's windows always show what the command did, and the other way around.

## Everyday use

```sh
opentraffic services                          # what's running on this Mac, and for how long
opentraffic share 5173 --collab               # a temporary public URL with live collaboration
opentraffic share 5173 --via opentunnel       # a lasting OpenTunnel address
opentraffic share 3000 --via domain --hostname app.example.com
opentraffic                                   # your shares (same as `opentraffic list`)
opentraffic status Orbit                      # URL, connection path, who's there, protection
opentraffic comments Orbit                    # what visitors pinned to the page
opentraffic reply Orbit 015ec043 "Fixed in the header"
opentraffic resolve Orbit 015ec043
opentraffic stop --all
```

`share` and `start` wait until the share is live and print its public URL. Sharing an address that already has a share starts that share instead of making another.

## Commands

### Shares

| Command | Does |
| --- | --- |
| `list` (`ls`) | Your shares, their state, public URL, people, and open comments. The default command. |
| `status <share>` | One share in detail: public and local URL, way of sharing, who can open it, collaboration and who's there, project, schedule, health of each hop, last error. |
| `share <port\|host:port\|url> [options]` | Share a local server. See below. |
| `start <share>` / `stop <share>` / `stop --all` / `restart <share>` | Start, stop, restart. |
| `remove <share> [--yes]` (`rm`) | Remove a share with its settings and comments. Asks first on a terminal; scripts pass `--yes`. |
| `rename <share> <new name>` | Rename. |
| `set <share> [options]` | `--url PORT\|URL` (stop it first), `--collab on\|off`, `--errors on\|off`, `--autostart on\|off`, `--project NAME` / `--no-project`, `--host-header on\|off`, `--stop-after never\|15m\|1h\|4h`. |
| `protect <share> password [--user NAME]` | Protect an ngrok share with a generated password; prints it. |
| `protect <share> google\|github [email …]` | Sign in with Google or GitHub (ngrok), optionally only for these emails. |
| `protect <share> email <email …>` | One-time email codes for a custom domain (Cloudflare Access). |
| `protect <share> off` | Anyone with the link. |
| `password <share> [--new]` | Show the username and password, or make a new password. |

`share` options:

| Option | Meaning |
| --- | --- |
| `--via quick` | A temporary trycloudflare.com URL, new each start. The default. |
| `--via opentunnel` | A lasting opentunnel.xyz address, encrypted end to end. |
| `--via tailscale [--funnel]` | Your tailnet only, or public on the internet with `--funnel`. |
| `--via ngrok [--hostname DOMAIN] [--password [--user NAME]]` | Your ngrok domain, or a reserved one; optionally password protected. |
| `--via domain --hostname HOST [--replace-dns]` | A hostname in your Cloudflare account (`opentraffic domains` lists them). `--replace-dns` takes over a hostname that already has a DNS record, as in the New Tunnel sheet. |
| `--name NAME` | What to call it. |
| `--collab` | Live collaboration (temporary URLs and OpenTunnel). |
| `--save` | Save without starting. |
| `--copy` | Copy the public URL to the clipboard. |

### Links

| Command | Does |
| --- | --- |
| `url <share> [path]` | Print the public URL. |
| `copy <share> [path]` | Copy it to the clipboard. |
| `open <share> [path]` | Open it in your browser. |
| `qr <share> [path]` | Show a QR code in the terminal, to open it on a phone. |

### Feedback

| Command | Does |
| --- | --- |
| `comments <share> [--resolved \| --all]` | Comments with their element, browser, picture, and replies. |
| `reply <share> <comment> <text>` | Reply. |
| `resolve <share> <comment> [--reopen]` | Resolve, or reopen. |
| `delete-comment <share> <comment> [--yes]` | Delete. |
| `screenshot <share> <comment> [-o FILE]` | Save the picture of what the comment points at. |
| `errors <share>` | Browser errors visitors ran into. |
| `logs <share> [-n LINES] [-f]` | The share's log; `-f` keeps following it. |
| `watch [share]` | Follow events as they happen: shares starting and stopping, people joining, comments, errors. |

### This Mac and OpenTraffic

| Command | Does |
| --- | --- |
| `services` | Web servers running on this Mac, their page title, process, how long they've been up, and which share publishes them. |
| `projects` / `project start\|stop <name>` | Projects: shares that start and stop together. |
| `domains` | Domains in your Cloudflare account. |
| `doctor` | Checks OpenTraffic, its API, and whether each way of sharing is ready (and why not). |
| `setup` | Turns on the local API. |
| `show [share]` | Opens OpenTraffic's window. |
| `help [command]`, `version` | Help and version. |

Shares are named by name (case-insensitive) or id; quote names with spaces.

## Scripts and automation

Every command takes `--json` and then prints the API's JSON. Exit status is `0` when it worked, `1` when OpenTraffic refused or something failed (the message says why), `2` for a wrong command line, and `3` when OpenTraffic isn't reachable or set up.

```sh
url=$(opentraffic share 5173 --json | jq -r .publicURL)
opentraffic watch --json | while read -r event; do …; done
```

Anything that puts something on the internet asks for confirmation in OpenTraffic first, unless you turn on **Settings → Integrations → Apps can share without asking**. Turn that on for unattended use. Sharing an address on another device always asks.

The command reads `OPENTRAFFIC_API_PORT` and `OPENTRAFFIC_API_TOKEN_FILE` if you've moved the API; otherwise it uses OpenTraffic's settings.

## Links (`opentraffic://`)

Shortcuts, Raycast, and other apps can also use links. They don't print anything back; use the command for that.

| Link | Action |
| --- | --- |
| `opentraffic://share?port=3000&via=tailscale` | Share a local port |
| `opentraffic://share?port=5173&collab=1&name=Orbit` | Share with collaboration |
| `opentraffic://start?name=Orbit` / `stop?name=Orbit` / `stop?all` | Start or stop |
| `opentraffic://copy?name=Orbit` | Copy the public URL |
| `opentraffic://show` | Open the app window |
| `opentraffic://project?name=Demo&action=start` | Start a project |
| `opentraffic://enable-api` | Turn on the local API (always asks) |

Percent-encode values with spaces or special characters. Links that share or start something ask for confirmation unless **Allow automation without confirmation** is on in General settings; any app or web page can open a link, so turn that on only if it fits how you work.

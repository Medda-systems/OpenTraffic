## Install and set up

The `opentraffic` command comes with the app. The [installer](/docs/installation) links it into your PATH, and OpenTraffic itself keeps it linked whenever it runs from Applications, whichever way you installed it, in the first of `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin` that can take it. The link points into the app, so updates update the command too. An `opentraffic` that isn't OpenTraffic's is never replaced, and removing OpenTraffic with Homebrew removes the link. **Settings → General → Install the opentraffic command** turns it off (and removes the link).

There's nothing to set up: the command is part of OpenTraffic. It talks to the app over a private connection that only OpenTraffic's own signed tools can use, so it needs no token, doesn't depend on **Settings → Integrations**, and never asks you to confirm anything, including sharing. Check everything with `opentraffic doctor`.

If OpenTraffic isn't running, the command starts it in the background: in the menu bar, without opening its window or taking focus. Shares still run in the app, so the menu bar and the app's windows always show what the command did, and the other way around.

## Everyday use

```sh
opentraffic services                          # what's running on this Mac, and for how long
opentraffic share 5173 --collab               # a temporary public URL with live collaboration
opentraffic share 5173 --via opentunnel       # a lasting OpenTunnel address
opentraffic share dist/mac-arm64/Orbit.app    # an Electron app you built (see Electron apps)
opentraffic share Orbit --via opentunnel      # a Mac app you're building, by name or .app path
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
| `share <app name\|App.app> [--via quick\|opentunnel] [--empty-data]` | Share a Mac app you're building (SwiftUI, AppKit, Catalyst), by its name as `services` lists it or its .app path: an isolated copy runs hidden on this Mac and viewers use its window in the browser, with live collaboration. `--empty-data` starts the copy without the app's data. Needs Accessibility and Screen Recording for OpenTraffic. See [Mac apps](/docs/mac-apps). |
| `start <share>` / `stop <share>` / `stop --all` / `restart <share>` | Start, stop, restart. |
| `restart <share> --app` / `--reset-data` | Mac app shares: start just the app again from its latest build on the same address (after rebuilding it to show a fix), or start it over from the data it started with. |
| `remove <share> [--yes]` (`rm`) | Remove a share with its settings and comments. Asks first on a terminal; scripts pass `--yes`. |
| `rename <share> <new name>` | Rename. |
| `set <share> [options]` | `--url PORT\|URL` (stop it first), `--collab on\|off`, `--errors on\|off`, `--branch on\|off`, `--autostart on\|off`, `--project NAME` / `--no-project`, `--host-header on\|off`, `--stop-after never\|15m\|1h\|4h`; for a Mac app, `--control everyone\|watch-only\|ask`, `--appearance viewer\|mac\|light\|dark`, `--window-size fit\|app`. |
| `protect <share> password [--user NAME]` | Protect a share with a generated password; prints it. Temporary and OpenTunnel shares get OpenTraffic's sign-in page (any username works there). |
| `protect <share> google\|github [email …]` | Sign in with Google or GitHub (ngrok), optionally only for these emails. |
| `protect <share> email <email …>` | One-time email codes for a custom domain (Cloudflare Access). |
| `protect <share> off` | Anyone with the link. |
| `password <share> [--new]` | Show the password (with the username, and for temporary and OpenTunnel shares the link with the password built in), or make a new password. |

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
| `--branch` | Live collaboration, and [work on a branch](/docs/collaboration#work-on-a-branch) while it runs. |
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
| `comments <share> [--resolved \| --all]` | Comments with their element, browser, picture, and replies, plus suggested edits (`✎`), where the element comes from (`⌖` component, source file, selector), and an area's size. |
| `reply <share> <comment> <text>` | Reply. |
| `resolve <share> <comment> [--reopen]` | Resolve, or reopen. The commenter is told it's fixed. |
| `claim <share> <comment> [progress]` | Say you're working on it, so other agents leave it alone and the session sees it; again to update the progress and keep the claim (it lapses after 15 minutes). |
| `release <share> <comment>` | Stop working on a comment you claimed, without resolving it. |
| `delete-comment <share> <comment> [--yes]` | Delete. |
| `screenshot <share> <comment> [--after] [-o FILE\|FOLDER/]` | Save the picture of what the comment points at; `--after`, the picture of it once fixed. A folder (ending in `/`) is made if need be, and the picture gets its usual name in it. |
| `errors <share>` | Browser errors visitors ran into. |
| `logs <share> [-n LINES] [-f]` | The share's log; `-f` keeps following it. |
| `watch [share]` | Follow events as they happen: shares starting and stopping, people joining, comments, errors. |

### This Mac and OpenTraffic

| Command | Does |
| --- | --- |
| `services` | Web servers running on this Mac, their page title, process, how long they've been up, and which share publishes them; then the Mac apps you're building (running debug builds and recent builds), with their project folder. |
| `projects` / `project start\|stop <name>` | Projects: shares that start and stop together. |
| `domains` | Domains in your Cloudflare account. |
| `doctor` | Checks OpenTraffic, its API, and whether each way of sharing is ready (and why not). |
| `setup` | Turns on the local API. |
| `install <cloudflared\|opentunnel\|ngrok\|tailscale>` | Installs a tool to share with, from its maker's official release, checked before it's installed (see [Installation](/docs/installation#tools-for-sharing)). Tailscale asks for your Mac's password. Does nothing if it's already there. |
| `show [share]` | Opens OpenTraffic's window. |
| `permissions` | Opens the window that walks you through the permissions sharing Mac apps needs (Accessibility and Screen Recording). |
| `help [command]`, `version` | Help and version. |

Shares are named by name (case-insensitive) or id; quote names with spaces.

## Scripts and automation

Every command takes `--json` and then prints the API's JSON. Exit status is `0` when it worked, `1` when OpenTraffic refused or something failed (the message says why), `2` for a wrong command line, and `3` when OpenTraffic isn't reachable or set up.

```sh
url=$(opentraffic share 5173 --json | jq -r .publicURL)
opentraffic watch --json | while read -r event; do …; done
```

The command never asks for confirmation, including when it shares something, so it works unattended, in scripts, and for coding agents. Only OpenTraffic's own signed tools can use its private connection; other apps go through the [local API](/docs/rest-api), which still asks.

With an OpenTraffic older than 1.0.8, the command falls back to the local API and reads `OPENTRAFFIC_API_PORT` and `OPENTRAFFIC_API_TOKEN_FILE` if you've moved it.

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
| `opentraffic://enable-api` | Turn on the local API for other apps (always asks) |

Percent-encode values with spaces or special characters. Links that share or start something ask for confirmation unless **Allow automation without confirmation** is on in General settings; any app or web page can open a link, so turn that on only if it fits how you work.

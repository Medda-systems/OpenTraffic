# Changelog

## Unreleased

- **One-click tools:** OpenTraffic installs what it shares through for you. The setup assistant, Settings, and New Tunnel show an **Install** button for Cloudflare's, OpenTunnel's, and ngrok's tools that says what it downloads (version, size, where from, who signed it), shows its progress, and checks the download against its maker's published checksum or Developer ID signature before installing it into OpenTraffic's own folder. No Homebrew, Terminal, or password needed. ngrok's account connects by pasting your authtoken, and Tailscale opens in the App Store.
- **`opentraffic install cloudflared`** (or `opentunnel`, `ngrok`) does the same from the command line, and `opentraffic doctor` says which to run.

## 1.0.6

- **Clearer when temporary URLs can't work:** if your network's DNS filter blocks Cloudflare's temporary tunnels (some ISPs' "safe browsing" filters do), OpenTraffic and `opentraffic doctor` say so, instead of "cloudflared exited with status 1". Other cloudflared failures now say what went wrong too.
- **Host header fix for Tailscale shares:** Vite, Next.js, and other dev servers that reject your tailnet name now work with **Fix Host Header**, like the other providers.
- **Refused up front:** sharing with Tailscale Funnel when it isn't allowed, or on a hostname that already has a DNS record, is refused before OpenTraffic asks you anything, and nothing is left behind. From the command line, add `--replace-dns` to replace the record.
- **ngrok request inspector:** response bodies are shown decoded (no more chunk sizes around JSON, and gzip is unpacked), new requests no longer overlap in the list, and the inspector fits narrower windows.
- **Health checks:** a new custom-domain hostname that this Mac looked up too early no longer shows as failing while everyone else can open it.
- `opentraffic stop` waits until the share has stopped, so the next command can change it right away. Browser errors list each page once, the Logs tab names the right connector, the reply field is ready to type in, and Settings no longer suggests a token can turn on email sign-in when Cloudflare refuses it.

## 1.0.5

- **Signed by Medda Systems and notarized by Apple:** OpenTraffic now opens like any other app, from the disk image, Homebrew, or the installer, with no trip to Privacy & Security. The first update to this version may ask once for access to OpenTraffic's saved Keychain items, because the app's signature changes.
- **`opentraffic watch` stops when nothing reads it anymore**, so `opentraffic watch | head -1` and similar pipelines end instead of running on.
- **Agent skill:** `curl -fsSL https://opentraffic.dev/skill | sh` teaches Claude Code, Codex, opencode, and other agents to share your dev server and act on feedback. See https://opentraffic.dev/docs/agent-skill.

## 1.0.4

- **A complete `opentraffic` command:** everything the app's windows do, from a terminal. List and inspect shares (with each hop's health and who's there), share through any provider including custom domains (with DNS replacement), Tailscale Funnel, and password-protected ngrok, change settings, protect, rename, restart, and remove shares, read and answer feedback, follow logs and live events, see the web servers running on this Mac with their uptime, run projects, and show QR codes. Every command takes `--json` and returns meaningful exit codes. It comes with the app: the installer links it into your PATH and OpenTraffic keeps it linked whenever it runs from Applications, however you installed it (Settings → General turns that off). `opentraffic setup` turns on the local API it uses, and the command starts OpenTraffic in the background when needed, without opening a window.
- **Local API:** new endpoints for status, local services, projects, Cloudflare domains, share details, editing, restarting, removing, protection, passwords, and deleting comments. Shares for a provider that isn't set up are refused instead of being created in a failed state.

## 1.0.3

- **OpenTunnel branding:** Anomaly’s logo now appears throughout the app, including both New Tunnel menus, Settings, the sidebar, and connection details.
- **Custom-domain DNS replacement:** explicitly choose to replace an existing hostname’s DNS route when creating a Cloudflare tunnel. CNAMEs are updated in place; A/AAAA records are replaced with the new tunnel’s CNAME. Replacement is refused when unrelated record types such as TXT or MX are present.
- **Clearer labels:** OpenTunnel shares show “anyone with the link”, and coding-agent replies are labeled “Agent” in the Feedback view.
- **Documentation:** installation, providers, collaboration, CLI, REST API, MCP, and troubleshooting guides are now available at https://opentraffic.dev/docs.

## 1.0.2

- **One-line install:** `curl -fsSL https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/install.sh | sh` downloads the latest release, checks its checksum and signature, and puts OpenTraffic in Applications.
- **Homebrew:** current Homebrew asks you to trust casks from other taps first; the install instructions now include `brew trust --cask medda-systems/tap/opentraffic`.
- Builds with Swift 6.3, and every release is now built, signed, and published automatically.

## 1.0.1

- **Automatic updates.** OpenTraffic checks for new versions once a day and installs them, verified with Medda Systems' signing key. **Check for Updates…** is in the app menu, and Settings → General has the options.
- **Homebrew:** `brew tap medda-systems/tap`, `brew trust --cask medda-systems/tap/opentraffic`, then `brew install --cask opentraffic`.
- Stopping a share closes every visitor connection, including ones the tunnel kept open.
- Webhook signing secrets are kept in the Keychain.
- The `opentraffic` command checks its arguments and accepts `host:port` without `http://`.

## 1.0.0

First public release.

- Share local web servers through Cloudflare Quick Tunnels, your own Cloudflare domains, Tailscale (tailnet or Funnel), ngrok, and OpenTunnel (a lasting address, encrypted end to end), from the menu bar.
- **Ready to Share** lists the web servers running on this Mac, keeps their uptime, and opens one in the browser with a click.
- Health checks follow each share along its whole path (local server → this Mac → provider → public URL) and offer fixes such as the Host header fix.
- Protected shares: ngrok passwords or Google/GitHub sign-in, and Cloudflare Access email codes for custom domains.
- Live collaboration on Quick Tunnel and OpenTunnel shares:
  - presence, cursors, and following the host
  - comments pinned to elements, with screenshots and browser errors
  - pointing
  - a localhost bridge for apps made of several local services
- A local API, MCP server, and signed webhooks, so coding agents and your own tools can share servers and act on feedback.
- The `opentraffic` command and `opentraffic://` links for scripts, Shortcuts, Raycast, and Alfred.

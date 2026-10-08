# Changelog

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

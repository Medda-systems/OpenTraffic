## General preferences

On first launch (with no saved tunnels) a setup assistant checks for `cloudflared`, optionally connects a Cloudflare account, and sets preferences. It can be rerun from Help → Setup Assistant or General Settings. General Settings cover launch at login, Dock visibility (always, or only while the window is open), copying the public URL automatically, and notifications when a URL is ready or a tunnel needs attention. Notifications require running the bundled app.

## Provider settings

Each provider has its own settings for executable detection, credentials or connection status. You can override an executable path if the provider CLI is outside the usual locations. See the individual [provider guides](/docs/providers).

## Integrations

Settings → Integrations controls the local API, publication approvals, API token regeneration, and webhooks. Keep the generated client configuration from this screen as the source of truth for your installation path and port.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New Tunnel |
| ⇧⌘I | Import from Cloudflare |
| ⌘⏎ | Start or stop the selected tunnel |
| ⇧⌘C | Copy the selected public URL |
| ⌘O | Open the public URL in the browser |
| ⌘R | Recheck health |
| ⌘1 / ⌘2 | Overview / Logs |
| Delete | Remove the selected tunnel (sidebar, with confirmation) |
| ⇧⌘T | Show the OpenTraffic window |

| Shortcut | Action |
| --- | --- |
| ⌘3 | Requests for ngrok |
| ⌘4 | Feedback |
| ⇧⌘P | Protection |
| ⌃⌥⌘S | Share newest service (opt-in global shortcut) |
| ⌃⌥⌘C | Copy latest URL (opt-in global shortcut) |

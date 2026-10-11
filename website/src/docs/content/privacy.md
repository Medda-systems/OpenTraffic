## Network activity and storage

OpenTraffic has no analytics, telemetry, or account of its own. It only connects to:

- **Your own servers:** the local servers you share. It checks the ones listening on this Mac to show page titles and favicons, and it skips well-known database ports.
- **Cloudflare:**
  - `api.cloudflare.com`, only when you connect a Cloudflare account.
  - `cloudflare-dns.com` (DNS over HTTPS), to see whether a new public hostname resolves yet.
  - Your shares' public URLs, for health checks.
- **GitHub:** once a day, to check `github.com/Medda-systems/OpenTraffic-releases` for updates (you can turn this off in Settings → General).
- **The connectors it runs:** `cloudflared`, `tailscale`, `ngrok`, and `opentunnel` each talk to their own service. OpenTunnel keeps its own files in `~/.config/opentunnel`, `~/.local/share/opentunnel`, and `~/.local/state/opentunnel` (OpenTraffic's are the `opentraffic` profile).

Where it keeps things:

- **Settings:** in the app's preferences (`se.medda.opentraffic`).
- **Saved shares, comments, and screenshots:** in `~/Library/Application Support/OpenTraffic/`. Site previews are cached there too, up to 50 MB.
- **API token:** the local API's token is in `~/Library/Application Support/OpenTraffic/api-token`, readable only by you.
- **Keychain:** Cloudflare API tokens are under the service `com.tunnelbar.app`, ngrok share passwords under `com.tunnelbar.share-password` (names from when the app was called TunnelBar), and webhook signing secrets under `se.medda.opentraffic.webhook-secret`.

## Uninstall

1. Quit OpenTraffic and delete it from Applications.
2. Delete `~/Library/Application Support/OpenTraffic` and `~/Library/Preferences/se.medda.opentraffic.plist`.
3. Remove the Keychain items above with Keychain Access.
4. Delete the `opentraffic` command's link from `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin` (or first turn off **Settings → General → Install the opentraffic command**, which removes it). `brew uninstall --cask opentraffic` removes it for you.

## Site previews

The detail header previews the site's local HTTP(S) origin using an isolated `WKWebView` with a nonpersistent website data store. OpenTraffic does not reuse browser cookies or history, submit forms, click controls, or authenticate. Top-level navigation is limited to the origin host, authentication challenges are cancelled, capture concurrency is one, and loading is bounded by a timeout. A failed refresh keeps the last cached preview.

Snapshots use a fixed 1440×900 master viewport and proportional Retina small, medium, and large derivatives with aspect-fill cropping. The local Application Support preview cache is bounded to 50 MB. Managed previews are keyed by tunnel UUID and removed with the saved tunnel; discovered previews use the stable executable-and-origin preference identity.

## Collaboration data

Presence carries chosen names, paths, and cursor positions. Explicit comments carry text, selected-element context and screenshots, browser information, and optional errors. Text fields are blanked in element screenshots, but other visible page content can remain. Feedback and screenshots are stored locally with the share.

## Data sent to integrations

When you enable webhooks or ask an agent to read feedback, that selected destination receives the relevant data. Its own storage and retention rules then apply. OpenTraffic does not run an external collaboration account service.

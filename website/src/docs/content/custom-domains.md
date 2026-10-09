## Connect your account

Open Settings → Cloudflare (or pick Your Domain / Existing Tunnel in New Tunnel, which shows the same form inline) and enter:

1. The Cloudflare account ID.
2. A scoped API token. OpenTraffic stores it in the macOS Keychain, never in preferences or the tunnel JSON file.

Create a scoped API token with exactly these permission rows:

- Account → Cloudflare Tunnel → Edit
- Zone → Zone → Read
- Zone → DNS → Edit

Scope the token to the selected account and only the zones OpenTraffic should manage. Tunnel Edit covers listing, importing, connector-token retrieval, and creating the supported remotely managed tunnels.

The Existing Tunnel view reads the existing remote ingress configuration and leaves it unchanged. Locally configured tunnels (`config_src: local`) are shown as unsupported because starting them correctly depends on their existing YAML and credentials outside OpenTraffic.

When OpenTraffic rewrites a tunnel's route (Finish Setup, a changed local URL, or the Host header fix), it keeps every other rule exactly as it was, including their `originRequest` and `path` settings and config-level settings such as `warp-routing`, and leaves path-specific rules for the same hostname alone.

The Your Domain view performs three explicit Cloudflare operations: create the remote tunnel, install a hostname/local-service ingress rule with a final `http_status:404` catch-all, and create a proxied CNAME. The hostname is entered as a subdomain plus a zone picker, so it always belongs to the chosen zone (an empty subdomain serves the zone apex). The form checks the local service and the DNS record while typing. Local URLs with a path are rejected up front because Cloudflare ingress rules cannot proxy to a path; a trailing slash is normalized away. In version 1.0.2, creation shows per-step progress, checks for a conflicting DNS record before creating the tunnel (creation is blocked while one exists), and offers **Start Now** on success. A DNS record that already points at the same tunnel is accepted; a record that points anywhere else is reported as a conflict and OpenTraffic never overwrites it. If configuration or DNS setup fails after tunnel creation, the app retains the new tunnel ID as an imported entry and reports it for recovery. The detail view's **Finish Setup** action (shown in a Setup incomplete banner and on a failed DNS check) re-applies the saved hostname's ingress rule and DNS record, keeping ingress rules for other hostnames, so a half-created tunnel can be completed without creating a duplicate.

When the Your Domain form opens, it captures the currently selected managed or discovered HTTP(S) origin once (falling back to the newest detected server) and offers all saved/discovered origins in a picker. With neither, the URL starts blank; OpenTraffic never silently substitutes `localhost:3000`. The first Create click performs a bounded HEAD reachability check. If the origin does not answer, Cloudflare creation remains blocked until the user explicitly chooses **Create Anyway**.

Account refresh also reads each saved remote tunnel's current configuration. OpenTraffic matches only the ingress with the saved hostname and synchronizes its displayed local service/hostname metadata, so dashboard-side repairs appear locally without rewriting or flattening any remote configuration.

While an app-owned connector is running, OpenTraffic also resolves its effective origin directly from that process's loopback `/config`. It verifies the connector PID and start time, the runtime generation, and ownership of the exact listening metrics port before and after the read. Named tunnels require one unambiguous service for the exact saved hostname; Quick Tunnels require one unambiguous applicable service. Ambiguous configurations never overwrite saved intent. A verified live origin is persisted separately as last-known metadata, so stopped or locked-account views remain accurate and clearly label the source/freshness. Rows, details, previews, and the Create origin picker all use this same resolved origin.

## DNS replacement — unreleased

The next app release adds **Replace it with this tunnel’s record** when a hostname is already in use. This is not available in 1.0.2.

When explicitly selected, an existing CNAME is repointed to the new tunnel. A/AAAA records are deleted and replaced with the tunnel’s proxied CNAME. If TXT, MX, or other unsupported record types are present, replacement is refused and those records are left unchanged. Traffic at the hostname switches away from its previous destination.

The A/AAAA replacement is a sequence of API requests, not an atomic transaction. If a request fails, inspect the DNS records in Cloudflare before retrying.

## Stop versus remove

Stopping ends this Mac’s connector. Removing a share deletes its local saved entry. Neither action deletes the remote Cloudflare tunnel, DNS route, or connectors on other machines. If another connector is running elsewhere, Cloudflare can still report the tunnel as healthy.

## More help

For authentication on a hostname, see [Protected shares](/docs/protection). For failed health checks or partial setup, see [Troubleshooting](/docs/troubleshooting).

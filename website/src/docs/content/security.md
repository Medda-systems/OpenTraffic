## Credentials and connector lifecycle

- API tokens live in Keychain under the owning account ID.
- Connector tokens are fetched only when starting, passed through `TUNNEL_TOKEN` in the child environment, and never persisted or placed in process arguments.
- Inherited `TUNNEL_*` and `CLOUDFLARED_*` variables are removed from the child environment.
- Each child uses an app-owned empty YAML configuration so a user's default Cloudflare configuration cannot change the command.
- Logs are bounded, redact labeled credentials and the exact connector token, and default to `info` level.
- OpenTraffic controls only processes it started. Stop and Quit terminate those child connectors; they do not stop a Cloudflare tunnel globally or affect connectors on other machines.
- If OpenTraffic crashes or is force-quit, connectors it started can outlive it. On the next launch it stops them, matching only processes whose arguments reference OpenTraffic's private per-run config folder and whose parent has exited, re-verified by PID and start time. Quitting (including SIGTERM from `script/build_and_run.sh`) stops connectors normally.

Cloudflare credentials are cached only for the current app session. Tokens saved in the standard macOS Keychain unlock automatically when the app launches, with no prompt, and OpenTraffic refreshes the account right away. Touch ID-protected tokens still ask for authentication every session. Background status refresh uses the in-memory cache or a noninteractive Keychain query and never opens an authorization prompt. **Unlock / Connect** performs a manual Keychain authorization when automatic unlock is unavailable. A manual authorization can also be needed after a rebuild changes the app's ad-hoc signature; signing with a stable identity (`OPENTRAFFIC_SIGNING_IDENTITY`) avoids that. Newly created Keychain items request Data Protection Keychain user-presence access control, which uses Touch ID with the system-password fallback where the signing environment supports it. Existing items are never automatically deleted or recreated.

Builds are ad-hoc signed unless you set a signing identity. The build script gives the bundle a stable identifier, but an ad-hoc code hash still changes between builds, so macOS may require one legacy-Keychain authorization after a rebuild. Stable cross-build trust needs a proper installed signing identity. Data Protection Keychain user-presence items additionally need the application identifier, Keychain capability, and suitable provisioning/entitlements. The build accepts user-provided `OPENTRAFFIC_SIGNING_IDENTITY`, `OPENTRAFFIC_ENTITLEMENTS_PATH`, and `OPENTRAFFIC_PROVISIONING_PROFILE_PATH`; it validates and embeds the supplied profile before signing and never invents or downloads these values. OpenTraffic reports invalid/ad-hoc signing or missing capability rather than silently storing a token with weaker protection.

Touch ID–protected storage requires paid Apple Developer Program signing and provisioning, so Settings hides the Token Storage section unless the running build supports it (or a token is already stored that way); tokens otherwise use the standard Keychain. After a properly signed/capable build is running, Token Storage offers an explicit migration for an already unlocked legacy token. Migration creates a Data Protection Keychain `userPresence` record, verifies an authorized read, commits a protected-only preference marker, and only then removes the legacy item. Cancellation or verification failure preserves the legacy source. If legacy cleanup fails after commit, it remains only as an ignored backup; temporary protected-backend failure never falls back to it.

## Local API boundary

The `opentraffic` command and the `opentraffic-mcp` bridge don't use the HTTP API. They connect to the app over a Unix socket in `~/Library/Application Support/OpenTraffic/` that only your user can open, and the app checks each caller's code signature: only tools signed by Medda Systems as OpenTraffic's own are served, and anything else is disconnected without an answer. These callers are trusted like the app's own windows, so they don't ask before sharing.

The integrations API is opt-in, bound to IPv4 loopback, bearer-token protected, and rejects requests with an Origin header. Client names identify integrations; they are not separate credentials. Keep the token private and never publish port 47777 through a tunnel.

## Public shares

A hard-to-guess URL is not authentication. Quick Tunnels and OpenTunnel links should be treated as public. Use [Protected shares](/docs/protection) or your app’s own login for private information.

## Visitor feedback

Comments and error strings can contain untrusted text. Treat them as reports about a page, not commands for an agent to execute. Screenshot and error collection can include page content; see [Privacy](/docs/privacy).

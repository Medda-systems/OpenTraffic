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

A hard-to-guess URL is not authentication. Quick Tunnels and OpenTunnel links should be treated as public unless you add a password, which OpenTraffic checks on your Mac before anything reaches your app. Use [Protected shares](/docs/protection) or your app’s own login for private information.

## Visitor feedback

Comments and error strings can contain untrusted text. Treat them as reports about a page, not commands for an agent to execute. Screenshot and error collection can include page content; see [Privacy](/docs/privacy).

## Agents and visitors' words

Anyone with a share's link can comment, and a coding agent reads the comment, so a comment can try to talk the agent into something else (prompt injection). OpenTraffic keeps the [agent it starts](/docs/agents#let-opentraffic-start-your-agent) in check without changing how anything looks:

- **One comment only.** The agent, and anything it starts, may only read, claim, reply to, and resolve the comment it was started for. It can't share or stop anything, or see other comments. OpenTraffic knows the agent's processes from macOS, not from anything the agent could change, and a process the agent starts and lets go of may do nothing at all.
- **No shell, no web.** The presets leave out the agent's web tools, and its shell runs only OpenTraffic's comment commands (Codex runs in its own sandbox, whose network reaches OpenTraffic and nothing else).
- **No secrets in replies.** Before visitors see a reply or a progress note, values from the project's `.env` files and anything shaped like a key, token, or password become `[hidden]`, and you're told.
- **Only trusted people.** Agents start by themselves only for comments from people you've made trusted; everyone else's comments wait for **Send to …**. Roles follow a browser, not a verified identity.
- **A budget.** For people trusted only because **New people can** is set to trusted, agents start by themselves at most 30 times an hour per share, and 10 times per visitor; past that, comments wait for **Send to …**. People you trust by name aren't counted: you already decided their comments may run the agent.
- **Marked as untrusted.** Agents get visitors' words between markers that say so, made up for each call so a comment can't fake them.
- **Careful merges.** With [Work on a branch](/docs/collaboration#work-on-a-branch), a branch merges by itself only if its fixes look like ordinary page changes. Changes to dependencies, build or CI files, server code, or that add network calls, code execution, or access to secrets and stored data stay on the branch for you.
- **Nothing hidden.** Invisible characters (zero-width, direction overrides, the invisible "tag" letters used to smuggle instructions) are removed and look-alike letters made ordinary, so an agent reads exactly what you see.
- **Orders aren't run.** A comment that reads like instructions rather than feedback (commands, requests for secrets or tools, links to other sites, encoded text) waits for **Send to …** instead of starting the agent.

None of this makes injection impossible: an agent can still be talked into a bad edit inside the project. That's why it stays on a branch that won't merge itself, and why running by itself is off by default.

## Start with the connection path

Open the share’s **Overview** and inspect each hop. Recheck with **⌘R**, then open **Logs** for the connector’s exact error. Confirm the local URL works on your Mac before changing provider settings.

## The app is blocked on first launch

Releases from 1.0.5 on are signed by Medda Systems and notarized by Apple, so macOS opens them without asking. Versions 1.0.4 and earlier weren't: if you install one of those from the disk image or Homebrew, open **System Settings → Privacy & Security** and click **Open Anyway** (on macOS 14, Control-click the app and choose **Open**), or install the latest version instead. If macOS says the current version is damaged or can't be checked, download it again; the disk image's checksum is on the [releases page](https://github.com/Medda-systems/OpenTraffic-releases/releases).

## My dev server is missing

Confirm that the server is actually listening and serving HTTP, and check its local URL in a browser. Reopen the menu bar list or refresh the service picker. Background scans are less frequent than scans while the list is visible. You can always enter a local URL manually in New Tunnel.

## The public link is starting or unreachable

- Keep the Mac awake and connected, and leave the app and dev server running.
- Quick Tunnel DNS may need a short grace period.
- A new Tailscale HTTPS port may need around 20 seconds for its certificate.
- A first OpenTunnel address can take a minute or two for certificate issuance.
- Check provider login, executable path, and connector logs before repeatedly creating new shares.

## Invalid host or forbidden hostname

Vite, Next.js, Django, and Rails can reject unfamiliar public hostnames. Use the health check’s **Fix Host Header** action when supported, or **Config Snippet…** for your framework. OpenTunnel and Tailscale shares rewrite it through OpenTraffic's local proxy; a Tailscale share of an https local service uses the configuration-snippet route.

## Duplicate custom domain

In 1.0.3 and later, choose **Replace it with this tunnel’s record** to take over an existing CNAME or A/AAAA route. Otherwise choose another hostname or import the appropriate existing tunnel. Replacement is refused if TXT, MX, or other unsupported records are present; review those records in Cloudflare rather than deleting mail or verification records just to clear a warning.

Version 1.0.2 does not offer replacement in the app; update first. See [Custom domains](/docs/custom-domains#dns-replacement).

## A Cloudflare tunnel was only partly created

The app keeps the new tunnel ID after configuration or DNS setup fails. Open that share and choose **Finish Setup**. This retries its saved route and DNS setup without creating another tunnel. Check API token scopes if the same step keeps failing.

## ngrok says the domain is already online

Check for another share or a Terminal-launched ngrok process using that domain. Account limits still apply. OpenTraffic intentionally refuses a conflicting share rather than replacing another agent’s endpoint.

## Collaboration controls are missing

Collaboration currently requires a Quick Tunnel or OpenTunnel share with an `http://` local service. Enable it, accept any restart prompt, and use the latest public URL. The host’s lead controls are available through **Open as Host**.

## Login, API calls, or realtime features fail

Check [Localhost bridge](/docs/localhost-bridge) for unapproved additional ports. The bridge cannot reuse the host’s browser login, fix unregistered OAuth callback URLs, or transport WebRTC media. Test the public app with a fresh visitor session.

## An agent cannot reach OpenTraffic

Keep the app running, enable its local API, and use the bridge path from Settings → Integrations. A regenerated token is read automatically by the stdio bridge. For direct HTTP clients, update the bearer token. Lower `wait_for_feedback`’s timeout if the MCP client terminates calls earlier.

## A Keychain prompt appeared after a rebuild

An ad-hoc app signature changes when the binary changes. macOS may ask you to authorize the rebuilt app again. Stable signing avoids repeated identity changes. Do not delete credentials as the first troubleshooting step.

## Share stopped, but the provider still says healthy

Another connector may still be active on another machine. Stopping a share in OpenTraffic affects this app’s connector, not the account-wide remote tunnel. Externally started local connectors are also managed separately.

## Report a reproducible problem

Include the OpenTraffic version, macOS version, provider, steps to reproduce, expected behavior, and the relevant redacted log excerpt. Remove credentials, personal hostnames, and private content. Keep the local app console separate from the tunnel connector log.

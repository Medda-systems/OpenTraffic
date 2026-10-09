## Provider comparison

| Provider | Address | Access | Collaboration | Setup |
| --- | --- | --- | --- | --- |
| Cloudflare Quick Tunnel | Temporary; normally changes on restart | Public | Yes, HTTP origin | cloudflared; no account |
| Cloudflare custom domain | Your own hostname | Public; optional Cloudflare Access | Not currently supported | Account, zone, API token, cloudflared |
| OpenTunnel | Lasting named address | Public; app must handle its own sign-in | Yes, HTTP origin | opentunnel; no account |
| Tailscale Serve | Mac’s tailnet name and HTTPS port | Tailnet only | Not currently supported | Tailscale signed in; HTTPS enabled |
| Tailscale Funnel | Mac’s tailnet name and allowed port | Public | Not currently supported | Funnel permission in tailnet |
| ngrok | Account or reserved domain | Public; optional password or sign-in | Not currently supported | ngrok and account authtoken |

## Decide by workflow

Choose **Quick Tunnel** for an occasional review, **OpenTunnel** when you want to reuse a link, **Tailscale** for access within an existing tailnet, **ngrok** for HTTP request inspection and protected demos, or a **custom domain** when the hostname belongs to your project.

## Provider boundaries

OpenTraffic manages the local connector and provider configuration needed for the shares you create. It does not replace a provider subscription, grant access to paid features, or guarantee provider availability. Temporary tunnels are for development and testing.

See the individual provider guides for prerequisites and cleanup behavior.

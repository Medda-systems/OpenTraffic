## Setup and sharing

**New Tunnel → Your Tailnet** (or **Share ▾ → Private on Your Tailnet** in the menu bar) shares a local server on this Mac's Tailscale name, `https://<mac>.<tailnet>.ts.net[:port]`. Each app gets its own HTTPS port; only the apps you pick are exposed. Private shares can be opened only by devices signed in to your tailnet. **Public on the internet (Funnel)** is available when Funnel is enabled for this device in the tailnet's access controls, and is limited to ports 443, 8443, and 10000.

Tailscale itself only proxies to `127.0.0.1`. When a server isn't reachable there — for example Vite/Node listening only on `::1`, or another machine on the LAN — OpenTraffic runs a small loopback TCP relay and points Tailscale at it; WebSockets and hot reload pass through unchanged.

Shares live in the Tailscale daemon, so OpenTraffic records exactly which port and target it applied (`tailscale-shares.json` in Application Support) and removes only those on Stop, Remove, and Quit, and on the next launch after a crash. It never runs `tailscale serve reset` and never changes a port that now points elsewhere. Shares created outside OpenTraffic are listed read-only in Settings → Tailscale, which also shows connection, HTTPS-certificate, and Funnel status with links to the admin console.

The first request on a new port can take around 20 seconds while Tailscale issues the HTTPS certificate; the health checks show this as in progress rather than failed.

## Next steps

See [Protected shares](/docs/protection), [Everyday sharing](/docs/sharing), and [Troubleshooting](/docs/troubleshooting).

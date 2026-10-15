## Setup and sharing

**New Tunnel → OpenTunnel** (or **Share ▾ → Lasting Address with OpenTunnel**) shares a local server through [OpenTunnel](https://opentunnel.xyz), Anomaly's open-source tunnel.

How addresses work:
- This Mac gets one lasting address, `<id>.opentunnel.xyz`, and each share is a name in front of it, such as `https://orbit.<id>.opentunnel.xyz`.
- A share keeps its URL every time it starts, so a link you've sent keeps working.
- The first share creates the address, which takes a minute or two while its certificate is issued.
- TLS ends on this Mac, so OpenTunnel's relay can't read the traffic. There's no account.

How OpenTraffic manages it:
- OpenTunnel runs as a background service. OpenTraffic uses its own `opentraffic` profile for it, so routes you add yourself with `opentunnel route add` are never touched.
- Stopping a share removes its route, and the service stops when no routes are left.
- Quitting, and the next launch after a crash, clean up the same way.
- OpenTraffic never deletes the tunnel, so the address stays yours.

Requirements and limits:
- Only `http://` local addresses can be shared.
- OpenTunnel passes the public hostname to your server as-is, so Vite and similar dev servers reject it. **Fix Host Header** puts OpenTraffic's local proxy in front to send the local host instead.
- Live collaboration works the same as on Quick Tunnels.
- Anyone with the link can open a share, and the address shows up in public certificate logs. Add a password under **Protection…** and OpenTraffic asks visitors for it before anything reaches your app (see [Protected shares](/docs/protection#passwords-on-quick-tunnels-and-opentunnel)).
- OpenTunnel is an early beta.

## Next steps

See [Protected shares](/docs/protection), [Everyday sharing](/docs/sharing), and [Troubleshooting](/docs/troubleshooting).

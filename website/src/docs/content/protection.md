## Configure access

**Protection…** (⇧⌘P, or the lock chip under the public URL) chooses who can open a share:

- **ngrok:** a password (username plus a generated password kept in the Keychain, never in the tunnels file; **New Password** locks out the old one), or sign-in with Google or GitHub through ngrok's managed apps, optionally limited to listed email addresses.
- **Custom domains:** sign-in with an emailed one-time code through a Cloudflare Access application for the hostname, limited to listed email addresses. This needs a Zero Trust organization and the API token permission *Account → Access: Apps and Policies → Edit*; Settings → Cloudflare shows whether the token can read Access. Turning protection off deletes the application; removing the tunnel from OpenTraffic leaves it in place.
- **Tailscale** private shares are already limited to your tailnet; **Quick Tunnels** and public Funnel shares can't be protected.

Health checks treat a sign-in wall as reachable rather than failed.

## OpenTunnel

OpenTunnel shares do not offer password protection in OpenTraffic. Anyone with the link can open them unless your app implements its own authentication. Hostnames may appear in public certificate logs.

## Collaboration is not authentication

A participant name, host controls, or a presence pill is not a login wall. Choose the provider’s access control or your app’s own authentication based on the information you are sharing.

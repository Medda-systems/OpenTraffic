## Configure access

**Protection…** (⇧⌘P, or the lock chip under the public URL) chooses who can open a share:

- **ngrok:** a password (username plus a generated password kept in the Keychain, never in the tunnels file; **New Password** locks out the old one), or sign-in with Google or GitHub through ngrok's managed apps, optionally limited to listed email addresses.
- **Custom domains:** sign-in with an emailed one-time code through a Cloudflare Access application for the hostname, limited to listed email addresses. This needs a Zero Trust organization and the API token permission *Account → Access: Apps and Policies → Edit*; Settings → Cloudflare shows whether the token can read Access. Turning protection off deletes the application; removing the tunnel from OpenTraffic leaves it in place.
- **Quick Tunnels and OpenTunnel:** a password, checked by OpenTraffic itself (see below).
- **Tailscale** private shares are already limited to your tailnet; public Funnel shares can't be protected.

Health checks treat a sign-in wall as reachable rather than failed.

## Passwords on Quick Tunnels and OpenTunnel

Neither provider can be told to ask for a password, but everything they carry reaches your Mac through OpenTraffic's own proxy first, so OpenTraffic asks for it there:

- Visitors see an OpenTraffic sign-in page with the share's name and enter the password once. On a share with live collaboration they can also give the name others see them by. Signing in lasts 30 days in that browser.
- **Copy Link with Password** (in the menu of the copy button next to the share's address, the share's ⋯ and right-click menus, and Live Collaboration) copies the share's link with a sign-in token in it. Whoever opens it skips the page; the token is removed from the address straight away. The password itself is never in the link.
- Scripts and tools send the password as HTTP basic auth, with any username: `curl -u x:PASSWORD https://…`.
- **New Password** signs everyone out and stops old links working, without restarting the share. Turning the password on or off doesn't restart it either, except a running Quick Tunnel that has nothing in front of it yet: that one restarts once, and so gets a new address.
- Five wrong passwords in a minute pause further tries from that visitor (on Quick Tunnels, which say who's visiting) or for the share (on OpenTunnel).
- The page, the collaboration overlay, the localhost bridge, hot reload, and every other request need the password. Your app never sees OpenTraffic's cookie or the password. The host link (**Open as Host**) works as before.

OpenTunnel hostnames may still appear in public certificate logs; with a password, finding the address is no longer enough to open it.

## Collaboration is not authentication

A participant name, host controls, or a presence pill is not a login wall. Choose the provider’s access control or your app’s own authentication based on the information you are sharing.

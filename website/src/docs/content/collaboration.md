## Start a session

Turn on **Live collaboration** for a temporary share (in New Tunnel, the share's detail view, or `opentraffic share 5173 --collab`) and everyone who opens the link sees each other: a presence pill with names, live cursors anchored to page elements, and — after **Open as Host** — a **Lead** switch that brings everyone to the page and scroll position you're on.

People can also pin **comments** to any element (the Comment button in the pill) and **point** at things for everyone (the Point button, or ⌥-click). Comments appear in the share's **Feedback** tab (⌘4), where you can resolve or delete them for everyone and copy them as Markdown or as a GitHub issue; they're kept between sessions. OpenTraffic can notify you when someone joins or comments, and shows your name from Settings → General → Live Collaboration to the people you share with.

OpenTraffic runs a small proxy on 127.0.0.1 between cloudflared and your dev server. It forwards everything unchanged, with two exceptions:
- HTML pages get two script tags, `/__opentraffic/bridge.js` and `/__opentraffic/collab.js`.
- OpenTraffic answers `/__opentraffic/*` itself.

Hot-reload WebSockets are relayed byte for byte. The hub lives in OpenTraffic, with no account or outside service.

What visitors share:
- Everyone sees each other's chosen names and cursors, and which page (path only, never the query string) they're on.
- Cursor and presence messages do not send page content or form-field values. Explicit comments and element screenshots carry the selected feedback described below.
- When someone pins a comment, it carries a short label of the element, the page title, a picture of the element (with text fields blanked), their browser and window size, and, if you turned on error collection, the browser errors they hit.

Live collaboration works with Quick Tunnel and OpenTunnel shares of `http://` addresses. Other providers and HTTPS local origins are not currently supported for collaboration.



## Multi-service apps

See [Localhost bridge](/docs/localhost-bridge) when your frontend calls another local API or WebSocket server.

## Feedback workflow

See [Comments & feedback](/docs/feedback) to resolve threads or connect an agent.

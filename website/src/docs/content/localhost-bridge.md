## Route additional services

Many apps call other local services directly — an API on `localhost:3001`, a realtime server on `ws://localhost:7880`. Through a tunnel those addresses would point at each visitor's own computer. With live collaboration on, OpenTraffic's **localhost bridge** sends such calls through the same share instead: the first time the app tries to reach another port, the share's Live Collaboration card asks **Allow localhost:7880?**, and from then on visitors' browsers reach it at `/__opentraffic/port/7880/` on the share. The proxy also keeps redirects and `localhost` cookies on the share, and adjusts a strict Content-Security-Policy only so OpenTraffic's own scripts load. Limits: sign-in providers only return to callback URLs the app registered (usually `localhost`), and WebRTC media can't go through a tunnel.

## Approve a port

1. Start your frontend and its required backend services on the host Mac.
2. Enable collaboration on a supported share and open it in a visitor browser.
3. When the app requests another localhost port, review **Allow localhost:PORT?** in the share’s Live Collaboration card.
4. Approve only the service the app actually needs, then retry the browser request.

Approving a port makes that local service reachable through the share. It does not grant the visitor your browser session or bypass the target app’s own authentication.

## Compatibility boundaries

The bridge handles supported browser HTTP and WebSocket calls; it does not turn an arbitrary desktop app into a collaborative web app (Electron apps you build can be shared: see [Electron apps](/docs/electron-apps)). It does not carry WebRTC media, copy host cookies from another browser, or register OAuth callback URLs for you. A sign-in provider must accept the callback URL configured by your app.

For a “private network” or blocked-host error, first inspect the failing URL in browser developer tools. If it still points at the visitor’s localhost, check collaboration and port approval. If it points at the public hostname and is rejected by the app, check the host header or app authentication.

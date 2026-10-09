## Create a temporary link

Click **Share** next to a detected server in the menu bar, or choose **New Tunnel… → Temporary URL**. The sheet scans this Mac for listening web services and preselects the newest one; detected services show their page title, process, port, HTTP status, and start time, followed by saved and discovered origins, and any URL can be typed instead. Connector processes (`cloudflared`) are never offered. **Start Sharing** saves and starts the tunnel; sharing a port that already has a saved Quick Tunnel reuses it instead of adding a duplicate. OpenTraffic captures the generated public URL and real connector logs. **Stop** sends graceful termination with a five-second drain period, retaining the saved definition. Starting it again normally creates a different public URL.

Quick Tunnels are intended for testing and development. They have Cloudflare's documented Quick Tunnel limitations and are not a production availability mechanism.

### Discovering Terminal-launched tunnels

OpenTraffic automatically scans at launch and about every five seconds for Quick Tunnels started outside the app by the same macOS user. Discovery uses the real `cloudflared` executable path, PID, process start time, and argument boundaries. It rejects named `run`, token, credential, and name-based connector forms. A candidate appears only after OpenTraffic confirms its process-specific loopback metrics endpoint returns a valid `*.trycloudflare.com` hostname.

Discovered tunnels appear in a separate **Running Elsewhere** section with their PID, origin when available, and public URL. OpenTraffic probes only loopback listener ports owned by that candidate process. It reads only the hostname from `/quicktunnel` and, when necessary, the HTTP(S) ingress service from `/config`; it never stores or displays the raw metrics configuration.

Managed and discovered rows expose the same context-menu actions (also on hover) for renaming, copying the current URL, opening the site, and viewing logs. Managed entries can be removed after confirmation. Discovered entries can be hidden without signaling their process and restored from General Settings. Discovered aliases persist for the same cloudflared executable and local origin across PID changes; **Use Current Hostname** removes an alias.

Row summaries use live process metrics when cloudflared exposes them: local port, process uptime, and total tunnel requests. Detail views additionally show origin-proxy errors, response-code counters, and QUIC transport bytes. QUIC byte counters include transport overhead and can be unavailable for HTTP/2 connectors. Missing metrics display as `—`; OpenTraffic never substitutes synthetic zeroes.

Another process's Terminal or pipe output is unavailable. When the command explicitly provides an absolute `--logfile` path that is a regular file owned by the same user, OpenTraffic shows only a bounded, redacted, read-only tail. It never consumes another process's stdout or stderr.

Stop, Remove, and Quit never affect discovered processes. **Manage in OpenTraffic** is an explicit conversion: after confirmation, OpenTraffic re-verifies the PID, start time, and live Quick Tunnel metadata, sends graceful termination without a force-kill, and starts a fresh app-owned Quick Tunnel for the same origin. The public URL changes.

The main management scene is a singleton. **Open OpenTraffic**, **View Logs**, and Window → **Show OpenTraffic** reveal and deminiaturize the existing window; a new instance is created only after the singleton has actually closed.

## Provider documentation

[Cloudflare Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) describes provider-side limitations.

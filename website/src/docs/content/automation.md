## Automate sharing

- **Keep-alive.** Tunnels whose connector exits unexpectedly restart after 2 s, 10 s, then 30 s, and OpenTraffic gives up after three restarts in ten minutes. ngrok account and plan errors aren't retried.
- **Auto-start.** *Start automatically when … is running* (Edit sheet) starts a tunnel as soon as its local server answers. After you stop it, it stays stopped until the server goes away and comes back.
- **Projects.** Give tunnels the same project name to start and stop them together from the sidebar, the menu bar, or links.
- **Global shortcuts** (opt-in): ⌃⌥⌘S shares the newest local server; ⌃⌥⌘C copies the latest tunnel's URL.
- **Links and the `opentraffic` command.** `opentraffic://share?port=3000&via=tailscale`, `start?name=`, `stop?name=` / `stop?all`, `copy?name=`, `show`, and `project?name=…&action=start|stop` control OpenTraffic from scripts, Raycast/Alfred, or Shortcuts' *Open URLs* action. Settings → General installs the bundled `opentraffic` command (`opentraffic share 3000 --via ngrok`, `opentraffic copy Docs`, `opentraffic stop --all`, …) as a symlink. Because any app or web page can open a `opentraffic://` link, links that share or start something ask for confirmation unless *Allow automation without confirmation* is on.

## Choose an integration

The [CLI](/docs/cli) sends commands to the macOS app. Use [REST](/docs/rest-api) when you need structured results, and [MCP](/docs/mcp) for coding agents. OpenTraffic must be running to host shares and serve the local API.

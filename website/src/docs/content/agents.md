## Enable the local API

Open **Settings → Integrations → Allow apps on this Mac to use OpenTraffic**. Keep OpenTraffic running. Use the exact setup shown there if your app is installed outside `/Applications` or you changed the API port.

The bridge reads your local API token automatically. Do not paste the token into a project or a public configuration file.

## Claude Code

Add the bundled server:

```sh
claude mcp add --scope user opentraffic --env OPENTRAFFIC_CLIENT="Claude Code" \
  -- /Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp
```



## Codex

`~/.codex/config.toml`:

```toml
[mcp_servers.opentraffic]
command = "/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp"
env = { OPENTRAFFIC_CLIENT = "Codex" }
# wait_for_feedback can take up to 300 seconds.
tool_timeout_sec = 330
```

## Cursor

`~/.cursor/mcp.json` (or `.cursor/mcp.json` in a project):

```json
{
  "mcpServers": {
    "opentraffic": {
      "command": "/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp",
      "env": { "OPENTRAFFIC_CLIENT": "Cursor" }
    }
  }
}
```

## opencode

`opencode.json` (project) or `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "opentraffic": {
      "type": "local",
      "command": ["/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp"],
      "environment": { "OPENTRAFFIC_CLIENT": "opencode" },
      "enabled": true
    }
  }
}
```

## Other MCP clients

- **stdio:** command `/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp`, no arguments, optionally
  `OPENTRAFFIC_CLIENT` in the environment.
- **Streamable HTTP:** `http://127.0.0.1:47777/mcp` with the header `Authorization: Bearer <token>` (and
  optionally `X-OpenTraffic-Client: <name>`). JSON responses only, no sessions; protocol `2025-06-18` or `2025-03-26`.

## Try the connection

Ask your agent: “List my OpenTraffic shares.” Once that works, ask it to share a running dev server and collect feedback. OpenTraffic asks before publishing unless publishing without confirmation has been allowed in Settings.

A useful review instruction is: “Read the open comments for Orbit, inspect the relevant screenshots, fix the issues in this project, verify the changes, then reply and resolve each completed comment.”

## Troubleshooting

If the bridge cannot connect, check that OpenTraffic is running, the local API is enabled, and the installation path is correct. If `wait_for_feedback` times out in your client, lower `timeout_seconds` or increase the client’s tool timeout. See [MCP reference](/docs/mcp) for the complete tool list.

## Before you start

There's nothing to turn on. The `opentraffic-mcp` bridge comes with OpenTraffic and connects to it privately, without a token, and starts OpenTraffic in the background when it isn't running. **Settings → Integrations** shows the exact setup for your app, with the right path if OpenTraffic isn't in `/Applications`.

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
- **Streamable HTTP:** turn on **Settings → Integrations → Allow apps on this Mac**, then use `http://127.0.0.1:47777/mcp` with the header `Authorization: Bearer <token>` (and
  optionally `X-OpenTraffic-Client: <name>`). JSON responses only, no sessions; protocol `2025-06-18` or `2025-03-26`.

## Try the connection

Ask your agent: “List my OpenTraffic shares.” Once that works, ask it to share a running dev server and collect feedback. The bridge doesn't ask you before publishing, so your agent shares only what you ask it to.

A useful review instruction is: “Read the open comments for Orbit, inspect the relevant screenshots, fix the issues in this project, verify the changes, then reply and resolve each completed comment.”

## Troubleshooting

If the bridge cannot connect, check that OpenTraffic is installed at the path in your configuration and opens normally. If `wait_for_feedback` times out in your client, lower `timeout_seconds` or increase the client’s tool timeout. See [MCP reference](/docs/mcp) for the complete tool list.

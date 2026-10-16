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

## Let OpenTraffic start your agent

When no agent is watching a share, OpenTraffic can start one for a comment. Choose it in **Settings → Integrations → Agent for comments**: Claude Code, Codex, Cursor, opencode, or your own command. Then:

- **Send to Claude Code** on a comment in the Feedback tab runs it for that comment, or
- **Run it by itself for new comments when no agent is watching** runs it a few seconds after a visitor comments, unless an agent claims the comment first, is waiting for feedback on the share (`wait_for_feedback`, and for 90 seconds after), or is working on another of its comments.

OpenTraffic runs the command in the share's project folder: the folder its local server runs from, or one you choose in the Feedback tab. It runs one comment at a time per share, and stops a run after 20 minutes. The Feedback tab shows what it's doing, what it printed, and a **Stop** button. The presets:

```sh
claude -p "$OPENTRAFFIC_PROMPT" --permission-mode acceptEdits --allowedTools mcp__opentraffic
codex exec -s workspace-write "$OPENTRAFFIC_PROMPT"
cursor-agent -p "$OPENTRAFFIC_PROMPT"
opencode run "$OPENTRAFFIC_PROMPT"
```

Each may edit files in the project and use OpenTraffic's MCP tools, so the agent needs the MCP server set up as above. The Claude Code preset can also read the project but not run shell commands; the others follow their tool's own permissions (Codex's `workspace-write` sandbox, for example, may run commands inside the project). Edit the command to change that. The command gets `OPENTRAFFIC_PROMPT` (what to do), `OPENTRAFFIC_SHARE`, `OPENTRAFFIC_SHARE_ID`, `OPENTRAFFIC_COMMENT_ID`, and `OPENTRAFFIC_CLIENT` (the name it shows in the session). Never the comment's text: the agent reads that through OpenTraffic, marked as written by a visitor. The agent uses its own sign-in or API key; OpenTraffic doesn't run any model. A script of your own can use the same variables, with the [`opentraffic` command](/docs/cli) or the [REST API](/docs/rest-api).

Running by itself only starts the agent for comments from people you've made **Trusted** in the Live Collaboration card (or everyone, if **New people can** is set to trusted); others' comments wait for **Send to …**. See [Who can do what](/docs/collaboration#who-can-do-what). OpenTraffic also limits what that agent can do: one comment only, no shell or web, secrets hidden from replies, a budget, and comments that read like orders wait for you. See [Agents and visitors' words](/docs/security#agents-and-visitors-words).

A comment the agent reads carries `context` (the element's selector, key styles, and, on development builds that expose it, its component and source file), any `edits` the commenter suggested on the page (apply them as given), and `area` for a comment on a region.

## Try the connection

Ask your agent: “List my OpenTraffic shares.” Once that works, ask it to share a running dev server and collect feedback. The bridge doesn't ask you before publishing, so your agent shares only what you ask it to.

A useful review instruction is: “Read the open comments for Orbit, inspect the relevant screenshots, fix the issues in this project, verify the changes, then reply and resolve each completed comment.”

## Troubleshooting

If the bridge cannot connect, check that OpenTraffic is installed at the path in your configuration and opens normally. If `wait_for_feedback` times out in your client, lower `timeout_seconds` or increase the client’s tool timeout. See [MCP reference](/docs/mcp) for the complete tool list.

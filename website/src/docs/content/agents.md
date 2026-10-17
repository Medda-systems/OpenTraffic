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
claude -p "$OPENTRAFFIC_PROMPT" --permission-mode dontAsk --allowedTools "Read,Edit,Write,Glob,Grep,mcp__opentraffic,Bash(opentraffic comments *),…"
codex exec -c allow_login_shell=false -c features.network_proxy=true … --skip-git-repo-check "$OPENTRAFFIC_PROMPT"
cursor-agent -p "$OPENTRAFFIC_PROMPT"
OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"deny","opentraffic comments *":"allow",…},"webfetch":"deny",…}}' opencode run "$OPENTRAFFIC_PROMPT"
```

**Model** picks the model the agent runs with, one per agent: its own default (shown with what that is), one of the models it offers, or **Other…** for any name. OpenTraffic asks the agent which models it has: Codex's model catalog, opencode's models from the providers you've set up, and Claude Code's aliases (Fable, Opus, Sonnet, Haiku: the latest of each your subscription has). Cursor can't list its models, so type one. The refresh button asks again. The run gets it as `OPENTRAFFIC_MODEL`, which the presets pass on as `--model`.

Each may edit files in the project and reach the comment with the [`opentraffic` command](/docs/cli), or with OpenTraffic's MCP tools if you've set them up as above, so Claude Code, Codex, and opencode need no setup. OpenTraffic puts its own `opentraffic` first on the agent's PATH, whether or not you linked the command. The agent's shell runs only the comment commands (`comments`, `claim`, `release`, `reply`, `resolve`, `screenshot`), and it has no web: Claude Code runs only what's listed, opencode's shell refuses everything else, and Codex runs in its sandbox, writing only in the project, with a network that reaches OpenTraffic and nothing else (if a Codex version ever let the web through, OpenTraffic doesn't start it). Cursor needs the MCP server and follows its own allowlist. Edit the command to change any of this. The command gets `OPENTRAFFIC_PROMPT` (what to do), `OPENTRAFFIC_SHARE`, `OPENTRAFFIC_SHARE_ID`, `OPENTRAFFIC_COMMENT_ID`, `OPENTRAFFIC_CLIENT` (the name it shows in the session), and `OPENTRAFFIC_SOCKET` (where the `opentraffic` command reaches OpenTraffic). Never the comment's text: the agent reads that through OpenTraffic, marked as written by a visitor. The agent uses its own sign-in or API key; OpenTraffic doesn't run any model. A script of your own can use the same variables, with the [`opentraffic` command](/docs/cli) or the [REST API](/docs/rest-api).

Running by itself only starts the agent for comments from people you've made **Trusted** in the Live Collaboration card (or everyone, if **New people can** is set to trusted); others' comments wait for **Send to …**. See [Who can do what](/docs/collaboration#who-can-do-what). OpenTraffic also limits what that agent can do: one comment only, no shell or web, secrets hidden from replies, a budget, and comments that read like orders wait for you. See [Agents and visitors' words](/docs/security#agents-and-visitors-words).

A comment the agent reads carries `context` (the element's selector, key styles, and, on development builds that expose it, its component and source file), any `edits` the commenter suggested on the page (apply them as given), and `area` for a comment on a region.

## Try the connection

Ask your agent: “List my OpenTraffic shares.” Once that works, ask it to share a running dev server and collect feedback. The bridge doesn't ask you before publishing, so your agent shares only what you ask it to.

A useful review instruction is: “Read the open comments for Orbit, inspect the relevant screenshots, fix the issues in this project, verify the changes, then reply and resolve each completed comment.”

## Troubleshooting

If the bridge cannot connect, check that OpenTraffic is installed at the path in your configuration and opens normally. If `wait_for_feedback` times out in your client, lower `timeout_seconds` or increase the client’s tool timeout. See [MCP reference](/docs/mcp) for the complete tool list.

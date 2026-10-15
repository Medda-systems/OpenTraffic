## What it does

The OpenTraffic skill teaches coding agents that support [Agent Skills](https://agentskills.io), such as Claude Code, Codex, and opencode, to use OpenTraffic. Ask your agent to share, preview, or demo what you're building, and it finds your dev server, shares it the way you asked, and gives you the link. Ask it to deal with feedback, and it reads the comments people pinned to the page, looks at the pictures of what they pointed at, fixes the code, replies, and resolves them. It also knows how to work out why a shared link isn't working.

The skill uses the [`opentraffic` command](/docs/cli), which comes with OpenTraffic. Install [OpenTraffic](/docs/installation); there's nothing else to set up.

## Install

```sh
curl -fsSL https://opentraffic.dev/skill | sh
```

This installs it for you, in every project, for the agents it finds on your Mac. Restart your agent afterwards so it loads the skill.

| Agent | Folder |
| --- | --- |
| Claude Code | `~/.claude/skills/opentraffic` |
| Codex | `~/.agents/skills/opentraffic` |
| opencode | either of the two |
| Other agents that read Agent Skills | usually `~/.agents/skills/opentraffic` |

To add it to one project instead, so everyone who works on it gets it, run this in the project's folder and commit the result:

```sh
curl -fsSL https://opentraffic.dev/skill | sh -s -- --project
```

That puts it in `.claude/skills/opentraffic` and `.agents/skills/opentraffic`.

### Download it

Or download the skill and put the `opentraffic` folder in one of the folders above yourself:

- [opentraffic.zip](https://opentraffic.dev/skills/opentraffic.zip): the whole skill
- [SKILL.md](https://opentraffic.dev/skills/opentraffic/SKILL.md) and [reference.md](https://opentraffic.dev/skills/opentraffic/reference.md): the two files it's made of
- [The installer](https://opentraffic.dev/skills/install.sh), to read before you run it

## Try it

Once your agent has restarted, ask it things like:

- “Share my dev server so I can look at it on my phone.”
- “Put this on a link with live collaboration so the team can comment.”
- “Go through the comments on the shared page and fix what you can.”
- “The shared link says the host isn't allowed. Fix it.”
- “Give me a link to the API on port 3001 that keeps working tomorrow.”

The `opentraffic` command doesn't ask you to confirm anything, so the skill makes the agent the check: it tells the agent to share only what you asked for, and never to remove shares, replace DNS records, or change protection unless you asked it to.

## The skill and the MCP server

The skill teaches an agent to use the `opentraffic` command. The [MCP server](/docs/agents) gives it tools instead, including `wait_for_feedback`, which waits until someone comments. They work well together: with both, the agent follows the skill's workflow and uses the MCP tools where they fit.

## Update or remove it

Run the installer again to get the latest version. To remove it:

```sh
curl -fsSL https://opentraffic.dev/skill | sh -s -- --uninstall
```

Add `--project` to remove it from the current project instead.

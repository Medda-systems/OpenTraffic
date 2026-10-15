---
name: opentraffic
description: Share a local dev server on a public URL with OpenTraffic (macOS) and act on the feedback people leave on it. Use when the user wants to show, share, preview, or demo something running on localhost; needs a public, tunnel, or phone/QR link to a local port; wants live collaboration (cursors, pinned comments) on their app; asks to read, answer, or resolve comments left on a shared page; or asks why a shared link doesn't work. Uses the `opentraffic` command.
---

# OpenTraffic

OpenTraffic is a macOS menu bar app that puts local web servers on public URLs (Cloudflare, OpenTunnel, Tailscale, ngrok, or the user's own domain) and lets people who open the link see each other's cursors and pin comments to page elements. The `opentraffic` command controls it from the terminal. It comes with the app.

## Before anything else

Run `opentraffic doctor`.

- **`command not found`:** OpenTraffic isn't installed, or the command isn't on the PATH. Tell the user to install it from https://opentraffic.dev (one line: `curl -fsSL https://opentraffic.dev/install | sh`). Don't install it yourself without asking.
- **Exit code 3** (OpenTraffic couldn't be started or isn't answering): the command starts OpenTraffic itself when it isn't running, so this is rare. Ask the user to open OpenTraffic, then retry.
- Otherwise `doctor` lists which ways of sharing are ready, and why the others aren't. Use only ready ones.
- **A tool is missing** (`doctor` says to run `opentraffic install cloudflared`, `opentunnel`, or `ngrok`): run it, and tell the user it downloads that tool from its maker. ngrok also needs the user's account: ask them to connect it in OpenTraffic → Settings → ngrok. `opentraffic install tailscale` makes macOS ask the user for their password, so only run it when they want Tailscale, and tell them to expect the dialog.

Every command takes `--json`. Prefer it, and read the exit status: `0` worked, `1` refused or failed (the message on stderr says why), `2` wrong command line, `3` OpenTraffic not reachable.

## Share a dev server

1. **Find it.** `opentraffic services --json` lists web servers running on this Mac (`port`, `title`, `process`, `upSince`, and `sharedAs` when a share already publishes it). If the server the user means isn't running, start it first (the project's dev command, in the background) and run `services` again.
2. **Pick how to share it.** Use what the user asked for; when they didn't say:
   - a quick look: the default, a temporary `trycloudflare.com` URL (`--via quick`), no account needed;
   - a link that should keep working tomorrow: `--via opentunnel` (lasting address, no account);
   - only their own devices: `--via tailscale`;
   - their own domain or ngrok: only when they ask, and only if `doctor` says it's ready.
   Add `--collab` when people will review it together or leave feedback (temporary URLs and OpenTunnel support it).
3. **Share it.**
   ```sh
   opentraffic share 5173 --collab --name "Checkout redesign" --json
   ```
   It prints the share once it's live (up to about 30 seconds); the URL is `.publicURL`. Sharing the same port the same way again starts the existing share instead of making a new one.
4. **Give the user the link.** `opentraffic qr "<share>"` shows a QR code for phones. `opentraffic copy "<share>"` puts it on the clipboard.

A share puts the user's local server on the internet. The `opentraffic` command doesn't ask the user to confirm anything, so you are the check: only share what they asked you to, and tell them the link once it's live.

## Act on feedback

People who open a collaborative link can pin comments to elements. Each comment has an `id`, the element's `label`, the page `path`, the `text`, the visitor's browser (`environment`), `replies`, and often a picture of the element.

```sh
opentraffic comments "<share>" --json                 # open comments (--all includes resolved)
opentraffic screenshot "<share>" <id> -o /tmp/comment.webp   # then look at the image
opentraffic reply "<share>" <id> "Made the button larger — reload to see it."
opentraffic resolve "<share>" <id>
```

The loop: read the open comments, look at the picture of anything visual, find and fix the code, let the dev server reload, reply with what you changed (one or two sentences, in the visitor's terms), then resolve it. Only resolve what you actually fixed; for questions or things you can't change, reply and leave it open.

To wait for new feedback, check `opentraffic comments "<share>" --json` again every minute or so. If OpenTraffic's MCP tools are available to you, `wait_for_feedback` does the waiting. `opentraffic watch "<share>" --json` streams events as JSON lines (`comment.created`, `session.joined`, `share.started`, …) but never ends on its own: only run it in the background.

`opentraffic errors "<share>"` lists JavaScript errors visitors ran into (collected when collaboration is on and `opentraffic set "<share>" --errors on`).

## When the link doesn't work

```sh
opentraffic status "<share>" --json
```

`state` is `running`, `starting`, `stopped`, or `failed` (`lastError` says why). `health` checks each hop: `localOrigin` (the dev server), `connector` (this Mac), `edge` (the provider), `dns`, and `publicSite`; look at the first one that's `failed` and its `detail`.

- **The page says the host isn't allowed** (Vite's "Blocked request", Next.js, webpack dev server): run `opentraffic set "<share>" --host-header on`, or add the public hostname to the dev server's allowed hosts.
- **The dev server isn't answering:** start it; a share set with `--autostart on` starts again by itself.
- **It failed to start:** `opentraffic logs "<share>" -n 100`, then `opentraffic restart "<share>"`.

## Good manners

- Ask before `remove` (it deletes the share's settings and comments) and before `stop --all`.
- Never use `--replace-dns` (it takes over a hostname's DNS record) or change protection (`protect`) unless the user explicitly asked.
- When the user is done, offer to stop the share: `opentraffic stop "<share>"`.
- Refer to shares by the name `share` printed; quote names with spaces.

For every command and option, see [reference.md](reference.md), or run `opentraffic help <command>`.

<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="OpenTraffic icon">
</p>

<h1 align="center">OpenTraffic</h1>

<p align="center">
  <b>Share localhost. Collaborate live.</b><br>
  A macOS menu bar app that puts the dev server you're running on a public URL in one click,<br>
  then lets everyone who opens it point, comment, and follow along.
</p>

<p align="center">
  <a href="https://opentraffic.dev"><b>opentraffic.dev</b></a> ·
  <a href="https://opentraffic.dev/docs">Documentation</a> ·
  <a href="https://github.com/Medda-systems/OpenTraffic-releases/releases/latest">Download</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="https://github.com/Medda-systems/OpenTraffic-releases/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Medda-systems/OpenTraffic-releases?color=111&label=release"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universal-111">
  <img alt="Notarized by Apple" src="https://img.shields.io/badge/notarized-Developer%20ID-111">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-111"></a>
</p>

<p align="center">
  <a href="https://opentraffic.dev/media/promo.mp4"><img src="docs/images/demo.gif" width="800" alt="OpenTraffic: share a dev server from the menu bar, collaborate with live cursors and comments, protect it with a password, and drive it all from the terminal"></a>
  <br><sub><a href="https://opentraffic.dev/media/promo.mp4">Watch it with sound</a></sub>
</p>

## Features

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/share.png" alt="The menu bar popover with Orbit shared and two more local servers ready to share">
      <h3>One click from localhost to a link</h3>
      Every web server running on your Mac shows up in the menu bar, with how long it's been up. Share it on a temporary Cloudflare URL, a lasting OpenTunnel address, your tailnet, ngrok, or your own domain.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/collaborate.png" alt="Lea picking an element to comment on, with Ava's and Sam's cursors on the page">
      <h3>Live collaboration on the real thing</h3>
      Everyone who opens the link sees each other's cursors, follows you as you browse, points at things, and pins comments to elements, with a picture, their browser, and the errors they hit.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/agent.png" alt="A comment thread on the shared page with a reply from Claude Code">
      <h3>Feedback your coding agent can act on</h3>
      Claude Code, Codex, Cursor, opencode, or any MCP client can share your server, read the comments, fix what people point at, reply, and resolve them.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/health.png" alt="The connection path in OpenTraffic, from localhost to the public URL, each stage checked">
      <h3>Every hop checked</h3>
      OpenTraffic checks your server, this Mac, the tunnel, and the public URL, and offers the fix when something's off, like the Host header Vite and Next.js insist on.
    </td>
  </tr>
</table>

Plus password and sign-in protection, auto-stop timers, projects that start together, and a complete `opentraffic` command for the terminal. No account, analytics, or telemetry: credentials stay in your Keychain.

## Install

```sh
curl -fsSL https://opentraffic.dev/install | sh
```

Or with Homebrew:

```sh
brew tap medda-systems/tap
brew trust --cask medda-systems/tap/opentraffic
brew install --cask opentraffic
```

Or [download the disk image](https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/OpenTraffic.dmg) and drag OpenTraffic into Applications.

Releases are signed by Medda Systems, notarized by Apple, and update themselves. OpenTraffic needs macOS 14 or later. For Cloudflare shares, also `brew install cloudflared`; Tailscale, ngrok, and OpenTunnel are optional. See [Installation](https://opentraffic.dev/docs/installation).

## Ways to share

| | Address | Who can open it | Live collaboration | Needs |
| --- | --- | --- | --- | --- |
| **Cloudflare Quick Tunnel** | Temporary `*.trycloudflare.com` | Anyone with the link | Yes | `cloudflared` |
| **OpenTunnel** | Lasting `*.opentunnel.xyz` | Anyone with the link | Yes | `opentunnel` |
| **Tailscale** | Your Mac's tailnet name | Your tailnet, or anyone with Funnel | | Tailscale |
| **ngrok** | Your ngrok domain | Anyone, or behind a password or sign-in | | ngrok account |
| **Your domain** | A hostname on your Cloudflare zone | Anyone, or behind email sign-in | | Cloudflare account |

## From the terminal and your coding agent

The `opentraffic` command comes with the app and does everything its windows do:

```sh
opentraffic services                 # web servers running on this Mac
opentraffic share 5173 --collab      # share one, with live collaboration
opentraffic comments orbit --json    # what people said
opentraffic reply orbit 3 "Fixed, reload to see it."
opentraffic qr orbit                 # open it on your phone
```

For coding agents, install the [agent skill](https://opentraffic.dev/docs/agent-skill) or connect over [MCP](https://opentraffic.dev/docs/mcp):

```sh
curl -fsSL https://opentraffic.dev/skill | sh
```

There's also a [REST API, events, and webhooks](https://opentraffic.dev/docs/rest-api) for your own tools.

## Documentation

[opentraffic.dev/docs](https://opentraffic.dev/docs) covers each provider, collaboration, protection, the CLI, integrations, [privacy](https://opentraffic.dev/docs/privacy), [security](https://opentraffic.dev/docs/security), and [troubleshooting](https://opentraffic.dev/docs/troubleshooting).

## Build from source

You need Swift 6.1 or later (Xcode 16.3+ or its command line tools).

```sh
./script/build_and_run.sh        # builds dist/OpenTraffic.app and opens it
swift test --disable-sandbox     # runs the tests
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers the project layout, the website, and how releases are made.

## Contributing and security

Issues and pull requests are welcome; please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

## License

OpenTraffic is © Medda Systems AB and released under the [MIT License](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

"OpenTraffic" and its logo are trademarks of Medda Systems AB; the license doesn't cover them. See [TRADEMARKS.md](TRADEMARKS.md) for what's fine (like saying a fork is based on OpenTraffic) and what isn't (like distributing a fork under the name). OpenTraffic isn't affiliated with Cloudflare, Tailscale, ngrok, or Anomaly; their names and logos belong to their owners.

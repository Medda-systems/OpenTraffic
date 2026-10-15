# Third-party notices

OpenTraffic is MIT licensed (see `LICENSE`). It includes or links the following.

## Swift packages (linked into the app)

All are © Apple Inc. and the Swift project authors, licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0):

| Package | Version |
| --- | --- |
| [SwiftNIO](https://github.com/apple/swift-nio) | 2.103.0 |
| [Swift Collections](https://github.com/apple/swift-collections) | 1.7.1 |
| [Swift Atomics](https://github.com/apple/swift-atomics) | 1.3.1 |
| [Swift System](https://github.com/apple/swift-system) | 1.8.1 |

Their license texts are in [`Licenses/`](Licenses), together with SwiftNIO's `NOTICE.txt` (which
credits code it derives from Netty, llhttp, and others). The app bundle carries the same files in
`OpenTraffic.app/Contents/Resources/Licenses`.

## Sparkle (embedded in the app)

[Sparkle](https://sparkle-project.org) 2.10.0, which installs OpenTraffic's updates, is © Andy
Matuschak and the Sparkle contributors under the MIT License. It includes code under other
permissive licenses, listed in its license file, `Licenses/Sparkle-LICENSE.txt`. It's embedded as
`OpenTraffic.app/Contents/Frameworks/Sparkle.framework`.

## Provider marks

`Sources/OpenTraffic/Resources/provider-cloudflare.svg`, `provider-ngrok.svg`, and
`provider-tailscale.svg` come from [Simple Icons](https://simpleicons.org) 16.33.0, released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

## Coding agent marks

`Sources/OpenTraffic/Resources/agent-claude.svg`, `agent-cursor.svg`, and `agent-opencode.svg` come from
[Simple Icons](https://simpleicons.org) 16.35.0, released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). `agent-codex.svg` comes from
[Lobe Icons](https://github.com/lobehub/lobe-icons) 1.95.1, © 2023 LobeHub, released under the MIT License
(`Licenses/LobeIcons-LICENSE.txt`). The same marks are drawn by `Sources/OpenTraffic/Resources/collab.js`.

OpenTraffic shows these marks only to identify the coding agent working on a comment (Claude Code,
Codex, Cursor, or OpenCode), never as its own branding.

## Trademarks

Cloudflare, ngrok, Tailscale, Claude, Codex, OpenAI, Cursor, and OpenCode are trademarks of their
respective owners. OpenTraffic is an independent project; it is not affiliated with, endorsed by, or
sponsored by Cloudflare, Inc., ngrok, Inc., Tailscale Inc., Anthropic PBC, OpenAI, Anysphere, Inc., or Anomaly. Their
names and marks are used only to identify the services and tools OpenTraffic works with. OpenTraffic's own icon is original artwork.

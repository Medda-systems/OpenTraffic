# Contributing

Thanks for helping. Bug reports, ideas, and pull requests are all welcome; for anything big, open an issue
first so we can agree on the approach.

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/OpenTraffic` | The SwiftUI app: menu bar, windows, stores, and the services that run each provider. |
| `Sources/OpenTrafficCore` | Code shared and unit tested without the UI: the Cloudflare client, the collaboration hub and proxy, the local API. |
| `Sources/opentraffic-cli` | The `opentraffic` command (a client of the local API). |
| `Sources/opentraffic-mcp` | The stdio MCP bridge for coding agents. |
| `Tests/` | Unit tests for the core and the command. |
| `Integrations/` | MCP setup, REST API reference, and the Claude Code plugin. |
| `website/` | opentraffic.dev, its docs (`website/src/docs/content`), the agent skill, and the Remotion videos. |
| `script/` | Building, packaging, installing, and releasing. |
| `Examples/collab-demo` | A small site for trying live collaboration. |

## Build and test

You need macOS 14 or later and Swift 6.1 or later (Xcode 16.3+ or its command line tools).

```sh
./script/build_and_run.sh          # build dist/OpenTraffic.app and open it (also: --debug, --logs, --build-only)
swift test --disable-sandbox       # run the tests
```

`build_and_run.sh` signs with your Apple Development certificate when you have one, so Keychain access
survives rebuilds; otherwise it signs ad hoc and macOS may ask for Keychain access again after a rebuild.
To keep a test build's settings and data apart from your real ones, give it another bundle identifier:
`OPENTRAFFIC_BUNDLE_ID=se.medda.opentraffic.dev ./script/build_and_run.sh`.

For the website: `cd website && npm install && npm run dev`.

## Pull requests

- Keep each pull request to one change, with tests for logic in `OpenTrafficCore` or the command.
- Run `swift test` before pushing; the Tests workflow runs it too.
- Match the surrounding style. User-facing text is short and plain.
- Update the docs in `website/src/docs/content` and add a line under "Unreleased" in `CHANGELOG.md` when
  behavior changes.

By submitting a contribution, you confirm you have the right to, and you agree that it's licensed under the
[MIT License](LICENSE) and that Medda Systems AB may also distribute it under other license terms, including
in future versions of OpenTraffic. You keep the copyright to your contribution.

## Releases

Maintainers release by setting `VERSION`, turning "Unreleased" in `CHANGELOG.md` into the version's dated section
(`## 1.2.3 (16 October 2026)`, the day it's published; the Release workflow refuses a section without a date), and
pushing a tag:

```sh
git tag -a v1.2.3 -m "OpenTraffic 1.2.3" && git push origin v1.2.3
```

The Release workflow (`.github/workflows/release.yml`) then:

1. builds the universal app with `script/package_dmg.sh`, signs it with Medda Systems' Developer ID, and has
   Apple notarize and staple the app and the disk image (a tag refuses to publish anything that isn't);
2. signs the disk image and `appcast.xml`, the update feed, with Medda Systems' Sparkle update key;
3. runs `script/publish_release.sh`, which publishes the GitHub Release in
   [OpenTraffic-releases](https://github.com/Medda-systems/OpenTraffic-releases) and updates the cask in
   [homebrew-tap](https://github.com/Medda-systems/homebrew-tap).

Its secrets are the update key (`SPARKLE_PRIVATE_KEY`), the Developer ID certificate
(`DEVELOPER_ID_CERTIFICATE`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`), an App Store Connect API key for notarizing
(`NOTARY_API_KEY`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`), and `RELEASES_TOKEN` for publishing. Running the
workflow from the Actions tab is a dry run that keeps the build as an artifact.

`script/package_dmg.sh` also works locally. Without a Developer ID it signs ad hoc, which is fine for testing;
see the comment at the top of the script for the signing and notarizing variables.

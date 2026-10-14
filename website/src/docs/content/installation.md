## Requirements

- macOS 14 or newer
- The tool for each way of sharing you use: `cloudflared` (Cloudflare), `opentunnel` (OpenTunnel), `ngrok`, or the Tailscale app. OpenTraffic installs the first three for you, in one click (see below).

## Tools for sharing

OpenTraffic shares through other companies' free tools. When one is missing, the setup assistant, Settings, and New Tunnel show an **Install** button that says what it downloads: the version, the size, where from, and who signed it.

| Tool | Downloaded from | Checked with |
| --- | --- | --- |
| `cloudflared` | Cloudflare's GitHub releases | The published SHA-256 and Cloudflare's Developer ID signature |
| `opentunnel` | Anomaly's GitHub releases | The published SHA-256 |
| `ngrok` | ngrok's download server | ngrok's Developer ID signature |
| Tailscale | Tailscale's download server (`pkgs.tailscale.com`) | The published SHA-256, and Tailscale's Developer ID Installer signature and Apple notarization |

A download that doesn't pass its checks isn't installed. The command-line tools go in OpenTraffic's own folder, `~/Library/Application Support/OpenTraffic/Tools`, so nothing else on your Mac changes and no password is needed. From the command line: `opentraffic install cloudflared` (or `opentunnel`, `ngrok`, `tailscale`).

**Tailscale** is a Mac app with a VPN, so it's installed the way Tailscale ships it outside the App Store: OpenTraffic downloads and checks Tailscale's installer, then opens it in Apple's Installer: click through Tailscale's steps and enter your Mac's password when macOS asks. Tailscale then opens: sign in, allow its VPN when macOS asks, and turn on HTTPS certificates for your tailnet. The **⋯** menu next to Install offers the App Store version or the Homebrew command (`brew install --cask tailscale-app`) instead.

**ngrok** also needs your free account: paste your authtoken from the ngrok dashboard into OpenTraffic once.

Tools you installed yourself keep working: OpenTraffic looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, and `~/.local/bin` first (and for Tailscale, inside `/Applications/Tailscale.app`), then in its own folder. You can choose a different executable in Settings.

## Install OpenTraffic

In Terminal:

```sh
curl -fsSL https://opentraffic.dev/install | sh
```

This downloads the latest release, checks its checksum and signature, and puts OpenTraffic in Applications ([read the installer](https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/install.sh)).

With Homebrew:

```sh
brew tap medda-systems/tap
brew trust --cask medda-systems/tap/opentraffic
brew install --cask opentraffic
```

Homebrew asks you to trust casks from taps outside its official collection; the second line trusts just this one.

Or download it:

1. Download [`OpenTraffic.dmg`](https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/OpenTraffic.dmg) (every version and its checksum are on the [releases page](https://github.com/Medda-systems/OpenTraffic-releases/releases)) and open it.
2. Drag **OpenTraffic** onto **Applications**.
3. Open OpenTraffic from Applications. It's signed by Medda Systems and notarized by Apple, so it opens without any warning.
4. The setup assistant offers the [tools for sharing](#tools-for-sharing): click **Install** next to Cloudflare (and OpenTunnel, if you like). Tailscale and ngrok are optional.

Every way of installing also gives you the [`opentraffic` command](/docs/cli): the installer links it right away, and OpenTraffic links it whenever it runs from Applications (in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`). Run `opentraffic setup` once to start using it. Settings → General → **Install the opentraffic command** turns this off.

OpenTraffic updates itself: it checks once a day, and **Check for Updates…** is in the app menu. Updates are signed with Medda Systems' key and verified before they're installed. Settings → General can turn the checks or background installs off.

Continue with the [quickstart](/docs/quickstart).

## First launch

Open the app from Applications. The setup assistant checks for cloudflared and offers optional account setup. A Cloudflare account is only needed for custom domains and importing remotely managed tunnels. The menu bar icon gives you access to detected services and saved shares.

## Update checks

Use **Check for Updates…** from the app menu for an immediate check. Automatic checks run daily unless disabled in Settings → General. Update signatures verify the update package; they are separate from Apple Developer ID signing and notarization.

## Uninstall

See [Privacy & local data](/docs/privacy#uninstall) for the app, local files, CLI link, and Keychain entries.

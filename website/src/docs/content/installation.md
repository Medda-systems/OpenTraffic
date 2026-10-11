## Requirements

- macOS 14 or newer
- `cloudflared` for Cloudflare shares
- Optional: the Tailscale app for tailnet shares, the `ngrok` CLI for ngrok shares, the `opentunnel` CLI (`brew install anomalyco/tap/opentunnel`) for OpenTunnel shares

OpenTraffic looks for these in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, and `~/.local/bin`, and for Tailscale also in the CLI inside `/Applications/Tailscale.app`. You can choose a different executable in Settings. Tailscale shares need the Tailscale app signed in, with HTTPS certificates turned on for the tailnet.

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
3. Open OpenTraffic from Applications. Releases from the disk image or Homebrew aren't notarized by Apple yet, so the first launch is blocked:
   - **macOS 15 or later:** open **System Settings → Privacy & Security**, scroll down to the message about OpenTraffic, and click **Open Anyway**.
   - **macOS 14:** Control-click OpenTraffic in Applications, choose **Open**, then **Open** again.
4. Install `cloudflared` for Cloudflare shares, either with `brew install cloudflared` or from [Cloudflare's downloads](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/). Tailscale, ngrok, and OpenTunnel are optional.

Every way of installing also gives you the [`opentraffic` command](/docs/cli): the installer links it right away, and OpenTraffic links it whenever it runs from Applications (in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`). Run `opentraffic setup` once to start using it. Settings → General → **Install the opentraffic command** turns this off.

OpenTraffic updates itself: it checks once a day, and **Check for Updates…** is in the app menu. Updates are signed with Medda Systems' key and verified before they're installed. Settings → General can turn the checks or background installs off.

Continue with the [quickstart](/docs/quickstart).

## First launch

Open the app from Applications. The setup assistant checks for cloudflared and offers optional account setup. A Cloudflare account is only needed for custom domains and importing remotely managed tunnels. The menu bar icon gives you access to detected services and saved shares.

## Update checks

Use **Check for Updates…** from the app menu for an immediate check. Automatic checks run daily unless disabled in Settings → General. Update signatures verify the update package; they are separate from Apple Developer ID signing and notarization.

## Uninstall

See [Privacy & local data](/docs/privacy#uninstall) for the app, local files, CLI link, and Keychain entries.

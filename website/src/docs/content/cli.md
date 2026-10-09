## Install the command

Use **Settings → General** to install the bundled `opentraffic` command as a symlink. The default path is `/usr/local/bin/opentraffic`. Ensure that directory is on your shell’s PATH.

The CLI sends `opentraffic://` links to the macOS application. It is not an independent headless tunnel server. macOS opens the app as needed; sharing still runs in the app.

## Command reference

```sh
opentraffic share <port|url> [--via quick|tailscale|ngrok|opentunnel] [--name NAME] [--collab]
opentraffic start NAME
opentraffic stop NAME
opentraffic stop --all
opentraffic copy NAME
opentraffic show [NAME]
opentraffic project start NAME
opentraffic project stop NAME
opentraffic --help
```

Quote names with spaces. A numeric target is a port between 1 and 65535; `localhost:3000` and full HTTP(S) URLs are also accepted.

## Examples

```sh
opentraffic share 5173 --name "My app" --collab
opentraffic share 3000 --via tailscale
opentraffic share http://localhost:8080 --via ngrok --name API
opentraffic share 5173 --via opentunnel --collab --name Orbit
opentraffic copy Orbit
opentraffic stop Orbit
opentraffic project start "Demo day"
```

## Output and completion

`share` dispatches the request and prints no URL; dispatch success does not mean a tunnel is already online. `copy` waits for the app to update the clipboard, then prints the URL. If nothing is copied within its short polling window, it exits with an error. It also changes your clipboard.

For reliable scripting with structured responses and share state, use the [REST API](/docs/rest-api).

## URL schemes

| Link | Action |
| --- | --- |
| `opentraffic://share?port=3000&via=tailscale` | Share a local port |
| `opentraffic://share?port=5173&collab=1&name=Orbit` | Share with collaboration |
| `opentraffic://start?name=Orbit` | Start a saved share |
| `opentraffic://stop?name=Orbit` | Stop one share |
| `opentraffic://stop?all` | Stop managed shares |
| `opentraffic://copy?name=Orbit` | Copy the public URL |
| `opentraffic://show` | Open the app window |
| `opentraffic://project?name=Demo&action=start` | Start a project |

Percent-encode query values containing spaces or special characters. macOS Shortcuts can call these through **Open URLs**.

## Approval behavior

Sharing and starting ask for confirmation unless **Allow automation without confirmation** is enabled in General Settings. Any app or web page can attempt to open an app URL, so enable that preference only if it fits your workflow.

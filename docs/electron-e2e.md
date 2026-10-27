# Electron app sharing, end to end

`script/electron-e2e.mjs` runs the whole journey of sharing an Electron app the way a person would,
before a person tries it: it installs a scratch copy of the electron-orbit fixture
(`Examples/electron-orbit`), launches an isolated OpenTraffic copy, runs the fixture's dev script and
shares its dev server with the copy's own `opentraffic` command through OpenTunnel, then drives the
shared page from headless Chrome through its public address. Every step saves a screenshot; the run
stops at the first failure, names the step and exits 1. Node only, no npm packages of its own (the
fixture installs Electron); Chrome is driven over its DevTools protocol.

## Prerequisites

- **An isolated OpenTraffic copy**, never the OpenTraffic you use day to day: the same copy as the
  [Mac app end-to-end run](macapp-e2e.md#prerequisites), built once (and again after changing
  OpenTraffic) with its own bundle identifier, outside `/tmp` and `~/Library`:

  ```sh
  OPENTRAFFIC_CONFIGURATION=release OPENTRAFFIC_BUNDLE_ID=se.medda.opentraffic.e2e \
    OPENTRAFFIC_DIST_DIR=/Users/Shared/OpenTraffic-e2e ./script/build_and_run.sh --build-only
  ```

  `--build` makes the script run this command itself. Electron sharing needs no permissions.
- **npm** and a network that reaches the npm registry (the first run installs the fixture's Electron,
  about 100 MB, cached by npm and Electron afterwards) and opentunnel.xyz.
- **Google Chrome** (`CHROME` points at another Chromium binary).
- **The copy isn't running.** The script launches it with its own home and API socket in the work
  folder and quits it at the end; it refuses to start when the copy already runs.

Nothing shows on the Mac: the fixture's own Electron runs with `ORBIT_HIDDEN=1` (no window, no Dock
icon) and keeps its data in the work folder (`CFFIXED_USER_HOME`). The fixture's dev server and local
API get free ports, never 5173.

## Running it

```sh
node script/electron-e2e.mjs                       # about 2 minutes
node script/electron-e2e.mjs --work /tmp/ot-el     # keep everything in this folder (and the install)
OPENTRAFFIC_E2E=1 swift test --filter ElectronEndToEndTests   # the same, from swift test
```

Options: `--app <OpenTraffic.app>` (default `/Users/Shared/OpenTraffic-e2e/OpenTraffic.app`), `--build`
(rebuild that copy first), `--via opentunnel|quick`, `--name <share>` (default "Electron Orbit E2E"),
`--steps a,b` or `--skip a,b` (step names as printed; the set-up steps always run), and `--keep`
(leave the share live, the fixture and the copy running, to look at it afterwards; the script prints
how to reach them). `swift test` passes options in `OPENTRAFFIC_E2E_ARGS`.

The work folder (by default a new `ot-electron-e2e-<time>` folder in the temporary folder) holds the
fixture's scratch copy and its install, the fixture's own home, the copy's home and socket, Chrome's
profile (deleted at the end), the file the open dialog uploads, `downloads/` with what the save dialog
downloaded, `shots/` with one screenshot per step (plus the open menu, the open dialog and the phone
view), the fixture's logs and `summary.json` with every step's result and duration. At the end the
share is stopped, which removes its OpenTunnel route, and removed with its comments, the fixture stops
and the copy quits (SIGTERM to the process the script started).

## The steps

| Step | What it proves |
| --- | --- |
| prepare the fixture | a scratch copy of `Examples/electron-orbit` is installed (`npm ci`, skipped when `--work` has it already) |
| build the OpenTraffic copy | `--build` only; otherwise the existing copy is used |
| launch the copy | the copy starts with its own home and API socket and answers |
| start the fixture | `node dev.mjs` serves the renderer and the local API on free ports and starts Electron hidden; `opentraffic services` lists the dev server as "Orbit (Electron app)" |
| share the fixture | `opentraffic share <port> --via opentunnel --name "Electron Orbit E2E"` goes live under that name, with live collaboration; the public URL answers |
| page loads with the collab toolbar at 1440 px | the app's page with its preload (`window.orbit`), the collaboration overlay and its toolbar, and the desktop preview bar naming Orbit; the main process answers |
| ipcRenderer invoke, send and sendSync round trips | invoke sends bytes and gets them back as bytes; sendSync answers Orbit 0.1.0; send and `event.reply` give pong 100 for ping 99 (and 42 for the page's own 41); the form adds a note through invoke |
| main-to-renderer events reach the page | the hello greeting (`did-finish-load`), notes:changed after the note, and the app's 5-second tick |
| the app menu template shows and its items run | the bar's Menu shows the app's Orbit and Notes menus with New Note ⌘N and Export…; New Note and ⌘N run the item in the main process, which focuses the note field |
| an open dialog uploads a file | Open file… opens the page's file dialog; the picked file is uploaded to the sandboxed copy and the main process reads its name, size and text |
| a save dialog downloads the file | Export… saves notes.json in the sandboxed copy, the browser downloads it with the new note in it, and a Saved toast shows |
| openExternal opens a new tab | Open website opens https://opentraffic.dev in a new tab, without the "wants to open a link" fallback |
| a Notification shows as a toast | Notify's `new Notification(...).show()` is a toast on the page |
| a pinned comment shows in opentraffic comments | with the comment tool, a comment on Save; `opentraffic comments` lists it, pinned to Save |
| editing main.js restarts the backend without a page reload | the fixture's `version:sync` handler is edited; the main process restarts with it and the page, not reloaded, gets the new answer |
| Reset app data restores the data | `opentraffic restart --reset-data`: the note is gone, the notes are the ones the copy started with, on the same page |
| a finished app shares under its --name | `npm run package` builds dist/Orbit.app, which runs hidden; `opentraffic share dist/Orbit.app --name <a name another share has>` is refused, `--name "Electron Orbit E2E (finished app)"` goes live under that name; stopped and removed again |
| phone view at 390 px | the page loads at 390 px with the collaboration toolbar and the desktop preview bar inside the screen |
| opentraffic restart keeps the page connected | `opentraffic restart <share>`: the same address, and the page, not reloaded, reaches the main process again |
| no page errors | no JavaScript errors on the page |
| stop | `opentraffic stop`: the share is stopped and its public address no longer reaches the app |

## Results

27 October 2026, Mac15,12 (Apple M3, 16 GB), macOS 27.0, Chrome 156, release copy of OpenTraffic
1.0.20+ (`se.medda.opentraffic.e2e`), OpenTunnel, Electron 38.8.6. All steps passed in 26 s, from
`swift test` with a fresh work folder (`npm ci` 1.9 s with npm's cache); the finished app's step,
which packages and starts dist/Orbit.app and shares it, took 6.2 s of it.

The first runs found three bugs, fixed since: a link the app opened showed the "wants to open a link"
toast even though its tab had opened (`window.open` with `noopener` always returns null); a sendSync
call while the main process restarted failed with the proxy's error page instead of waiting; and
`opentraffic restart --app` / `--reset-data` refused Electron shares.

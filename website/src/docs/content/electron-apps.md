## Share an Electron app

An Electron app you're building shows up in the menu bar under **Ready to Share**, next to your web servers, as `Orbit · Electron · ~/code/orbit`. **Share** works as it does for a web page: one click, the link is on your clipboard, and live collaboration is on. People who open it use the app in their browser, with cursors, comments pinned to its elements, and style suggestions, and nothing to install.

Two kinds of app can be shared:

- **An app in development**, running from its project folder (`npm run dev`, `electron .`, electron-vite, Electron Forge). Its dev server is shown as part of the app, not separately.
- **A finished app you built** (an `.app` with its code in `app.asar`, from electron-builder, Forge, or similar), while it's open. It counts as yours when it was built inside a project folder, isn't signed or is signed ad hoc, or is signed with one of your own signing identities. Apps you only installed, signed by their makers, aren't listed: their data holds your logins, and their code isn't yours to share.

From the terminal: `opentraffic share 5173` (the app's dev server port) or `opentraffic share dist/mac-arm64/Orbit.app`.

## How it works

An Electron app has two halves: its windows (web pages) and its main process (Node.js code that runs on the computer). OpenTraffic sends the windows to viewers' browsers through the share, and runs **a second copy of the main process** on your Mac to answer them. Your own app window and its data are never touched.

- The page gets a stand-in for Electron's renderer side, so the app's preload works as it does in the app: `window.api.saveNote()` reaches the copy's `ipcMain` handlers over the share. `invoke`, `send`, `sendSync`, and events from the main process all work, and npm packages the preload uses are sent along.
- The copy runs on the app's own Electron. A finished app that turned off Electron's Node mode (the RunAsNode fuse, as Forge's template does) runs on a stock copy of the same Electron version instead, downloaded once from Electron's releases and checked against their published checksums.
- Things only a desktop can do are handed to the viewer: an open dialog asks them for a file (it's uploaded to the copy), a saved file is downloaded, links open in a new tab, notifications show as toasts, and the app's menus are under **Menu** in the small **desktop preview** bar.

## The sandbox

People who open the link drive the copy through the app's own handlers, so it runs in a macOS sandbox:

- It reads the project (or the finished app) and nothing else in your home folder or on other volumes.
- It writes only its own folder: a throwaway copy of the app's data. An app in development starts from a copy of its own data (or empty, with **Share with Empty Data**); a finished app always starts empty.
- It can't use the keychain.
- It reaches the internet, but of the local services on your Mac only those the app uses: its dev server, anything else its project runs, and ports named in its environment or `.env` files. Anything else is asked for once in the share's Live Collaboration card, like the [localhost bridge](/docs/localhost-bridge). A service you allow is your real one, not a copy; OpenTraffic warns when it looks like a database.

**Reset Data** in the card starts the copy over from its original data, and **Restart** restarts it. Stopping the share deletes the copy.

## Changes reach people live

- Changes to the windows arrive through the dev server's hot reload, as for a web page.
- When the main process's code changes, the copy restarts with it; pages stay open and calls in flight are sent again. electron-vite rebuilds the main process only with `--watch`, so without it OpenTraffic runs the project's `electron-vite build` itself.
- When the preload changes, open pages reload to pick it up.
- A finished app changes when you rebuild it.

So an agent fixing a comment works the same as on a web page: the person who left it sees the fix appear.

## Limits

- Everyone in a session uses the same copy, so they see the same data.
- Desktop-only features with no browser equivalent do nothing: tray icons, global shortcuts, screen capture, native window controls, several windows working together.
- A window that shows a remote website can't be shared.
- The dev server stops with the app in most setups, so a saved share of an app in development needs the app running.

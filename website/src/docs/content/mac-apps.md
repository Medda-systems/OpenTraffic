## Share a Mac app

A Mac app you're building with SwiftUI, AppKit, or Catalyst shows up in the menu bar under **Mac Apps**, below your web servers and Electron apps, as `Orbit` with `Mac app · ~/code/orbit` under it. **Share** works as it does for a web page: one click, the link is on your clipboard, and live collaboration is on. People who open it use the real app in their browser, with cursors and comments pinned to its buttons and labels, and nothing to install.

The list has two kinds of app:

- **Debug builds that are running:** built by Xcode, built into a project's `.build` or `dist` folder, or any app that isn't signed or is signed ad hoc, as long as it isn't in Applications.
- **Recent Xcode builds:** the newest debug build of each app from the last 30 days, while its project still exists. It doesn't have to be running.

iPhone apps you built in Xcode and installed in a booted Simulator are listed too, as `Orbit · iPhone 17 Simulator`, but can't be shared yet: their **Share** stays off.

Apps you only installed, apps that come with macOS, and apps signed by someone else's team aren't listed. Electron apps have their own list: see [Electron apps](/docs/electron-apps). Like the other lists, it shows the first 5; **Show More** reveals the rest.

**Share ▾** has **Temporary Public URL**, **Lasting Address with OpenTunnel**, and **Share with Empty Data**. A plain click on **Share** uses a temporary URL, or OpenTunnel when that's what your Share button uses.

From the terminal: `opentraffic share Orbit`, or the app's path, `opentraffic share dist/Orbit.app`. A path works for any app of yours, listed or not: one built inside a project folder, not signed or signed ad hoc, or signed with one of your own signing identities.

## How it works

A Mac app has no web page to send, so OpenTraffic sends what the app looks like and what it means. It runs a separate copy of the app on your Mac, on an off-screen display nobody sees. Viewers get its windows as pictures, sent only where something changed. Over the pictures lies an invisible layer of real web elements made from the app's accessibility tree: every button, field, and label, with its name. Comments are pinned to those elements, and clicks and typing go through them to the app. Your own copy of the app, its windows, and its data are never touched.

## What viewers can do

- Click, scroll, and type into the app. Typing goes to the field that has focus.
- Use the app's menus, in a bar above the window. A shortcut with Cmd or Ctrl that belongs to a menu item chooses that item. Copy and paste stay in the browser: your Mac's clipboard isn't shared.
- Right-click for the app's context menu, shown where the app put it.
- On a phone, or in a window narrower than 700 pixels, use the **Simple view**: the app's window as a scrollable page of text and web controls, with a small live picture of the window at the top. Two buttons in the bar switch between the window and the Simple view at any size.
- Everything [live collaboration](/docs/collaboration) does: cursors, following, pointing, drawing, and comments. A comment's label reads like `Button “Add Order”`, and a comment pinned in one view shows in the other.

Sheets, alerts, popovers, and the app's other windows show up too: sheets and popovers where the app put them, alerts in the middle, and other windows side by side, or as tabs when they wouldn't fit. A click in a window brings it to the front, so typing goes there. A tab's close button closes its window.

## Who drives it, its size, and its look

The Mac app section of the share's Live Collaboration card has three choices, kept with the share:

- **Viewers:** **Everyone can control** (the default), **Watch only**, or **Ask to control**. Watching viewers see the app and comment on it, but their clicks and typing don't reach it, and the bar above the window tells them so. With **Ask to control**, a viewer clicks **Request Control** in that bar; you get a notification and an **Allow** button on the card. Control stays with that person until you click **Take Back** or they click **Give Back**, and comes back to them if their page reconnects. Your own browser, opened with **Open as Host**, can always use the app.
- **Window size:** **Fit the viewer's browser** (the default) resizes the app's main window to fill the first viewer's browser (or the browser of the person you gave control), as far as the app's minimum size and OpenTraffic's off-screen display allow. Everyone else sees it scaled down. **The app's own size** leaves the window as the app made it.
- **Appearance:** **First viewer's** (the default) shows the app light or dark as the first viewer's browser prefers; or pick **This Mac's**, **Light**, or **Dark**. Changing it restarts the copy with the same data. Dark only works while your Mac uses the Dark appearance; otherwise the app stays light, and the card says so.

## Permissions

OpenTraffic needs two permissions to share a Mac app, both in System Settings → Privacy & Security:

- **Accessibility**, to read the app's controls and press them.
- **Screen Recording** (called Screen & System Audio Recording on recent macOS), to show the app's window, and only that window.

If you click **Share** without them, the Mac Apps list says which are missing. Click **Accessibility…** or **Screen Recording…**: macOS asks, and System Settings opens at the right list. Switch on OpenTraffic there. The share starts by itself once both are on; **Cancel** drops it. If Screen Recording stays off after you switched it on, quit and reopen OpenTraffic.

The share's Live Collaboration card shows the same buttons, or that both permissions are on. The `opentraffic` command, the REST API, and MCP don't wait: they refuse the share and say what's missing.

## The isolated copy

Each share runs its own copy of the app:

- The `.app` is copied into a folder of OpenTraffic's, with its own bundle identifier (yours with `.opentraffic` added), and signed again ad hoc. Its preferences, saved windows, and single-instance checks are its own, so it runs next to your copy.
- Its home folder is in that folder too. By default it starts with a copy of the app's data: its Application Support folder (named after the app or its bundle identifier) and its preferences. A sandboxed app's data is read from its container. **Share with Empty Data** starts it as on a first launch.
- Its preferences are kept under `<bundle id>.opentraffic` and removed when the share stops.
- What the app prints, including its `Logger` and `os_log` messages, is in the share's **Logs**.

The share's Live Collaboration card has a Mac app section with the copy's state and how many people are viewing:

- **Restart App** quits the copy and opens it again with the same data. If you rebuilt the app, the new build is copied first. Viewers stay connected and see it come back.
- **Reset Data** quits it and starts it over from the data it started with.

If the app quits by itself, viewers see that it did, and OpenTraffic opens it again once. Stopping the share, or quitting OpenTraffic, quits the copy and deletes its folder.

## Show a fix

OpenTraffic doesn't rebuild the app for you yet. After changing the code, build the app the way you usually do, then click **Restart App**, or run `opentraffic restart Orbit --app`. The share keeps its address, and viewers stay on the page.

## Comments and agents

Comments on a Mac app work as on a web page, and the [agent for comments](/docs/agents) can fix them. OpenTraffic tells it the app is a native SwiftUI or AppKit app, not HTML, and gives it:

- the element: its accessibility path, role, label, value, accessibility identifier, and window;
- the app's windows;
- the last 20 things viewers did before the comment;
- up to 40 lines of what the app printed around the comment, without macOS's own messages.

The agent works in the share's project folder, shown in the Feedback tab. By default that's the project the app is built from (Xcode's project or workspace, or the folder with `Package.swift`). When OpenTraffic doesn't know it, the comment waits and says so: choose the folder in the Feedback tab, then **Send to …**.

Give the views people comment on an identifier, and the agent finds them in the code at once: `.accessibilityIdentifier("addOrder")` in SwiftUI, the view's `identifier` in AppKit. Without one, it searches for the label's text.

Agents that read comments through MCP, the REST API, or the `opentraffic` command get the element's accessibility path as the comment's `context.selector`. The agent is told that viewers see its change once the app is rebuilt and restarted, and says so in its reply.

## From the terminal and from agents

```sh
opentraffic services                          # web servers, then the Mac apps you're building
opentraffic share Orbit                       # share it by name, on a temporary URL
opentraffic share dist/Orbit.app --via opentunnel --empty-data
opentraffic restart Orbit --app               # after a rebuild: the new build, same address
opentraffic restart Orbit --reset-data        # start over from the data it started with
opentraffic stop Orbit
```

- A name is matched against the apps `services` lists, ignoring case. When two builds have the same name, the running one wins; otherwise give the path.
- Mac apps are shared with `--via quick` (the default) or `--via opentunnel`, always with live collaboration. Sharing the same app the same way again starts that share. `--save` isn't supported.
- [REST API](/docs/rest-api): `POST /v1/shares` with `macApp` (the path or name) and `macAppData` (`copy` or `empty`); `POST /v1/shares/{ref}/restart-app` and `/reset-data`; `GET /v1/services` lists the apps under `apps`. A share without the permissions is refused with 409 `missing_permissions`; a restart whose app doesn't come back fails with 502 `restart_failed`.
- [MCP](/docs/mcp): the `share` tool takes `mac_app` and `mac_app_data`, and `restart_mac_app` restarts the app (`reset_data` to start over).

## Limits

- One share per app at a time. Stop the other share first.
- Everyone uses the same copy, so they see the same data, and one person's click is everyone's. Choose **Watch only** or **Ask to control** on the card when that's too many hands.
- The app can only look dark while your Mac uses the Dark appearance.
- No drag and drop between the app and other apps or the browser.
- There's a short delay between a click and the change on screen, longer on a slow connection.
- The copy isn't sandboxed. It runs as you, without the App Sandbox even when your app uses it, so it can reach what your app's own code can reach on this Mac. Viewers can only do what the app's windows and menus let them do, but share it with people you'd let use the app on your Mac.
- Entitlements that need your team's signature (iCloud, app groups, keychain sharing, push notifications, and the like) are left out of the copy. The card warns you, and features that use them may not work.
- From the first Mac app share until OpenTraffic quits, System Settings → Displays and Mission Control show a display called "OpenTraffic". That's where the copy's windows are kept, off screen.
- The viewer's menus leave out the Apple menu, Services, Hide, Quit, full screen, and window tiling.
- If OpenTraffic quits right after a share stops, an empty `<bundle id>.opentraffic` preferences file can stay behind. It holds no data.

## Troubleshooting

- **The app isn't listed:** only debug builds and recent Xcode builds are. Share it by its path; if it's refused, the message says why (installed, signed by another team, or an Electron app).
- **The share waits:** a permission is missing, and the Mac Apps list says which. See [Permissions](/docs/mac-apps#permissions).
- **"… is already shared by …":** that app is running in another share. Stop that one first.
- **"The window server isn't answering", or the share takes long to start:** macOS's display system is slow to answer. It happens more while another OpenTraffic or a test run has its own off-screen display; the card warns about that. Wait a moment and try again. If it keeps happening, log out and back in, or restart the Mac.
- **Something works in your copy but not in the shared one:** look at the card's warnings and the share's **Logs**.

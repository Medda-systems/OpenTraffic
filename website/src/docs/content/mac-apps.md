## Share a Mac app

A Mac app you're building with SwiftUI, AppKit, or Catalyst shows up in the menu bar under **Mac Apps**, below your web servers and Electron apps, as `Orbit` with `Mac app · ~/code/orbit` under it. **Share** works as it does for a web page: one click, the link is on your clipboard, and live collaboration is on. People who open it use the real app in their browser, with cursors and comments pinned to its buttons and labels, and nothing to install.

The list has two kinds of app:

- **Debug builds that are running:** built by Xcode, built into a project's `.build` or `dist` folder, or any app that isn't signed or is signed ad hoc, as long as it isn't in Applications.
- **Recent Xcode builds:** the newest debug build of each app from the last 30 days, while its project still exists. It doesn't have to be running.

iPhone apps you built in Xcode and installed in a booted Simulator are listed too, as `Orbit · iPhone 17 Simulator`, and share the same way: see [iPhone apps in the Simulator](/docs/mac-apps#iphone-apps-in-the-simulator).

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

- **Accessibility** (called Device Control and Data Access on macOS 27), to read the app's controls and press them.
- **Screen Recording** (called Screen & System Audio Recording on recent macOS), to show the app's window, and only that window.

If you click **Share** without them, a **Permissions for Mac Apps** window walks you through them, one step at a time:

1. **Open System Settings** asks macOS for the permission and opens the right list. Switch on OpenTraffic there. If OpenTraffic isn't in the list, drag its icon from the window into the list, or click **+** and choose it.
2. Each step ticks itself off as soon as its switch is on, and the next one starts.
3. macOS applies Screen Recording when an app starts. If its step still waits after you switched it on, click **Quit & Reopen**: OpenTraffic opens again and the share continues.

The share starts by itself once both are on; **Cancel Share** drops it. You can open the window any time from Settings → General → Mac App Sharing, which also shows whether each permission is on, with `opentraffic permissions`, or with the link `opentraffic://permissions`.

The share's Live Collaboration card says when a permission is missing, with a **Set Up…** button for the same window. The `opentraffic` command, the REST API, and MCP don't wait: they refuse the share, say what's missing, and open the window on your Mac.

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

When you or an agent save a change to the app's code, OpenTraffic builds the app, starts the new build on the same address, and puts viewers back where they were:

1. A second after the last change, it builds the project the app comes from: `xcodebuild` with the scheme that makes the app and the configuration you built (Debug) for an Xcode project or workspace, or `swift build` for a Swift package, followed by the package's own `package.sh` when it has one. Build folders (`.build`, `DerivedData`, `build`, `dist`), `.git`, and Xcode's per-user files don't count as changes.
2. While it builds, viewers keep using the running copy. If the build fails, they keep it: the errors are in the share's **Logs**, and the card shows a warning. The whole build output is in the session's `logs/build-<n>.log`.
3. When it built, the copy restarts with the new build and its data. Viewers see that it's restarting, then OpenTraffic repeats what they did since the share started or was last restarted by hand (clicks, presses, typing, menu commands), finding each element again by its accessibility path, so they land on the same screen with the same row selected. If an element is gone in the new build, it stops there.

Repeating what viewers did also repeats what changed the app's data: an order they added is added again. Use **Reset Data** to start over.

You can still build the app yourself and click **Restart App**, or run `opentraffic restart Orbit --app`; a restart you start doesn't repeat what viewers did.

## Comments and agents

Comments on a Mac app work as on a web page, and the [agent for comments](/docs/agents) can fix them. OpenTraffic tells it the app is a native SwiftUI or AppKit app, not HTML, and gives it:

- the element: its accessibility path, role, label, value, accessibility identifier, and window;
- the app's windows;
- the last 20 things viewers did before the comment;
- up to 40 lines of what the app printed around the comment, without macOS's own messages.

The agent works in the share's project folder, shown in the Feedback tab. By default that's the project the app is built from (Xcode's project or workspace, or the folder with `Package.swift`). When OpenTraffic doesn't know it, the comment waits and says so: choose the folder in the Feedback tab, then **Send to …**.

Give the views people comment on an identifier, and the agent finds them in the code at once: `.accessibilityIdentifier("addOrder")` in SwiftUI, the view's `identifier` in AppKit. Without one, it searches for the label's text.

Agents that read comments through MCP, the REST API, or the `opentraffic` command get the element's accessibility path as the comment's `context.selector`. The agent is told that OpenTraffic rebuilds the app and restarts it once it saves its change, and says so in its reply; when it's done, OpenTraffic builds right away if the code changed.

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

## iPhone apps in the Simulator

Sharing an iPhone app shows viewers the Simulator's window for its device, cut to the phone's screen in a phone frame. They tap, swipe, scroll, and type as on a phone, and comments are pinned to the app's elements, which the Simulator exposes through Accessibility. On a phone, the **Simple view** works as it does for a Mac app.

- **Share** starts the app in your booted simulator, with its **real data**: what viewers do is what you'll find there afterwards. **Reset Data** can't undo that; it only starts the app again.
- **Share with Empty Data** uses a simulator of OpenTraffic's own, `OpenTraffic · iPhone 17`, of the same kind and iOS version. It's erased before every share, the app is installed from your simulator, and it shuts down when the share stops. Your own simulator is left alone.
- If the Simulator app isn't open, OpenTraffic opens it out of sight on the off-screen display and quits it when the share stops. If it's already open, the device's window stays where it is and you see what viewers do in it. Keep that window open (it can be behind other windows, not minimized).
- Typing goes through the Simulator's hardware keyboard (**I/O → Keyboard → Connect Hardware Keyboard**, on by default), key by key on a US layout; characters no key types are pasted.
- The empty simulator shows light or dark as you or the first viewer choose; your own simulator keeps its own appearance.
- The app isn't rebuilt when its code changes: build and run it in Xcode, then use **Restart App** (with Empty Data, **Reset Data**, which installs the new build).

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
- **The share waits:** a permission is missing, and the Mac Apps list says which. Click **Set Up…**, or see [Permissions](/docs/mac-apps#permissions).
- **"… is already shared by …":** that app is running in another share. Stop that one first.
- **"The window server isn't answering", or the share takes long to start:** macOS's display system is slow to answer. It happens more while another OpenTraffic or a test run has its own off-screen display; the card warns about that. Wait a moment and try again. If it keeps happening, log out and back in, or restart the Mac.
- **"The Simulator didn't show iPhone 17":** the Simulator app is open but has no window for that device. Open it with **File → Open Simulator**, then share again.
- **Viewers see the whole Simulator window, not just the phone:** OpenTraffic didn't find the screen in the window (the card warns about it). Taps still land where viewers click.
- **Something works in your copy but not in the shared one:** look at the card's warnings and the share's **Logs**.

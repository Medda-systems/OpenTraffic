# Changelog

## 1.0.21 (20 October 2026)

- **Share Mac apps:** a SwiftUI, AppKit, or Catalyst app you're building shows up in the menu bar under **Mac Apps** and shares the same way as a web page: one click, live collaboration on. People open it in their browser, with nothing to install, and use the real app: OpenTraffic runs a separate copy of it on your Mac, out of sight, and sends its window as pictures, with its buttons, fields, and labels as real elements on the page. Running debug builds and Xcode's recent builds are listed, and installed apps that are running under **Installed**. iPhone apps you built and run in a booted Simulator are listed too, with their device, and share the same way: viewers get the device's screen in a phone frame and tap, swipe, and type into it, in your simulator with its real data or, with **Share with Empty Data**, in an erased simulator of OpenTraffic's own. From the terminal: `opentraffic share Orbit` or `opentraffic share dist/Orbit.app`. The docs have a new page, **Mac apps**.
- **Its own copy and data:** the shared copy has its own bundle identifier, preferences, and home folder, and starts with a copy of the app's data, or none with **Share with Empty Data**. Your own copy and its data aren't touched. The Live Collaboration card has **Restart App** (it picks up a new build, and viewers stay connected) and **Reset Data**. Stopping the share deletes the copy.
- **Windows, menus, and typing:** viewers click, scroll, and type into the app, use its menus in a bar above the window, choose menu items with their Cmd shortcuts, and get the app's context menus on a right click. Sheets, alerts, popovers, and the app's other windows show up too, where the app put them, with other windows side by side or as tabs. On a phone, the **Simple view** shows the window as a page of text and controls.
- **Who drives the app, its size, and its look:** on the Live Collaboration card, choose whether everyone can control a shared Mac app, viewers only watch, or they ask first (a **Request Control** button for them, an **Allow** button and a notification for you, **Take Back** when you want it back). The app's window is resized to fill the first viewer's browser, or keeps its own size if you prefer, and the app shows light or dark as the first viewer's browser prefers, or as you choose.
- **Two permissions, with a guide:** sharing a Mac app needs Accessibility and Screen Recording for OpenTraffic. When one is missing, a **Permissions for Mac Apps** window walks you through them one at a time: it opens the right place in System Settings, has OpenTraffic's icon to drag into the list when it isn't there, ticks each step off as soon as it's on, and has **Quit & Reopen** for Screen Recording, which macOS applies when the app starts. The share starts by itself once both are on. Open it any time from Settings → General → **Mac App Sharing** or with `opentraffic permissions`; a share from the terminal, the API, or MCP that's missing a permission opens it too.
- **Agents fix comments in the Swift code:** a comment's label reads like Button “Add Order”, and the agent gets the element's accessibility path, role, label, value, identifier, and window, what viewers did before the comment, and what the app printed around it. It works in the project the app is built from; when OpenTraffic doesn't know that project, the comment waits until you choose its folder in the Feedback tab. Setting `accessibilityIdentifier` on your views helps it find them.
- **A change to the code shows by itself:** when you or an agent save a shared Mac app's code, OpenTraffic builds it (`xcodebuild` for Xcode projects, `swift build` for Swift packages), restarts the copy with the new build on the same address, and repeats what viewers did so they're back on the same screen, usually within a minute. Viewers keep the running copy while it builds, and a failed build leaves it running.
- **From the terminal, the API, and MCP:** `opentraffic services` lists the Mac apps you're building, `opentraffic share` takes an app's name or path (with `--empty-data`), `opentraffic restart <share> --app` shows a new build on the same address (`--reset-data` starts over), and `opentraffic set <share> --control watch-only` (or `--appearance`, `--window-size`) changes the viewer options. The REST API takes `macApp` and `macAppData`, changes the viewer options with `macAppControl`, `macAppAppearance`, and `macAppWindowSize`, and has `/restart-app` and `/reset-data`; MCP's `share` takes `mac_app`, and `restart_mac_app` is new.
- **Answer requests to control from the terminal and agents:** `opentraffic status <share>` shows who has control of a shared Mac app set to ask to control and who asks, each with a number (`--json`, the REST API's share and MCP's `list_shares` have it under `macApp.control`); `opentraffic control <share> allow` (or `allow 3`, `allow Ada`), `deny`, and `take-back` answer as the card's **Allow**, **Not Now**, and **Take Back** do (`POST /v1/shares/{ref}/control`, MCP's `control_mac_app`); and `opentraffic watch`, webhooks, and the event API hear of each request (`control.requested`). A viewer who is turned down now reads **The host said not now** in their bar, instead of it quietly going back to **Request Control**.
- **A failed build says so:** while a shared Mac app is rebuilt, its Live Collaboration card says **Building…**; when the build fails, the card shows a warning with the compiler's first error, **Show Log** (the whole build output) and **Build Again**, and you get a notification when the card isn't in front of you. Viewers see a small banner saying the latest changes didn't build and they see the previous version. Both go away once a build succeeds. `opentraffic status <share>` shows it (`--json`, the REST API's share and MCP's `list_shares` under `macApp.build`, with the message, the build log and the command), and `opentraffic watch`, webhooks, and the event API report `build.started`, `build.failed`, and `build.succeeded`. Swift's colored diagnostics no longer hide the compiler's error behind SwiftPM's own "SwiftCompile failed" line.
- **Electron apps from the terminal, and fixes:** `opentraffic share dist/Orbit.app --name "Orbit Demo"` names the share (the name was ignored; a name another share has is refused, and an app shared before keeps its share's name), and `--via` other than quick or opentunnel is refused instead of sharing with quick. `opentraffic restart <share> --app` restarts a shared Electron app's main process with its latest code and `--reset-data` starts it over from its data, as the card's **Restart** and **Reset Data** do. A link the app opens no longer also shows as blocked in a toast when its tab opened, and `ipcRenderer.sendSync` waits while the main process restarts instead of failing.
- **The menu bar has a list for each kind:** **Localhost** for web servers, **Electron Apps**, and **Mac Apps**, each showing five before **Show More**. Before, Electron apps were mixed in with web servers under **Ready to Share**.
- **Mac Apps is always in the menu bar, with Choose App…:** when OpenTraffic finds no Mac app, the section stays and says how apps get there (run yours from Xcode, or a recent Debug build) with a **Choose App…** button; with apps listed, **Choose App…** is under them. It opens a file dialog (in Applications, or the folder you chose from last time) with the **Share ▾** choices under it, checks the app as `opentraffic share <path>` does, and shares it as a listed app, or says why it can't (an Electron app, a part of macOS, an app that can't run as a copy) with **Choose Another App…**. Apps you chose or shared stay in the list, running or not, including builds a `swift build` or a package script left in `dist/`; **Remove from List** takes one out. **Share a Mac App…** in the File menu, and in the main window when it has no shares, opens the same dialog.
- **More of an app's data comes along:** a share with data now also copies a Core Data or SwiftData store at the top of Application Support (`default.store`, with its `-wal` and `-shm` files) for an app that uses one, the App Group folders the app names, and an Application Support folder named after its bundle identifier where the copy looks for it. What can't come along is on the Live Collaboration card instead of silently missing: a folder macOS didn't let OpenTraffic read (it says what to allow), App Group data the copy may not find, and the app's iCloud data and keychain items. Your own data is still only read.
- **Share installed apps, by other developers too:** TextEdit, Calculator, App Store apps, and other developers' apps can be shared like your own, as a copy with a copy of their data (or none). The installed apps that are running are under **Installed** in the menu bar's Mac Apps, collapsed below your own apps, and `opentraffic services` lists them after your own (`installed: true` in `GET /v1/services`, a share's `macApp`, and MCP's new `list_mac_apps`). The first share of one says on its card that viewers use a copy of the app with a copy of its data, until **Got It**. Apps that can't run as a copy are refused before anything starts, with the reason: apps that use CloudKit (MindNode, many App Store apps), which stops a copy at launch, and parts of macOS like the Dock. The copy runs as `TextEdit (Shared)`, so AppleScript and Shortcuts still find your own TextEdit; it opens no files or links for macOS, has no extensions, and never updates itself. Tested on macOS 27: TextEdit, Calculator, CotEditor, and MarkEdit work; MindNode is refused.
- **Copies start cleaner:** a document app's copy opens a new document instead of its Open dialog, Open and Save dialogs start in the copy's own Documents folder, apps that use Sparkle don't ask viewers about updates, and the copy's entitlements that only Apple's own apps may have are left out (TextEdit's and Calculator's copies wouldn't start otherwise). The windows a copy saves in your temporary folder are deleted when the share stops.

## 1.0.20 (18 October 2026)

- **Share Electron apps:** an Electron app you're building shows up in the menu bar under **Ready to Share**, next to your web servers, and shares the same way: one click, live collaboration on. People open it in their browser, with nothing to install, and use it for real: its windows come through the share, and its main process runs as a second copy on your Mac that answers them. A finished app you built (an `.app` from electron-builder, Forge, or similar) can be shared too while it's open; apps you only installed aren't listed. From the terminal: `opentraffic share 5173` or `opentraffic share dist/mac-arm64/Orbit.app`. The docs have a new page, **Electron apps**.
- **Sandboxed:** the copy can read the app's project and nothing else in your home folder, writes only a throwaway copy of the app's data (a finished app's starts empty), can't use the keychain, and reaches only the local services the app uses; any other one is asked for once. **Reset Data** starts it over.
- **Desktop features in the browser:** open dialogs ask the viewer for a file, saved files download, links open in a new tab, notifications show as toasts, and the app's menus are in a small **desktop preview** bar.
- **Fixes reach people live:** changes to the app's windows arrive through hot reload, changes to its main process restart the copy without reloading anyone's page, and a changed preload reloads open pages. An agent fixing a comment works as it does on a web page.

## 1.0.19 (18 October 2026)

- **Comments from people you trust start the agent without waiting for you:** people you made **Trusted** by name in Live Collaboration are no longer held by the hourly limit on automatic runs. For everyone trusted through **New people can**, the limit is higher: 10 runs per visitor and 30 per share each hour (was 3 and 10).
- **A comment that waits says why:** in the Feedback tab, a comment that didn't start the agent by itself shows the reason next to **Send to …**: the person isn't trusted, it reads like instructions, or the hour's runs are used up. Before, the only sign was a notice that went away.

## 1.0.18 (17 October 2026)

- **Pick the agent's model:** Settings → Integrations → Agent for comments has a **Model** menu, one choice per agent: its own default (shown with what that is), the models it offers, or any name under **Other…**. OpenTraffic asks the agent: Codex's model catalog, opencode's models from the providers you've set up (grouped by provider), and Claude Code's aliases (Fable, Opus, Sonnet, Haiku); Cursor can't list them, so you type one. The Feedback tab shows the model while the agent works. Presets you hadn't changed are updated to pass it on.

## 1.0.17 (17 October 2026)

- **The page catches up by itself:** when a fix lands, or the share's project files change, every page in the session updates without a reload, even on a plain static server. Only what changed is replaced, so a comment being written, text typed into the page, the open comment, and the scroll position stay as they were; someone typing into the page gets a pause first. Changed stylesheets swap in without a flash. Dev servers with hot reload are left to it, and a page its scripts build is reloaded once nobody is busy, with the open comment brought back.
- **The picture of a fix shows the fix:** it's taken once the page has caught up, instead of from the page as it was.
- Agents no longer ask people to reload the page to see a fix.

## 1.0.16 (17 October 2026)

- **Agents don't trip over the screenshot folder:** the agent OpenTraffic starts for a comment often ran `mkdir -p /tmp/opentraffic` together with its `opentraffic` commands, and the whole line was refused, so opencode stopped after claiming the comment and Claude Code gave up. Making that folder is allowed now, and the agent is told to run each command on its own and to try a refused one again by itself. Presets you hadn't changed are updated.
- **A run that stops partway says so:** an agent that claims a comment but ends without replying, resolving, or releasing it shows as **stopped before answering the comment**, instead of finished.
- **Pictures are about the commented element:** a comment's picture is framed on the element (or the area dragged out) with a little of the page around it, instead of a large part of the page; the picture of the fix is framed the same way.
- **See it large, in place:** click a comment's picture to see it large, over the page or in the Feedback tab, instead of in a new tab or window. Esc, or a click beside it, closes it.
- **Hold to see before:** once a fix has its picture, a comment shows one picture, **After**, and **Hold to see before** shows the original for as long as you hold it, on the page and in the Feedback tab.

## 1.0.15 (17 October 2026)

- **Agents work without MCP:** the agent OpenTraffic starts for a comment reaches it with the `opentraffic` command when OpenTraffic's MCP server isn't set up for it, so Claude Code, Codex, and opencode work with nothing to set up. Their shell runs only OpenTraffic's comment commands, and OpenTraffic puts its own `opentraffic` first on their PATH, whether or not you linked the command. Codex's sandbox reaches OpenTraffic and nothing else; if a Codex version ever let the web through, OpenTraffic doesn't start it. Presets you hadn't changed are updated.
- **An agent can't slip out of its comment:** a process an agent starts and then lets go of (so it no longer runs under the agent) may do nothing at all; before, it could do anything the `opentraffic` command can.
- A run that ends without touching its comment shows as failed, saying it couldn't reach OpenTraffic, instead of finished.
- `opentraffic screenshot -o FOLDER/` saves into a folder, made if need be, under the usual name. In a sandbox without network, the `opentraffic` command says so instead of asking whether OpenTraffic is installed.

## 1.0.14 (16 October 2026)

- **Following is smooth:** when you follow someone, your page glides along with their scrolling and keeps up with them, instead of trailing behind in steps.
- **Drawing:** strokes are smooth curves, drawn out at the pace they were made, and the drawer's pointer moves with the line instead of lagging behind it.
- Fixed: a comment you had open closed by itself when an agent resolved it; it now stays open, showing it's fixed, until you close it.
- Fixed: pointing at something showed the person's name twice, on their pointer and on the pulse.

## 1.0.13 (16 October 2026)

- **Suggest an edit:** in the comment box, **Edit text** and **Edit style** change the element right on the page while you work. Colours come from a palette, the colours the page already uses, any colour, or the eyedropper; size, padding, and corners have sliders; weight is a row of samples. Each change has its own undo, and the comment box stays put while the element changes size. The comment carries the exact change, old → new (colours as hex, with swatches); anyone can **Preview on the page**, and agents apply it as given.
- **Agents start in the right file:** comments now record the element's selector and key styles, and on development builds of React, Vue, Svelte, and Angular, the component and its source file (`HeroActions · src/components/Hero.tsx`). You and your agent see it; other visitors don't.
- **Comment on an area, and draw:** drag a box in comment mode to comment on a region, like the gap between two cards. The new pen draws strokes everyone on the page sees for a few seconds; nothing is saved.
- **See it at their size:** the people list shows everyone's window size and system, and **View** shows the page they're on at exactly their size, as a phone, tablet, or browser window over your page. It follows them to other pages, shows their pointer, turns when their phone does, and fits your window or shows actual size. OpenTraffic's Live Collaboration card shows everyone's size too.
- **Phone or Desktop:** the new View button in the pill shows the page as a phone (390 × 844, and it turns), or as your own window. Comment, point, draw, and suggest edits inside any device view, someone's or your own phone: you pick on the page in the device, the comment box and bubbles open beside it at full size, always in the same place (centred, so they never clip), and the comment records the device's size.
- **Lead in a phone:** when the host leads with Phone open, everyone following sees the same phone, its page and scrolling, and turns with it. Back to Desktop, everyone has their own window again. **Followers match my window** gives them the host's exact window size instead.
- **Who can do what:** give each person a role in the Live Collaboration card (trusted, can comment, or view only), and choose what new people can do. View-only people can look, point, and draw, but not comment. **Only trusted people's comments start your agent by itself now**; others wait for **Send to …**.
- `opentraffic comments` shows suggested edits, the element's source, and an area's size; the API and MCP tools return `context`, `edits`, and `area` with comments, and `role` and `device` with people.
- Fixed: comment bubbles and the comment box scroll when they're taller than the window, and their buttons (Post, Reply, Resolve) stay in view. Local builds record the SDK they're built with, so they look exactly like releases (before, a fix could look right locally and still be wrong in the release, like the menu icons in 1.0.10).

## 1.0.12 (15 October 2026)

- **Agent marks in Settings are white in dark mode too:** the Claude Code, Codex, Cursor, and opencode marks in Settings → Integrations → Agent for comments now follow the menu's text colour like the rest of the menu; 1.0.11 fixed the other menus but not this one.

## 1.0.11 (15 October 2026)

- **Menu icons are really white in dark mode now:** 1.0.10's fix didn't reach the released app. The Claude Code, Codex, Cursor, and opencode marks in Settings → Integrations, and the Cloudflare, OpenTunnel, Tailscale, and ngrok marks in the New, New Tunnel, and Share menus, now follow the menu's text colour: white in dark mode, black in light mode.

## 1.0.10 (15 October 2026)

- **Icons in menus follow the menu in dark mode:** the Claude Code, Codex, Cursor, and opencode marks in Settings → Integrations, and the Cloudflare, OpenTunnel, Tailscale, and ngrok marks in the New, New Tunnel, and Share menus, are now white in dark mode like the rest of the menu instead of dark. The custom agent's sparkle is now the same size as the other marks.

## 1.0.9 (15 October 2026)

- **See agents at work:** a coding agent working on a comment now claims it (`claim_comment`, or `opentraffic claim`). Everyone on the page sees it in the session, its cursor beside the element ("✦ Claude Code · working") and what it's doing, and two agents never take the same comment. Claims lapse after 15 minutes unless renewed, so a stopped agent never leaves a comment stuck.
- **"Fixed: take a look":** when someone else resolves a comment, its author is told, right away or the next time they open the link. **Take a look** opens the element, with **Before** and **After** pictures, and asks them to confirm the fix or reopen it. The Feedback tab shows who resolved each comment and whether its author agreed, and OpenTraffic can notify you when they do.
- **Let OpenTraffic start your agent:** in Settings → Integrations, choose Claude Code, Codex, Cursor, opencode, or your own command. **Send to …** on a comment runs it in the project's folder, or it can run by itself for new comments when no agent is watching. It uses the agent's own subscription or API key; OpenTraffic doesn't run any model.
- **Work on a branch:** turn it on for a collaborative share and, while it runs, the project is on a branch of its own, `opentraffic/<share>-<date>`. Each resolved comment's changes are committed there, and stopping the share merges the branch back when that's clean, leaving it checked out (with the reason) when it isn't. Your uncommitted changes stay uncommitted. `opentraffic share --branch` and `set --branch on|off` do the same from the command line. For a project without git, turning it on offers to set git up: a local repository, a `.gitignore`, and a first commit that leaves out dependencies, `.env` files, and very large files.
- **Agents look like themselves:** Claude Code, Codex, Cursor, and OpenCode show their own marks (Claude and Codex in their colours) in the session, on the page, in the Feedback tab, and in Settings. Other agents show a sparkle.
- **Agents can't be talked into much:** an agent OpenTraffic starts may only work on its one comment (it can't share, stop, or see anything else), its preset has no shell or web access, replies and progress notes lose anything that looks like a secret before visitors see them, automatic runs have an hourly budget, comments that read like instructions wait for you, agents get visitors' words clearly marked as untrusted, invisible characters are removed from everything visitors send, and a branch only merges by itself when its fixes look like ordinary page changes. Nothing looks different unless one of these steps in.
- **Passwords for temporary and OpenTunnel shares:** **Protection…** now offers a password for Quick Tunnels and OpenTunnel too. OpenTraffic checks it on your Mac before anything reaches your app: visitors see an OpenTraffic sign-in page (and, with live collaboration, can give their name there), **Copy Link with Password** sends a link that signs them in directly, and scripts can use basic auth. A new password signs everyone out without restarting the share. `opentraffic protect <share> password` works for them, and `opentraffic password` prints the link.
- `opentraffic claim`, `release`, `screenshot --after`, and `comments` showing who's on a comment and who resolved it; `comment.claimed` and `comment.released` events; REST `…/claim` and `screenshot?which=after`. `opentraffic` uses `OPENTRAFFIC_CLIENT` as its name when it's set.

## 1.0.8 (15 October 2026)

- **The command line and coding agents just work:** `opentraffic` and the MCP bridge are now part of OpenTraffic itself. They talk to the app over a private connection that only OpenTraffic's own signed tools can use, so there's no `opentraffic setup`, no token, no Integrations switch to turn on, and no "Allow" dialog before sharing. If OpenTraffic isn't running, they start it in the background. Other apps still use the local API, with its token, and still ask.

## 1.0.7 (15 October 2026)

- **Online as soon as it's online:** a share now shows as online within about a second of its link working, instead of up to 45 seconds later (ngrok and custom domains) or 9 seconds (OpenTunnel). While a share starts, OpenTraffic checks every second, and a provider's "not ready yet" page no longer counts as a failure.
- **`opentraffic share` and `start` say "live" only once the link answers**, and "starting" (with what it's waiting for) when the provider needs longer, such as a custom domain whose DNS record was just replaced.
- **API servers look healthy:** a share whose server answers 404 (or anything else) at `/` shows as working when the public URL gives the same answer as the local server.
- **Custom domains:** a share can reuse the name of one you removed; OpenTraffic numbers the Cloudflare tunnel if the name is taken, instead of failing with "You already have a tunnel with this name". A tunnel that's already serving no longer shows Cloudflare's lagging "inactive" status.
- **One-click tools:** OpenTraffic installs what it shares through for you. The setup assistant, Settings, and New Tunnel show an **Install** button for Cloudflare's, OpenTunnel's, and ngrok's tools that says what it downloads (version, size, where from, who signed it), shows its progress, and checks the download against its maker's published checksum or Developer ID signature before installing it into OpenTraffic's own folder. No Homebrew, Terminal, or password needed. ngrok's account connects by pasting your authtoken. Tailscale installs from its own signed, notarized installer, opened in Apple's Installer (or from the App Store or Homebrew, under ⋯).
- **`opentraffic install cloudflared`** (or `opentunnel`, `ngrok`, `tailscale`) does the same from the command line, and `opentraffic doctor` says which to run.

## 1.0.6 (14 October 2026)

- **Clearer when temporary URLs can't work:** if your network's DNS filter blocks Cloudflare's temporary tunnels (some ISPs' "safe browsing" filters do), OpenTraffic and `opentraffic doctor` say so, instead of "cloudflared exited with status 1". Other cloudflared failures now say what went wrong too.
- **Host header fix for Tailscale shares:** Vite, Next.js, and other dev servers that reject your tailnet name now work with **Fix Host Header**, like the other providers.
- **Refused up front:** sharing with Tailscale Funnel when it isn't allowed, or on a hostname that already has a DNS record, is refused before OpenTraffic asks you anything, and nothing is left behind. From the command line, add `--replace-dns` to replace the record.
- **ngrok request inspector:** response bodies are shown decoded (no more chunk sizes around JSON, and gzip is unpacked), new requests no longer overlap in the list, and the inspector fits narrower windows.
- **Health checks:** a new custom-domain hostname that this Mac looked up too early no longer shows as failing while everyone else can open it.
- `opentraffic stop` waits until the share has stopped, so the next command can change it right away. Browser errors list each page once, the Logs tab names the right connector, the reply field is ready to type in, and Settings no longer suggests a token can turn on email sign-in when Cloudflare refuses it.

## 1.0.5 (13 October 2026)

- **Signed by Medda Systems and notarized by Apple:** OpenTraffic now opens like any other app, from the disk image, Homebrew, or the installer, with no trip to Privacy & Security. The first update to this version may ask once for access to OpenTraffic's saved Keychain items, because the app's signature changes.
- **`opentraffic watch` stops when nothing reads it anymore**, so `opentraffic watch | head -1` and similar pipelines end instead of running on.
- **Agent skill:** `curl -fsSL https://opentraffic.dev/skill | sh` teaches Claude Code, Codex, opencode, and other agents to share your dev server and act on feedback. See https://opentraffic.dev/docs/agent-skill.

## 1.0.4 (11 October 2026)

- **A complete `opentraffic` command:** everything the app's windows do, from a terminal. List and inspect shares (with each hop's health and who's there), share through any provider including custom domains (with DNS replacement), Tailscale Funnel, and password-protected ngrok, change settings, protect, rename, restart, and remove shares, read and answer feedback, follow logs and live events, see the web servers running on this Mac with their uptime, run projects, and show QR codes. Every command takes `--json` and returns meaningful exit codes. It comes with the app: the installer links it into your PATH and OpenTraffic keeps it linked whenever it runs from Applications, however you installed it (Settings → General turns that off). `opentraffic setup` turns on the local API it uses, and the command starts OpenTraffic in the background when needed, without opening a window.
- **Local API:** new endpoints for status, local services, projects, Cloudflare domains, share details, editing, restarting, removing, protection, passwords, and deleting comments. Shares for a provider that isn't set up are refused instead of being created in a failed state.

## 1.0.3 (9 October 2026)

- **OpenTunnel branding:** Anomaly’s logo now appears throughout the app, including both New Tunnel menus, Settings, the sidebar, and connection details.
- **Custom-domain DNS replacement:** explicitly choose to replace an existing hostname’s DNS route when creating a Cloudflare tunnel. CNAMEs are updated in place; A/AAAA records are replaced with the new tunnel’s CNAME. Replacement is refused when unrelated record types such as TXT or MX are present.
- **Clearer labels:** OpenTunnel shares show “anyone with the link”, and coding-agent replies are labeled “Agent” in the Feedback view.
- **Documentation:** installation, providers, collaboration, CLI, REST API, MCP, and troubleshooting guides are now available at https://opentraffic.dev/docs.

## 1.0.2 (8 October 2026)

- **One-line install:** `curl -fsSL https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/install.sh | sh` downloads the latest release, checks its checksum and signature, and puts OpenTraffic in Applications.
- **Homebrew:** current Homebrew asks you to trust casks from other taps first; the install instructions now include `brew trust --cask medda-systems/tap/opentraffic`.
- Builds with Swift 6.3, and every release is now built, signed, and published automatically.

## 1.0.1 (8 October 2026)

- **Automatic updates.** OpenTraffic checks for new versions once a day and installs them, verified with Medda Systems' signing key. **Check for Updates…** is in the app menu, and Settings → General has the options.
- **Homebrew:** `brew tap medda-systems/tap`, `brew trust --cask medda-systems/tap/opentraffic`, then `brew install --cask opentraffic`.
- Stopping a share closes every visitor connection, including ones the tunnel kept open.
- Webhook signing secrets are kept in the Keychain.
- The `opentraffic` command checks its arguments and accepts `host:port` without `http://`.

## 1.0.0 (8 October 2026)

First public release.

- Share local web servers through Cloudflare Quick Tunnels, your own Cloudflare domains, Tailscale (tailnet or Funnel), ngrok, and OpenTunnel (a lasting address, encrypted end to end), from the menu bar.
- **Ready to Share** lists the web servers running on this Mac, keeps their uptime, and opens one in the browser with a click.
- Health checks follow each share along its whole path (local server → this Mac → provider → public URL) and offer fixes such as the Host header fix.
- Protected shares: ngrok passwords or Google/GitHub sign-in, and Cloudflare Access email codes for custom domains.
- Live collaboration on Quick Tunnel and OpenTunnel shares:
  - presence, cursors, and following the host
  - comments pinned to elements, with screenshots and browser errors
  - pointing
  - a localhost bridge for apps made of several local services
- A local API, MCP server, and signed webhooks, so coding agents and your own tools can share servers and act on feedback.
- The `opentraffic` command and `opentraffic://` links for scripts, Shortcuts, Raycast, and Alfred.

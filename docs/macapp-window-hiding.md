# Keeping a shared Mac app's windows off screen

A shared Mac app runs for real on the host's Mac. The user must never see its windows, it must
never take focus, and ScreenCaptureKit (SCK) must still be able to capture every window. This is
what was tried (macOS 27, MacBook display plus an external display above it, 19 October 2026), what
works, and what OpenTraffic does: `MacAppWindowHider` and `OffscreenDisplay` in
`Sources/OpenTrafficCore/MacApp/WindowHiding.swift`.

## What was tried

Test apps were a small AppKit app (a titled window, an optional second window and a sheet on
timers), and Calculator. A sampler read `CGWindowListCopyWindowInfo` every few milliseconds to see
where the app's windows were and whether they were on screen.

| Approach | Result |
| --- | --- |
| (a) Launch with `NSWorkspace.OpenConfiguration` (`activates = false`, `hides = true`, `createsNewApplicationInstance = true`), set each window's `AXPosition` to `-20000,-20000` while hidden, then `NSRunningApplication.unhide()` | AX accepts the position while the app is hidden, but on unhide AppKit pulls the window back onto the nearest screen (top-left of the external display, `-403,-1410`), in full view. Frontmost app and menu bar unchanged. |
| Set `AXPosition` again after unhide | Clamped too: AppKit keeps about 40 pt of the window on a screen (`x = -863` against a screen starting at `-403`). |
| Positions far right (`5000,200`), far down (`200,20000`), far left at screen height | Moved back inside the main display as the app unhides (`1210,200`, `200,760`, `0,200`), where the user sees it whenever that display shows its desktop. |
| Keep the app hidden (never unhide) | The window keeps `-20000,-20000`, but hidden windows are ordered out and SCK refuses to capture them (`SCStreamErrorDomain -3811`). |
| Minimize the window (`AXMinimized`) | Ordered out as well: not capturable (`-3811`). |
| `AXParent` of a window | It is the application element; there is no frame to move. |
| Leave the window on screen behind everything | Rejected: wherever nothing covers it, the user sees it. |
| (b) A secondary virtual screen: a `CGVirtualDisplay` (CoreGraphics, the class DeskPad and BetterDisplay use), move the windows onto it while hidden, then unhide | **Works.** The windows stay where they were put (they are on a screen, so AppKit has nothing to correct), are on screen for SCK and capture at full quality, nothing shows on a physical display, the frontmost app and menu bar don't change, and none of the user's windows move. |

Other notes from the spike:

- `NSRunningApplication.unhide()` returns `false` here even when it works; don't rely on its result.
- A window an app shows on a physical display whose current Space is a full-screen app lands in
  that display's desktop Space: `kCGWindowIsOnscreen` is false and `kAXWindows` doesn't list it
  (accessibility only sees the current Spaces). `_AXUIElementCreateWithRemoteToken` (AltTab's way
  to reach windows on other Spaces) finds nothing on macOS 27.
- `kAXWindowCreatedNotification` can arrive a few hundred milliseconds after the window shows;
  `kAXFocusedWindowChanged` and `kAXMainWindowChanged` come within about 10 ms.
- Listing window ids (`CGWindowListCreate`, private to Swift but exported) costs about 0.5 ms;
  `CGWindowListCopyWindowInfo` for on-screen windows 1.5 to 2.8 ms.

## The approach

1. **The off-screen display.** `OffscreenDisplay.acquire()` makes one virtual display per process
   (shared, reference-counted): 1920 x 1200 pt at 2x (3840 x 2400 px), named "OpenTraffic", vendor
   id `0x4F54`. macOS first attaches a new display to the right of the main one; it is moved
   diagonally off a corner of a physical screen so it touches the user's screens at one point only
   (here `1710,1112`, the main display's bottom-right corner), and moved again if the user's
   arrangement changes (`CGDisplayRegisterReconfigurationCallback`). Coming online takes 1.1 to
   2.2 s; `ready()` waits for it.
2. **Launch.** `MacAppWindowHider.launch(bundle:environment:arguments:)` opens a fresh instance
   with `activates = false`, `hides = true`, `createsNewApplicationInstance = true`,
   `addsToRecentItems = false`, waits for its first accessibility window (up to 10 s), moves every
   window onto the off-screen display (cascaded 24 pt, clear of that display's menu bar), then
   unhides it. Hidden windows are ordered out, so moving them can't flash anything; once unhidden
   they are ordered in on the off-screen display, where SCK captures them. About 0.9 to 1.4 s
   after the display is ready for the test app, 2.9 to 3.1 s for Calculator (its own start-up).
3. **Later windows.** `keepOffScreen(pid:)` installs an `AXObserver` for window created, focused
   window changed and main window changed (on the app) and moved (on each window), plus a
   watchdog: every 16 ms it lists on-screen window ids, describes only new ones (and ones still
   waiting to be moved), and sweeps the app when one of its windows touches a physical screen.
   Sheets stay attached to their parent and move with it.
4. **Reading them.** `windows(pid:)` returns `HiddenWindow`s: the `CGWindowID` (for
   `SCShareableContent` / `SCContentFilter(desktopIndependentWindow:)`), the `AXUIElement` and the
   frame (global, top-left origin).
5. **Stopping.** `release(pid:)` quits the app (forcibly after 2 s), stops watching it, and drops
   the display when no app is left. The app must go first: when a display goes away, macOS moves
   its windows onto a screen the user sees.

The Dock shows the shared app's icon while it runs; the app never becomes active, so the menu bar
never switches to it.

## Limits

- **A window the app opens later at a fixed position on a physical screen** (an explicit frame,
  a panel centered on the user's main screen) can be visible there for one to three frames
  (measured 10 to 45 ms, during its fade-in animation) before it is moved. Windows opened while
  launching never show; windows that cascade from the app's own windows and panels centered on the
  app's screen open on the off-screen display (in the test, Calculator's About panel opened
  centered on it).
- **If that physical display shows a full-screen app** at that moment, the window goes to the
  display's desktop Space instead: nobody sees it, but accessibility can't reach it and SCK can't
  capture it until the user switches to that Space, when it is moved within a tick (a flash during
  the Space animation). Viewers miss such a window until then.
- **Private API.** `CGVirtualDisplay` (CoreGraphics), `_AXUIElementGetWindow` and
  `CGWindowListCreate` are undocumented. They have been stable for years (DeskPad, BetterDisplay,
  yabai, Hammerspoon, AltTab rely on them), OpenTraffic isn't distributed through the App Store, and
  every call is checked: `OffscreenDisplay` throws `.unavailable` if the classes or selectors
  change.
- **The display is visible to the system.** While an app is shared, System Settings > Displays,
  Mission Control and display-arranging tools show an "OpenTraffic" display; it has its own menu
  bar (and Dock, if the Dock is set to follow the pointer). The pointer could only reach it through
  the single corner point.
- **If OpenTraffic quits or crashes** without releasing, the display disappears with the process
  and macOS moves the shared app's windows onto the user's screens.
- **Accessibility is required** (`MacAppWindowHider.isPermitted`); capture needs Screen Recording.
  Without them `launch` throws `.notTrusted` and the tests skip.
- The watchdog costs one 0.5 ms window-id list every 16 ms while an app is shared
  (`watchdogInterval` changes it).

## Tests

`Tests/OpenTrafficCoreTests/MacAppWindowHidingTests.swift`: the corner placement for several
display layouts, and, with Accessibility and Screen Recording (skipped otherwise, as on GitHub
Actions), an end-to-end run that shares `Examples/macapp-orbit/dist/Orbit.app` when it is built and
Calculator otherwise. It checks that no window was ever on a physical screen while launching (a
4 ms CGWindowList sampler), that every window is on the off-screen display, that
`SCShareableContent` lists them on screen and a capture has real pixels, that a window opened
later (the About panel) ends up off screen and any visibility lasts under 250 ms, that the app is
never active, frontmost or the menu bar owner, and that releasing quits it and removes the display.

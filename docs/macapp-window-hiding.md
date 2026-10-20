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

1. **The off-screen display.** `OffscreenDisplay.shared()` makes one virtual display per process,
   on first use, and keeps it until the process exits: 1920 x 1200 pt at 2x (3840 x 2400 px), named
   "OpenTraffic", vendor id `0x4F54`. macOS first attaches a new display to the right of the main
   one; it is moved diagonally off a corner of a physical screen so it touches the user's screens at
   one point only (here `1710,1112`, the main display's bottom-right corner), clear of other
   processes' OpenTraffic displays, and moved again if the arrangement changes. Coming online takes
   1.1 to 2.2 s; `ready()` waits for it (and throws after 10 s). See "Lifetime" and "Deadlines"
   below.
2. **Launch.** `MacAppWindowHider.launch(bundle:environment:arguments:)` opens a fresh instance
   with `activates = false`, `hides = true`, `createsNewApplicationInstance = true`,
   `addsToRecentItems = false`, waits for its first accessibility window (up to 10 s), moves every
   window onto the off-screen display (cascaded 24 pt, clear of that display's menu bar), then
   unhides it and waits (up to 2 s) until its windows are in the window server's on-screen list.
   Hidden windows are ordered out, so moving them can't flash anything; once unhidden they are
   ordered in on the off-screen display, where SCK captures them. About 0.9 to 1.4 s after the
   display is ready for the test app, 2.9 to 3.1 s for Calculator (its own start-up). If the windows
   can't be moved (a window-server deadline passed), the app is quit while still hidden and the
   error is thrown.
3. **Later windows.** `keepOffScreen(pid:)` installs an `AXObserver` for window created, focused
   window changed and main window changed (on the app) and moved (on each window), plus a
   watchdog: every 16 ms, on its own queue, it lists on-screen window ids, describes only new ones
   (and ones still waiting to be moved), and sweeps the app when one of its windows touches a
   physical screen. Sweeps run one per app at a time; the moves themselves run off the main thread.
   Sheets stay attached to their parent and move with it.
4. **Reading them.** `windows(pid:)` returns `HiddenWindow`s: the `CGWindowID` (for
   `SCShareableContent` / `SCContentFilter(desktopIndependentWindow:)`), the `AXUIElement` and the
   frame (global, top-left origin).
5. **Stopping.** `release(pid:)` quits the app (forcibly after 2 s) and stops watching it. The
   display stays for the next share. The app must go before the process does: when a display goes
   away, macOS moves its windows onto a screen the user sees.

The Dock shows the shared app's icon while it runs; the app never becomes active, so the menu bar
never switches to it.

## Lifetime: one display per process, kept

The display is made the first time a process shares an app and lives until the process exits;
`release(pid:)` never removes it. Two reasons:

- **A second display in one process never comes online.** After the first `OffscreenDisplay` was
  released, the first virtual display stayed online and every later one made in the same process
  never appeared in the display list, so `ready()` gave up and the second hidden launch put the
  app's windows on the user's screen (found on 2026-10-19 while building the input tests). Reusing
  the one display avoids that entirely; the second launch in a process is now covered by a test.
- **Making and removing displays is the window server's most fragile path** (see "Deadlines").
  Doing it once per process instead of once per share keeps it rare.

`OffscreenDisplay.shutdown()` exists for tests and experiments only: it lets go of the display and
refuses to make another one in that process (it would never come online). Nothing in the app or the
test suites calls it; the display goes away with the process.

The cost: once something was shared, System Settings > Displays and Mission Control show the
"OpenTraffic" display until OpenTraffic quits.

## Deadlines: the window server must never take the Mac down

On 19 October 2026 around 16:09 the Mac's whole display system hung for hours:
`CGGetActiveDisplayList`, `screencapture` and `system_profiler` blocked in every process until the
user logged out. Three agents were running the full `swift test` at the same time; each run made
and removed its own virtual display under heavy load, and a test's main thread sat in a
display-configuration call that never returned. Each process also re-placed its display from
inside its display-reconfiguration callback, on the main thread, so every display the other runs
added or removed set off another configuration in each of them. What exactly wedged the window
server is not known; the code now avoids every ingredient:

- Every display-configuration and display-list call (making the display, waiting for it to come
  online, `CGGetActiveDisplayList`, `CGConfigureDisplayOrigin`) and every window move runs on a
  serial background queue (`WindowServerCalls`), never on the main thread, with a deadline: 10 s to
  make the display (`OffscreenDisplay.createTimeout`), 2 s per call (`callTimeout`). A call past its
  deadline throws `OffscreenDisplay.Failure.timedOut`; while it is still stuck, later calls fail at
  once with `.windowServerNotResponding` instead of queueing behind it, and work again when it
  returns. A stuck window server costs one share, not the app (and not the Mac).
- Accessibility calls to the shared app time out after 2 s (`AXUIElementSetMessagingTimeout`, AX's
  own default is 6 s).
- Nothing is reconfigured from inside the display-reconfiguration callback: it schedules a check
  100 ms later (a burst of changes is handled once) that runs on the background queue.
- The display's bounds and the physical screens' frames are cached (refreshed when the display is
  made, checked, moved, and after every display change), so `isVisible` and the watchdog's checks
  ask the window server nothing beyond the window list.
- The display lives as long as the process, so it is made once, not once per share or test.
- Tests take a cross-process turn (below) that a test process keeps until it exits, so parallel
  `swift test` runs never have two virtual displays at once.
- Two processes that each keep a virtual display and capture with ScreenCaptureKit make replayd
  stall (see "Taking turns"). The app keeps one display, but a `swift test` run on the same Mac while
  OpenTraffic shares an app adds a second one.

The private class may still hold window-server state that only a logout clears; this prevents, it
can't repair. If the display list hangs (a one-line `CGGetActiveDisplayList` probe takes more than
a second), stop running display tests and log out and back in.

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
- **If OpenTraffic quits or crashes** while an app is shared, the display disappears with the
  process and macOS moves the shared app's windows onto the user's screens.
- **Accessibility is required** (`MacAppWindowHider.isPermitted`); capture needs Screen Recording.
  Without them `launch` throws `.notTrusted` and the tests skip.
- The watchdog costs one 0.5 ms window-id list every 16 ms while an app is shared
  (`watchdogInterval` changes it).

## Tests

`Tests/OpenTrafficCoreTests/MacAppWindowHidingTests.swift`: the corner placement for several
display layouts (and clear of another process's display), the deadlines (a stuck call throws in
time, later calls fail at once until it returns), the cross-process lock, and, with Accessibility
and Screen Recording (skipped otherwise, as on GitHub Actions), two end-to-end runs on the Orbit
fixture (`Examples/macapp-orbit`, built by the tests when missing):

- one checks that no window was ever on a physical screen while launching (a 4 ms CGWindowList
  sampler), that every window is on the off-screen display, that `SCShareableContent` lists them
  on screen and a capture has real pixels, that a window opened later (the About panel) ends up
  off screen and any visibility lasts under 250 ms, that the app is never active, frontmost or the
  menu bar owner, and that releasing quits it and keeps the display;
- the other launches Orbit twice in one process with the sampler running and checks that neither
  launch was ever visible on a physical screen and that both used the same display.

Every test that launches the fixture goes through `OrbitFixture.launch()` /
`withOrbitFixture` in `MacAppFixtureSupport.swift`, so it is launched by `MacAppWindowHider`: never
activated, its window on the off-screen display. That matters for the accessibility tests: a
window merely parked far off screen keeps most of it off every display, and AppKit relayouts the
off-screen rows of a list endlessly while accessibility reads them.

**Taking turns.** Every test that launches the fixture, makes the display or captures windows
holds a `MacAppFixtureTurn` for the whole test (`withOrbitFixture` does it; the capture suite uses
the `.macAppFixtureTurn` trait). Within a process the turn passes from test to test in order (Swift
Testing runs suites in parallel). Across processes it is a directory made with `mkdir`,
`$TMPDIR/opentraffic-macapp-fixture.lock`, with the holder's pid in `owner`, and a test process
keeps it from its first Mac app test until it exits: every test process keeps its virtual display
(and its ScreenCaptureKit connection) for life, and two of those at once are what the lock has to
prevent. With two full `swift test` runs alternating test by test (the first design), replayd sat
at 80 to 95% CPU for 10 to 40 s around every capture, every capture test timed out, and the display
list took up to 3.9 s while both displays came online (20 October 2026). So a parallel run's Mac app
tests wait until the first run has exited (its other tests run meanwhile). The holder touches the
lock every 30 s; a lock whose holder has exited, or untouched for 5 minutes (a frozen process), is
broken, and a normal exit removes it. The tests that hold the turn have 10-minute time limits to
allow for the waiting; ScreenCaptureKit calls in them have 10 s deadlines (a request can be lost
for good when replayd drops its connection, and Swift Testing's time limit can't end an await that
ignores cancellation).

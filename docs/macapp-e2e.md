# Mac app sharing, end to end

`script/macapp-e2e.mjs` runs the whole journey of sharing a Mac app the way a person would, before a
person tries it: it builds the Orbit fixture (`Examples/macapp-orbit`), launches an isolated
OpenTraffic copy, shares Orbit with the copy's own `opentraffic` command through OpenTunnel, and
drives the shared page from headless Chrome through its public address. Every step saves a
screenshot; the run stops at the first failure, names the step and exits 1. Node only, no npm
packages; Chrome is driven over its DevTools protocol.

## Prerequisites

- **An isolated OpenTraffic copy**, never the OpenTraffic you use day to day. Build it once (and
  again after changing OpenTraffic) with its own bundle identifier, outside `/tmp` and `~/Library`
  (see [Benchmarks](macapp-benchmarks.md#against-a-real-share-of-the-orbit-fixture) for why):

  ```sh
  OPENTRAFFIC_CONFIGURATION=release OPENTRAFFIC_BUNDLE_ID=se.medda.opentraffic.e2e \
    OPENTRAFFIC_DIST_DIR=/Users/Shared/OpenTraffic-e2e ./script/build_and_run.sh --build-only
  ```

  Keep the default signing (your Apple Development certificate): the permissions below then stay
  with every rebuild. `--build` makes the script run this command itself.
- **Accessibility and Screen Recording for that copy** (it shows as "OpenTraffic (e2e)" in System
  Settings → Privacy & Security). Its `opentraffic permissions` walks through them.
- **Google Chrome** (`CHROME` points at another Chromium binary), Xcode's Swift toolchain (the
  fixture and a small display probe are compiled), and a network that reaches opentunnel.xyz.
- **A healthy window server.** The first step checks that `CGGetActiveDisplayList` answers in well under
  a second ([Hidden windows](macapp-window-hiding.md)); on a Mac where it takes seconds every timing is
  the window server's. Run one display-creating test at a time: not next to `swift test`'s fixture
  suites.
- **The copy isn't running.** The script launches it with its own home and API socket in the work
  folder and quits it at the end; it refuses to start when the copy already runs.

## Running it

```sh
node script/macapp-e2e.mjs                       # about 2 minutes
node script/macapp-e2e.mjs --work /tmp/ot-e2e    # keep everything in this folder
OPENTRAFFIC_E2E=1 swift test --filter MacAppEndToEndTests   # the same, from swift test
```

Options: `--app <OpenTraffic.app>` (default `/Users/Shared/OpenTraffic-e2e/OpenTraffic.app`), `--build`
(rebuild that copy first), `--via opentunnel|quick`, `--name <share>` (default "Orbit E2E"),
`--steps a,b` or `--skip a,b` (step names as printed; the set-up steps always run), `--keep`
(leave the share live and the copy running, to look at it afterwards; stop it with the command the
script prints), and `--card` (also press Allow and Take Back, and Build Again after a failed build,
on the share's Live Collaboration card: it opens the copy's window on your screen, and needs
Accessibility for the terminal that runs the script; when a full-screen app is in front, the window
opens on another Space where Accessibility can't read it, and those steps are skipped). `swift test` passes options in `OPENTRAFFIC_E2E_ARGS`.

The work folder (by default a new `ot-e2e-<time>` folder in the temporary folder) holds the fixture's
scratch copy, the copy's home and socket, Chrome's profile (deleted at the end), `shots/` with one
screenshot per step (plus the open sheet, alert and popover, the dark app, the 1100 px window and the
phone view), `orbit-home/` (the home Orbit saves its own orders in, which the copy reads its data from
through `OPENTRAFFIC_TEST_DATA_HOME`: the run never reads or writes Orbit's data in your Library), and
`summary.json` with every step's result and duration. At the end the shares are stopped, which removes
their OpenTunnel routes, and removed with their comments, and the copy quits (SIGTERM to the process the
script started). The copy's preferences aren't isolated by its home: the script then puts back what the
run changed in them (the scratch Orbit it remembered under `rememberedMacApps`, and `selectedTunnelID`).

## The steps

| Step | What it proves |
| --- | --- |
| display is healthy | `CGGetActiveDisplayList` answers in under a second |
| build the fixture | a scratch copy of `Examples/macapp-orbit` builds (`package.sh`) |
| Orbit saves its orders on its own | the scratch Orbit, run on its own with its home in the work folder, changes order #1001's note (`--set-note`, no window) and saves `Application Support/se.medda.orbit/orders.json` there |
| build the OpenTraffic copy | `--build` only; otherwise the existing copy is used |
| launch the copy | the copy starts with its own home and API socket and answers |
| share the fixture | `opentraffic share <Orbit.app> --via opentunnel --name … --collab` goes live; status says the app runs with collaboration on; the public URL answers |
| page loads with the collab toolbar and the window | at 1440 px the viewer connects, shows Orbit's window (pixels and 60+ elements, 30 orders), the bar names Orbit and the collaboration overlay and its toolbar are on the page |
| viewers see the host's saved orders | shared with data, the page shows order #1001 selected with the note Orbit saved (not the sample's Gift wrap); the copy's `orders.json` in its session home is the host's, and the status has no warning about data |
| the picker selects Add Order with a label naming it | with the comment tool, the element under the pointer is Add Order's; a comment is posted on it |
| the pinned comment is in opentraffic comments with the element's label | `opentraffic comments` has it, labelled Button “Add Order” |
| dark appearance | `opentraffic set --appearance dark` restarts the app dark (dark pixels); back to the viewer's choice it is light again. Skipped when the Mac uses Light (an app can only be dark while the Mac is) |
| selecting a row shows its order | a click on a customer's name selects the row; the detail pane shows that order |
| the toggle changes the app | Express shipping flips and stays flipped, and the order's total changes |
| the stepper changes the quantity | the stepper's upper half adds one |
| the segmented filter filters the list | Shipped lists the 10 shipped orders, All the 30 again |
| typing a customer and Add Order adds the order | a click in New customer, typing, Add Order: a 31st order with that name |
| the copy saves the change and the host's file stays as it was | the order added through the page is in the copy's `orders.json`; the host's file is byte for byte as Orbit saved it |
| scrolling the long list reaches its end | wheel events over the list bring the last order into view |
| a sheet opens and closes | Edit Address… opens the sheet as its own surface with its own pixels; Cancel closes it |
| an alert opens and is dismissed | Delete Order's alert shows; Cancel closes it and the order stays |
| a popover opens and is dismissed | Tracking's popover shows; Escape closes it |
| the app menu's action runs | Orders → Mark All Shipped from the viewer's menu bar: 0 open |
| a context menu item runs | a right click on an order's name shows its context menu; Duplicate adds an order |
| viewport resize resizes the window | at 1100 px the app's window is resized to the browser (not just scaled), and back at 1440 |
| phone view at 390 px | the Simple view replaces the window: Add Order and the orders as list items with their text, nothing wider than the phone |
| watch-only mode blocks input | `opentraffic set --control watch-only`: the bar says Watching only and a click changes nothing; `--control everyone` gives control back |
| ask to control: a second viewer asks | `--control ask`; a second viewer (a browser context of its own, so its own storage and collaboration id, named "E2E Asker") clicks Request Control and waits; `opentraffic status --json` lists the request (number, name, time) and the text status shows it; `opentraffic watch --json` reports `control.requested` |
| control allow lets the asker click, not the first page | `opentraffic control … allow <number>`: the asker's bar says You have control, the first page's names who has it; the asker's click on Express shipping changes the app (both pages see it), the first page's click doesn't; the status shows the holder |
| control take-back blocks the asker again | `control … take-back`: both pages watch and the asker's click changes nothing; a second take-back is refused (nobody has control) |
| control deny shows the asker the refusal | the asker asks again; `control … deny "E2E Asker"` (by name): its bar says The host said not now with Request Control; `allow` with nobody asking is refused; `--control everyone` again |
| the card's Allow and Take Back | `--card` only: the asker asks, the copy's window opens on the share (a GetURL Apple event to the copy's pid, never Launch Services), and Accessibility presses the card's Allow, then Take Back; the asker gets and loses control, and the status follows |
| Reset Data restores the orders | `opentraffic restart --reset-data`: the 30 orders and 20 open again, on the same page |
| Restart keeps the page connected | `opentraffic restart --app`: a new launch reaches the same page, which stays connected |
| an edited label is rebuilt and shows in the browser | the fixture's `Add Order` becomes `Add New Order` in its sources; OpenTraffic rebuilds and relaunches it and the page shows the new label |
| a broken build warns and keeps the previous version | the label becomes `Add Fixed Order` and a compile error goes into the same file; `opentraffic status --json` reports `macApp.build` `failed` with the compiler's `OrdersView.swift:<line>:<col>: error:`, its log (which has the error) and the command, the text status says so, the page shows the build banner and still the previous version's `Add New Order`, and `opentraffic watch --json` reports `build.started` then `build.failed` |
| the card's build warning and Build Again | `--card` only: the card shows "Orbit didn't build" with the error and an enabled Show Log; Accessibility presses Build Again, the card says Building…, and (the sources still broken) a new build fails again with a new log, `build.started` and `build.failed` again |
| fixing the build clears the warning and shows the new version | the compile error is removed: the page shows `Add Fixed Order` without reloading, the banner goes, the status is `idle` again, `watch` reports `build.started` then `build.succeeded`, and (with `--card`) the card's warning goes |
| WebKit | skipped: there is no headless WebKit without npm packages, and Safari's WebDriver drives the user's own Safari |
| no page errors | no JavaScript errors on the page |
| the host's saved orders are untouched | after everything above (restarts, Reset Data, rebuilds), the host's `orders.json` is unchanged and alone in its folder |
| Empty Data starts with the sample orders | the share is stopped and Orbit shared again with `--empty-data`: status says `empty`, the page shows the 30 sample orders and Gift wrap, not the host's note |

## Results

25 October 2026, Mac15,12 (Apple M3, 16 GB), macOS 27.0, Chrome 155, release copy of OpenTraffic
1.0.20+ (`se.medda.opentraffic.e2e`), OpenTunnel. Load average 13 to 30 from other work on the Mac.
All steps passed in 68 s (the rebuild step 17 s of it; Orbit's debug build and relaunch).

27 October 2026, the same Mac, Chrome 156, with the ask-to-control steps and `--card`: all steps
passed in 69 s (load average about 14). Asking, allow, take back and deny took 2 to 3 s each, the
card's Allow and Take Back 8 s (opening the window and reading it through Accessibility), the rebuild
10 s.

27 October 2026, the same Mac, with the failed-then-fixed rebuild: all steps passed in 88 s without
`--card` (the broken build reported in 4 s, the fix shown in 13 s), and in 177 s with `--card` under a
load average of 40 to 48 from other work (the failure in 5.5 s, Build Again's second failure 10 s, the
fix shown in 22 s).

28 October 2026, the same Mac, with Orbit saving its orders: all steps passed in 65 to 84 s without
`--card`; the copy showed the host's saved note, saved the page's new order in its own home, and the
host's file stayed byte for byte the same; the Empty Data share started in 4 to 5 s.

# Mac app mirror benchmarks

How fast a shared Mac app feels in the browser: how long a viewer waits after a press or a keystroke,
how long the first picture takes, and how much data the mirror sends, on this Mac and through a
tunnel. The numbers come from `script/macapp-bench.mjs`.

## What the harness measures

`script/macapp-bench.mjs` connects to a share's mirror socket (`/__opentraffic/macapp/ws`) like a
viewer does and speaks the [mirror protocol](macapp-mirror-protocol.md): it reads `hello`, `tree`,
`frame` and the binary tiles, and sends `act`, `text`, `setText` and `pointer` messages. Every time is
taken when the whole WebSocket message has arrived. Node only, no npm packages.

| Row | From | To |
| --- | --- | --- |
| connect: socket upgrade | opening the connection | the `101 Switching Protocols` answer (TCP, TLS and the proxy's checks) |
| connect: hello / first tree | opening the connection | the `hello`, the first `tree` |
| connect: first full frame | opening the connection | the last tile of the main window's first `full` frame |
| network: ping round trip | a WebSocket ping | its pong (the mirror server answers pings itself, so through a share this crosses the tunnel and the proxy) |
| press -> tree | `act press` on an element | the next `tree` of its window with a new `v` |
| press -> first tile | `act press` | the first tile of any window |
| press -> tile over element | `act press` | the first tile that covers the element: the moment a viewer can draw the changed pixels |
| keystroke -> tree | one `text` character | a `tree` where the field's value changed |
| keystroke -> tile over field | one `text` character | the first tile over the field (keystroke echo) |
| restart -> new hello / first full frame | starting `--restart-cmd` | the new boot's `hello`, its first full frame |

Bandwidth (tiles, kB and trees per second, average tile size) is measured idle (nobody touching the
app), while pressing, while typing, and while wheeling over the largest list. kB is 1000 bytes of
WebSocket traffic, headers included.

Before each press or keystroke the harness waits until no tile or tree has come for 250 ms
(`--quiet`), so the answer to the previous one isn't counted; samples that never got quiet are
listed as a note. A sample with no answer within 3 s (`--timeout`) is a miss, counted in its own
column. The defaults press the first checkbox it finds (pressing it an even number of times, so it
ends as it was), type into the first text field (cleared every 12 characters and put back at the
end), and wheel over the largest list, table or scroll area. `--press` and `--type-into` pick another
element by its key or a label it contains.

The harness never sends `viewport`, so it doesn't resize the app's main window or change its
appearance ([Viewer options](macapp-mirror-protocol.md#viewer-options)); keep browser viewers off the
share while it runs, since the first one's viewport and color scheme would resize or restart the app.
When the share's control is `watchOnly` or `askToControl` the server drops the harness's input, so it
skips the press, type and scroll phases and says so; set control to Everyone for a benchmark.

**What it leaves out.** The times end when the bytes reach the client, not when a browser has
decoded and painted them; decoding a 2-30 kB JPEG tile and drawing it on a canvas adds a few
milliseconds in Chrome. The ticket's first plan (headless Chrome, polling the canvas pixel under the
element) was dropped for this protocol-level measure: it needs no browser, runs against any URL,
and splits the time into network (ping) and app plus capture (press -> tree, press -> tile).

## Running it

```sh
node script/macapp-bench.mjs --self-test                                   # the harness against the stub
node script/macapp-bench.mjs http://127.0.0.1:52011                         # one share, local
node script/macapp-bench.mjs http://127.0.0.1:52011 https://orbit.opentunnel.xyz --json bench.json
```

It prints a table per URL (n, p50, p95, max, misses), a bandwidth table, a comparison table when it
is given several URLs, and a JSON summary (to stdout, or to the `--json` file). Options are listed
at the top of the script; the useful ones are `--samples` (30), `--password` for a share with a
password, `--restart-cmd` and `--phases connect,network,idle,press,type,scroll,restart`.

`--self-test` starts `script/macapp-viewer-stub.mjs --react` (the stub answers `act`, `setText`,
`text` and wheel events with a new tree and a tile, the way an app would) and runs every phase
against it, a restart included. It checks the harness; its numbers say nothing about OpenTraffic.

### Against a real share of the Orbit fixture

The fixture is `Examples/macapp-orbit` (an order list with a detail pane; order 1 is selected at
launch, so its "Express shipping" checkbox, the "New customer" field and the order list are what the
defaults find). Run it with an isolated OpenTraffic copy, never the one you use day to day:

1. Make sure the display subsystem is healthy: a `CGGetActiveDisplayList` probe should answer in
   about 50 ms (see [Hidden windows](macapp-window-hiding.md)). Don't benchmark a Mac where it takes
   seconds; every number would be the window server's.
2. Build the fixture and an isolated OpenTraffic copy (own bundle id, home and socket):

   ```sh
   sh Examples/macapp-orbit/package.sh                      # dist/Orbit.app
   OPENTRAFFIC_CONFIGURATION=release OPENTRAFFIC_BUNDLE_ID=se.medda.opentraffic.e2e \
     OPENTRAFFIC_DIST_DIR=~/Library/Developer/OpenTraffic-e2e OPENTRAFFIC_SIGNING_IDENTITY=- ./script/build_and_run.sh --build-only
   ```

   Not in `/tmp`: macOS doesn't register apps in temporary folders, so System Settings can't list
   the copy and its permissions can't be seen or reset there. The copy shows as "OpenTraffic (e2e)";
   its Permissions for Mac Apps window (`opentraffic permissions`) walks through granting them.
   Launch the copy with `CFFIXED_USER_HOME=/tmp/ot-bench/home` and
   `OPENTRAFFIC_SOCKET=/tmp/ot-bench/ot.sock`, from a terminal that has Accessibility and Screen
   Recording. Benchmark the release configuration: an unoptimized debug build can't compare Retina
   frames fast enough and its numbers are meaningless.
3. Share Orbit through OpenTunnel with the copy's command:

   ```sh
   export OPENTRAFFIC_SOCKET=/tmp/ot-bench/ot.sock
   ~/Library/Developer/OpenTraffic-e2e/OpenTraffic.app/Contents/MacOS/opentraffic-cli share Examples/macapp-orbit/dist/Orbit.app --via opentunnel --name Orbit
   ```

   It prints the public URL (`https://….opentunnel.xyz`). `--via quick` (trycloudflare.com) works the
   same where that service isn't blocked.
4. Find the local addresses. The share's proxy and the mirror server both listen on loopback ports
   of the OpenTraffic copy; the proxy also serves `/__opentraffic/collab.js`, the mirror server
   doesn't:

   ```sh
   for p in $(lsof -nP -a -p "$(pgrep -f ~/Library/Developer/OpenTraffic-e2e/OpenTraffic.app/Contents/MacOS/OpenTraffic)" -iTCP -sTCP:LISTEN | awk 'NR>1 {sub(/.*:/,"",$9); print $9}'); do
     printf '%s mirror:%s proxy:%s\n' "$p" \
       "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$p/__opentraffic/macapp/viewer.js)" \
       "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$p/__opentraffic/collab.js)"
   done
   ```

5. Run the harness: the mirror server directly, the proxy on loopback, then the tunnel, with a
   restart through the CLI:

   ```sh
   node script/macapp-bench.mjs http://127.0.0.1:<mirror port> http://127.0.0.1:<proxy port> https://<name>.opentunnel.xyz \
     --label mirror --label proxy --label opentunnel \
     --restart-cmd "~/Library/Developer/OpenTraffic-e2e/OpenTraffic.app/Contents/MacOS/opentraffic-cli restart Orbit --app" \
     --json /tmp/ot-bench/bench.json
   ```

6. Stop the share (`opentraffic-cli stop Orbit`), quit the copy, and remove what it left: the
   OpenTunnel route it made under your address, the `se.medda.opentraffic.e2e` preferences and
   `/tmp/ot-bench`.

Copy the tables into Results below with the date, the machine and the build.

## Targets

| What | Target |
| --- | --- |
| Press -> tile over element, local (p50) | under 120 ms; if not, this page names what dominates |
| The mock it replaces (`/tmp/swiftui-mirror`, polled JPEG) | about 300 ms click to pixel (the ticket's figure, not re-measured here) |
| Through a tunnel | the local time plus about one network round trip (the ping row) |
| Idle | close to 0 tiles per second when the app doesn't change |

## Results

### Real app (Orbit fixture)

25 October 2026, Mac15,12 (Apple M3, 8 cores, 16 GB), macOS 27.0, Node 22, one built-in display.
The mirror server and the proxy ran in the test runner (`swift test -c release`, which has
Accessibility and Screen Recording; the same `MacAppSession` and `CollabProxy` the app uses),
serving `Examples/macapp-orbit/dist/Orbit.app` as an isolated copy with empty data; the restart
command restarted the session. 30 presses and 30 keystrokes, 5 connects, 20 pings. The OpenTunnel
column waits for an OpenTraffic test copy with the two permissions granted (the steps above).

| Row (p50 / p95 ms) | mirror (local) | proxy (local) | OpenTunnel |
| --- | --- | --- | --- |
| connect: first full frame | 18.2 / 20.5 | 21.2 / 24.3 | not yet measured |
| network: ping round trip | 0.6 / 1.4 | 0.9 / 2.2 | not yet measured |
| press -> tree | 60.9 / 99.5 | 60.3 / 85 | not yet measured |
| press -> tile over element | 36.5 / 94.4 | 35.9 / 68.9 | not yet measured |
| keystroke -> tile over field | 44.8 / 64.2 | 47 / 70.4 | not yet measured |
| restart -> first full frame | 1225 (n=1) | 964 (n=1) | not yet measured |
| idle kB/s, tiles/s | 74, 0.4 (two full frames in 5 s) | 37, 0.2 | not yet measured |
| scrolling kB/s, tiles/s | 2156, 20 (83 kB per tile) | 2144, 23 | not yet measured |

The first full frame of the 1020 by 660 point window is 184 kB (scale 2). Pressing costs about
100 kB/s and typing about 85 kB/s. A debug build of the same host (`swift test`) gave press ->
tile over element 47.7 / 86.4 ms direct and 41.5 / 76.9 ms through the proxy.

What dominates: the tile comes before the tree. Press -> tile over element (36 ms) is the app's
redraw plus ScreenCaptureKit's next frame and the JPEG tile; press -> tree (61 ms) adds the
accessibility read of the whole window, which the tile doesn't wait for. The proxy adds nothing
measurable on loopback. Two things to look at: when the app is idle the mirror still sends a full
frame now and then (two in 5 s here, 184 kB each), and scrolling the long list sends 83 kB tiles
at 20 per second (2 MB/s), which a tunnel can't carry; smaller tiles or a lower rate while
scrolling would help there.

### Harness self-test (the stub, not product performance)

`node script/macapp-bench.mjs --self-test`, 20 October 2026, Mac15,12 (Apple M3, 8 cores, 16 GB),
macOS 27.0, Node 22.23.3, with other agents' work running on the Mac. The stub answers at once from
memory and sends recorded JPEG tiles; these numbers only show that every phase is measured.

| Row | n | p50 ms | p95 ms | max ms | misses |
| --- | --- | --- | --- | --- | --- |
| connect: socket upgrade | 5 | 2.6 | 6.1 | 6.1 | 0 |
| connect: first full frame | 5 | 3 | 6.5 | 6.5 | 0 |
| network: ping round trip | 20 | 0.8 | 4.3 | 7.7 | 0 |
| press -> tree | 30 | 1.5 | 8.8 | 15.7 | 0 |
| press -> tile over element | 30 | 1.7 | 8.8 | 15.7 | 0 |
| keystroke -> tree | 30 | 6.3 | 27.5 | 29.7 | 0 |
| keystroke -> tile over field | 30 | 6.8 | 27.9 | 29.7 | 0 |
| restart -> first full frame | 1 | 828.8 | 828.8 | 828.8 | 0 |

Bandwidth against the stub: idle 0 tiles/s; pressing 4 tiles/s, 27.5 kB/s; typing 4.1 tiles/s,
26.6 kB/s; scrolling 17.8 tiles/s, 30.7 kB/s (one tile per wheel event). The first full frame is
31.1 kB. On the busy Mac these vary from run to run (an earlier run had restart 89 ms and keystroke
p50 0.8 ms); the restart row is mostly the time to start `curl`, the self-test's restart command.

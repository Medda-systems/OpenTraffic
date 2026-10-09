# Capturing the demo

The demo video and the README's pictures are made from the real app, not drawings of it. A debug
build shows its views in windows behind the desktop picture (see `Sources/OpenTraffic/Support/DemoCapture.swift`),
so capturing never takes over the screen or touches your own OpenTraffic.

1. Build a separate copy, so its settings don't mix with yours:

   ```sh
   OPENTRAFFIC_BUNDLE_ID=se.medda.opentraffic.demo OPENTRAFFIC_DIST_DIR=/tmp/ot-demo-app \
     OPENTRAFFIC_SIGNING_IDENTITY=- ./script/build_and_run.sh --build-only
   ```

2. Start Orbit's demo servers (ports 5175, 3002, 4400) with `node servers.mjs`, then `./launch.sh`.
   The copy keeps its data in `/tmp/ot-demo-home`, lists only the demo ports, and uses its own
   OpenTunnel profile, `opentraffic-demo`.

3. Capture a window with `./shot.sh <popover|main|newTunnel> <file.png> '<command>'`, where the command
   is JSON like `{"select": "Orbit", "tab": "feedback", "appearance": "light", "newTunnel": "quick"}`.
   Share Orbit through the local API (token in `/tmp/ot-demo-home/Library/Application Support/OpenTraffic/api-token`):

   ```sh
   curl -X POST -H "authorization: Bearer $TOKEN" -d '{"port":5175,"provider":"opentunnel","name":"Orbit","collaboration":true}' \
     http://127.0.0.1:47799/v1/shares
   ```

4. Record a session on the shared page with `node record-session.mjs <public-url> <token>`: three headless
   Chromes (Ava watches and opens the comment, Lea picks an element and comments, Sam points), with Ava's
   and Lea's screens saved frame by frame to `/tmp/ot-session`. It records in slow motion (the pages'
   animations, transitions, and timers run ten times slower) so the result plays back smoothly at 30 fps;
   it takes about ten times as long as the session. `node collab-driver.mjs <url> <token> presence <seconds>`
   just keeps three people on the page while you capture the app. Restart the app first and people get
   the same colours in every session (orange, blue, green, in joining order).

5. Copy the captures into `remotion/public/capture/`: the session to `session/` (`ava/`, `lea/`,
   `session.json`), the app windows next to it (`popover-before.png`, `popover-live.png`,
   `main-overview.png`, `main-feedback.png`), and the promo's dark captures to `promo/` (see the names in
   `promo/Promo.tsx`). Then `npm run video`, `npm run video:gif`, and `remotion still … Stills` for the
   README's pictures, and `npm run promo` for the promo, which makes its sound effects and music
   (`audio/sfx.py`, `audio/music.py`), renders, and masters the sound to -14 LUFS.

Afterwards remove the demo tunnel with `opentunnel --profile opentraffic-demo delete --yes`.

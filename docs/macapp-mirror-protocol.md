# Mac app mirror protocol (v1)

How a shared Mac app's window reaches a browser. The **mirror server** (`MirrorServer`, one per
session) runs next to the real app on the host's Mac; the **viewer** (`macapp-viewer.html/.js/.css`)
runs in the browser. This page is the whole contract: the viewer can be written from it alone.
The Swift side of it is `Sources/OpenTrafficCore/MacApp/MirrorProtocol.swift` (`MirrorProtocol.*`),
tested in `Tests/OpenTrafficCoreTests/MacAppProtocolTests.swift`; change all three together.

## Origin and HTTP

The mirror server listens on a loopback port per session (`http://127.0.0.1:<port>`). In a share it is
the upstream of CollabProxy, so viewers reach it through the share URL with the collaboration overlay.

| Request | Answer |
| --- | --- |
| `GET /` | The viewer page (HTML, so CollabProxy injects `bridge.js` and `collab.js` into it like any page) |
| `GET /__opentraffic/macapp/viewer.js` | The viewer script |
| `GET /__opentraffic/macapp/viewer.css` | The viewer styles |
| `GET /__opentraffic/macapp/icon.png` | The app's icon |
| `GET /__opentraffic/macapp/snapshot.png?window=<id>` | The window's full current frame as PNG |
| WebSocket `/__opentraffic/macapp/ws` | Everything live, below |

All mirror paths start with `/__opentraffic/macapp/`; a proxy in front passes that prefix through
untouched. The WebSocket refuses (403) pages from other sites: its `Origin` must be a loopback address,
the request's own `Host`, or an origin the session allows, so a proxy that rewrites `Host` must have
the share's public origin allowed.

The share's proxy marks the WebSocket of the host's own page (opened with Open as Host) with the
request header `X-OpenTraffic-Host: 1` and removes that header from everyone else's requests. The
mirror server only listens on loopback, and pages can't set headers on a WebSocket, so only the proxy
(or another program of the host's) can send it. That viewer controls the app in every control mode.

## WebSocket rules

- Server to client: JSON **text** messages, plus **binary** messages that carry frame tiles (only
  ever right after a `frame` message). Client to server: JSON text messages only.
- Every JSON message is an object with its type in `t`.
- **Optional fields are always written**, as `null` when absent, so readers see `null`, never
  `undefined`. Readers treat a missing optional field as `null` (or as the default named below).
- **Unknown fields are ignored** and **unknown `t` values are ignored** (not errors) on both sides, so
  later versions only add fields and messages.
- Ids: window ids are unsigned 32-bit integers. All geometry is in **points** (not pixels).
- Several viewers can be connected to one app at once; each gets the full stream.

On connect the server sends `hello`, then a full `tree` for every window, then a full `frame` for every
window, then live updates.

## Server to client

### `hello`

```json
{"t":"hello","boot":"6F1C7D0E-2D7B-4E55-9C59-0B5A3C1D2E3F","scale":2,"appearance":"dark","app":{"name":"Orbit"},
 "windows":[{"id":1,"title":"","w":860,"h":572,"x":0,"y":0,"kind":"main","parent":null,"focused":false}]}
```

- `boot`: a UUID per app launch. If it differs from the `boot` the viewer saw before (after a
  reconnect), the app restarted: clear the layer, every window and every canvas.
- `scale`: the backing scale of the frames. A tile of `w`×`h` points is an image of `w*scale` by
  `h*scale` pixels. Draw canvases at CSS size `w`×`h` with a backing store `scale` times larger.
- `appearance`: `"dark"` or `"light"`, the app's current appearance.
- `app.name`: the app's display name.
- `app.device` (only for an iPhone app shared from the iOS Simulator): `{"name":"iPhone 17","screen":{"x":38,"y":92,"w":402,"h":874,"radius":62}}`.
  The main window is then the Simulator's window for that device, and `screen` is where the device's
  screen is in it (window points; `radius` its corner radius). The viewer shows only the screen, in a
  phone frame; coordinates stay the window's, so taps, trees and comments are unchanged. `screen` is
  absent when OpenTraffic couldn't find the screen (the viewer then shows the whole window). Trees hold
  only the elements on the screen; `pointer` presses are touches, a run of `wheel` events is one finger
  drag, right clicks are ignored, and `windowAction` `close` does nothing.
- `windows`: as in `windows` below.

### `windows`

```json
{"t":"windows","windows":[
  {"id":1,"title":"","w":860,"h":572,"x":0,"y":0,"kind":"main","parent":null,"focused":false},
  {"id":2,"title":"","w":380,"h":154,"x":240,"y":28,"kind":"sheet","parent":1,"focused":true}]}
```

The full window list, sent whenever a window appears, moves, resizes, closes or takes the focus. A
window missing from the list is gone: remove its surface and layer. Every window in the list is a
surface of its own: it has its own `tree`, its own `frame`s and tiles, and takes its own input (the
`window` of client messages). The main window comes first; a sheet, alert, popover or menu comes after
the window it belongs to, so list order is also stacking order (later is in front).

| Field | Meaning |
| --- | --- |
| `id` | Window id (UInt32); the same id in `tree`, `frame`, tiles and client messages |
| `title` | The window's title, `""` when none |
| `w`, `h` | Size in points |
| `x`, `y` | Position in points relative to the main window's top-left (the main window is at 0,0), where the app has it on the host |
| `kind` | `main`, `sheet`, `alert`, `popover`, `menu` or `window` (a second ordinary window or a panel) |
| `parent` | The id of the window a sheet/alert/popover/menu belongs to, else `null` |
| `focused` | Whether this is the app's key window, where typing goes: the window the app has in front, or the sheet or alert on it while one is up |

What each kind is and where the viewer draws it:

| `kind` | What it is | Where |
| --- | --- | --- |
| `main` | The app's main window, kept as the main one while it exists | The page's window |
| `window` | A second window or panel (`Window > Statistics`) | Beside the main window, top-aligned; one at a time as tabs when side by side would make everything much smaller |
| `sheet` | A sheet attached to `parent` (a SwiftUI `.sheet`, an AppKit sheet) | At its `x`,`y` over its window (under the title bar) |
| `alert` | An alert: one shown as a sheet (SwiftUI `.alert`, `NSAlert` sheets), or an app-modal alert window | Centred over `parent`; an alert sheet keeps its `y` |
| `popover` | A popover anchored in `parent` | At its `x`,`y`; it may stick out of its window |
| `menu` | A menu the app popped up (a context menu, a pop-up button's menu); its items come in `menu.context` | At its `x`,`y`; a viewer that draws `menu.context` as its own menu hides these pixels while it does |

Sheets, alerts and popovers are found in their window's accessibility tree (they are windows of their
own there) and are left out of that window's `tree`; second windows and app-modal alerts are the
app's other windows; a menu is the app's window at the pop-up-menu level. All of them stay on the
host's off-screen display, like the main window. Older servers sent only `main`.

### `tree`

```json
{"t":"tree","window":1,"v":"9f3a01c2","nodes":[
  {"key":"/Window:","role":"AXWindow","label":"","value":null,"x":0,"y":0,"w":860,"h":572,"depth":0,
   "enabled":true,"focused":false,"selected":false,"actions":[]},
  {"key":"/Window:/Group:/Button:Add Order","role":"AXButton","label":"Add Order","value":null,
   "x":226,"y":530,"w":86,"h":24,"depth":2,"enabled":true,"focused":false,"selected":false,"actions":["press"]}]}
```

A **full snapshot** of one window's accessibility tree; there are no deltas in v1. Replace the
window's layer with it, reconciling by `key` (reuse elements whose key survives). `v` identifies the
content: two snapshots with the same `v` are identical. Nodes come in document order (a parent before
its children).

| Field | Meaning |
| --- | --- |
| `key` | Stable id of the element, see [Node keys](#node-keys) |
| `role` | The raw AX role string, passed through: `AXButton`, `AXCheckBox`, `AXTextField`, `AXSecureTextField`, `AXStaticText`, `AXRadioButton`, `AXIncrementor`, `AXRow`, ... |
| `label` | The element's name (AXDescription, else AXTitle, else the value of static text); `""` when none |
| `value` | The value as a string (checkboxes and radio buttons `"0"`/`"1"`, text fields their text, steppers the number), or `null` |
| `x`, `y`, `w`, `h` | Frame in points relative to **this window's** top-left; all four `0` when the element is out of sight (no size, or wholly outside the window or a scroll area around it). An element scrolled out of view (like a list row) keeps its node and key but its contents are left out until it scrolls in |
| `depth` | 0 for the window, 1 for its children, ... |
| `enabled`, `focused`, `selected` | AXEnabled, AXFocused, AXSelected |
| `actions` | The protocol actions the element supports, from: `press`, `increment`, `decrement`, `confirm`, `cancel`, `showMenu`, `scrollToVisible` |

The action names map to AX actions: `press` AXPress, `increment` AXIncrement, `decrement`
AXDecrement, `confirm` AXConfirm, `cancel` AXCancel, `showMenu` AXShowMenu, `scrollToVisible`
AXScrollToVisible. Other AX actions are not part of the protocol.

### `frame` and binary tiles

```json
{"t":"frame","window":1,"seq":12,"full":false,"tiles":3}
```

Announces that exactly `tiles` binary messages follow, each one tile of window `window`. `seq` counts
frames per window. `full: true` means the tiles cover the whole window (the first frame, and after a
resize); otherwise they are only the parts that changed. Paint each tile at its `x`,`y` in the
window's canvas.

Each binary message is a 17-byte header followed by the encoded image. All integers are
**big-endian** (network order, `DataView`'s default):

| Offset | Type | Field |
| --- | --- | --- |
| 0 | UInt32 | `window` |
| 4 | UInt32 | `seq` (equals the preceding `frame`'s `seq`) |
| 8 | UInt16 | `x` (points, from the window's top-left) |
| 10 | UInt16 | `y` |
| 12 | UInt16 | `w` (points; the image is `w*scale` by `h*scale` pixels) |
| 14 | UInt16 | `h` |
| 16 | UInt8 | `format`: 0 JPEG, 1 WebP |
| 17 | bytes | the image, to the end of the message |

```js
socket.binaryType = "arraybuffer";
function readTile(buffer) {
  const v = new DataView(buffer);
  const type = v.getUint8(16) === 1 ? "image/webp" : "image/jpeg";
  return {
    window: v.getUint32(0), seq: v.getUint32(4),
    x: v.getUint16(8), y: v.getUint16(10), w: v.getUint16(12), h: v.getUint16(14),
    image: new Blob([new Uint8Array(buffer, 17)], { type }),
  };
}
// createImageBitmap(tile.image) then ctx.drawImage(bitmap, x*scale, y*scale) on the window's canvas.
```

### `cursor`

```json
{"t":"cursor","shape":"pointer"}
```

The app's cursor: `default`, `pointer`, `text` or `grab`. Map to the same CSS `cursor` names.

### `status`

```json
{"t":"status","state":"restarting","message":"Rebuilt; restarting Orbit"}
```

`state` is `running`, `restarting`, `crashed` or `stopped`; `message` is a human sentence or `null`.
Show a banner for anything but `running`.

### `menu`

```json
{"t":"menu","bar":[
  {"title":"Orbit","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[
    {"title":"About Orbit","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[]}]},
  {"title":"Orders","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[
    {"title":"Mark All Shipped","enabled":true,"checked":false,"shortcut":"⇧⌘S","separator":false,"items":[]},
    {"title":"","enabled":false,"checked":false,"shortcut":null,"separator":true,"items":[]},
    {"title":"Filter","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[
      {"title":"All","enabled":true,"checked":true,"shortcut":null,"separator":false,"items":[]}]}]}],
 "context":null}
```

The app's menu bar and the menu it has popped up, if any. Sent on connect once the menus have been
read (after the trees, before the frames) and again whenever either changes; servers without menus
never send it.

`bar` lists the app's top-level menus in order. The first is the app's own menu, titled with its name
(on a Mac the bold name in the menu bar). Each menu item:

| Field | Meaning |
| --- | --- |
| `title` | The item's title (`""` for a separator) |
| `enabled` | Whether it can be chosen now |
| `checked` | Whether it shows a checkmark |
| `shortcut` | The key equivalent as macOS shows it, or `null`: modifiers in the order `fn` `⌃` `⌥` `⇧` `⌘`, then the key: a capital letter, a digit or punctuation, `Space`, `F1`…`F19`, or a symbol (`↩` `⌤` `⎋` `⌫` `⌦` `⇥` `←` `→` `↑` `↓` `↖` `↘` `⇞` `⇟`) |
| `items` | A submenu's items (`[]` for a plain item); a submenu is never chosen itself, and has no `shortcut` |
| `separator` | A line between groups of items |

The server leaves out what reaches beyond the shared app or would take its window away from the
viewers: the Apple menu (the host's Mac), Services, AutoFill, Dictation, Emoji & Symbols, Hide,
Hide Others, Show All, Quit, full screen, minimize and window tiling. It can't choose them either.
Menus are read through Accessibility, and some apps update an item's checkmark or enabled state only
when the menu is about to open on screen, so those two may lag behind the app.

`context` is `null`, or the menu the app has popped up (a context menu after a right click, a pop-up
button's menu):

| Field | Meaning |
| --- | --- |
| `window` | The window it belongs to |
| `x`, `y` | Its top-left corner in points relative to that window's top-left; show the menu there |
| `items` | Its items, as above |

While the app has a menu open it waits for an answer: choose an item or close it with `menuAction`
(below). A press anywhere else in the viewer should close it (and, as on a Mac, go no further).
Viewers see the same context menu, whoever right-clicked.

### `control`

```json
{"t":"control","mode":"askToControl","you":false,"requested":true,"holder":"Ada"}
```

Who may control the app, as the host chose (see [Viewer options](#viewer-options)). Sent after `hello`
(and `status`) when the mode isn't `everyone`, and again to each viewer whenever what it says for that
viewer changes. A viewer that never got one controls the app, as with `everyone`.

| Field | Meaning |
| --- | --- |
| `mode` | `everyone` (every viewer controls the app), `watchOnly` (viewers see it, their input is dropped), `askToControl` (only the viewer the host allowed) |
| `you` | Whether this viewer's input reaches the app now |
| `requested` | Whether this viewer asked for control (`requestControl`) and the host hasn't answered yet; `false` again after a no |
| `holder` | `askToControl`: the name of the viewer who has control (`"A viewer"` when it gave none), `null` when nobody has it; `null` in the other modes |
| `refused` | `askToControl`, and only sent when `true`: the host turned this viewer's latest request down (the viewer says so); gone once it asks again or the mode changes |

A viewer without control sends no input (`act`, `pointer`, `text`, `key`, `setText`, `menuAction`,
`windowAction`); the server drops any it gets anyway. It should not show the effect of input either
(no optimistic presses, read-only fields, no menus or close buttons), and it says why: watching only,
or a Request Control button in `askToControl`.

## Client to server

The server applies a connection's messages in order. It never takes raw accessibility handles from
the client: `key`s are resolved against the window's **latest** snapshot, and a key that no longer
exists is ignored.

| Message | Meaning |
| --- | --- |
| `{"t":"act","window":1,"key":"/Window:/Group:/Button:Add Order","action":"press"}` | Perform an action (one of the node's `actions`) on the node |
| `{"t":"pointer","window":1,"kind":"move","x":10,"y":20,"dx":0,"dy":-30,"modifiers":["shift"]}` | A pointer event at window-relative points |
| `{"t":"text","window":1,"text":"Ada"}` | Type Unicode text at the app's current focus |
| `{"t":"key","window":1,"code":"Enter","modifiers":["cmd"]}` | Press one named key |
| `{"t":"setText","window":1,"key":"/Window:/Group:/TextField:Customer","value":"Ada Lovelace"}` | Replace a field's whole value (the server focuses it, selects all, types) |
| `{"t":"viewport","w":1200,"h":700,"appearance":"dark"}` | The room the viewer has for the main window, in CSS pixels (the area under its bar less margins), and its `prefers-color-scheme` (`dark`, `light` or `null`). Sent once after every `hello` and when either changes (a resized browser after a short pause). `0` by `0`: no size wish (the Simple view), only the color scheme counts |
| `{"t":"menuAction","path":["Orders","Mark All Shipped"],"context":false}` | Choose a menu item by its titles, from the menu bar down; with `"context":true` from the open context menu down (`["Duplicate"]`), and an empty `path` closes the context menu without choosing |
| `{"t":"windowAction","window":2,"action":"focus"}` | `focus`: bring a window to the front as the app's key window, so typing goes there (a viewer sends it when it shows a window's tab, or before a press in a window that isn't the focused one); `close`: close it like its close button (a popover is dismissed, a menu closed). The main window is never closed |
| `{"t":"requestControl","name":"Ada","client":"q9X…"}` | Ask the host for control (`askToControl`). `name` (or `null`) is how the host's notice names the viewer; `client` (or `null`) is an opaque id the page keeps (the collaboration overlay's own, 8 to 128 letters, digits, `-`, `_`): a page that had control and reconnects sends `requestControl` again with it and gets control back at once |
| `{"t":"releaseControl"}` | Give control back, or take back a request still waiting |

- `pointer.kind`: `move`, `down`, `up`, `rightdown`, `rightup`, `wheel`. `dx`/`dy` are wheel
  deltas in points (positive `dy` scrolls content down, as in DOM `WheelEvent.deltaY`) and `0` for the
  other kinds; the client may omit `dx`, `dy` and `modifiers`.
- `key.code`: `Enter`, `Escape`, `Tab`, `Backspace`, `Delete`, `ArrowUp`, `ArrowDown`, `ArrowLeft`,
  `ArrowRight`, `Space` (DOM `KeyboardEvent.key` names, with `Space` for `" "`).
- `modifiers` (pointer and key): any of `cmd`, `shift`, `alt`, `ctrl`; may be omitted (`[]`).
- `menuAction.context` may be omitted (`false`). A path that doesn't lead to an item the `menu`
  message offered, or to a disabled item, is ignored. Titles are matched exactly; with two items of
  the same title in one menu the first is chosen.
- A right click is `pointer` `rightdown` then `rightup`; if the app pops up a context menu, a `menu`
  message with `context` follows (usually within half a second). `act` `showMenu` opens an element's
  context menu the same way, for viewers without a right button.
- **Menu shortcuts.** Cmd key combinations sent as `key` events don't reach an app that isn't the
  frontmost app on the host's Mac, so a viewer sends a shortcut that belongs to a menu item as that
  item's `menuAction`. The viewer page matches the key event against the `shortcut` of every item:
  letters and digits by `KeyboardEvent.code` (`KeyS`, `Digit1`) with Shift exactly as listed,
  named keys by `KeyboardEvent.key` (`↩` is `Enter`), punctuation by `KeyboardEvent.key` (Shift may be
  what types it). It leaves copy, cut and paste to the browser (the host's clipboard is no use to a
  viewer), and select all and undo too while one of its fields has focus.

## Viewer options

The host decides three things on the share's card; the server and the session apply them.

**Control** (`control` above). `everyone` is the default. In `watchOnly` every viewer only watches. In
`askToControl` a viewer sends `requestControl`; the host sees who asks (a notice on the card with
Allow, and a notification; `opentraffic status`, the API's `macApp.control` and its `control.requested`
event) and may allow one viewer at a time, or turn the request down (`refused`). Control stays with that viewer until
the host takes it back, the viewer sends `releaseControl`, or the host changes the mode (which also
drops waiting requests). A viewer with control that disconnects keeps it while away when its
`requestControl` carried a `client` id, and gets it back when it returns; without one it loses it.
Input is checked as it arrives, so messages already queued when control moves still apply. The
host's own page always controls the app (see Origin and HTTP).

**Window size.** `fitViewer` (the default): the server sizes the app's **main** window through
Accessibility (AXSize) to the leading viewer's `viewport`, in whole points (CSS pixels are points at
scale 1), at least 200×150, at most what fits the off-screen display (1840×1100 on its 1920×1200
points). An app's own minimum wins: the first resize it refuses shows its minimum, and later ones
don't ask for less. A size that would make the window reach one of the host's screens (a window the
app placed elsewhere on the display) isn't asked for. Second windows, sheets, alerts and popovers keep
their size. A resize waits for
150 ms of quiet, and the new size reaches viewers as a `windows` message and a full `frame`. `app`:
the window keeps (or gets back) the size it had before any viewport changed it, and viewers scale it
down to fit.

**Appearance.** `viewer` (the default): the app shows in the first viewer's color scheme; `mac`: this
Mac's; `light` or `dark`. An app reads its appearance when it starts, so the session launches the copy
with it and restarts it (same data, same address, a `restarting` status, then a new `hello` whose
`appearance` says it) when the wanted appearance changes: once when the first viewer's scheme differs,
and when the host picks another. Light works whatever the Mac uses (the launch argument
`-NSRequiresAquaSystemAppearance YES`); dark only while this Mac uses Dark: AppKit takes the dark
appearance from the account's global preferences, which no launch argument or per-app preference
overrides (`-AppleInterfaceStyle Dark` changes what the app's defaults read, not how it looks), and the
copy shares the account's preferences daemon. A wish for dark on a light Mac leaves the app light, and
the card says why.

**Several viewers.** The first viewer wins: the main window follows the `viewport` of the viewer
that connected first (of those connected and with a size wish), or of the viewer the host gave
control in `askToControl`; when it leaves, the next one leads. The appearance follows the first
viewer that sent a color scheme in the session, and doesn't change when other viewers come or go.
Everyone else sees the same window, scaled down to fit their page (never up).

## Node keys

A key names an element by its path from the window, so it survives re-snapshots:

- One segment per level: `/<role without the AX prefix>:<label>`. The main window itself is always
  `/Window:` (its title is left out, so keys survive a title change).
- Keys are unique across all of the app's windows, so DOM ids never collide: a second window's root
  is `/Window:<title>` (`/Window:Statistics`; `#2`, `#3` on windows that would share one, so an
  untitled one is `/Window:#2`), and a sheet, alert or popover keeps the key it has in its parent's
  tree, its elements continuing from it (`/Window:/Sheet:/Group:/Button:Save`,
  `/Window:/Group:/Button:Tracking/Popover:/Group:/StaticText:Tracking`). A comment pinned to a sheet's
  button finds it again the next time the sheet opens.
- The label is cut to 40 characters; runs of whitespace (newlines, tabs) become one space and `/`
  becomes `∕` (U+2215), so a label never splits the path. An element without a label ends in `:`.
- When siblings would have the same segment, the second gets `#2`, the third `#3`, and so on; the
  first keeps the bare segment.

Examples: `/Window:/Group:/Button:Add Order`, `/Window:/Group:/List:/Row:Grace Hopper#2`,
`/Window:/Sheet:alert/Button:Delete`, `/Window:Statistics/Group:/StaticText:Revenue`.

The viewer treats keys as opaque strings. The DOM id of a node's element is `ax-` + the djb2 hash of
the key over its UTF-16 code units, as an unsigned 32-bit number in base 36:

```js
function domId(key) {
  let h = 5381;
  for (let i = 0; i < key.length; i++) h = ((h << 5) + h + key.charCodeAt(i)) >>> 0;
  return "ax-" + h.toString(36);
}
domId("/Window:/Group:/Button:Add Order"); // "ax-3tt01y"
```

`MirrorProtocol.NodeKey.domID(for:)` computes the same id in Swift (tests pin both to the same
values), so a comment pinned to `#ax-3tt01y` finds the same element on the host side.
